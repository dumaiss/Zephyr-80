// Execute MKDIR, RMDIR, PWD, FSTAT and MV against models of both volume types.
#include <qkz80/qkz80.h>
#include <algorithm>
#include <fstream>
#include <iostream>
#include <map>
#include <string>
#include <vector>
using namespace std;
static void need(bool v, const string &m) { if (!v) throw runtime_error(m); }

struct CPU : qkz80 {
    explicit CPU(qkz80_cpu_mem *m) : qkz80(m) { set_cpu_mode(MODE_Z80); }
    void unimplemented_opcode(qkz80_uint8, qkz80_uint16 pc) override {
        throw runtime_error("unsupported opcode at " + to_string(pc));
    }
};

struct Rig {
    qkz80_cpu_mem mem; CPU cpu{&mem};
    unsigned drive = 1, user = 8, dma = 0x80;
    map<string, vector<unsigned char>> files;   // keyed "d:NAME"
    vector<string> cwd;
    unsigned free_bytes = 0x20000000u, total_bytes = 0x40000000u;
    unsigned native_op = 0, native_calls = 0;
    string native_name;
    vector<string> trace;
    string output;
    string open_src, open_dst;
    unsigned read_at = 0;

    Rig(const char *bin) {
        fill(mem.get_mem(), mem.get_mem() + 65536, 0);
        ifstream f(bin, ios::binary);
        f.read(reinterpret_cast<char *>(mem.get_mem()) + 0x100, 0xff00);
        need(f.gcount() > 0, "missing image");
    }
    unsigned byte(unsigned a) { return mem.fetch_mem(a); }
    void put(unsigned a, unsigned v) { mem.store_mem(a, v); }
    void ret_bdos(unsigned a) {
        unsigned sp = cpu.regs.SP.get_pair16();
        cpu.regs.PC.set_pair16(mem.fetch_mem16(sp));
        cpu.regs.SP.set_pair16(sp + 2);
        cpu.regs.AF.set_high(a);
    }
    void tail(const string &t) {
        put(0x80, t.size());
        for (size_t i = 0; i < t.size(); ++i) put(0x81 + i, t[i]);
    }
    void fcb(unsigned base, unsigned d, const string &packed) {
        for (unsigned i = 0; i < 16; ++i) put(base + i, 0);
        put(base, d);
        for (unsigned i = 0; i < 11; ++i) put(base + 1 + i, packed.empty() ? ' ' : packed[i]);
    }
    string name_at(unsigned a) {
        string n; for (unsigned i = 0; i < 11; ++i) n.push_back(char(byte(a + i))); return n;
    }
    string key(unsigned fcbaddr) {
        unsigned d = byte(fcbaddr); if (d == 0) d = drive + 1;
        return to_string(d) + ":" + name_at(fcbaddr + 1);
    }

    void bdos() {
        const unsigned f = cpu.regs.BC.get_low(), de = cpu.regs.DE.get_pair16();
        switch (f) {
        case 2: output.push_back(char(cpu.regs.DE.get_low())); ret_bdos(0); return;
        case 9: { unsigned a = de; while (byte(a) != '$') output.push_back(char(byte(a++)));
                  ret_bdos(0); return; }
        case 25: ret_bdos(drive); return;
        case 26: dma = de; ret_bdos(0); return;
        case 32: if (cpu.regs.DE.get_low() != 0xff) user = cpu.regs.DE.get_low();
                 ret_bdos(user); return;
        case 15: trace.push_back("open"); open_src = key(de); read_at = 0;
                 ret_bdos(files.count(open_src) ? 0 : 0xff); return;
        case 22: trace.push_back("make"); open_dst = key(de); files[open_dst].clear();
                 ret_bdos(0); return;
        case 16: trace.push_back("close"); ret_bdos(0); return;
        case 19: trace.push_back("delete"); ret_bdos(files.erase(key(de)) ? 0 : 0xff); return;
        case 20: { trace.push_back("read");
                   auto &d = files[open_src];
                   if (read_at >= d.size()) { ret_bdos(1); return; }
                   for (unsigned i = 0; i < 128; ++i)
                       put(dma + i, read_at + i < d.size() ? d[read_at + i] : 0x1a);
                   read_at += 128; ret_bdos(0); return; }
        case 21: { trace.push_back("write");
                   auto &d = files[open_dst];
                   for (unsigned i = 0; i < 128; ++i) d.push_back((unsigned char)byte(dma + i));
                   ret_bdos(0); return; }
        case 23: { trace.push_back("rename");
                   const string from = key(de), to = to_string(byte(de) ? byte(de) : drive + 1)
                                                    + ":" + name_at(de + 17);
                   if (!files.count(from) || files.count(to)) { ret_bdos(0xff); return; }
                   files[to] = files[from]; files.erase(from); ret_bdos(0); return; }
        case 218: {
            need(byte(de) == 1, "bad descriptor version");
            native_op = byte(de + 1); ++native_calls;
            native_name = name_at(de + 18);
            if (native_op == 17) {                    // CWD
                const unsigned idx = byte(de + 3);
                put(de + 16, cwd.size()); put(de + 17, 0);
                if (idx < cwd.size())
                    for (unsigned i = 0; i < 11; ++i) put(de + 18 + i, cwd[idx][i]);
                put(de + 2, 0); ret_bdos(0); return;
            }
            if (native_op == 18) {                    // SPACE
                put(de + 6, free_bytes & 255); put(de + 7, (free_bytes >> 8) & 255);
                put(de + 8, (free_bytes >> 16) & 255); put(de + 9, (free_bytes >> 24) & 255);
                put(de + 18, total_bytes & 255); put(de + 19, (total_bytes >> 8) & 255);
                put(de + 20, (total_bytes >> 16) & 255); put(de + 21, (total_bytes >> 24) & 255);
                put(de + 2, 0); ret_bdos(0); return;
            }
            put(de + 2, 0); ret_bdos(0); return;      // MKDIR / RMDIR / STAT
        }
        default: throw runtime_error("unexpected BDOS function " + to_string(f));
        }
    }
    void run() {
        constexpr unsigned sp0 = 0xd000, back = 0xd100;
        mem.store_mem16(sp0, back);
        cpu.regs.SP.set_pair16(sp0); cpu.regs.PC.set_pair16(0x100);
        unsigned b = 8000000;
        while (cpu.regs.PC.get_pair16() != back && b--) {
            if (cpu.regs.PC.get_pair16() == 5) bdos(); else cpu.execute();
        }
        need(b > 0, "execution timeout");
        need(cpu.regs.SP.get_pair16() == sp0 + 2, "entry stack not restored");
    }
    string joined() const {
        string s; for (auto &t : trace) { s += t; s += ' '; } return s;
    }
};

