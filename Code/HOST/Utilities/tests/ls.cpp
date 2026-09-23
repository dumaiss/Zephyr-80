// Execute the assembled LS.COM against models of both drive types.
#include <qkz80/qkz80.h>
#include <algorithm>
#include <fstream>
#include <iostream>
#include <string>
#include <vector>
using namespace std;
static void need(bool v, const string &m) { if (!v) throw runtime_error(m); }

struct Entry { string name; bool dir; unsigned size; };

struct CPU : qkz80 {
    explicit CPU(qkz80_cpu_mem *m) : qkz80(m) { set_cpu_mode(MODE_Z80); }
    void unimplemented_opcode(qkz80_uint8, qkz80_uint16 pc) override {
        throw runtime_error("unsupported opcode at " + to_string(pc));
    }
};

struct Rig {
    qkz80_cpu_mem mem; CPU cpu{&mem};
    vector<Entry> entries; unsigned at = 0;
    unsigned drive = 1, dma = 0x80, search_at = 0;
    bool dir_open = false, dir_released = false;
    string output;

    Rig(const char *bin) {
        fill(mem.get_mem(), mem.get_mem() + 65536, 0);
        ifstream f(bin, ios::binary);
        f.read(reinterpret_cast<char *>(mem.get_mem()) + 0x100, 0xff00);
        need(f.gcount() > 0, "missing LS.COM");
    }
    unsigned byte(unsigned a) { return mem.fetch_mem(a); }
    void put(unsigned a, unsigned v) { mem.store_mem(a, v); }
    void ret_bdos(unsigned a) {
        unsigned sp = cpu.regs.SP.get_pair16();
        cpu.regs.PC.set_pair16(mem.fetch_mem16(sp));
        cpu.regs.SP.set_pair16(sp + 2);
        cpu.regs.AF.set_high(a);
    }
    void tail(const string &t, const string &packed) {
        put(0x80, t.size());
        for (size_t i = 0; i < t.size(); ++i) put(0x81 + i, t[i]);
        for (unsigned i = 0; i < 11; ++i) put(0x5d + i, packed.empty() ? ' ' : packed[i]);
    }
    void bdos() {
        const unsigned f = cpu.regs.BC.get_low(), de = cpu.regs.DE.get_pair16();
        if (f == 2) { output.push_back(char(cpu.regs.DE.get_low())); ret_bdos(0); return; }
        if (f == 9) { unsigned a = de; while (byte(a) != '$') output.push_back(char(byte(a++))); ret_bdos(0); return; }
        if (f == 25) { ret_bdos(drive); return; }
        if (f == 26) { dma = de; ret_bdos(0); return; }
        if (f == 37) { dir_open = false; dir_released = true; ret_bdos(0); return; }
        if (f == 17 || f == 18) {   // SEARCH FIRST / NEXT
            if (f == 17) search_at = 0;
            if (search_at >= entries.size()) { ret_bdos(0xff); return; }
            const Entry &e = entries[search_at++];
            for (unsigned i = 0; i < 32; ++i) put(dma + i, 0);
            put(dma + 0, 0);
            for (unsigned i = 0; i < 11; ++i) put(dma + 1 + i, e.name[i]);
            put(dma + 12, e.size);      // reused as the extent number here
            ret_bdos(0);                // always slot 0
            return;
        }
        if (f == 218) {
            const unsigned d = de, op = byte(d + 1);
            if (op == 7) {              // OPENDIR
                need(!dir_open, "LS opened a directory twice");
                dir_open = true; at = 0; put(d + 2, 0); ret_bdos(0); return;
            }
            if (op == 8) {              // READDIR
                need(dir_open, "LS read a directory it had not opened");
                if (at >= entries.size()) { put(d + 2, 0x41); ret_bdos(0x41); return; }
                const Entry &e = entries[at++];
                for (unsigned i = 0; i < 11; ++i) put(d + 18 + i, e.name[i]);
                put(d + 3, e.dir ? 0x10 : 0x00);
                put(d + 6, e.size & 255); put(d + 7, (e.size >> 8) & 255);
                put(d + 8, (e.size >> 16) & 255); put(d + 9, (e.size >> 24) & 255);
                put(d + 2, 0); ret_bdos(0); return;
            }
            throw runtime_error("unexpected native op " + to_string(op));
        }
        throw runtime_error("unexpected BDOS function " + to_string(f));
    }
    void run() {
        constexpr unsigned sp0 = 0xd000, back = 0xd100;
        mem.store_mem16(sp0, back);
        cpu.regs.SP.set_pair16(sp0); cpu.regs.PC.set_pair16(0x100);
        unsigned b = 8000000;
        while (cpu.regs.PC.get_pair16() != back && b--) {
            if (cpu.regs.PC.get_pair16() == 5) bdos(); else cpu.execute();
        }
        need(b > 0, "LS execution timeout");
        need(cpu.regs.SP.get_pair16() == sp0 + 2, "LS did not restore entry stack");
    }
};

int main(int argc, char **argv) try {
    need(argc >= 2, "usage: ls-test ls.com");

    // FAT volume: directories must be marked, files sized, and the single
    // controller directory slot handed back before LS exits.
    Rig fat(argv[1]);
    fat.drive = 1;
    fat.entries = {{"GAMES      ", true, 0}, {"LESSON  MD ", false, 1400},
                   {"SONG    ZVG", false, 79872}, {"VGMPLAY COM", false, 3000}};
    fat.tail("", "");
    fat.run();
    if (fat.output.find("FAIL") != string::npos) cerr << fat.output;
    need(fat.output.find("GAMES   .     <DIR>") != string::npos,
         "a directory was not marked:\n" + fat.output);
    need(fat.output.find("LESSON  .MD     2K") != string::npos,
         "size not rounded up to KiB:\n" + fat.output);
    need(fat.output.find("SONG    .ZVG   78K") != string::npos,
         "large size wrong:\n" + fat.output);
    need(fat.output.find("3 file(s)") != string::npos && fat.output.find("1 dir(s)") != string::npos,
         "counts wrong:\n" + fat.output);
    need(fat.dir_released, "LS left the controller directory slot open");

    // A filter must apply on the FAT side too.
    Rig filt(argv[1]);
    filt.drive = 1;
    filt.entries = fat.entries;
    filt.tail(" *.COM", "????????COM");
    filt.run();
    need(filt.output.find("VGMPLAY .COM") != string::npos, "filter dropped a match");
    need(filt.output.find("LESSON") == string::npos, "filter kept a non-match");
    need(filt.output.find("1 file(s)") != string::npos, "filtered count wrong:\n" + filt.output);

    // Conventional volume: names only, and one line per file rather than one
    // per extent.  The model puts the extent number in byte 12.
    Rig cpm(argv[1]);
    cpm.drive = 2;
    cpm.entries = {{"BIG     DAT", false, 0}, {"BIG     DAT", false, 1},
                   {"SMALL   TXT", false, 0}};
    cpm.tail("", "");
    cpm.run();
    need(cpm.output.find("BIG     .DAT") != string::npos, "CP/M listing missing a file");
    need(cpm.output.find("2 file(s)") != string::npos,
         "a multi-extent file was listed twice:\n" + cpm.output);
    need(!cpm.dir_released, "LS reset a conventional drive it never opened");

    cout << "PASS: LS marks directories, sizes files, filters, releases the "
            "directory slot, and lists CP/M volumes one line per file\n";
} catch (const exception &e) {
    cerr << "FAIL: " << e.what() << '\n';
    return 1;
}
