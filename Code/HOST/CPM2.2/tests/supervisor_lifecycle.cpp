// Runs the assembled transient-supervisor lifecycle in libqkz80.
//
// Memory is the shipped mode-11 view: ROM page 0 (common memory) with the
// bank-7 payload, ZSDOS and the pristine CCP included, over 2000h-DFFFh.  Ports
// are mocked and the latch is not modelled.  Device and teardown routines are
// stubbed and recorded in order, so the test checks WHAT runs and in WHICH
// order without modelling the V9958, CTC, SIO or FS2 hardware.  Everything the
// supervisor milestone changed runs as assembled: BOOT, WBOOT, the BDOS facade,
// the BDOS 219 loader, the supervisor, ZSDOS function 0, and the CCP shim.
//
// Not covered here (hardware acceptance): the real provider, FS2 CWD
// persistence, console recovery and the real A:ZSH.COM load.
#include <qkz80/qkz80.h>
#include <algorithm>
#include <fstream>
#include <functional>
#include <iostream>
#include <map>
#include <stdexcept>
#include <string>
#include <vector>
using namespace std;

static void require(bool ok, const string &why) { if (!ok) throw runtime_error(why); }
static string hex4(unsigned v) { char b[8]; snprintf(b, sizeof b, "%04Xh", v & 0xffff); return b; }

struct CPU : qkz80 {
    vector<pair<unsigned, unsigned>> writes;
    explicit CPU(qkz80_cpu_mem *m) : qkz80(m) { set_cpu_mode(MODE_Z80); }
    void port_out(qkz80_uint8 p, qkz80_uint8 v) override { writes.emplace_back(p, v); }
    qkz80_uint8 port_in(qkz80_uint8) override { return 0; }
    void block_io(qkz80_uint8 opcode) override {
        if (opcode == 0x79) { port_out(regs.BC.get_low(), regs.AF.get_high()); return; }
        throw runtime_error("unsupported port opcode " + to_string(opcode));
    }
    void unimplemented_opcode(qkz80_uint8, qkz80_uint16 pc) override {
        throw runtime_error("unsupported instruction at " + hex4(pc));
    }
};

// One emulated FS2 file behind native_vfs_entry, for the BDOS 219 loader.
struct Provider {
    vector<unsigned char> image;
    size_t offset = 0;
    bool open = false;
    int fail_read = -1;            // fail the Nth READ (0-based); -1 never
    unsigned reads = 0, closes = 0, opens = 0;
    void start(const vector<unsigned char> &bytes, int fail = -1) {
        require(!open, "previous executable handle leaked");
        image = bytes; offset = 0; open = true; fail_read = fail; reads = 0; ++opens;
    }
};

struct Rig {
    qkz80_cpu_mem mem;
    CPU cpu{&mem};
    map<string, unsigned> sym;
    map<unsigned, string> stubs, observers;
    vector<string> trace;
    vector<unsigned char> ccp;
    Provider fs;
    function<bool()> bdos_hook;    // when set, intercepts CALL 5 at 0005h
    unsigned commit_role = 0xff, teardown_role = 0xff;
    bool ccp_intact_at_teardown = true, reached_tpa = false;
    unsigned bios_stack_low = 0xffff, commit_close_order = 0;