int main(int argc, char **argv) try {
    need(argc == 7, "usage: tools-test mkdir rmdir pwd fstat mv cp");
    const char *MKDIR = argv[1], *RMDIR = argv[2], *PWD = argv[3],
               *FSTAT = argv[4], *MV = argv[5], *CP = argv[6];

    // MKDIR / RMDIR reach the controller on the FAT volume...
    for (auto [bin, op, word] : {make_tuple(MKDIR, 15u, "created"),
                                 make_tuple(RMDIR, 16u, "removed")}) {
        Rig r(bin); r.drive = 1; r.tail(" NEWDIR");
        r.fcb(0x5c, 0, "NEWDIR     "); r.run();
        need(r.native_calls == 1 && r.native_op == op,
             string("wrong native op from ") + word);
        need(r.native_name == "NEWDIR     ", "wrong name passed");
        need(r.output.find(word) != string::npos, "no confirmation:\n" + r.output);
        // ...and refuse on a CP/M volume without asking the controller at all.
        Rig c(bin); c.drive = 2; c.tail(" NEWDIR");
        c.fcb(0x5c, 0, "NEWDIR     "); c.run();
        need(c.native_calls == 0, "a CP/M volume was sent a directory op");
        need(c.output.find("no directories") != string::npos,
             "no explanation on a CP/M volume:\n" + c.output);
    }

    // PWD: a CP/M volume has only a drive and user; the FAT one has a path.
    Rig pc(PWD); pc.drive = 2; pc.user = 8; pc.run();
    need(pc.output.find("C8:") != string::npos, "CP/M PWD wrong:\n" + pc.output);
    need(pc.native_calls == 0, "CP/M PWD asked for a path");

    Rig pf(PWD); pf.drive = 1; pf.user = 8;
    pf.cwd = {"GAMES      ", "RPG        "};
    pf.run();
    need(pf.output.find("B8:/GAMES/RPG") != string::npos, "FAT PWD wrong:\n" + pf.output);

    Rig pr(PWD); pr.drive = 1; pr.user = 0; pr.run();
    need(pr.output.find("B0:/") != string::npos, "PWD at the root wrong:\n" + pr.output);

    // FSTAT reports the controller's figures, not the clamped ALV.
    Rig fv(FSTAT); fv.drive = 1; fv.run();
    need(fv.native_op == 18, "FSTAT did not ask for free space");
    need(fv.output.find("Free 512M of 1024M") != string::npos,
         "FSTAT volume figures wrong:\n" + fv.output);
    Rig fc(FSTAT); fc.drive = 2; fc.run();
    need(fc.native_calls == 0 && fc.output.find("use STAT") != string::npos,
         "FSTAT did not defer to STAT on a CP/M volume:\n" + fc.output);

    // MV within one drive is a rename.
    Rig mr(MV); mr.drive = 1;
    mr.files["2:OLD     TXT"] = vector<unsigned char>(10, 7);
    mr.tail(" OLD.TXT NEW.TXT");
    mr.fcb(0x5c, 0, "OLD     TXT"); mr.fcb(0x6c, 0, "NEW     TXT");
    mr.run();
    need(mr.joined() == "rename ", "same-drive MV was not a rename: " + mr.joined());
    need(mr.files.count("2:NEW     TXT") == 1 && mr.files.count("2:OLD     TXT") == 0,
         "rename did not move the file");

    // Across drives it copies, then deletes -- and the delete must come last,
    // after the close, or a failure part-way would lose the original.
    Rig mc(MV); mc.drive = 1;
    mc.files["2:DATA    BIN"] = vector<unsigned char>(300, 0x5A);
    mc.tail(" DATA.BIN C:");
    mc.fcb(0x5c, 0, "DATA    BIN"); mc.fcb(0x6c, 3, "           ");
    mc.run();
    need(mc.joined() == "open make read write read write read write read close delete ",
         "cross-drive MV order wrong: " + mc.joined());
    need(mc.files.count("3:DATA    BIN") == 1, "MV did not create the destination");
    need(mc.files.count("2:DATA    BIN") == 0, "MV did not remove the original");
    need(mc.files["3:DATA    BIN"].size() == 384, "MV copied the wrong length");
    need(mc.output.find("Moved") != string::npos, "no confirmation:\n" + mc.output);

    // A missing source must not create anything.
    Rig mm(MV); mm.drive = 1;
    mm.tail(" GONE.BIN C:");
    mm.fcb(0x5c, 0, "GONE    BIN"); mm.fcb(0x6c, 3, "           ");
    mm.run();
    need(mm.joined() == "open ", "MV kept going past a failed open: " + mm.joined());
    need(mm.files.empty(), "MV created something from a missing source");

    // One name is not a move.
    Rig mu(MV); mu.tail(" ONLYONE.TXT");
    mu.fcb(0x5c, 0, "ONLYONETXT"); mu.fcb(0x6c, 0, "");
    mu.run();
    need(mu.joined().empty() && mu.output.find("Usage") != string::npos,
         "MV acted on a single argument:\n" + mu.output);

    // CP is the same copy without the delete, and the original must survive.
    Rig cc(CP); cc.drive = 1;
    cc.files["2:DATA    BIN"] = vector<unsigned char>(300, 0x5A);
    cc.tail(" DATA.BIN C:");
    cc.fcb(0x5c, 0, "DATA    BIN"); cc.fcb(0x6c, 3, "           ");
    cc.run();
    need(cc.joined() == "open make read write read write read write read close ",
         "CP order wrong: " + cc.joined());
    need(cc.files.count("3:DATA    BIN") == 1, "CP did not create the destination");
    need(cc.files.count("2:DATA    BIN") == 1, "CP removed the original");
    need(cc.output.find("Copied") != string::npos, "no confirmation:\n" + cc.output);

    // Within one drive it is still a copy, never a rename.
    Rig cw(CP); cw.drive = 1;
    cw.files["2:OLD     TXT"] = vector<unsigned char>(10, 7);
    cw.tail(" OLD.TXT NEW.TXT");
    cw.fcb(0x5c, 0, "OLD     TXT"); cw.fcb(0x6c, 0, "NEW     TXT");
    cw.run();
    need(cw.joined().find("rename") == string::npos, "CP renamed instead of copying");
    need(cw.files.count("2:OLD     TXT") == 1 && cw.files.count("2:NEW     TXT") == 1,
         "CP within a drive lost a file");

    // Copying a file onto itself would truncate it through the MAKE.
    Rig cs(CP); cs.drive = 1;
    cs.files["2:DATA    BIN"] = vector<unsigned char>(300, 0x5A);
    cs.tail(" DATA.BIN DATA.BIN");
    cs.fcb(0x5c, 0, "DATA    BIN"); cs.fcb(0x6c, 0, "DATA    BIN");
    cs.run();
    need(cs.joined().empty(), "CP copied a file onto itself: " + cs.joined());
    need(cs.files["2:DATA    BIN"].size() == 300, "CP truncated the file it refused");
    need(cs.output.find("same file") != string::npos, "no explanation:\n" + cs.output);

    // And "CP FILE C:" with the same drive is also the same file.
    Rig cd2(CP); cd2.drive = 2;
    cd2.files["3:DATA    BIN"] = vector<unsigned char>(64, 1);
    cd2.tail(" DATA.BIN C:");
    cd2.fcb(0x5c, 0, "DATA    BIN"); cd2.fcb(0x6c, 3, "           ");
    cd2.run();
    need(cd2.joined().empty(), "CP copied onto itself via a bare drive: " + cd2.joined());

    cout << "PASS: MKDIR/RMDIR gate on volume type, PWD prints the FAT path, "
            "FSTAT uses real free space, MV renames in place and copies "
            "before it deletes, CP keeps the original and refuses self-copy\n";
} catch (const exception &e) {
    cerr << "FAIL: " << e.what() << '\n';
    return 1;
}
