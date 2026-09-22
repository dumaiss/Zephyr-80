// Execute the assembled ZFW.COM against a model of the bank-7 native file
// service, so the program's own logic is proven before it is run on hardware.
//
// The model deliberately mirrors ../../CPM2.2/src/cbios_fat_layout.asm rather
// than being convenient: OPEN reports the existing size through ZN_POSITION
// and resets the slot position, WRITE and READ advance that slot position,
// TRUNCATE takes its size from ZN_POSITION, and BDOS 28/37 reset FAT context.
// If ZFW passes here but fails on the machine, the difference is in the real
// controller path, not in ZFW.
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

// ZN_ status bytes; ../src/zbdos.inc is the authority.
enum {
    ZN_OK = 0x00,
    ZN_ERR_NOT_FOUND = 0x40,
    ZN_ERR_EXISTS = 0x42,
    ZN_ERR_READ_ONLY = 0x44,
    ZN_ERR_NO_HANDLE = 0x48,
    ZN_ERR_RANGE = 0x4a,
    ZN_ERR_UNKNOWN_WRITE = 0x4d,
};

// Descriptor offsets; ../src/zbdos.inc is the authority.
enum {
    OFF_VERSION = 0, OFF_OP = 1, OFF_STATUS = 2, OFF_FLAGS = 3,
    OFF_HANDLE = 4, OFF_POSITION = 6, OFF_LENGTH = 10, OFF_BUFFER = 12,
    OFF_RESULT = 16, OFF_NAME = 18,
};

enum {
    OP_OPEN = 1, OP_CLOSE = 2, OP_READ = 3, OP_SEEK = 4, OP_TELL = 5,
    OP_STAT = 6, OP_WRITE = 10, OP_SYNC = 11, OP_TRUNCATE = 12,
};

enum { MODE_READ = 0, MODE_UPDATE = 1, MODE_CREATE_NEW = 2, MODE_CREATE_ALWAYS = 3 };

constexpr unsigned CHUNK_MAX = 512;
constexpr unsigned SLOTS = 2;  // IOC_FS2_FILE_SLOTS

struct CPU : qkz80 {
    explicit CPU(qkz80_cpu_mem *memory) : qkz80(memory) { set_cpu_mode(MODE_Z80); }
    void unimplemented_opcode(qkz80_uint8, qkz80_uint16 pc) override {
        throw runtime_error("unsupported opcode at " + to_string(pc));
    }
};

struct Slot {
    bool active = false;
    unsigned mode = MODE_READ;
    string name;
    unsigned position = 0;
};

struct Rig {
    qkz80_cpu_mem memory;
    CPU cpu{&memory};
    unsigned drive = 3;             // D: is the FAT-backed drive
    map<string, vector<unsigned char>> files;
    Slot slots[SLOTS];
    bool write_protected = false;
    // zsdos.lib ships FLGBITS = 01101101B; bit 2 is "Read-Only Enable", and
    // CMND37 skips the DSKWP clear whenever it is set.
    unsigned zsdos_flags = 0x6d;
    bool honour_reset_drive = true; // false models a reset that never clears
    bool controller_writes = true;  // false models a controller predating Milestone 5
    bool answer_caps = true;        // false models a controller that drops the frame
    unsigned fail_write_after = 0;  // 0 = never; otherwise fail the Nth write
    unsigned write_status = ZN_ERR_UNKNOWN_WRITE;
    unsigned writes = 0;
    string output;

    Rig(const char *binary, const char *symbol_file) {
        fill(memory.get_mem(), memory.get_mem() + 65536, 0);
        ifstream image(binary, ios::binary);
        image.read(reinterpret_cast<char *>(memory.get_mem()) + 0x100, 0xff00);
        need(image.gcount() > 0, "missing ZFW.COM");
        (void)symbol_file;
    }

    unsigned byte(unsigned address) { return memory.fetch_mem(address); }
    unsigned word(unsigned address) { return memory.fetch_mem16(address); }
    void put(unsigned address, unsigned value) { memory.store_mem(address, value); }
    void put_word(unsigned address, unsigned value) { memory.store_mem16(address, value); }

    unsigned dword(unsigned address) {
        return word(address) | (word(address + 2) << 16);
    }
    void put_dword(unsigned address, unsigned value) {
        put_word(address, value & 0xffff);
        put_word(address + 2, (value >> 16) & 0xffff);
    }

    void return_from_bdos(unsigned result) {
        const unsigned sp = cpu.regs.SP.get_pair16();
        cpu.regs.PC.set_pair16(word(sp));
        cpu.regs.SP.set_pair16(sp + 2);
        cpu.regs.AF.set_high(result);
    }