    Rig(const string &page0, const string &bank7, const string &symbols) {
        vector<unsigned char> a(65536), b(65536);
        ifstream f(page0, ios::binary); f.read((char *)a.data(), 65536);
        require(f.gcount() == 65536, "missing page 0 image");
        ifstream g(bank7, ios::binary); g.read((char *)b.data(), 65536);
        require(g.gcount() == 65536, "missing bank 7 image");
        copy(a.begin(), a.end(), mem.get_mem());
        copy(b.begin() + 0x2000, b.begin() + 0xe000, mem.get_mem() + 0x2000);
        ifstream s(symbols); string name; unsigned value;
        while (s >> name >> value) sym[name] = value;
        ccp.assign(mem.get_mem() + at("CCP_RESTORE_BASE"),
                   mem.get_mem() + at("CCP_RESTORE_BASE") + at("CCP_RESTORE_SIZE"));
        require(equal(ccp.begin(), ccp.end(), mem.get_mem() + at("CBASE")),
                "image CCP slot differs from the pristine bank-7 copy");
    }
    bool has(const string &n) const { return sym.count(n) != 0; }
    unsigned at(const string &n) const {
        auto i = sym.find(n); require(i != sym.end(), "missing symbol " + n); return i->second;
    }
    unsigned byte(const string &n) { return mem.fetch_mem(at(n)); }
    void stub(const string &n) { if (has(n)) stubs[at(n)] = n; }
    void observe(const string &n) { observers[at(n)] = n; }
    void ret() {
        unsigned sp = cpu.regs.SP.get_pair16();
        cpu.regs.PC.set_pair16(mem.fetch_mem16(sp));
        cpu.regs.SP.set_pair16(sp + 2);
    }
    bool ccp_intact() { return equal(ccp.begin(), ccp.end(), mem.get_mem() + at("CBASE")); }

    // Emulate the provider for the loader's descriptor at DE.
    void provider() {
        unsigned d = cpu.regs.DE.get_pair16();
        require(d == at("FAC_SFCB_BUF"), "loader descriptor is not in common staging");
        unsigned op = mem.fetch_mem(d + at("ZNATIVE_OFF_OP"));
        unsigned status = 0, result = 0;
        if (op == at("ZNATIVE_READ")) {
            require(fs.open, "READ on a closed handle");
            require(mem.fetch_mem16(d + at("ZNATIVE_OFF_LENGTH")) == 512, "loader chunk is not 512");
            if ((int)fs.reads++ == fs.fail_read) status = 0x05;
            else {
                result = min<size_t>(512, fs.image.size() - fs.offset);
                for (unsigned i = 0; i < result; ++i)
                    mem.store_mem(at("FAC_BULK_BUF") + i, fs.image[fs.offset + i]);
                fs.offset += result;
            }
        } else if (op == at("ZNATIVE_CLOSE")) {
            require(fs.open, "CLOSE of a handle that is not open");
            fs.open = false; ++fs.closes; commit_close_order = trace.size();
        } else throw runtime_error("unexpected native op " + to_string(op));
        mem.store_mem16(d + at("ZNATIVE_OFF_RESULT"), result);
        cpu.regs.AF.set_high(status);
        ret();
    }

