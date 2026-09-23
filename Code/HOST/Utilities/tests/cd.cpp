// Execute the assembled CD.COM with only its CALL 5 services mocked.
#include <qkz80/qkz80.h>

#include <algorithm>
#include <fstream>
#include <iostream>
#include <map>
#include <stdexcept>
#include <string>
#include <vector>

using namespace std;

static void need(bool value, const string &message) {
    if (!value) throw runtime_error(message);
}

struct CPU : qkz80 {
    explicit CPU(qkz80_cpu_mem *memory) : qkz80(memory) { set_cpu_mode(MODE_Z80); }
    void unimplemented_opcode(qkz80_uint8, qkz80_uint16 pc) override {
        throw runtime_error("unsupported opcode at " + to_string(pc));
    }
};

struct Rig {
    qkz80_cpu_mem memory;
    CPU cpu{&memory};
    map<string, unsigned> symbols;
    unsigned drive = 3;
    unsigned user = 8;
    unsigned native_calls = 0;
    unsigned native_user = 0xff;
    unsigned native_op = 0;
    string native_name;
    string output;
    vector<unsigned> user_sets;

    Rig(const char *binary, const char *symbol_file) {
        fill(memory.get_mem(), memory.get_mem() + 65536, 0);
        ifstream image(binary, ios::binary);
        image.read(reinterpret_cast<char *>(memory.get_mem()) + 0x100, 0xff00);
        need(image.gcount() > 0, "missing CD.COM");
        ifstream names(symbol_file);
        string name;
        unsigned value;
        while (names >> name >> value) symbols[name] = value;
    }

    unsigned byte(unsigned address) { return memory.fetch_mem(address); }
    unsigned word(unsigned address) { return memory.fetch_mem16(address); }
    void put(unsigned address, unsigned value) { memory.store_mem(address, value); }
    void put_word(unsigned address, unsigned value) { memory.store_mem16(address, value); }

    void return_from_bdos(unsigned result) {
        const unsigned sp = cpu.regs.SP.get_pair16();
        cpu.regs.PC.set_pair16(word(sp));
        cpu.regs.SP.set_pair16(sp + 2);
        cpu.regs.AF.set_high(result);
    }

    void bdos() {
        const unsigned function = cpu.regs.BC.get_low();
        if (function == 9) {
            unsigned address = cpu.regs.DE.get_pair16();
            while (byte(address) != '$') output.push_back(char(byte(address++)));
            return_from_bdos(0);
            return;
        }
        if (function == 25) {
            return_from_bdos(drive);
            return;
        }
        if (function == 32) {
            const unsigned requested = cpu.regs.DE.get_low();
            if (requested != 0xff) {
                user = requested;
                user_sets.push_back(user);
            }
            return_from_bdos(user);
            return;
        }
        if (function == 218) {
            const unsigned descriptor = cpu.regs.DE.get_pair16();
            need(byte(descriptor) == 1, "bad native descriptor version");
            native_op = byte(descriptor + 1);
            need(native_op == 9 || native_op == 19,
                 "CD issued something other than CHDIR or CDUP");
            native_calls++;
            native_user = user;
            native_name.clear();
            for (unsigned i = 0; i < 11; ++i)
                native_name.push_back(char(byte(descriptor + 18 + i)));
            put(descriptor + 2, 0);
            return_from_bdos(0);
            return;
        }
        throw runtime_error("unexpected BDOS function " + to_string(function));
    }

    void setup(unsigned current_drive, unsigned current_user, unsigned fcb_drive,
               const string &name, const string &tail) {
        drive = current_drive;
        user = current_user;
        for (unsigned i = 0; i < 36; ++i) put(0x5c + i, 0);
        put(0x5c, fcb_drive);
        for (unsigned i = 0; i < 11; ++i)
            put(0x5d + i, i < name.size() ? unsigned(name[i]) : unsigned(' '));
        put(0x80, tail.size());
        for (unsigned i = 0; i < tail.size(); ++i) put(0x81 + i, tail[i]);
        put(0x81 + tail.size(), 0);
    }

