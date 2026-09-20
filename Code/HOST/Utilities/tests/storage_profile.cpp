// STORAGE_PROFILE removable tests. Real assembled routines on libqkz80;
// CALL 5 and timers mocked here. This is not a full banked-machine simulation.
#include <qkz80/qkz80.h>
#include <algorithm>
#include <fstream>
#include <iostream>
#include <map>
#include <stdexcept>
#include <vector>
using namespace std;
void check(bool b,const string &s) { if(!b) throw runtime_error(s); }
struct CPU:qkz80 { CPU(qkz80_cpu_mem *m):qkz80(m){set_cpu_mode(MODE_Z80);}
 void unimplemented_opcode(qkz80_uint8,unsigned short pc) override {throw runtime_error("opcode at "+to_string(pc));}
};
struct Rig {
 qkz80_cpu_mem m; CPU c{&m}; map<string,unsigned> s; unsigned calls=0,ticks=0,fail_at=0; bool loop=false, profile=false, bad_page=false;
 unsigned mock_status=0,mock_class=0x8b;
 Rig(const char *bin,const char *symbols,unsigned base){fill(m.get_mem(),m.get_mem()+65536,0);ifstream f(bin,ios::binary);f.read((char*)m.get_mem()+base,65536-base);check(f.gcount()>0,"binary missing");ifstream sy(symbols);string n;unsigned a;while(sy>>n>>a)s[n]=a;c.regs.SP.set_pair16(0xd000);}
 unsigned a(const string&n){return s.at(n);} unsigned byte(unsigned p){return m.fetch_mem(p);} unsigned word(unsigned p){return byte(p)|(byte(p+1)<<8);}
 void put(unsigned p,unsigned v){m.store_mem(p,v);} void w(unsigned p,unsigned v){m.store_mem16(p,v);}
 void d(unsigned p,unsigned v){w(p,v);w(p+2,v>>16);} void ret(){unsigned sp=c.regs.SP.get_pair16();c.regs.PC.set_pair16(word(sp));c.regs.SP.set_pair16(sp+2);}
 void result(unsigned v){c.regs.AF.set_high(v);ret();}
 void step(){unsigned pc=c.regs.PC.get_pair16();
  if(pc==5){
   unsigned fn=c.regs.BC.get_low();
   if(!loop){check(fn==2||fn==9,"unexpected parser BDOS call");result(0);return;}
   check(fn==20,"non-read CALL 5 inside timed region");++calls;ticks+=10;
   unsigned f=c.regs.DE.get_pair16(); check(f==a("fb_fcb"),"FCB pointer");
   check(byte(f+12)==0&&byte(f+14)==0x80&&byte(f+32)==((calls-1)%4),"sequential rewind/order");
   for(unsigned i=16;i<32;i++)check(byte(f+i)==i+30,"allocation map overwritten");
   if(fail_at==calls){result(1);return;}
   put(f+32,byte(f+32)+1); unsigned h=word(0xe100);w(0xe100,min(h+1,65535u));result(0);return;
  }
  if(loop && pc==a("tk_read")){d(a("acc32"),ticks);ret();return;}
  if(loop && pc==a("tk_stop")){ret();return;}
  if(profile && pc==a("IOCALL")){
   unsigned tx=c.regs.HL.get_pair16(),rx=c.regs.DE.get_pair16();
   check(byte(tx)==0x0b&&byte(tx+3)==2&&byte(tx+5)==2,"profile request framing");
   fill(m.get_mem()+rx,m.get_mem()+rx+32,0);put(rx,mock_class);put(rx+2,mock_status);put(rx+3,bad_page?24:16);put(rx+4,1);
   d(rx+6,512);d(rx+10,200000);w(rx+14,520);w(rx+16,2);w(rx+18,3);result(0);return;
  }
  c.execute();
 }
 void call(const string&name){unsigned sp=c.regs.SP.get_pair16();w(sp-2,0xd100);c.regs.SP.set_pair16(sp-2);c.regs.PC.set_pair16(a(name));unsigned n=12000000;while(c.regs.PC.get_pair16()!=0xd100&&n--)step();check(n>0,"timeout "+name);check(c.regs.SP.get_pair16()==sp,"stack "+name);}
 bool zero(){return c.regs.AF.get_low()&0x40;}
 void tail(const string&t,bool named){fill(m.get_mem()+0x5c,m.get_mem()+0x68,' ');if(named)put(0x5d,'F');put(0x80,t.size());copy(t.begin(),t.end(),m.get_mem()+0x81);call("parse_tail");}
 void setup_loop(){loop=true;calls=ticks=0;unsigned f=a("fb_fcb");for(unsigned i=0;i<36;i++)put(f+i,0);for(unsigned i=16;i<32;i++)put(f+i,i+30);put(a("hh_ex"),0);put(a("hh_s2"),0x80);put(a("hh_cr"),0);w(a("hh_cache_ptr"),0xe100);w(a("hh_xport_ptr"),0xe110);w(0xe100,20);w(0xe102,8);w(0xe110,65534);w(0xe112,100);}
};
int main(int argc,char**argv){try {check(argc==5,"arguments");Rig u(argv[1],argv[2],0x100);
 for(auto t:vector<pair<string,int>>{{"FILE /H",3},{"FILE /h /n",3},{"FILE /S /P",2},{"FILE /s /c /p",2},{"FILE",1}}){u.tail(t.first,true);check(u.c.regs.AF.get_high()==0&&u.byte(u.a("mode"))==unsigned(t.second),"valid options "+t.first);}
 for(auto t:{"/H","/P","/S /P"}){u.tail(t,false);check(u.c.regs.AF.get_high()!=0,"missing filename");}
 for(auto t:{"FILE /H /S","FILE /H /C","FILE /H /P","FILE /P"}){u.tail(t,true);check(u.c.regs.AF.get_high()!=0,"conflicting switches");}
 u.setup_loop();u.call("hh_run");u.call("hh_validate");check(u.c.regs.AF.get_high()==0,"valid host run rejected");check(u.calls==4096&&u.word(u.a("hh_success"))==4096,"read count");check(u.word(u.a("hh_ticks"))==40960,"aggregate timer");
 auto after=u.a("hh_after");for(unsigned off:{0u,2u,4u,6u}){unsigned old=u.word(after+off);u.w(after+off,old+1);u.call("hh_validate");check(u.c.regs.AF.get_high()!=0,"bad delta accepted");u.w(after+off,old);}
 for(unsigned off:{0u,2u}){unsigned old=u.word(u.a("hh_before")+off);u.w(u.a("hh_before")+off,65535);u.call("hh_validate");check(u.c.regs.AF.get_high()!=0,"saturation accepted");u.w(u.a("hh_before")+off,old);}
 u.setup_loop();u.fail_at=7;u.call("hh_run");u.call("hh_validate");check(u.c.regs.AF.get_high()!=0&&u.word(u.a("hh_attempts"))==7&&u.word(u.a("hh_success"))==6,"partial read accepted");u.loop=false;
 u.profile=true;u.put(u.a("sp_enabled"),1);u.call("sp_begin");check(u.c.regs.AF.get_high()==0&&u.word(u.a("sp_base"))==520,"profile baseline");check(u.byte(u.a("tx_frame")+4)==1,"reset control");u.call("sp_end");check(u.c.regs.AF.get_high()==0&&u.word(u.a("sp_reply")+2)==512,"profile snapshot");check(u.byte(u.a("tx_frame")+4)==0,"snapshot control");
 u.bad_page=true;u.call("sp_end");check(u.c.regs.AF.get_high()!=0,"old page fallback accepted");u.bad_page=false;
 u.mock_status=1;u.call("sp_end");check(u.c.regs.AF.get_high()!=0,"error profile accepted");u.mock_status=0;u.mock_class=0xff;u.call("sp_end");check(u.c.regs.AF.get_high()!=0,"normal firmware accepted");
 Rig b(argv[3],argv[4],0);b.put(b.a("sd_deblock_valid"),1);b.put(b.a("sd_deblock_unit"),0);b.put(b.a("sd_storage_unit"),0);b.w(b.a("sd_deblock_block"),0x1234);b.w(b.a("sd_deblock_want"),0x1234);b.call("sd_deblock_match");check(b.zero(),"resident block mismatch");
 for(auto n:{"sd_deblock_valid","sd_deblock_unit","sd_deblock_block"}){unsigned p=b.a(n),old=b.byte(p);b.put(p,old^1);b.call("sd_deblock_match");check(!b.zero(),"false deblock hit");b.put(p,old);}
 cout<<"PASS: assembled SDBENCH parsing, 4096 fn20 calls, rewind/map preservation, aggregate timing, invalid/saturated counters, profile framing/decoding; BIOS deblock match\n";
 }catch(const exception&e){cerr<<e.what()<<'\n';return 1;}}