    void step() {
        unsigned pc = cpu.regs.PC.get_pair16();
        if (pc == 0x0100) reached_tpa = true;
        if (pc == 0x0005 && bdos_hook && bdos_hook()) return;
        if (pc == at("native_vfs_entry")) { trace.push_back("native_vfs_entry"); provider(); return; }
        auto s = stubs.find(pc);
        if (s != stubs.end()) { trace.push_back(s->second); ret(); return; }
        auto o = observers.find(pc);
        if (o != observers.end()) {
            trace.push_back(o->second);
            if (o->second == "supervisor_after_teardown") {
                teardown_role = byte("sup_role");
                ccp_intact_at_teardown = ccp_intact();
            }
            if (o->second == "supervisor_exec_replace_commit") commit_role = byte("sup_role");
        }
        if (mem.fetch_mem(pc) == 0xed && mem.fetch_mem(pc + 1) == 0x79) {
            cpu.port_out(cpu.regs.BC.get_low(), cpu.regs.AF.get_high());
            cpu.regs.PC.set_pair16(pc + 2);
        } else cpu.execute();
        unsigned sp = cpu.regs.SP.get_pair16();
        if (sp >= 0xc000 && sp <= at("CBIOS_STACK_TOP")) bios_stack_low = min(bios_stack_low, sp);
    }
    // Run until PC == stop.  With stop = 0x10000, run until a HALT opcode or an
    // entry at 0100h, whichever comes first.
    void run(unsigned stop, unsigned budget = 4000000) {
        while (budget--) {
            unsigned pc = cpu.regs.PC.get_pair16();
            if (pc == stop) return;
            if (stop == 0x10000 && (mem.fetch_mem(pc) == 0x76 || pc == 0x0100)) return;
            step();
        }
        throw runtime_error("execution timeout at " + hex4(cpu.regs.PC.get_pair16()) +
                            " waiting for " + (stop > 0xffff ? string("HALT") : hex4(stop)));
    }
    unsigned last_bank_write() {
        for (auto i = cpu.writes.rbegin(); i != cpu.writes.rend(); ++i)
            if (i->first == at("BANK_PORT")) return i->second;
        return 0x100;
    }
    void state(unsigned role, unsigned flags, const string &where) {
        require(byte("sup_version") == at("SUP_STATE_VERSION"), where + ": bad state version");
        require(byte("sup_role") == role, where + ": role " + to_string(byte("sup_role")) +
                ", expected " + to_string(role));
        require(byte("sup_policy") == at("EXEC_REPLACE"), where + ": policy is not EXEC_REPLACE");
        require(byte("sup_flags") == flags, where + ": flags " + to_string(byte("sup_flags")));
    }
    // The foreground transfer: the selected shell entry in mode 10, on the
    // common facade stack, with the CCP slot restored and page zero rebuilt.
    void at_shell_entry(unsigned drive, const string &where) {
        auto &r = cpu.regs;
        require(r.PC.get_pair16() == at("CCP_CLEARBUF_ENTRY"), where + ": not at the CCP entry");
        require(r.SP.get_pair16() == at("FAC_STACK_TOP"), where + ": SP " + hex4(r.SP.get_pair16()));
        require(last_bank_write() == at("MEM_MODE_APPLICATION"), where + ": not mode 10");
        require(r.BC.get_low() == drive, where + ": C is not TDRIVE");
        require(ccp_intact(), where + ": CCP slot not restored");
        require(mem.fetch_mem(0) == 0xc3 && mem.fetch_mem16(1) == at("WBOOT"), where + ": JP WBOOT");
        require(mem.fetch_mem(5) == 0xc3 && mem.fetch_mem16(6) == at("FBASE"), where + ": JP FBASE");
        state(at("FG_SHELL"), 0, where);
    }
};

static vector<string> expected(Rig &t, vector<string> names) {
    vector<string> out;
    for (auto &n : names) if (t.has(n)) out.push_back(n);
    return out;
}
static string join(const vector<string> &v) { string s; for (auto &x : v) s += x + " "; return s; }

// The zero-length tail of the cold or warm path, from the first stubbed call.
static const vector<string> COLD = {
    "irq_boot_prepare", "sound_silence_psgs", "sio_core_init", "bank7_check",
    "sio1_ioc_init", "ioc_link_bringup", "console_backend_cold_init", "sercon_init",
    "boot_print_banner", "prepare_runnable_bank", "facade_reset", "fat_context_reset",
    "sio_core_enable_interrupts", "irq_enable",
    "supervisor_cold_start", "supervisor_enter_foreground"};
// WBOOT: complete teardown, then -- and only then -- the supervisor.
static const vector<string> WARM = {
    "irq_boot_prepare", "sound_silence_psgs", "irq_enable", "console_wait_key",
    "irq_disable", "sio_core_init", "prepare_runnable_bank", "facade_reset",
    "fat_context_reset", "console_init", "sercon_install",
    "sio_core_enable_interrupts", "irq_enable",
    "supervisor_after_teardown", "supervisor_enter_foreground"};

static void cold_boot(Rig &t) {
    t.trace.clear();
    t.cpu.regs.PC.set_pair16(t.at("boot"));
    t.run(t.at("CCP_CLEARBUF_ENTRY"));
    require(t.trace == expected(t, COLD), "cold boot order: " + join(t.trace));
    t.at_shell_entry(0, "cold boot");
}

