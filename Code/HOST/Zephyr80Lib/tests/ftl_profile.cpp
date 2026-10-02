// Instruction-count profiler for the Zephyr80Lib per-tick path.
//
// Runs the native FTL-linked PROFTEST.COM under libqkz80 and counts emulated
// instructions between the two marker writes PROFTEST makes to port FEh.  The
// load and parse happen before the first marker, so the reported figure is the
// tick path alone.
//
// This is a RELATIVE instrument.  libqkz80 counts instructions, not T-states,
// so the number is only meaningful compared against another run of the same
// harness -- which is exactly what it is for: measuring whether an
// optimisation moved anything, without a hardware round trip.
//
// Enough BDOS is mocked to let Files.Lookup/SeqReadBlock read a host file;
// unknown calls are reported rather than silently answered, because a wrong
// answer here would show up as a bogus instruction count.
#include <qkz80/qkz80.h>
#include <cstring>
#include <fstream>
#include <iostream>
#include <stdexcept>
#include <string>
#include <vector>
#include <algorithm>
using namespace std;

static void need(bool ok, const string &s) { if (!ok) throw runtime_error(s); }

struct CPU : qkz80 {
    string output;
    vector<unsigned char> file;     // the .ZTR served to the guest
    size_t filePos = 0;
    bool fileOpen = false;
    unsigned dma = 0x80;
    unsigned long long steps = 0;
    unsigned long long atBegin = 0, atEnd = 0;
    bool sawBegin = false, sawEnd = false, loadFailed = false;
    unsigned psgWrites = 0;
    vector<unsigned long long> perTick;
    vector<unsigned> perTickWrites;
    vector<size_t> orderTicks;
    unsigned long long tickMark = 0;
    unsigned tickWrites = 0;
    unsigned long long rowTotal = 0, rowMark = 0; unsigned rows = 0; bool inRow = false;
    unsigned long long psgHash = 1469598103934665603ULL;  // FNV-1a over the write stream

    CPU(qkz80_cpu_mem *m) : qkz80(m) { set_cpu_mode(MODE_Z80); }

    void port_out(qkz80_uint8 p, qkz80_uint8 v) override {
        if (p == 0xfe) {
            if (v == 1) { atBegin = steps; sawBegin = true; tickMark = steps; }
            else if (v == 2) { atEnd = steps; sawEnd = true; }
            else if (v == 255) loadFailed = true;
            return;
        }
        if (p == 0xfb) {
            if (v == 1) { rowMark = steps; inRow = true; }
            else if (inRow) { rowTotal += steps - rowMark; ++rows; inRow = false; }
            return;
        }
        if (p == 0xfc) { orderTicks.push_back(perTick.size()); return; }
        if (p == 0xfd) {
            perTick.push_back(steps - tickMark);
            perTickWrites.push_back(tickWrites);
            tickWrites = 0;
            tickMark = steps;
            return;
        }
        ++tickWrites;
        ++psgWrites;
        psgHash = (psgHash ^ p) * 1099511628211ULL;
        psgHash = (psgHash ^ v) * 1099511628211ULL;
    }
    void unimplemented_opcode(qkz80_uint8, qkz80_uint16 p) override {
        throw runtime_error("unsupported instruction at " + to_string(p));
    }

    void step() {
        unsigned pc = regs.PC.get_pair16();
        // This libqkz80 build omits ED-prefixed OUT (C),r / IN r,(C).
        if (mem->fetch_mem(pc) == 0xed && mem->fetch_mem(pc + 1) == 0x59) {
            port_out(regs.BC.get_low(), regs.DE.get_low());
            regs.PC.set_pair16(pc + 2);
            ++steps;
            return;
        }
        if (mem->fetch_mem(pc) == 0xed && mem->fetch_mem(pc + 1) == 0x58) {
            regs.DE.set_low(0);
            regs.PC.set_pair16(pc + 2);
            ++steps;
            return;
        }
        if (pc != 5) { execute(); ++steps; return; }
        bdos();
    }

    void bdos() {
        unsigned fn = regs.BC.get_low(), de = regs.DE.get_pair16(), answer = 0;
        switch (fn) {
        case 200: answer = 0; regs.IX.set_pair16(0xdead); break;  // CTC register
        case 201: regs.IX.set_pair16(0xdead); break;              // CTC release
        case 2:  output += char(de & 255); break;
        case 9:  for (unsigned i = de; mem->fetch_mem(i) != '$'; ++i)
                     output += char(mem->fetch_mem(i));
                 break;
        case 11: answer = 0; break;            // console status: no key
        case 12: answer = 0x22; break;         // CP/M version
        case 13: break;                        // reset disk system
        case 14: answer = 0; break;            // select disk
        case 25: answer = 0; break;            // current disk
        case 26: dma = de; break;              // set DMA
        case 15:                               // open file
            fileOpen = true; filePos = 0; answer = 0; break;
        case 16: fileOpen = false; answer = 0; break;   // close
        case 20:                               // read sequential
            if (!fileOpen || filePos >= file.size()) { answer = 1; break; }
            for (unsigned i = 0; i < 128; ++i) {
                unsigned char b = filePos < file.size() ? file[filePos] : 0x1a;
                mem->store_mem(dma + i, b);
                ++filePos;
            }
            answer = 0;
            break;
        default:
            throw runtime_error("unexpected BDOS " + to_string(fn));
        }
        regs.AF.set_high(answer & 255);
        regs.HL.set_pair16(answer);
        regs.PC.set_pair16(pop_word());
    }
};

