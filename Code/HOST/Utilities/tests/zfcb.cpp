// Execute the assembled ZFCB.COM against a model of CP/M's FCB calls.
//
// ZFCB makes only standard BDOS calls, so this models what any CP/M BDOS does
// -- record position from EX/S2/CR, directory codes 0-3 for success, wildcard
// DELETE, ZSDOS's sticky write protection -- and proves ZFCB's own sequencing
// before it is used to judge the FAT backend.
#include <qkz80/qkz80.h>

#include <algorithm>
#include <fstream>
#include <iostream>
#include <map>
#include <stdexcept>
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
    qkz80_cpu_mem mem;
    CPU cpu{&mem};
    map<string, vector<unsigned char>> files;
    string output;
    unsigned dma = 0x80;
    unsigned drive = 3;
    bool write_protected = false;
    unsigned zsdos_flags = 0x6d;   // bit 2 = Read-Only Enable, as shipped
    // A conventional CP/M drive zero-fills only a PREVIOUSLY UNALLOCATED
    // BLOCK, so a gap inside a block that is already allocated keeps whatever
    // was there.  With this set, function 40 gives that weaker guarantee --
    // which is all ZFCB may assume if it is to pass on both drive types.
    bool block_zero_fill_only = false;
    string open_name;

    Rig(const char *bin) {
        fill(mem.get_mem(), mem.get_mem() + 65536, 0);
        ifstream f(bin, ios::binary);
        f.read(reinterpret_cast<char *>(mem.get_mem()) + 0x100, 0xff00);
        need(f.gcount() > 0, "missing ZFCB.COM");
    }
    unsigned byte(unsigned a) { return mem.fetch_mem(a); }
    void put(unsigned a, unsigned v) { mem.store_mem(a, v); }
    void ret_bdos(unsigned a) {
        unsigned sp = cpu.regs.SP.get_pair16();
        cpu.regs.PC.set_pair16(mem.fetch_mem16(sp));
        cpu.regs.SP.set_pair16(sp + 2);
        cpu.regs.AF.set_high(a);
        cpu.regs.HL.set_pair16(a);
    }
    string name_at(unsigned fcb, unsigned off = 1) {
        string n;
        for (unsigned i = 0; i < 11; ++i) n.push_back(char(byte(fcb + off + i)));
        return n;
    }
    static bool matches(const string &pat, const string &n) {
        for (unsigned i = 0; i < 11; ++i)
            if (pat[i] != '?' && pat[i] != n[i]) return false;
        return true;
    }
    unsigned record_of(unsigned fcb) {
        return byte(fcb + 32) + (byte(fcb + 12) & 0x1f) * 128u
             + (byte(fcb + 14) & 0x3f) * 4096u;
    }
    void advance(unsigned fcb) {
        unsigned cr = byte(fcb + 32) + 1;
        if (cr < 128) { put(fcb + 32, cr); return; }
        put(fcb + 32, 0);
        unsigned ex = byte(fcb + 12) + 1;
        put(fcb + 12, ex & 0x1f);
        if ((ex & 0x1f) == 0) put(fcb + 14, byte(fcb + 14) + 1);
    }
    unsigned random_of(unsigned fcb) {
        return byte(fcb + 33) | (byte(fcb + 34) << 8) | (byte(fcb + 35) << 16);
    }

    void bdos() {
        const unsigned f = cpu.regs.BC.get_low();
        const unsigned de = cpu.regs.DE.get_pair16();
        switch (f) {
        case 2: output.push_back(char(cpu.regs.DE.get_low())); ret_bdos(0); return;
        case 9: {
            unsigned a = de;
            while (byte(a) != '$') output.push_back(char(byte(a++)));
            ret_bdos(0); return;
        }
        case 25: ret_bdos(drive); return;
        case 26: dma = de; ret_bdos(0); return;
        case 28: write_protected = true; ret_bdos(0); return;
        case 29: cpu.regs.HL.set_pair16(write_protected ? 8 : 0);
                 ret_bdos(write_protected ? 8 : 0); return;
        case 37: case 13:
            if (!(zsdos_flags & 0x04)) write_protected = false;
            ret_bdos(0); return;
        case 100: ret_bdos(zsdos_flags); return;
        case 101: zsdos_flags = cpu.regs.DE.get_low(); ret_bdos(zsdos_flags); return;
        case 15: {  // OPEN
            const string n = name_at(de);
            if (!files.count(n)) { ret_bdos(0xff); return; }
            open_name = n; ret_bdos(0); return;
        }
        case 16: ret_bdos(0); return;  // CLOSE: every record is already committed
        case 22: {  // MAKE
            if (write_protected) { ret_bdos(0xff); return; }
            const string n = name_at(de);
            files[n].clear(); open_name = n;
            put(de + 12, 0); put(de + 13, 0); put(de + 14, 0);
            put(de + 15, 0); put(de + 32, 0);
            ret_bdos(0); return;
        }
        case 19: {  // DELETE, ambiguous names allowed
            if (write_protected) { ret_bdos(0xff); return; }
            const string pat = name_at(de);
            unsigned hit = 0;
            for (auto it = files.begin(); it != files.end();) {
                if (matches(pat, it->first)) { it = files.erase(it); ++hit; }
                else ++it;
            }
            ret_bdos(hit ? 0 : 0xff); return;
        }
        case 23: {  // RENAME
            if (write_protected) { ret_bdos(0xff); return; }
            const string a = name_at(de), b = name_at(de, 17);
            if (!files.count(a) || files.count(b)) { ret_bdos(0xff); return; }
            files[b] = files[a]; files.erase(a); ret_bdos(0); return;
        }
        case 35: {  // COMPUTE FILE SIZE
            const string n = name_at(de);
            if (!files.count(n)) { ret_bdos(0xff); return; }
            unsigned recs = unsigned((files[n].size() + 127) / 128);
            put(de + 33, recs & 255); put(de + 34, (recs >> 8) & 255);
            put(de + 35, (recs >> 16) & 255);
            ret_bdos(0); return;
        }
        case 20: case 33: {  // READ SEQUENTIAL / RANDOM
            const string n = name_at(de);
            if (!files.count(n)) { ret_bdos(0xff); return; }
            unsigned rec = (f == 20) ? record_of(de) : random_of(de);
            vector<unsigned char> &d = files[n];
            if (rec * 128u >= d.size()) { ret_bdos(1); return; }
            for (unsigned i = 0; i < 128; ++i) {
                unsigned off = rec * 128u + i;
                put(dma + i, off < d.size() ? d[off] : 0x1a);
            }
            if (f == 20) advance(de);
            ret_bdos(0); return;
        }
        case 21: case 34: case 40: {  // WRITE SEQUENTIAL / RANDOM / ZERO FILL
            if (write_protected) { ret_bdos(0xff); return; }
            const string n = name_at(de);
            if (!files.count(n)) { ret_bdos(0xff); return; }
            unsigned rec = (f == 21) ? record_of(de) : random_of(de);
            vector<unsigned char> &d = files[n];
            // Function 34 leaves a skipped gap undefined; 40 guarantees zeros.
            // The fill value is deliberately not zero so the difference shows.
            bool zeros = (f == 40) && !block_zero_fill_only;
            if (d.size() < rec * 128u + 128u)
                d.resize(rec * 128u + 128u, zeros ? 0x00 : 0xCC);
            for (unsigned i = 0; i < 128; ++i) d[rec * 128u + i] = (unsigned char)byte(dma + i);
            if (f == 21) advance(de);
            ret_bdos(0); return;
        }
        default: throw runtime_error("unexpected BDOS function " + to_string(f));
        }
    }

    void run() {
        constexpr unsigned sp0 = 0xd000, back = 0xd100;
        mem.store_mem16(sp0, back);
        cpu.regs.SP.set_pair16(sp0);
        cpu.regs.PC.set_pair16(0x100);
        unsigned budget = 40000000;
        while (cpu.regs.PC.get_pair16() != back && budget--) {
            if (cpu.regs.PC.get_pair16() == 5) bdos();
            else cpu.execute();
        }
        need(budget > 0, "ZFCB execution timeout");
        need(cpu.regs.SP.get_pair16() == sp0 + 2, "ZFCB did not restore entry stack");
    }
    unsigned failures() const {
        unsigned n = 0;
        for (size_t a = output.find("FAIL"); a != string::npos; a = output.find("FAIL", a + 1)) ++n;
        return n;
    }
};