// Ask BDOS 219 for a child, from the shell's position at 0100h-AFFFh.
static void exec_child(Rig &t, const vector<unsigned char> &child, int fail = -1) {
    const unsigned desc = 0x9000, sentinel = 0xd100;
    for (unsigned i = 0; i < 32; ++i) t.mem.store_mem(desc + i, 0);
    t.mem.store_mem(desc + t.at("ZNATIVE_OFF_VERSION"), t.at("ZNATIVE_VERSION"));
    t.mem.store_mem(desc + t.at("ZNATIVE_OFF_OP"), t.at("ZNATIVE_READ"));
    t.mem.store_mem(desc + t.at("ZNATIVE_OFF_HANDLE"), 0x42);
    t.mem.store_mem16(desc + t.at("ZNATIVE_OFF_LENGTH"), 512);
    t.fs.start(child, fail);
    // The shell's image at 0100h is about to be destroyed; mark the CCP slot as
    // overwritten too, as a large child would leave it.
    for (unsigned i = 0; i < t.ccp.size(); ++i) t.mem.store_mem(t.at("CBASE") + i, 0xff);
    auto &r = t.cpu.regs;
    r.SP.set_pair16(0xb000 - 2); t.mem.store_mem16(0xb000 - 2, sentinel);
    r.BC.set_low(219); r.DE.set_pair16(desc); r.PC.set_pair16(0x0005);
    t.trace.clear(); t.reached_tpa = false; t.commit_role = 0xff;
}

static void child_runs(Rig &t, const vector<unsigned char> &child, const string &where) {
    t.run(0x0100);
    auto &r = t.cpu.regs;
    require(!t.fs.open, where + ": handle open when the child starts");
    require(t.commit_role == t.at("FG_SHELL"), where + ": commit did not see the launching shell");
    require(t.trace.size() >= 2 && t.trace[t.trace.size() - 2] == "supervisor_exec_replace_commit" &&
            t.trace.back() == "native_vfs_entry", where + ": commit is not the final close: " + join(t.trace));
    t.state(t.at("FG_CHILD"), 0, where + " (child started)");
    require(equal(child.begin(), child.end(), t.mem.get_mem() + 0x0100), where + ": image not at 0100h");
    require(r.SP.get_pair16() == t.at("ZEXEC_CHILD_STACK_TOP") - 2 &&
            t.mem.fetch_mem16(r.SP.get_pair16()) == t.at("WBOOT"), where + ": no WBOOT return word");
}

static void back_to_shell(Rig &t, unsigned drive, unsigned role, const string &where) {
    // Whatever the transient did, assume it overwrote the CCP slot; only the
    // supervisor's launch may put it back.
    for (unsigned i = 0; i < t.ccp.size(); ++i) t.mem.store_mem(t.at("CBASE") + i, 0xff);
    t.trace.clear();
    t.run(t.at("CCP_CLEARBUF_ENTRY"));
    // BDOS 0 reaches WBOOT through ZSDOS and wbtrap, which runs before WBOOT;
    // compare from WBOOT's own entry.
    auto start = find(t.trace.begin(), t.trace.end(), "wboot_masked");
    require(start != t.trace.end(), where + ": WBOOT never ran: " + join(t.trace));
    vector<string> warm(start + 1, t.trace.end());
    require(warm == expected(t, WARM), where + ": WBOOT order: " + join(warm));
    require(t.teardown_role == role, where + ": supervisor saw role " + to_string(t.teardown_role));
    require(!t.ccp_intact_at_teardown, where + ": WBOOT restored the CCP itself (policy leak)");
    t.at_shell_entry(drive, where);
}