    void run() {
        constexpr unsigned entry_sp = 0xd000;
        constexpr unsigned return_pc = 0xd100;
        put_word(entry_sp, return_pc);  // ZCPR's CALL 0100h return address
        cpu.regs.SP.set_pair16(entry_sp);
        cpu.regs.PC.set_pair16(0x100);
        unsigned budget = 200000;
        while (cpu.regs.PC.get_pair16() != return_pc && budget--) {
            if (cpu.regs.PC.get_pair16() == 5) bdos();
            else cpu.execute();
        }
        need(budget > 0, "CD execution timeout");
        need(cpu.regs.SP.get_pair16() == entry_sp + 2, "CD did not restore entry stack");
    }
};

int main(int argc, char **argv) try {
    need(argc == 3, "usage: cd-test cd.com symbols");

    Rig bare(argv[1], argv[2]);
    bare.setup(1, 8, 0, "", "");
    bare.run();
    need(bare.native_calls == 1 && bare.native_user == 8 && bare.native_name[0] == 0,
         "bare B8: root selection");
    need(bare.user == 8 && bare.user_sets.empty(), "bare CD changed USER");

    Rig remote(argv[1], argv[2]);
    remote.setup(0, 14, 2, "TESTDIR    ", " B8:TESTDIR");
    remote.run();
    need(remote.native_calls == 1 && remote.native_user == 8 &&
             remote.native_name == "TESTDIR    ",
         "remote B8:TESTDIR selection");
    need(remote.user == 14 && remote.user_sets == vector<unsigned>({8, 14}),
         "remote CD did not restore USER 14");

    Rig root(argv[1], argv[2]);
    root.setup(2, 0, 2, "           ", " B8:");
    root.run();
    need(root.native_calls == 1 && root.native_user == 8 && root.native_name[0] == ' ',
         "remote B8: root selection");
    need(root.user == 0 && root.user_sets == vector<unsigned>({8, 0}),
         "remote root did not restore USER 0");

    Rig wrong_drive(argv[1], argv[2]);
    wrong_drive.setup(2, 0, 0, "TESTDIR    ", " TESTDIR");
    wrong_drive.run();
    need(wrong_drive.native_calls == 0 &&
             wrong_drive.output.find("target must be B0") != string::npos,
         "relative CD from a non-FAT drive was accepted");

    // "CD .." must step up, not jump to the root.  The CCP hands this program
    // eleven spaces for it -- the same as a bare CD -- so the only thing that
    // can tell them apart is the untouched command tail.
    Rig up(argv[1], argv[2]);
    up.setup(1, 8, 0, "           ", " ..");
    up.run();
    need(up.native_calls == 1 && up.native_op == 19, "CD .. did not use CDUP");

    Rig up_drive(argv[1], argv[2]);
    up_drive.setup(0, 8, 2, "           ", " B8:..");
    up_drive.run();
    need(up_drive.native_calls == 1 && up_drive.native_op == 19,
         "CD B8:.. did not use CDUP");

    // A bare CD still selects the root, and a named directory still descends.
    Rig bare2(argv[1], argv[2]);
    bare2.setup(1, 8, 0, "", "");
    bare2.run();
    need(bare2.native_calls == 1 && bare2.native_op == 9, "bare CD stopped using CHDIR");

    Rig dotfile(argv[1], argv[2]);
    dotfile.setup(1, 8, 0, "GAMES      ", " GAMES");
    dotfile.run();
    need(dotfile.native_calls == 1 && dotfile.native_op == 9, "CD GAMES stopped using CHDIR");

    cout << "PASS: CD direct return, bare root, explicit B8 target, USER restore, "
            "and CD .. stepping one level up\n";
} catch (const exception &error) {
    cerr << "FAIL: " << error.what() << '\n';
    return 1;
}