int main(int argc, char **argv) try {
    need(argc >= 2, "usage: zfcb-test zfcb.com");

    Rig clean(argv[1]);
    clean.run();
    if (clean.failures()) cerr << clean.output;
    need(clean.failures() == 0, "ZFCB reported a failure on an empty drive");
    need(clean.output.find("passed 14") != string::npos, "ZFCB did not pass 14 checks");
    need(clean.files.empty(), "ZFCB left files behind");
    need(!clean.write_protected, "ZFCB left the drive write protected");
    need(clean.zsdos_flags == 0x6d, "ZFCB did not restore the ZSDOS flags byte");

    // A leftover file from an interrupted run must not change the outcome.
    Rig leftover(argv[1]);
    leftover.files["ZFCBTST TMP"] = vector<unsigned char>(999, 0x77);
    leftover.files["ZFCBTS2 TMP"] = vector<unsigned char>(5, 0x77);
    leftover.run();
    if (leftover.failures()) cerr << leftover.output;
    need(leftover.failures() == 0, "ZFCB is not safe to re-run");
    need(leftover.files.empty(), "a re-run left files behind");

    // An unrelated file must survive: the wildcard is ZFCBT???TMP, not *.*.
    Rig bystander(argv[1]);
    bystander.files["IMPORTANTDAT"] = vector<unsigned char>(3, 9);
    bystander.run();
    need(bystander.failures() == 0, "ZFCB failed with an unrelated file present");
    need(bystander.files.count("IMPORTANTDAT") == 1, "ZFCB deleted an unrelated file");

    // The C: run showed ZFCB was asserting more than CP/M promises: it
    // required a gap inside an already-allocated block to read back as zeros.
    // It must pass against the weaker, documented guarantee too.
    Rig conventional(argv[1]);
    conventional.block_zero_fill_only = true;
    conventional.run();
    if (conventional.failures()) cerr << conventional.output;
    need(conventional.failures() == 0,
         "ZFCB assumes more than CP/M's function 40 guarantees");

    // `ZFCB WP` adds the write-protect set.  It is off by default because a
    // conventional drive answers a protected write with a BDOS error that
    // takes the console, rather than with a result code.
    Rig wp(argv[1]);
    const string tail = " WP";
    wp.put(0x80, tail.size());
    for (size_t i = 0; i < tail.size(); ++i) wp.put(0x81 + i, tail[i]);
    wp.run();
    if (wp.failures()) cerr << wp.output;
    need(wp.failures() == 0, "ZFCB WP reported a failure");
    need(wp.output.find("passed 17") != string::npos, "ZFCB WP did not pass 17 checks");
    need(!wp.write_protected, "ZFCB WP left the drive protected");
    need(wp.zsdos_flags == 0x6d, "ZFCB WP did not restore the ZSDOS flags byte");
    need(wp.files.empty(), "ZFCB WP left files behind");

    cout << "PASS: ZFCB make/write/read/random/zero-fill/rename/delete, "
            "re-runnable, clean, valid on a conventional drive, optional W/P set\n";
} catch (const exception &e) {
    cerr << "FAIL: " << e.what() << '\n';
    return 1;
}