    // Function 28 and 37 both run fat_context_reset before touching the vector.
    void context_reset() {
        for (Slot &slot : slots) slot = Slot();
    }

    string name_at(unsigned descriptor) {
        string name;
        for (unsigned i = 0; i < 11; ++i) name.push_back(char(byte(descriptor + OFF_NAME + i)));
        return name;
    }

    // Returns a slot index, or SLOTS with *status set, exactly as
    // fat_native_slot does: handle 0 and handles above 2 are both NO_HANDLE.
    unsigned slot_for(unsigned descriptor, unsigned *status) {
        const unsigned handle = byte(descriptor + OFF_HANDLE);
        if (handle == 0 || handle > SLOTS || !slots[handle - 1].active) {
            *status = ZN_ERR_NO_HANDLE;
            return SLOTS;
        }
        *status = ZN_OK;
        return handle - 1;
    }

    unsigned native_open(unsigned descriptor) {
        const unsigned mode = byte(descriptor + OFF_FLAGS);
        if (mode > MODE_CREATE_ALWAYS) return ZN_ERR_RANGE;
        if (mode != MODE_READ && write_protected) return ZN_ERR_READ_ONLY;
        const string name = name_at(descriptor);
        const bool exists = files.count(name) != 0;
        if (mode == MODE_CREATE_NEW && exists) return ZN_ERR_EXISTS;
        if (mode == MODE_UPDATE && !exists) return ZN_ERR_NOT_FOUND;
        if (mode == MODE_READ && !exists) return ZN_ERR_NOT_FOUND;
        unsigned index = SLOTS;
        for (unsigned i = 0; i < SLOTS; ++i)
            if (!slots[i].active) { index = i; break; }
        if (index == SLOTS) return ZN_ERR_NO_HANDLE;
        if (mode == MODE_CREATE_ALWAYS || !exists) files[name].clear();
        slots[index] = Slot{true, mode, name, 0};
        put(descriptor + OFF_HANDLE, index + 1);
        put_dword(descriptor + OFF_POSITION, files[name].size());
        put(descriptor + OFF_FLAGS, 0);  // FAT attributes are not projected
        return ZN_OK;
    }

    unsigned native_transfer(unsigned descriptor, bool writing) {
        unsigned status = ZN_OK;
        const unsigned index = slot_for(descriptor, &status);
        if (status != ZN_OK) return status;
        Slot &slot = slots[index];
        if (writing && slot.mode == MODE_READ) return ZN_ERR_READ_ONLY;
        if (writing && write_protected) return ZN_ERR_READ_ONLY;
        const unsigned length = word(descriptor + OFF_LENGTH);
        if (length == 0 || length > CHUNK_MAX) return ZN_ERR_RANGE;
        const unsigned buffer = word(descriptor + OFF_BUFFER);
        vector<unsigned char> &data = files[slot.name];
        unsigned moved = 0;
        if (writing) {
            if (++writes == fail_write_after) return write_status;
            if (slot.position + length > data.size()) data.resize(slot.position + length, 0);
            for (unsigned i = 0; i < length; ++i) data[slot.position + i] = byte(buffer + i);
            moved = length;
        } else {
            while (moved < length && slot.position + moved < data.size()) {
                put(buffer + moved, data[slot.position + moved]);
                ++moved;
            }
        }
        slot.position += moved;
        put_word(descriptor + OFF_RESULT, moved);
        return ZN_OK;
    }

