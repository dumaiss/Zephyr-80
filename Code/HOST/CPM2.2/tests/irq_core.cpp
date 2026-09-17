// Runs the assembled BIOS in libqkz80; ports are mocked, not a machine model.
#include <qkz80/qkz80.h>
#include <algorithm>
#include <array>
#include <fstream>
#include <iostream>
#include <map>
#include <stdexcept>
#include <vector>
using namespace std;
void require(bool ok, const string &why) { if (!ok) throw runtime_error(why); }
struct CPU : qkz80 {
    vector<pair<int,int>> writes;
    int rx = 0, ctrl = 0x23, data = 0x22;
    explicit CPU(qkz80_cpu_mem *m) : qkz80(m) { set_cpu_mode(MODE_Z80); }
    void port_out(qkz80_uint8 p, qkz80_uint8 v) override { writes.emplace_back(p,v); }
    qkz80_uint8 port_in(qkz80_uint8 p) override {
        if (p == ctrl) return rx ? 1 : 0;
        if (p == data) { --rx; return 'K'; }
        return 0;
    }
    void block_io(qkz80_uint8 opcode) override {
        // libqkz80 delegates ED-prefixed port operations to this hook.
        if (opcode == 0x79) { port_out(regs.BC.get_low(),regs.AF.get_high()); return; }
        throw runtime_error("unsupported port opcode " + to_string(opcode));
    }
    void unimplemented_opcode(qkz80_uint8, qkz80_uint16 pc) override {
        throw runtime_error("unsupported instruction at " + to_string(pc));
    }
};
struct Rig {
    qkz80_cpu_mem mem;
    CPU cpu{&mem};
    map<string,unsigned> sym;
    unsigned minsp=0xffff;
    Rig(const char *binary, const char *symbols) {
        ifstream f(binary,ios::binary); f.read((char*)mem.get_mem(),65536);
        require(f.gcount()==65536,"missing flat firmware");
        ifstream s(symbols); string name; unsigned value;
        while(s>>name>>value) sym[name]=value;
        cpu.regs.SP.set_pair16(0xd000);
    }
    unsigned at(const string &n) { return sym.at(n); }
    void iff(bool on) { cpu.regs.IFF1=cpu.regs.IFF2=on; cpu.ei_delay=false; }
    void step() {
        // This libqkz80 build omits OUT (C),A; supply that port-only opcode.
        unsigned pc=cpu.regs.PC.get_pair16();
        if (mem.fetch_mem(pc)==0xed && mem.fetch_mem(pc+1)==0x79) {
            cpu.port_out(cpu.regs.BC.get_low(),cpu.regs.AF.get_high());
            cpu.regs.PC.set_pair16(pc+2);
        } else cpu.execute();
        unsigned sp=cpu.regs.SP.get_pair16();
        if (sp>=0xfe00 && sp<=at("CBIOS_ISR_STACK_TOP")) minsp=min(minsp,sp);
    }
    void run(unsigned stop, unsigned budget=3000000) {
        while(cpu.regs.PC.get_pair16()!=stop && budget--) step();
        require(cpu.regs.PC.get_pair16()==stop,"execution timeout at "+to_string(cpu.regs.PC.get_pair16()));
    }
    void call(const string &n) {
        unsigned sp=cpu.regs.SP.get_pair16(); mem.store_mem16(sp-2,0xd100);
        cpu.regs.SP.set_pair16(sp-2); cpu.regs.PC.set_pair16(at(n)); run(0xd100);
        require(cpu.regs.SP.get_pair16()==sp,"unbalanced stack: "+n);
    }
    void callback(unsigned addr) {
        // Clobber all general/index/alternate registers, then exercise an
        // ISR-reachable critical section. Its zero token must never enable EI.
        vector<unsigned char> code={0x01,1,2,0x11,3,4,0x21,5,6,0x3e,7,
            0xdd,0x21,8,9,0xfd,0x21,10,11,0xd9,0x01,12,13,0x11,14,15,
            0x21,16,17,0xd9,0x08,0x3e,18,0x08};
        for(auto name: {"sio_core_rx_lock","sio_core_rx_unlock"}) {
            unsigned a=at(name); code.insert(code.end(),{0xcd,(unsigned char)a,(unsigned char)(a>>8)});
        }
        code.push_back(0xc9);
        copy(code.begin(),code.end(),mem.get_mem()+addr);
    }
    array<unsigned,10> context() {
        auto &r=cpu.regs;
        return {r.AF.get_pair16(),r.BC.get_pair16(),r.DE.get_pair16(),r.HL.get_pair16(),
            r.IX.get_pair16(),r.IY.get_pair16(),r.AF_.get_pair16(),r.BC_.get_pair16(),r.DE_.get_pair16(),r.HL_.get_pair16()};
    }
    void seed() {
        auto &r=cpu.regs;
        r.AF.set_pair16(0x0123);r.BC.set_pair16(0x4567);r.DE.set_pair16(0x89ab);r.HL.set_pair16(0xcdef);
        r.IX.set_pair16(0x2468);r.IY.set_pair16(0x1357);r.AF_.set_pair16(0x9876);
        r.BC_.set_pair16(0x5432);r.DE_.set_pair16(0x1020);r.HL_.set_pair16(0x3040);
    }
    void interrupt(unsigned vector) {
        seed(); auto before=context(); unsigned sp=cpu.regs.SP.get_pair16();
        cpu.regs.PC.set_pair16(0xd100);cpu.regs.I=0xfd;cpu.regs.IM=2;iff(true);
        cpu.request_int(vector);require(cpu.check_interrupts(),"INT not accepted");
        bool returned=false;
        for(unsigned count=0;count<10000;++count) {
            // A test-side active sentinel: SP save may only contain the original
            // foreground SP; callbacks must remain masked until core EI/RETI.
            unsigned pc=cpu.regs.PC.get_pair16();
            if (pc==0xd100) { returned=true; break; }
            require(!cpu.regs.IFF1 || mem.fetch_mem(pc)==0xed,
                    "interrupts enabled inside callback/body at "+to_string(pc));
            step();
        }
        require(returned,"ISR failed to return");
        require(context()==before,"foreground registers changed for vector "+to_string(vector));
        require(cpu.regs.SP.get_pair16()==sp,"foreground SP changed");
        require(cpu.regs.IFF1 && cpu.regs.IFF2,"ISR did not restore enables");
        if(vector<0x20) require(mem.fetch_mem16(at("CBIOS_ISR_SP_SAVE"))==sp-2,"saved SP overwritten");
        require(minsp>=at("CBIOS_ISR_SP_SAVE")+2,"ISR stack overflow");
    }
};
int main(int argc,char **argv) try {
    require(argc==3,"usage: irq_core firmware_flat.bin symbols.txt");
    Rig t(argv[1],argv[2]); auto &r=t.cpu.regs;
    for(bool enabled:{false,true}) {
        t.iff(enabled);t.call("irq_save_disable");auto token=r.AF.get_high();
        require(token==enabled && !r.IFF1,"bad saved interrupt token");
        t.call("irq_save_disable");require(!r.AF.get_high(),"nested token enabled");
        t.call("irq_restore");require(!r.IFF1,"inner restore enabled");
        r.AF.set_high(token);t.call("irq_restore");require(bool(r.IFF1)==enabled,"outer state not restored");
        t.cpu.writes.clear();t.iff(enabled);t.call("sio_core_enable_interrupts");require(bool(r.IFF1)==enabled,"SIO enable changed global IFF");
        for(auto [port,value]:t.cpu.writes)
            require(port!=0x21 || value==0x38,"SIO enable reconfigured application channel A");
        require(t.mem.fetch_mem16(t.at("irq_sio_slot"))==t.at("sio_core_isr"),"SIO callback not registered");
        t.call("sio_core_disable_interrupts");
        require(t.mem.fetch_mem16(t.at("irq_sio_slot"))==0,"SIO disable retained kernel registration");
        require(bool(r.IFF1)==enabled,"SIO disable changed global IFF");
        for(auto lane:{"ioc_cmd_irq_","ioc_bulk_irq_"}) {
            t.call(string(lane)+"save");r.AF.set_pair16(0x5a33);t.call(string(lane)+"restore");
            require(r.AF.get_pair16()==0x5a33 && bool(r.IFF1)==enabled,"IOC lost result or IFF");
        }
        // Actual send timeout path, then bulk transfer timeout/error paths.
        r.HL.set_pair16(0xd200);t.mem.store_mem(0xd200,0);t.call("ioc_command_send_frame");
        require(bool(r.IFF1)==enabled,"command error changed IFF");
        r.HL.set_pair16(0xd200);r.DE.set_pair16(1);t.call("iocbulk_body");
        require(bool(r.IFF1)==enabled,"bulk error changed IFF");
    }
    for(unsigned ptr:{0xe000,0xefff,0xf958,0xffff}) {
        r.BC.set_high(4);r.DE.set_pair16(ptr);t.call("irq_register_kernel");
        require(r.AF.get_high()==0xff,"unsafe kernel entry accepted");
    }
    t.iff(false);r.I=0;r.IM=0;t.call("irq_boot_prepare");
    require(r.I==0xfd && r.IM==2 && !r.IFF1,"boot IRQ setup incorrect");
    t.callback(0xe000);
    array<int,4> ports={0x40,0x42,0x41,0x43};
    for(unsigned ch=0;ch<4;++ch) {
        t.iff(false);r.BC.set_high(ch);r.DE.set_pair16(0xe000);t.call("irq_register");
        require(r.AF.get_high()==0 && !r.IFF1,"register failed");
        t.call("irq_register");require(r.AF.get_high()==0xff,"duplicate accepted");
        t.interrupt(ch*2);
        r.BC.set_high(ch);t.cpu.writes.clear();t.call("irq_unregister");
        require(t.cpu.writes==vector<pair<int,int>>{{ports[ch],3}},"wrong CTC reset port");
        t.cpu.writes.clear();t.interrupt(ch*2);
        require(t.cpu.writes==vector<pair<int,int>>{{ports[ch],3}},"wrong unowned CTC port");
    }
    for(unsigned ptr:{0xdfff,0xe400,0xf000}) {
        r.BC.set_high(0);r.DE.set_pair16(ptr);t.call("irq_register");require(r.AF.get_high()==0xff,"unsafe user entry accepted");
    }
    r.BC.set_high(4);r.DE.set_pair16(0xe000);t.call("irq_register");require(r.AF.get_high()==0xff,"user stole SIO slot");
    t.call("sio_core_enable_interrupts");t.mem.store_mem16(t.at("SIO0B_RX_SINK"),0xe000);
    for(unsigned vector=0x10;vector<0x20;vector+=2) {t.cpu.rx=2;t.interrupt(vector);require(t.cpu.rx==0,"SIO did not drain bounded pair");}
    // Real console sink, including its queue writes; tests the resident path.
    t.mem.store_mem16(t.at("SIO0B_RX_SINK"),t.at("sercon_rx_sink"));
    t.mem.store_mem(t.at("SERCON_FLAGS"),3); t.cpu.rx=2;t.interrupt(0x10);
    for(unsigned vector:{0x08,0xfe,0xff}) t.interrupt(vector);
    for(bool enabled:{false,true}) {
        t.mem.store_mem16(t.at("SIO0B_RX_SINK"),0xe000);t.cpu.rx=1;t.seed();auto before=t.context();
        r.AF.set_high(0);t.iff(enabled);t.call("sio_rx_kick");auto after=t.context();
        for(unsigned i=1;i<before.size();++i) require(before[i]==after[i],"polling sink corrupted context");
        require(bool(r.IFF1)==enabled,"polling sink changed IFF");
        for(unsigned ch=0;ch<4;++ch) {r.BC.set_high(ch);r.DE.set_pair16(0xe000);t.call("irq_register");}
        auto kernel=t.mem.fetch_mem16(t.at("irq_sio_slot"));t.cpu.writes.clear();t.call("irq_program_exit");
        require(bool(r.IFF1)==enabled,"exit changed IFF");
        require(t.mem.fetch_mem16(t.at("irq_sio_slot"))==kernel,"exit erased kernel registration");
        for(unsigned ch=0;ch<4;++ch) require(t.cpu.writes[ch]==pair<int,int>{ports[ch],3},"exit port mismatch");
        vector<pair<int,int>> quiesce={{0x21,0x18},{0x21,1},{0x21,0},{0x21,3},{0x21,0},{0x21,5},{0x21,0},{0x21,0x30},{0x21,0x10}};
        require(vector<pair<int,int>>(t.cpu.writes.begin()+4,t.cpu.writes.end())==quiesce,"SIO0/A quiesce incorrect");
    }
    cout<<"PASS: IRQ tokens, IOC errors, registration, all CTC/SIO vectors, full context, polling, cleanup\n";
    cout<<"Maximum observed ISR stack use: "<<t.at("CBIOS_ISR_STACK_TOP")-t.minsp<<" / 62 bytes\n";
} catch(const exception &e) {cerr<<"FAIL: "<<e.what()<<'\n';return 1;}
