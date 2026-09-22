#include <qkz80/qkz80.h>
#include <algorithm>
#include <fstream>
#include <iostream>
#include <map>
#include <stdexcept>
#include <string>
#include <array>
#include <vector>
using namespace std;
void need(bool v, const string &s) { if (!v) throw runtime_error(s); }
struct CPU : qkz80 {
    explicit CPU(qkz80_cpu_mem *m):qkz80(m){set_cpu_mode(MODE_Z80);}
    void port_out(qkz80_uint8,qkz80_uint8) override { throw runtime_error("unexpected I/O"); }
    qkz80_uint8 port_in(qkz80_uint8) override { throw runtime_error("unexpected I/O"); }
    void block_io(qkz80_uint8) override { throw runtime_error("unexpected block I/O"); }
    void unimplemented_opcode(qkz80_uint8,qkz80_uint16) override { throw runtime_error("opcode"); }
};
struct Rig {
    qkz80_cpu_mem mem; CPU cpu{&mem}; map<string,unsigned> s;
    array<bool,2> slot_open{{false,false}};
    array<unsigned,2> slot_cookie{{1,1}};
    unsigned opens=0, reads=0, bulks=0, closes=0, max_open=0;
    unsigned pending_offset=0, mock_file_size=1024;
    unsigned dir_index=0, dir_cookie=1, mock_dir_file_size=1024;
    vector<string> resolver;
    bool dir_open=false;
    bool fail_next_open=false, fail_next_read=false, fail_next_close=false;
    Rig(char *bin,char *syms){ifstream f(bin,ios::binary);f.read((char*)mem.get_mem(),65536);need(f.gcount()==65536,"image");ifstream n(syms);string k;unsigned v;while(n>>k>>v)s[k]=v;cpu.regs.SP.set_pair16(0xd800);}
    unsigned at(const string&k){return s.at(k);}
    unsigned get16(unsigned p){return mem.fetch_mem(p)|(mem.fetch_mem(p+1)<<8);}
    unsigned get32(unsigned p){return get16(p)|(get16(p+2)<<16);}
    void put16(unsigned p,unsigned v){mem.store_mem(p,v);mem.store_mem(p+1,v>>8);}
    void put32(unsigned p,unsigned v){put16(p,v);put16(p+2,v>>16);}
    void fake_return(unsigned a){auto sp=cpu.regs.SP.get_pair16();auto pc=mem.fetch_mem16(sp);cpu.regs.SP.set_pair16(sp+2);cpu.regs.PC.set_pair16(pc);cpu.regs.AF.set_high(a);}
    unsigned live_slots(){unsigned n=0;for(bool open:slot_open)n+=open;return n;}
    void reply(unsigned cls,unsigned status,unsigned len){unsigned rx=at("FAT_RX");for(unsigned i=0;i<32;i++)mem.store_mem(rx+i,0);mem.store_mem(rx,cls);mem.store_mem(rx+2,status);mem.store_mem(rx+3,len);}
    void mock_iocall(){
        const unsigned tx=at("FAT_TX"), rx=at("FAT_RX"); unsigned cmd=mem.fetch_mem(tx), token, slot;
        switch(cmd){
        case 0x33: resolver.clear();reply(0xb3,0,0);break; // ROOT
        case 0x34: {string component;for(unsigned i=0;i<11;i++)component.push_back(char(mem.fetch_mem(tx+4+i)));resolver.push_back(component);reply(0xb4,0,0);break;} // PUSH
        case 0x35: { // OPEN_RO
            if(fail_next_open){fail_next_open=false;reply(0xb5,0x40,0);break;}
            slot=2;for(unsigned i=0;i<2;i++)if(!slot_open[i]){slot=i;break;}
            if(slot==2){reply(0xb5,0x48,0);break;}
            slot_open[slot]=true;if(++slot_cookie[slot]>255)slot_cookie[slot]=1;
            token=(slot_cookie[slot]<<8)|(slot+1);opens++;max_open=max(max_open,live_slots());
            reply(0xb5,0,7);put16(rx+4,token);put32(rx+6,mock_file_size);mem.store_mem(rx+10,0);
            break;
        }
        case 0x36: { // READ
            token=get16(tx+4);slot=(token&255)-1;
            if(fail_next_read){fail_next_read=false;reply(0xb6,0x4e,0);break;}
            if(slot>=2||!slot_open[slot]||(token>>8)!=slot_cookie[slot]){reply(0xb6,0x48,0);break;}
            pending_offset=get32(tx+6);unsigned wanted=get16(tx+10);unsigned got=0;
            if(pending_offset<mock_file_size)got=min(wanted,mock_file_size-pending_offset);
            reads++;reply(0xb6,0,8);mem.store_mem(rx+4,1);mem.store_mem(rx+5,1);put16(rx+6,got);put32(rx+8,pending_offset);
            break;
        }
        case 0x37: { // CLOSE
            token=get16(tx+4);slot=(token&255)-1;closes++;
            if(slot>=2||!slot_open[slot]||(token>>8)!=slot_cookie[slot]){reply(0xb7,0x48,0);break;}
            slot_open[slot]=false;
            if(fail_next_close){fail_next_close=false;reply(0xb7,0x4e,0);break;}
            reply(0xb7,0,0);break;
        }
        case 0x38: // OPENDIR
            dir_open=true;dir_index=0;if(++dir_cookie>255)dir_cookie=1;reply(0xb8,0,2);put16(rx+4,(dir_cookie<<8)|1);break;
        case 0x39: { // READDIR: a directory first, then one ordinary file
            token=get16(tx+4);
            if(!dir_open||token!=((dir_cookie<<8)|1)){reply(0xb9,0x48,0);break;}
            if(dir_index==0){const string n="TESTDIR    ";reply(0xb9,0,16);for(unsigned i=0;i<11;i++)mem.store_mem(rx+4+i,n[i]);mem.store_mem(rx+15,0x10);put32(rx+16,0);dir_index++;break;}
            if(dir_index==1){const string n="LESSON  MD ";reply(0xb9,0,16);for(unsigned i=0;i<11;i++)mem.store_mem(rx+4+i,n[i]);mem.store_mem(rx+15,0);put32(rx+16,mock_dir_file_size);dir_index++;break;}
            reply(0xb9,0x41,0);break;
        }
        case 0x3a: dir_open=false;reply(0xba,0,0);break; // CLOSEDIR
        default: throw runtime_error("unexpected mock IOC command "+to_string(cmd));
        }
        fake_return(0);
    }
    void mock_iocbulk(){unsigned dst=cpu.regs.HL.get_pair16(),len=cpu.regs.DE.get_pair16();for(unsigned i=0;i<len;i++)mem.store_mem(dst+i,(pending_offset+i)&255);bulks++;fake_return(0);}
    void call(const string&k){auto sp=cpu.regs.SP.get_pair16();mem.store_mem16(sp-2,0xd100);cpu.regs.SP.set_pair16(sp-2);cpu.regs.PC.set_pair16(at(k));unsigned b=400000;while(cpu.regs.PC.get_pair16()!=0xd100&&b--){auto pc=cpu.regs.PC.get_pair16();if(pc==at("IOCALL"))mock_iocall();else if(pc==at("IOCBULK"))mock_iocbulk();else cpu.execute();}need(b,"timeout "+k);need(cpu.regs.SP.get_pair16()==sp,"stack "+k);}
};
int main(int ac,char**av)try{
    need(ac==3,"usage");Rig t(av[1],av[2]);auto&r=t.cpu.regs;unsigned fcb=0x6600,dma=0x6700;
    for(unsigned i=0;i<36;i++)t.mem.store_mem(fcb+i,0);
    t.mem.store_mem(t.at("fat_current_drive"),3);r.DE.set_pair16(fcb);r.HL.set_pair16(dma);
    t.mem.store_mem(fcb+12,1);t.mem.store_mem(fcb+32,1);t.call("fat_seq_record");
    unsigned seq=t.mem.fetch_mem(t.at("fat_record"))
                 | (t.mem.fetch_mem(t.at("fat_record")+1)<<8)
                 | (t.mem.fetch_mem(t.at("fat_record")+2)<<16);
    need(seq==129,"sequential record calculation: got "+to_string(seq));
    t.mem.store_mem(fcb+12,0);t.mem.store_mem(fcb+14,0);t.mem.store_mem(fcb+32,127);r.DE.set_pair16(fcb);t.call("fat_increment_seq");
    need(t.mem.fetch_mem(fcb+32)==0&&t.mem.fetch_mem(fcb+12)==1,"extent rollover");
    r.BC.set_low(19);r.DE.set_pair16(fcb);r.HL.set_pair16(dma);t.call("fat_bdos_dispatch");
    need((r.AF.get_low()&1)&&r.AF.get_high()==0xff,"mutation did not fail read-only");
    const string name="BIG     DAT",rdname="LESSON  MD ";for(unsigned i=0;i<11;i++)t.mem.store_mem(t.at("fat_search_name")+i,name[i]);
    t.mem.store_mem(t.at("fat_current_user"),15);t.mem.store_mem(t.at("fat_search_user"),15);t.mem.store_mem16(t.at("fat_work_dma"),dma);
    t.mem.store_mem16(t.at("fat_search_records"),0);t.mem.store_mem(t.at("fat_search_records")+2,0);
    t.call("fat_search_emit_saved");need(t.mem.fetch_mem(dma+12)==0&&t.mem.fetch_mem(dma+14)==0&&t.mem.fetch_mem(dma+15)==0,"empty-file terminal extent");
    t.mem.store_mem16(t.at("fat_search_records"),128);t.mem.store_mem(t.at("fat_search_records")+2,0);
    t.call("fat_search_emit_saved");need(t.mem.fetch_mem(dma+12)==0&&t.mem.fetch_mem(dma+14)==0&&t.mem.fetch_mem(dma+15)==128,"128-record terminal extent");
    t.mem.store_mem16(t.at("fat_search_records"),257);t.mem.store_mem(t.at("fat_search_records")+2,0);t.mem.store_mem(t.at("fat_search_extent"),0);t.mem.store_mem(t.at("fat_search_pending"),1);
    t.call("fat_search_emit_saved");need(t.mem.fetch_mem(dma)==15,"search user");need(t.mem.fetch_mem(dma+12)==2&&t.mem.fetch_mem(dma+14)==0&&t.mem.fetch_mem(dma+15)==1,"257-record terminal extent: EX="+to_string(t.mem.fetch_mem(dma+12))+" S2="+to_string(t.mem.fetch_mem(dma+14))+" RC="+to_string(t.mem.fetch_mem(dma+15)));need((t.mem.fetch_mem(dma+9)&0x80)==0&& (t.mem.fetch_mem(dma+10)&0x80)==0&& (t.mem.fetch_mem(dma+11)&0x80)==0,"FAT attributes leaked into CP/M name");need(t.mem.fetch_mem(dma+31)==0,"allocation bytes");need(t.mem.fetch_mem(dma+32)==0xe5,"unused slot");need(t.mem.fetch_mem(t.at("fat_search_pending"))==0,"SEARCH left a continuation");
    // Exact and large files still produce one entry, describing the terminal
    // logical extent so catalogue tools can recover the complete record count.
    t.mem.store_mem16(t.at("fat_search_records"),256);t.mem.store_mem(t.at("fat_search_records")+2,0);t.mem.store_mem(t.at("fat_search_pending"),1);
    t.call("fat_search_emit_saved");need(t.mem.fetch_mem(dma+12)==1&&t.mem.fetch_mem(dma+14)==0&&t.mem.fetch_mem(dma+15)==128,"256-record terminal extent");need(t.mem.fetch_mem(t.at("fat_search_pending"))==0,"256-record continuation");
    t.mem.store_mem16(t.at("fat_search_records"),624);t.mem.store_mem(t.at("fat_search_records")+2,0);t.mem.store_mem(t.at("fat_search_pending"),1);
    t.call("fat_search_emit_saved");need(t.mem.fetch_mem(dma+12)==4&&t.mem.fetch_mem(dma+14)==0&&t.mem.fetch_mem(dma+15)==112,"624-record terminal extent");need(t.mem.fetch_mem(t.at("fat_search_pending"))==0,"624-record continuation");
    t.mem.store_mem16(t.at("fat_search_records"),4097);t.mem.store_mem(t.at("fat_search_records")+2,0);t.mem.store_mem(t.at("fat_search_pending"),1);
    t.call("fat_search_emit_saved");need(t.mem.fetch_mem(dma+12)==0&&t.mem.fetch_mem(dma+14)==1&&t.mem.fetch_mem(dma+15)==1,"4097-record S2 rollover");
    // Exercise SEARCH itself: skip a structural directory, return the file
    // once for 624 records, stamp S1, then close at exhaustion.
    for(unsigned i=0;i<36;i++)t.mem.store_mem(fcb+i,0);
    for(unsigned i=0;i<11;i++)t.mem.store_mem(fcb+1+i,'?');
    t.mock_dir_file_size=624*128;
    r.DE.set_pair16(fcb);r.HL.set_pair16(dma);t.call("fat_bdos_search_first");need(r.AF.get_high()==0,"624-record SEARCH result");need(t.mem.fetch_mem(dma+1)=='L'&&t.mem.fetch_mem(dma+2)=='E',"directory escaped SEARCH filter");need(t.mem.fetch_mem(fcb+13)==0x8f,"SEARCH did not stamp S1 USER");
    r.DE.set_pair16(fcb);r.HL.set_pair16(dma);t.call("fat_bdos_search_next");need(r.AF.get_high()==0xff&& !t.dir_open,"624-record SEARCH exhaustion");
    // CRC 2.0 catalogues a drive with CP/M's special FCB drive byte '?', which
    // requests a raw directory scan and ignores the remaining search FCB.  On
    // the synthetic current drive it must enter the FAT search personality.
    for(unsigned i=0;i<36;i++)t.mem.store_mem(fcb+i,0);
    t.mem.store_mem(fcb,'?');
    r.BC.set_low(17);r.DE.set_pair16(fcb);r.HL.set_pair16(dma);t.call("fat_bdos_dispatch");need((r.AF.get_low()&1)&&r.AF.get_high()==0,"raw-directory SEARCH was not routed to FAT");need(t.mem.fetch_mem(dma)==0&&t.mem.fetch_mem(dma+1)=='L'&&t.mem.fetch_mem(dma+2)=='E',"raw-directory SEARCH did not start at USER 0");
    for(unsigned user=1;user<16;user++){r.BC.set_low(18);r.DE.set_pair16(fcb);r.HL.set_pair16(dma);t.call("fat_bdos_dispatch");need((r.AF.get_low()&1)&&r.AF.get_high()==0&&t.mem.fetch_mem(dma)==user,"raw-directory SEARCH USER "+to_string(user));}
    r.BC.set_low(18);r.DE.set_pair16(fcb);r.HL.set_pair16(dma);t.call("fat_bdos_dispatch");need((r.AF.get_low()&1)&&r.AF.get_high()==0xff&&!t.dir_open,"raw-directory SEARCH did not exhaust after USER 15");
    // ZCD selects a directory visible inside the current CP/M USER namespace.
    // USER therefore precedes the relative CWD in the FS2 resolver.
    unsigned desc=0x6800;for(unsigned i=0;i<32;i++)t.mem.store_mem(desc+i,0);t.mem.store_mem(desc,1);t.mem.store_mem(desc+1,9);const string dirname="TESTDIR    ";for(unsigned i=0;i<11;i++)t.mem.store_mem(desc+18+i,dirname[i]);t.mem.store_mem(t.at("fat_current_user"),8);r.DE.set_pair16(desc);t.call("fat_native_entry");need(t.mem.fetch_mem(desc+2)==0,"native CHDIR failed, status="+to_string(t.mem.fetch_mem(desc+2))+" cwd="+to_string(t.mem.fetch_mem(t.at("fat_cwd_count")))+" resolver-components="+to_string(t.resolver.size()));need(t.resolver.size()==4&&t.resolver[0]=="CPM        "&&t.resolver[1]=="D          "&&t.resolver[2]=="@8         "&&t.resolver[3]==dirname,"native CHDIR was not USER-relative");need(t.mem.fetch_mem(t.at("fat_cwd_count"))==1&&t.mem.fetch_mem(t.at("fat_cwd_user"))==8,"native CHDIR did not retain its USER-owned CWD");t.mem.store_mem(t.at("fat_current_user"),15);

    // Function 218 must return the descriptor status after its READ/non-READ
    // dispatch, and SELDSK must validate the drive root rather than replaying
    // a CWD that belongs beneath a USER directory.
    unsigned staged=t.at("FAC_SFCB_BUF");for(unsigned i=0;i<32;i++)t.mem.store_mem(staged+i,0);t.mem.store_mem(staged,1);t.mem.store_mem(staged+1,9);t.mem.store_mem(staged+2,0);t.mem.store_mem16(t.at("fac_de"),desc);t.mem.store_mem16(t.at("fac_caller_sp"),r.SP.get_pair16()-2);r.AF.set_high(0);t.call("native_gate_status_dispatch");need(r.AF.get_high()==0,"function 218 returned operation instead of status");
    t.call("fat_bios_seldsk");need(r.HL.get_pair16()==t.at("FAT_BIOS_DPH"),"saved USER-relative CWD made SELDSK fail");need(t.resolver.size()==2&&t.resolver[0]=="CPM        "&&t.resolver[1]=="D          ","SELDSK replayed USER-relative CWD");
    r.AF.set_high(1);t.call("fat_fs2_path");need(t.resolver.size()==3&&t.resolver[2]=="@15        ","USER 8 CWD leaked into USER 15");
    t.mem.store_mem(t.at("fat_current_user"),8);
    for(unsigned i=18;i<29;i++)t.mem.store_mem(desc+i,0);
    r.DE.set_pair16(desc);t.call("fat_native_entry");need(t.mem.fetch_mem(desc+2)==0&&t.mem.fetch_mem(t.at("fat_cwd_count"))==0&&t.mem.fetch_mem(t.at("fat_cwd_user"))==8,"empty native CHDIR did not select USER root");
    t.mem.store_mem(t.at("fat_current_user"),15);
    // OPEN supplies the caller-visible USER and RC metadata ZSDOS applications
    // expect even though allocation fields remain synthetic.
    for(unsigned i=0;i<36;i++)t.mem.store_mem(fcb+i,0);
    for(unsigned i=0;i<11;i++)t.mem.store_mem(fcb+1+i,rdname[i]);
    t.mock_file_size=1024;r.DE.set_pair16(fcb);t.call("fat_bdos_open");need(r.AF.get_high()==0&&t.mem.fetch_mem(fcb+13)==0x8f&&t.mem.fetch_mem(fcb+15)==8,"OPEN small-file FCB metadata");
    t.mock_file_size=624*128;r.DE.set_pair16(fcb);t.call("fat_bdos_open");need(r.AF.get_high()==0&&t.mem.fetch_mem(fcb+15)==128,"OPEN large-file RC cap");
    t.mem.store_mem(desc,0);r.DE.set_pair16(desc);t.call("fat_native_entry");need(t.mem.fetch_mem(desc+2)==0xff,"native version rejection");
    // Exercise more records than the real two-slot FS2 pool.  Every record
    // must close the exact token it opened, keep the stack balanced, and leave
    // both slots reusable.  The ninth call is genuine EOF and still closes.
    t.mock_file_size=1024;
    unsigned base_opens=t.opens,base_reads=t.reads,base_bulks=t.bulks,base_closes=t.closes;
    for(unsigned i=0;i<36;i++)t.mem.store_mem(fcb+i,0);
    for(unsigned i=0;i<11;i++)t.mem.store_mem(fcb+1+i,rdname[i]);
    t.mem.store_mem(t.at("fat_current_drive"),3);
    for(unsigned record=0;record<8;record++){r.DE.set_pair16(fcb);r.HL.set_pair16(dma);t.call("fat_bdos_read_seq");need(r.AF.get_high()==0,"multi-record read "+to_string(record));need(t.mem.fetch_mem(dma)==((record*128)&255),"record data "+to_string(record));need(t.live_slots()==0,"slot leaked after record "+to_string(record));}
    r.DE.set_pair16(fcb);r.HL.set_pair16(dma);t.call("fat_bdos_read_seq");need(r.AF.get_high()==1,"genuine EOF result");need(t.opens==base_opens+9&&t.reads==base_reads+9&&t.bulks==base_bulks+8&&t.closes==base_closes+9,"OPEN/READ/BULK/CLOSE lifecycle counts");need(t.max_open==1,"temporary reads consumed concurrent slots");
    // Filesystem and close failures are errors, never EOF, and a failed read
    // still attempts to release its temporary context.
    t.mem.store_mem(fcb+12,0);t.mem.store_mem(fcb+14,0);t.mem.store_mem(fcb+32,0);t.fail_next_read=true;unsigned oldclose=t.closes;r.DE.set_pair16(fcb);r.HL.set_pair16(dma);t.call("fat_bdos_read_seq");need(r.AF.get_high()==0xff,"READ error masqueraded as EOF");need(t.closes==oldclose+1&&t.live_slots()==0,"READ error did not close context");
    t.fail_next_close=true;r.DE.set_pair16(fcb);r.HL.set_pair16(dma);t.call("fat_bdos_read_seq");need(r.AF.get_high()==0xff,"CLOSE error ignored");need(t.live_slots()==0,"mock CLOSE did not release slot");
    t.fail_next_open=true;r.DE.set_pair16(fcb);r.HL.set_pair16(dma);t.call("fat_bdos_read_seq");need(r.AF.get_high()==0xff,"OPEN error masqueraded as EOF");
    // Stream the reported SONG.ZVG size across every EXM=1 boundary.
    t.mock_file_size=624*128;for(unsigned i=0;i<36;i++)t.mem.store_mem(fcb+i,0);for(unsigned i=0;i<11;i++)t.mem.store_mem(fcb+1+i,rdname[i]);
    for(unsigned record=0;record<624;record++){r.DE.set_pair16(fcb);r.HL.set_pair16(dma);t.call("fat_bdos_read_seq");need(r.AF.get_high()==0,"624-record read "+to_string(record));if(record==127||record==128||record==255||record==256||record==511||record==512)need(t.mem.fetch_mem(dma)==((record*128)&255),"boundary data "+to_string(record));need(t.live_slots()==0,"boundary slot leak "+to_string(record));}
    need(t.mem.fetch_mem(fcb+12)==4&&t.mem.fetch_mem(fcb+32)==112,"624-record final FCB position");r.DE.set_pair16(fcb);r.HL.set_pair16(dma);t.call("fat_bdos_read_seq");need(r.AF.get_high()==1,"624-record EOF");
    cout<<"PASS: FAT BDOS routing, all-USER raw SEARCH, USER-relative CHDIR, 624-record FS2 lifecycle, and error mapping\n";
}catch(const exception&e){cerr<<"FAIL: "<<e.what()<<'\n';return 1;}