int main(int argc, char **argv) try {
    require(argc == 5, "usage: supervisor_lifecycle page0.bin bank7.bin symbols.txt zshell|zcpr2");
    Rig t(argv[1], argv[2], argv[3]);
    const string ccp_kind = argv[4];
    for (auto n : {"irq_boot_prepare", "sound_silence_psgs", "sio_core_init", "bank7_check",
                   "sio1_ioc_init", "ioc_link_bringup", "console_backend_cold_init", "sercon_init",
                   "boot_print_banner", "facade_reset", "fat_context_reset",
                   "sio_core_enable_interrupts", "irq_enable", "irq_disable", "console_wait_key",
                   "console_init", "sercon_install"})
        t.stub(n);
    for (auto n : {"wboot_masked", "prepare_runnable_bank", "supervisor_cold_start", "supervisor_after_teardown",
                   "supervisor_enter_foreground", "supervisor_exec_replace_commit"})
        t.observe(n);

    // Cold boot: supervisor initialized, default shell selected.
    for (unsigned i = 0; i < 4; ++i) t.mem.store_mem(t.at("SUPERVISOR_STATE_START") + i, 0xa5);
    cold_boot(t);
    const unsigned drive = 1;                   // the shim selects B:
    t.mem.store_mem(t.at("TDRIVE"), drive);

    // Each CP/M termination mechanism, from a BDOS 219 child.
    const vector<pair<string, vector<unsigned char>>> exits = {
        {"RET", {0xc9}},
        {"JP 0000h", {0xc3, 0x00, 0x00}},
        {"BDOS 0", {0x0e, 0x00, 0xcd, 0x05, 0x00}},
    };
    for (auto &e : exits) {
        vector<unsigned char> image = e.second;
        image.resize(1300, 0x5a);               // three chunks: 512, 512, 276
        exec_child(t, image);
        child_runs(t, image, e.first);
        require(t.fs.reads == 4, e.first + ": loader did not read to the zero-length end");
        back_to_shell(t, drive, t.at("FG_CHILD"), e.first);
    }

    // The shell itself terminating is respawned, through the same WBOOT path.
    for (auto &e : exits) {
        if (e.first == "RET") {
            // The shim gives the shell a zero return word.
            auto &r = t.cpu.regs;
            r.SP.set_pair16(0xb000 - 2); t.mem.store_mem16(0xb000 - 2, 0x0000);
            t.mem.store_mem(0x0100, 0xc9);
        } else {
            copy(e.second.begin(), e.second.end(), t.mem.get_mem() + 0x0100);
            t.cpu.regs.SP.set_pair16(0xb000);
        }
        t.cpu.regs.PC.set_pair16(0x0100);
        back_to_shell(t, drive, t.at("FG_SHELL"), "shell " + e.first);
    }

    // Loader failure after the shell is partly overwritten: handle closed,
    // child never entered, no commit, the shell relaunched by the supervisor.
    for (int fail : {0, 1}) {
        vector<unsigned char> image(1300, 0xc9);
        exec_child(t, image, fail);
        string where = "load failure on read " + to_string(fail);
        back_to_shell(t, drive, t.at("FG_SHELL"), where);
        require(!t.fs.open, where + ": handle leaked");
        require(!t.reached_tpa, where + ": partial child was entered");
        require(find(t.trace.begin(), t.trace.end(), "supervisor_exec_replace_commit") == t.trace.end(),
                where + ": a failed load committed a child");
    }

    // Stress: repeated shell -> child -> WBOOT -> shell cycles.  State, the
    // drive, the handle count and the BIOS stack depth must not drift.
    t.bios_stack_low = 0xffff;
    unsigned first_low = 0;
    const unsigned cycles = 600;
    unsigned opens = t.fs.opens, closes = t.fs.closes;
    for (unsigned n = 0; n < cycles; ++n) {
        auto &e = exits[n % exits.size()];
        exec_child(t, e.second);
        string where = "cycle " + to_string(n);
        child_runs(t, e.second, where);
        back_to_shell(t, drive, t.at("FG_CHILD"), where);
        if (n == 0) first_low = t.bios_stack_low;
        require(t.bios_stack_low == first_low, where + ": BIOS stack depth drifted to " + hex4(t.bios_stack_low));
    }
    require(t.fs.opens - opens == cycles && t.fs.closes - closes == cycles, "stress: open/close imbalance");

    // A corrupt state block is repaired, flagged, and the shell launched.
    t.mem.store_mem(t.at("sup_version"), 0x55);
    t.cpu.regs.SP.set_pair16(0xb000); t.cpu.regs.PC.set_pair16(0x0000);
    t.trace.clear();
    t.run(t.at("CCP_CLEARBUF_ENTRY"));
    t.state(t.at("FG_SHELL"), t.at("SUP_FLAG_STATE_REPAIRED"), "repair");
    t.mem.store_mem(t.at("sup_role"), 0x77);    // out-of-range role: same repair
    t.cpu.regs.PC.set_pair16(0x0000);
    t.run(t.at("CCP_CLEARBUF_ENTRY"));
    t.state(t.at("FG_SHELL"), t.at("SUP_FLAG_STATE_REPAIRED"), "role repair");
    cold_boot(t);                               // cold boot clears the flag

    // The default shell's loader: the CCP=zshell shim, against a BDOS that
    // serves a fake A:ZSH.COM.  Its fatal paths must halt, not warm boot.
    string shim_result = "zcpr2 build: shim not linked";
    if (ccp_kind == "zshell") {
        struct Bdos { bool missing = false; int fail = -1; unsigned records = 3, served = 0;
                      unsigned dma = 0x80, drive = 0xff; bool closed = false; string printed; } b;
        auto install = [&](Bdos init) {
            b = init;
            t.bdos_hook = [&]() {
                auto &r = t.cpu.regs;
                unsigned fn = r.BC.get_low(), de = r.DE.get_pair16(), a = 0;
                if (fn == 15) a = b.missing ? 0xff : 0;
                else if (fn == 26) b.dma = de;
                else if (fn == 20) {
                    if ((int)b.served == b.fail) a = 2;
                    else if (b.served >= b.records) a = 1;
                    else for (unsigned i = 0; i < 128; ++i) t.mem.store_mem(b.dma + i, 0x30 + b.served);
                    ++b.served;
                } else if (fn == 16) b.closed = true;
                else if (fn == 14) b.drive = de & 0xff;
                else if (fn == 9) {
                    for (unsigned p = de; t.mem.fetch_mem(p) != '$'; ++p) b.printed += char(t.mem.fetch_mem(p));
                } else throw runtime_error("shim used BDOS " + to_string(fn));
                r.AF.set_high(a);
                t.ret();
                return true;
            };
        };
        auto start = [&]() {
            cold_boot(t);
            t.reached_tpa = false;
        };
        // Success: three records, EOF, B: selected, DMA restored, JP 0100h.
        start(); install({});
        t.run(0x0100);
        require(b.closed && b.dma == 0x80 && b.drive == 1, "shim: load epilogue");
        require(t.mem.fetch_mem(0x0100) == 0x30 && t.mem.fetch_mem(0x0200) == 0x32, "shim: image");
        require(t.cpu.regs.SP.get_pair16() == 0xb000 - 2 && t.mem.fetch_mem16(0xaffe) == 0, "shim: stack");
        t.state(t.at("FG_SHELL"), 0, "shim launched");
        // Fatal: missing, read error, too large.  Halted, never at 0100h.
        const vector<pair<Bdos, string>> fatal = {
            {[] { Bdos x; x.missing = true; return x; }(), "is missing"},
            {[] { Bdos x; x.fail = 1; return x; }(), "read error"},
            {[] { Bdos x; x.records = 100000; return x; }(), "overlaps its loader"},
        };
        for (auto &f : fatal) {
            start(); install(f.first);
            t.run(0x10000);
            require(b.printed.find("supervisor: default shell A:ZSH.COM " + f.second) != string::npos,
                    "shim fatal message: " + b.printed);
            require(!t.cpu.regs.IFF1, "shim fatal halt with interrupts enabled");
            require(!t.reached_tpa, "shim jumped into a failed image (" + f.second + ")");
        }
        t.bdos_hook = nullptr;
        shim_result = "shim load, missing/read-error/oversize fatal halts";
    }

    cout << "PASS: supervisor cold start, WBOOT teardown-then-supervisor order, BDOS 219 commit, "
            "RET/JP 0000h/BDOS 0 child and shell exits, load failure, " << cycles
         << "-cycle stress, state repair, " << shim_result << "\n";
    return 0;
} catch (const exception &e) {
    cerr << "FAIL: " << e.what() << "\n";
    return 1;
}