    unsigned native(unsigned descriptor) {
        need(byte(descriptor + OFF_VERSION) == 1, "bad native descriptor version");
        const unsigned op = byte(descriptor + OFF_OP);
        unsigned status = ZN_OK;
        unsigned index = SLOTS;
        switch (op) {
        case OP_OPEN:
            return native_open(descriptor);
        case OP_CLOSE:
            index = slot_for(descriptor, &status);
            if (status != ZN_OK) return status;
            slots[index] = Slot();
            return ZN_OK;
        case OP_READ:
            return native_transfer(descriptor, false);
        case OP_WRITE:
            return native_transfer(descriptor, true);
        case OP_SEEK:
            index = slot_for(descriptor, &status);
            if (status != ZN_OK) return status;
            slots[index].position = dword(descriptor + OFF_POSITION);
            return ZN_OK;
        case OP_TELL:
            index = slot_for(descriptor, &status);
            if (status != ZN_OK) return status;
            put_dword(descriptor + OFF_POSITION, slots[index].position);
            return ZN_OK;
        case OP_SYNC:
            index = slot_for(descriptor, &status);
            if (status != ZN_OK) return status;
            if (slots[index].mode == MODE_READ) return ZN_ERR_READ_ONLY;
            return ZN_OK;
        case OP_TRUNCATE: {
            index = slot_for(descriptor, &status);
            if (status != ZN_OK) return status;
            Slot &slot = slots[index];
            if (slot.mode == MODE_READ) return ZN_ERR_READ_ONLY;
            if (write_protected) return ZN_ERR_READ_ONLY;
            const unsigned size = dword(descriptor + OFF_POSITION);
            files[slot.name].resize(size, 0);
            slot.position = size;
            return ZN_OK;
        }
        case OP_STAT: {
            // STAT opens and closes internally, so it needs a free slot.
            bool free_slot = false;
            for (const Slot &slot : slots) free_slot = free_slot || !slot.active;
            if (!free_slot) return ZN_ERR_NO_HANDLE;
            const string name = name_at(descriptor);
            if (!files.count(name)) return ZN_ERR_NOT_FOUND;
            put_dword(descriptor + OFF_POSITION, files[name].size());
            put(descriptor + OFF_FLAGS, 0);
            return ZN_OK;
        }
        default:
            throw runtime_error("unexpected native op " + to_string(op));
        }
    }

    void bdos() {
        const unsigned function = cpu.regs.BC.get_low();
        if (function == 2) {
            output.push_back(char(cpu.regs.DE.get_low()));
            return_from_bdos(0);
            return;
        }
        if (function == 9) {
            unsigned address = cpu.regs.DE.get_pair16();
            while (byte(address) != '$') output.push_back(char(byte(address++)));
            return_from_bdos(0);
            return;
        }
        if (function == 11) {  // CONST: releases a buffered console print run
            return_from_bdos(0);
            return;
        }
        if (function == 25) {
            return_from_bdos(drive);
            return;
        }
        if (function == 28) {
            write_protected = true;
            context_reset();
            return_from_bdos(0);
            return;
        }
        if (function == 29) {  // read-only vector; D: is bit 3
            const unsigned vector = write_protected ? 0x0008 : 0x0000;
            cpu.regs.HL.set_pair16(vector);
            return_from_bdos(vector & 0xff);
            return;
        }
        if (function == 100) {  // ZSDOS Get Flags
            return_from_bdos(zsdos_flags);
            return;
        }
        if (function == 101) {  // ZSDOS Set Flags
            zsdos_flags = cpu.regs.DE.get_low();
            return_from_bdos(zsdos_flags);
            return;
        }
        if (function == 13) {
            if (honour_reset_drive && !(zsdos_flags & 0x04)) write_protected = false;
            drive = 0;
            context_reset();
            return_from_bdos(0);
            return;
        }
        if (function == 14) {
            drive = cpu.regs.DE.get_low();
            return_from_bdos(0);
            return;
        }
        if (function == 37) {
            if (honour_reset_drive && !(zsdos_flags & 0x04) &&
                (cpu.regs.DE.get_pair16() & 0x0008) != 0)
                write_protected = false;
            context_reset();
            return_from_bdos(0);
            return;
        }
        if (function == 214) {  // IOCALL through the zb_regs block
            const unsigned regs = cpu.regs.DE.get_pair16();
            const unsigned tx = word(regs + 5);
            const unsigned rx = word(regs + 3);
            need(byte(tx + 0) == 0x30, "unexpected raw IOC command from ZFW");
            if (!answer_caps) {
                put(regs, 0x01);  // IOC_XPORT_TIMEOUT
                return_from_bdos(0x01);
                return;
            }
            put(rx + 0, 0xb0);           // RSP_FS2_CAPS
            put(rx + 2, 0);              // status
            put(rx + 3, 14);             // payload length
            put(rx + 4, 1);              // version
            put(rx + 5, 1);              // status version
            // CAP_READ_ONLY|EXPLICIT_OFFSET|COMPONENT_RESOLVER|MEDIA_GENERATION
            // |STAT|SPACE, plus WRITE|TRUNCATE on a Milestone-5 controller.
            put_word(rx + 6, controller_writes ? 0x00ff : 0x003f);
            put(regs, 0);
            return_from_bdos(0);
            return;
        }
        if (function == 218) {
            const unsigned descriptor = cpu.regs.DE.get_pair16();
            const unsigned status = native(descriptor);
            put(descriptor + OFF_STATUS, status);
            return_from_bdos(status);
            return;
        }
        throw runtime_error("unexpected BDOS function " + to_string(function));
    }