int main(int argc, char **argv) try {
    need(argc == 3, "usage: ftl_profile PROFTEST.COM song.ztr");
    qkz80_cpu_mem mem;
    CPU cpu(&mem);

    ifstream f(argv[1], ios::binary);
    f.read((char *)mem.get_mem() + 0x100, 0xdd00);
    need(f.gcount() > 0, "missing COM");

    ifstream z(argv[2], ios::binary);
    need(z.good(), string("missing song: ") + argv[2]);
    cpu.file.assign(istreambuf_iterator<char>(z), istreambuf_iterator<char>());
    need(!cpu.file.empty(), "empty song");

    mem.store_mem(0, 0xc3); mem.store_mem16(1, 0xf000);
    mem.store_mem(5, 0xc3); mem.store_mem16(6, 0xe800);
    cpu.regs.SP.set_pair16(0xe700);
    cpu.push_word(0);
    cpu.regs.PC.set_pair16(0x100);

    unsigned long long budget = 4000000000ULL;
    while (cpu.regs.PC.get_pair16() != 0 && budget--) cpu.step();
    need(budget > 0, "program did not return");
    need(!cpu.loadFailed, "Player.Load rejected the song");
    need(cpu.sawBegin && cpu.sawEnd, "markers missing: probe did not reach the loop");

    const unsigned ticks = cpu.perTick.empty() ? 1 : (unsigned)cpu.perTick.size();
    unsigned long long span = cpu.atEnd - cpu.atBegin;
    cout << "song        " << argv[2] << " (" << cpu.file.size() << " bytes)\n";
    cout << "ticks       " << ticks << "\n";
    cout << "PSG writes  " << cpu.psgWrites << "\n";
    cout << "PSG stream  " << hex << cpu.psgHash << dec << "\n";
    cout << "instructions in tick path  " << span << "\n";
    cout << "per tick                   " << span / ticks << "\n";
    if (!cpu.perTick.empty()) {
        vector<unsigned long long> v = cpu.perTick;
        sort(v.begin(), v.end());
        unsigned long long med = v[v.size()/2], p99 = v[v.size()*99/100], mx = v.back();
        cout << "\n  per-tick distribution (" << v.size() << " ticks)\n";
        cout << "    median  " << med << "\n";
        cout << "    p99     " << p99 << "\n";
        cout << "    max     " << mx << "  (" << (mx / (med ? med : 1)) << "x median)\n";
        // Rank the worst ticks and show where they fall, so a spike that
        // recurs on a row boundary can be told from one on an order boundary.
        vector<size_t> idx(cpu.perTick.size());
        for (size_t i = 0; i < idx.size(); ++i) idx[i] = i;
        sort(idx.begin(), idx.end(),
             [&](size_t a, size_t b){ return cpu.perTick[a] > cpu.perTick[b]; });
        cout << "\n  most expensive ticks (index: cost, gap from previous)\n";
        vector<size_t> worst(idx.begin(), idx.begin() + min<size_t>(12, idx.size()));
        sort(worst.begin(), worst.end());
        size_t prev = 0;
        for (size_t i : worst) {
            cout << "    " << i << ": " << cpu.perTick[i]
                 << "  (+" << (i - prev) << ")\n";
            prev = i;
        }
    }
    if (cpu.rows) {
        cout << "\n  BeginRow: " << cpu.rows << " rows, "
             << cpu.rowTotal / cpu.rows << " instructions each, "
             << cpu.rowTotal / cpu.perTick.size() << " amortised per tick\n";
    }
    if (!cpu.orderTicks.empty()) {
        cout << "\n  order changes at ticks:";
        for (size_t i = 0; i < cpu.orderTicks.size() && i < 10; ++i)
            cout << " " << cpu.orderTicks[i];
        cout << "  (" << cpu.orderTicks.size() << " total)\n";
        unsigned long long sumC = 0, sumW = 0;
        for (size_t i : cpu.orderTicks)
            if (i < cpu.perTick.size()) { sumC += cpu.perTick[i]; sumW += cpu.perTickWrites[i]; }
        size_t n = cpu.orderTicks.size();
        cout << "    cost at order ticks   " << sumC / n << "\n";
        cout << "    PSG writes there      " << double(sumW) / n << "\n";
    }
    {
        unsigned long long sw = 0; unsigned mx = 0;
        for (unsigned w : cpu.perTickWrites) { sw += w; if (w > mx) mx = w; }
        cout << "    PSG writes per tick   avg "
             << double(sw) / cpu.perTickWrites.size() << "  max " << mx << "\n";
        vector<size_t> wi(cpu.perTickWrites.size());
        for (size_t i = 0; i < wi.size(); ++i) wi[i] = i;
        sort(wi.begin(), wi.end(), [&](size_t a, size_t b){
            return cpu.perTickWrites[a] > cpu.perTickWrites[b]; });
        cout << "\n  heaviest write bursts (tick: writes, cost)\n";
        for (size_t k = 0; k < 8 && k < wi.size(); ++k) {
            size_t i = wi[k];
            bool isOrder = find(cpu.orderTicks.begin(), cpu.orderTicks.end(), i)
                           != cpu.orderTicks.end();
            cout << "    " << i << ": " << cpu.perTickWrites[i]
                 << " writes, " << cpu.perTick[i]
                 << (isOrder ? "   <- order change" : "") << "\n";
        }
    }
    return 0;
} catch (const exception &e) {
    cerr << "ftl_profile: " << e.what() << "\n";
    return 1;
}
