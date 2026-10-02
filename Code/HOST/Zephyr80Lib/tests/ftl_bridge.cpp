// Native FTL compiler/assembler/linker output, with mocked Zephyr BDOS/CTC/PSG.
#include <qkz80/qkz80.h>
#include <fstream>
#include <iostream>
#include <map>
#include <stdexcept>
#include <string>
#include <vector>
using namespace std;
void need(bool ok, const string &s) { if (!ok) throw runtime_error(s); }
struct CPU : qkz80 {
    string output;
    vector<pair<int,int>> ports;
    bool reject=false;
    unsigned starts=0, stops=0;
    CPU(qkz80_cpu_mem *m):qkz80(m) { set_cpu_mode(MODE_Z80); }
    void port_out(qkz80_uint8 p,qkz80_uint8 v) override { ports.emplace_back(p,v); }
    void unimplemented_opcode(qkz80_uint8,qkz80_uint16 p) override {
        throw runtime_error("unsupported instruction at " + to_string(p));
    }
    void step() {
        // This libqkz80 build omits ED-prefixed OUT (C),r. Supply OUT (C),E
        // used by PSGIO, including its unchanged flags and interrupt state.
        unsigned pc=regs.PC.get_pair16();
        if (mem->fetch_mem(pc)==0xed && mem->fetch_mem(pc+1)==0x59) {
            port_out(regs.BC.get_low(),regs.DE.get_low());
            regs.PC.set_pair16(pc+2);
            return;
        }
        if (regs.PC.get_pair16()!=5) { execute(); return; }
        unsigned fn=regs.BC.get_low(), de=regs.DE.get_pair16(), answer=0;
        if(fn==200) {
            need(regs.BC.get_high()==0 && de==0xe3c0,"wrong registration");
            ++starts;answer=reject?255:0;
            regs.IX.set_pair16(0xdead); // FTL frame pointer must survive BDOS.
        } else if(fn==201) { ++stops; regs.IX.set_pair16(0xdead); }
        else if(fn==2) output+=char(de&255);
        else if(fn==9) { for(unsigned i=de;mem->fetch_mem(i)!='$';++i) output+=char(mem->fetch_mem(i)); }
        else if(fn==12) answer=0x22;
        else if(fn==11 || fn==25) answer=0;
        else throw runtime_error("unexpected BDOS " + to_string(fn));
        regs.AF.set_high(answer&255);regs.HL.set_pair16(answer);
        regs.PC.set_pair16(pop_word());
    }
};
int main(int argc,char **argv) try {
    need(argc==3,"usage: ftl_bridge FTLTEST.COM SYMBOLS.TXT");
    qkz80_cpu_mem mem; CPU cpu(&mem);
    ifstream f(argv[1],ios::binary); f.read((char*)mem.get_mem()+0x100,0xdd00);
    need(f.gcount()>0,"missing COM");
    map<string,unsigned> symbols;ifstream sf(argv[2]);string name;unsigned value;
    while(sf>>name>>value) symbols[name]=value;
    need(symbols.at("CTCEND")-symbols.at("CTCISR")==55,"callback size changed");
    for(unsigned address:{0xe3bf,0xe3f7,0xe3ff}) mem.store_mem(address,0xa5);
    mem.store_mem(0,0xc3);mem.store_mem16(1,0xf000);
    mem.store_mem(5,0xc3);mem.store_mem16(6,0xe800);
    cpu.regs.SP.set_pair16(0xe700);cpu.push_word(0);cpu.regs.PC.set_pair16(0x100);
    unsigned budget=10000000;
    while(cpu.regs.PC.get_pair16()!=0 && budget--) cpu.step();
    need(budget>0,"native program did not return");
    need(cpu.output.find("FTL bridge PASS")!=string::npos && cpu.output.find("FAIL")==string::npos,
         "native compiler ABI regression: "+cpu.output);
    need(cpu.starts==1000 && cpu.stops==1000,"missing native calls");
    vector<pair<int,int>> expected;
    auto mute=[&]() {
        for(int port=0xe0;port<=0xe3;++port)
            for(int byte:{0x9f,0xbf,0xdf,0xff}) expected.emplace_back(port,byte);
    };
    mute();
    for(int port=0xe0;port<=0xe3;++port)
        for(int byte:{0x81,0x00,0xaf,0x3f,0xc0,0x1c,0x9f,0xd0,
                      0xe0,0xe1,0xe2,0xe3,0xe4,0xe5,0xe6,0xe7,0xe7})
            expected.emplace_back(port,byte);
    mute();mute();
    need(expected.size()==116,"invalid PSG test expectation");
    for(unsigned i=0;i<1000;++i)
        for(int byte:{0xa7,217,3}) expected.emplace_back(0x40,byte);
    need(cpu.ports==expected,"native Sound/CTC port bytes or ordering changed");
    for(unsigned address:{0xe3bf,0xe3f7,0xe3ff}) need(mem.fetch_mem(address)==0xa5,"callback reservation exceeded");
    for(unsigned i=0;i<55;++i)
        need(mem.fetch_mem(0xe3c0+i)==mem.fetch_mem(symbols.at("CTCISR")+i),"callback copy changed");
    auto call=[&](unsigned pc) {
        auto sp=cpu.regs.SP.get_pair16(); cpu.push_word(0xd000);cpu.regs.PC.set_pair16(pc);
        unsigned steps=10000;
        while(cpu.regs.PC.get_pair16()!=0xd000 && steps--) cpu.step();
        need(steps>0 && cpu.regs.SP.get_pair16()==sp,"call stack imbalance");
    };
    auto start=[&](unsigned rate) {
        cpu.regs.SP.set_pair16(0xd800);cpu.push_word(rate);cpu.push_word(0xd000);
        cpu.regs.PC.set_pair16(symbols.at("LSTART"));
        unsigned steps=10000;
        while(cpu.regs.PC.get_pair16()!=0xd000 && steps--) cpu.step();
        need(steps>0 && cpu.regs.SP.get_pair16()==0xd800,"LStart parameter cleanup");
    };
    auto query=[&](const string &proc,bool iff) {
        cpu.regs.IFF1=cpu.regs.IFF2=iff;cpu.ei_delay=false;
        cpu.push_word(0xd100);cpu.push_word(0xd000);cpu.regs.PC.set_pair16(symbols.at(proc));
        unsigned steps=10000;
        while(cpu.regs.PC.get_pair16()!=0xd000 && steps--) cpu.step();
        need(steps>0 && cpu.regs.SP.get_pair16()==0xd800,"query parameter cleanup");
        need(bool(cpu.regs.IFF1)==iff,"query changed IFF");
        return mem.fetch_mem16(0xd100);
    };
    for(unsigned rate:{1,50,60,179,180}) {
        start(rate);
        for(unsigned i=0;i<180;++i) call(0xe3c0);
        need(query("INTS",false)==180,"raw interrupt count");
        need(query("PEND",true)==rate,"phase accumulator");
        for(unsigned i=0;i<rate;++i) need(query("TAKE",i&1)==1,"take pending tick");
        need(query("TAKE",false)==0 && query("PEND",true)==0,"empty queue");
        need(query("OVER",false)==0,"unexpected overflow");
        call(symbols.at("LSTOP"));
    }
    start(180);
    for(unsigned i=0;i<300;++i) call(0xe3c0);
    need(query("PEND",true)==255 && query("OVER",false)==45,"queue saturation");
    mem.store_mem16(0xe3fa,65535);call(0xe3c0);
    need(query("INTS",true)==0,"counter rollover");
    call(symbols.at("LSTOP"));cpu.reject=true;cpu.ports.clear();start(180);
    need(query("ISACT",false)==0 && cpu.ports.empty(),"rejected registration started CTC");
    cout<<"PASS: 116 PSG writes across four chips; 1000 native FTL call cycles, callback rates, saturation, rollover, IFF and failure path\n";
} catch(const exception &e) { cerr<<e.what()<<'\n';return 1; }
