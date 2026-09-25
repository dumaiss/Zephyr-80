// Runs the assembled synthetic FAT BIOS in libqkz80. Ports are unused.
#include <qkz80/qkz80.h>

#include <fstream>
#include <iostream>
#include <map>
#include <stdexcept>
#include <string>

using namespace std;

void require(bool ok, const string &why) {
    if (!ok) throw runtime_error(why);
}

struct CPU : qkz80 {
    explicit CPU(qkz80_cpu_mem *memory) : qkz80(memory) {
        set_cpu_mode(MODE_Z80);
    }
    void port_out(qkz80_uint8, qkz80_uint8) override {}
    qkz80_uint8 port_in(qkz80_uint8) override { return 0; }
    void block_io(qkz80_uint8 opcode) override {
        throw runtime_error("unexpected port opcode " + to_string(opcode));
    }
    void unimplemented_opcode(qkz80_uint8, qkz80_uint16 pc) override {
        throw runtime_error("unsupported instruction at " + to_string(pc));
    }
};

struct Rig {
    qkz80_cpu_mem mem;
    CPU cpu{&mem};
    map<string, unsigned> sym;

    Rig(const char *binary, const char *symbols) {
        ifstream image(binary, ios::binary);
        image.read(reinterpret_cast<char *>(mem.get_mem()), 65536);
        require(image.gcount() == 65536, "missing flat firmware");
        ifstream names(symbols);
        string name;
        unsigned value;
        while (names >> name >> value) sym[name] = value;
        cpu.regs.SP.set_pair16(0xd800);
    }

    unsigned at(const string &name) { return sym.at(name); }

    void run(unsigned stop, unsigned budget = 100000) {
        while (cpu.regs.PC.get_pair16() != stop && budget--) cpu.execute();
        require(cpu.regs.PC.get_pair16() == stop, "execution timeout");
    }

    void call(const string &name) {
        unsigned sp = cpu.regs.SP.get_pair16();
        mem.store_mem16(sp - 2, 0xd100);
        cpu.regs.SP.set_pair16(sp - 2);
        cpu.regs.PC.set_pair16(at(name));
        run(0xd100);
        require(cpu.regs.SP.get_pair16() == sp, "unbalanced stack: " + name);
    }

    unsigned word(unsigned address) { return mem.fetch_mem16(address); }
};

int main(int argc, char **argv) try {
    require(argc == 3, "usage: fat_bios_m1 firmware_flat.bin symbols.txt");
    Rig t(argv[1], argv[2]);
    auto &r = t.cpu.regs;

    const unsigned dph = t.at("FAT_BIOS_DPH");
    const unsigned dpb = t.at("FAT_BIOS_DPB");
    const unsigned alv = t.at("FAT_BIOS_ALV");
    require(t.word(dph + 8) == t.at("CBIOS_STORAGE_DIRBUF"), "wrong DIRBUF pointer");
    require(t.word(dph + 10) == dpb, "wrong DPB pointer");
    require(t.word(dph + 12) == 0, "synthetic CSV is not null");
    require(t.word(dph + 14) == alv, "wrong ALV pointer");
    require(t.word(dpb) == 4, "wrong SPT");
    require(t.mem.fetch_mem(dpb + 2) == 5, "wrong BSH");
    require(t.mem.fetch_mem(dpb + 3) == 31, "wrong BLM");
    require(t.mem.fetch_mem(dpb + 4) == 1, "wrong EXM");
    require(t.word(dpb + 5) == 2047, "wrong DSM");
    require(t.word(dpb + 7) == 511, "wrong DRM");
    require(t.mem.fetch_mem(dpb + 9) == 0xf0, "wrong AL0");

    const unsigned dma = 0xd200;
    t.mem.store_mem16(t.at("cbios_dma_addr"), dma);
    r.BC.set_pair16(7);
    t.call("fat_bios_settrk");
    r.BC.set_pair16(3);
    t.call("fat_bios_setsec");
    for (unsigned i = 0; i < 128; ++i) t.mem.store_mem(dma + i, 0x5a);
    t.call("fat_bios_read");
    require(r.AF.get_high() == 0, "valid READ failed");
    for (unsigned i = 0; i < 128; ++i)
        require(t.mem.fetch_mem(dma + i) == 0xe5, "READ did not fill E5");

    r.BC.set_pair16(0x4000);
    t.call("fat_bios_settrk");
    t.call("fat_bios_read");
    require(r.AF.get_high() == 1, "out-of-range track accepted");
    t.call("fat_bios_home");
    r.BC.set_pair16(4);
    t.call("fat_bios_setsec");
    t.call("fat_bios_read");
    require(r.AF.get_high() == 1, "out-of-range sector accepted");
    t.call("fat_bios_write");
    require(r.AF.get_high() == 1, "synthetic WRITE succeeded");

    if (!t.at("FAT_DRIVE_ENABLED")) {
        r.BC.set_low(3);
        t.call("stg_seldsk");
        require(r.HL.get_pair16() == 0, "disabled D: was exposed");
        require(t.mem.fetch_mem(t.at("stg_drive")) == 0xff, "failed select not parked");
    }

    cout << "PASS: FAT BIOS DPH, empty READ, WRITE failure, bounds and disabled gate\n";
} catch (const exception &error) {
    cerr << "FAIL: " << error.what() << '\n';
    return 1;
}