    void run() {
        constexpr unsigned entry_sp = 0xd000;
        constexpr unsigned return_pc = 0xd100;
        put_word(entry_sp, return_pc);  // ZCPR's CALL 0100h return address
        cpu.regs.SP.set_pair16(entry_sp);
        cpu.regs.PC.set_pair16(0x100);
        unsigned budget = 40000000;
        while (cpu.regs.PC.get_pair16() != return_pc && budget--) {
            if (cpu.regs.PC.get_pair16() == 5) bdos();
            else cpu.execute();
        }
        need(budget > 0, "ZFW execution timeout");
        need(cpu.regs.SP.get_pair16() == entry_sp + 2, "ZFW did not restore entry stack");
    }

    unsigned failures() const {
        unsigned count = 0;
        for (size_t at = output.find("FAIL"); at != string::npos;
             at = output.find("FAIL", at + 1))
            ++count;
        return count;
    }
};

static void report(const Rig &rig, const string &label) {
    cerr << "--- " << label << " ---\n" << rig.output << '\n';
}

int main(int argc, char **argv) try {
    need(argc == 3, "usage: zfw-test zfw.com symbols");
    const char *binary = argv[1];
    const char *symbols = argv[2];

    // A card that has never seen ZFW: every check must pass, including the
    // create-new path that only a first run can take.
    Rig fresh(binary, symbols);
    fresh.run();
    if (fresh.failures() != 0) report(fresh, "fresh");
    need(fresh.failures() == 0, "ZFW reported a failure on a fresh volume");
    need(fresh.output.find("passed 28") != string::npos, "fresh run did not pass 28 checks");
    need(fresh.files.count("ZFWTEST TMP") == 1, "ZFW did not leave its test file");
    for (const Slot &slot : fresh.slots) need(!slot.active, "ZFW leaked a handle");
    need(!fresh.write_protected, "ZFW left the drive write protected");

    // A repeat run on the same volume: create-new must now report EXISTS and
    // the program must still pass, which is what makes it safe to re-run.
    Rig repeat(binary, symbols);
    repeat.files = fresh.files;
    repeat.run();
    if (repeat.failures() != 0) report(repeat, "repeat");
    need(repeat.failures() == 0, "ZFW reported a failure on a re-run");
    need(repeat.output.find("passed 28") != string::npos, "repeat run did not pass 28 checks");

    // Not the FAT-backed drive: refuse rather than write somewhere else.
    Rig wrong_drive(binary, symbols);
    wrong_drive.drive = 1;
    wrong_drive.run();
    need(wrong_drive.files.empty() &&
             wrong_drive.output.find("must run on the FAT-backed drive") != string::npos,
         "ZFW ran against a conventional drive");

    // An uncertain commit must be reported as itself, not swallowed: 4d is the
    // status the whole checkpoint exists to make visible.
    Rig unknown(binary, symbols);
    unknown.fail_write_after = 1;
    unknown.write_status = ZN_ERR_UNKNOWN_WRITE;
    unknown.run();
    need(unknown.output.find("FAIL 4D") != string::npos,
         "an unknown write completion was not reported as 4D");

    // A drive that stays protected must be called out, because otherwise every
    // later write in the session fails for an unrelated-looking reason.
    Rig stuck(binary, symbols);
    stuck.honour_reset_drive = false;
    stuck.run();
    need(stuck.output.find("left write protected") != string::npos,
         "a stuck write-protect bit was not reported");

    // A controller that predates the writable commands must be named, not
    // written to: CMD_FS2_OPEN_RW is dropped by its transport, so the host
    // would otherwise wait for a reply that is never sent.
    Rig old_firmware(binary, symbols);
    old_firmware.controller_writes = false;
    old_firmware.run();
    need(old_firmware.files.empty() &&
             old_firmware.output.find("no FS2 write support") != string::npos &&
             old_firmware.output.find("caps=003F") != string::npos,
         "a controller without write support was not reported");

    Rig mute(binary, symbols);
    mute.answer_caps = false;
    mute.run();
    need(mute.files.empty() &&
             mute.output.find("No FS2 capability reply") != string::npos,
         "a controller that ignored FS2 CAPS was not reported");

    cout << "PASS: ZFW capability preflight, fresh and repeat runs, drive guard, "
            "unknown write, stuck write protect\n";
} catch (const exception &error) {
    cerr << "FAIL: " << error.what() << '\n';
    return 1;
}
