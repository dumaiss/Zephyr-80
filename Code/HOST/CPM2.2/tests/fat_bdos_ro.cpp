#include <qkz80/qkz80.h>
#include <algorithm>
#include <fstream>
#include <iostream>
#include <map>
#include <set>
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
    // A real file model for the writable cases.  The read-only cases above
    // predate it and keep their synthetic mock_file_size behaviour, so
    // use_file_model stays off for them.
    bool use_file_model=false;
    map<string,vector<unsigned char>> model;
    set<string> model_dirs;
    vector<string> listing; unsigned listing_at=0;
    string open_name; unsigned xfer_id=0; unsigned write_status=0;
    unsigned pending_write_off=0, pending_write_len=0;
    unsigned unlinks=0, renames=0, mkdirs=0;
    string last_rename_from, last_rename_to;
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
            if(use_file_model){
                string n;for(unsigned i=0;i<11;i++)n.push_back(char(mem.fetch_mem(tx+4+i)));
                if(!model.count(n)){reply(0xb5,0x40,0);break;}
                open_name=n;
                slot=2;for(unsigned i=0;i<2;i++)if(!slot_open[i]){slot=i;break;}
                if(slot==2){reply(0xb5,0x48,0);break;}
                slot_open[slot]=true;if(++slot_cookie[slot]>255)slot_cookie[slot]=1;
                token=(slot_cookie[slot]<<8)|(slot+1);opens++;
                reply(0xb5,0,7);put16(rx+4,token);put32(rx+6,model[n].size());mem.store_mem(rx+10,0);
                break;
            }
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
            unsigned size=use_file_model?unsigned(model[open_name].size()):mock_file_size;
            if(pending_offset<size)got=min(wanted,size-pending_offset);
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
        case 0x3d: { // OPEN_RW
            unsigned mode=mem.fetch_mem(tx+4);
            string n; for(unsigned i=0;i<11;i++) n.push_back(char(mem.fetch_mem(tx+5+i)));
            open_name=n;
            bool exists=model.count(n)!=0;
            if(mode==1&&exists){reply(0xbd,0x42,0);break;}          // CREATE_NEW
            if(mode==0&&!exists){reply(0xbd,0x40,0);break;}          // UPDATE
            if(mode==2||!exists) model[n].clear();                   // CREATE_ALWAYS
            slot=2;for(unsigned i=0;i<2;i++)if(!slot_open[i]){slot=i;break;}
            if(slot==2){reply(0xbd,0x48,0);break;}
            slot_open[slot]=true;if(++slot_cookie[slot]>255)slot_cookie[slot]=1;
            token=(slot_cookie[slot]<<8)|(slot+1);opens++;max_open=max(max_open,live_slots());
            reply(0xbd,0,7);put16(rx+4,token);put32(rx+6,model[n].size());mem.store_mem(rx+10,0);
            break;
        }
        case 0x3e: { // WRITE: READY, then IOCBULKW, then XFER_STATUS
            token=get16(tx+4);slot=(token&255)-1;
            if(slot>=2||!slot_open[slot]||(token>>8)!=slot_cookie[slot]){reply(0xbe,0x48,0);break;}
            pending_write_off=get32(tx+6);pending_write_len=get16(tx+10);
            if(pending_write_len==0||pending_write_len>512){reply(0xbe,0x4a,0);break;}
            xfer_id=(xfer_id%255)+1;
            reply(0xbe,0,8);mem.store_mem(rx+4,xfer_id);mem.store_mem(rx+5,1);
            put16(rx+6,pending_write_len);put32(rx+8,pending_write_off);
            break;
        }
        case 0x06: // XFER_STATUS: DONE identity and result
            reply(0x86,0,2);mem.store_mem(rx+4,xfer_id);mem.store_mem(rx+5,write_status);
            break;
        case 0x41: { // UNLINK
            string n;for(unsigned i=0;i<11;i++)n.push_back(char(mem.fetch_mem(tx+4+i)));
            for(bool&o:slot_open)o=false;
            if(!model.count(n)){reply(0xc1,0x40,0);break;}
            model.erase(n);unlinks++;reply(0xc1,0,0);break;
        }
        case 0x42: { // RENAME
            string a,b;
            for(unsigned i=0;i<11;i++)a.push_back(char(mem.fetch_mem(tx+4+i)));
            for(unsigned i=0;i<11;i++)b.push_back(char(mem.fetch_mem(tx+15+i)));
            for(bool&o:slot_open)o=false;
            last_rename_from=a;last_rename_to=b;
            if(!model.count(a)){reply(0xc2,0x40,0);break;}
            if(model.count(b)){reply(0xc2,0x42,0);break;}
            model[b]=model[a];model.erase(a);renames++;reply(0xc2,0,0);break;
        }
        case 0x43: { // MKDIR
            string n;for(unsigned i=0;i<11;i++)n.push_back(char(mem.fetch_mem(tx+4+i)));
            if(model_dirs.count(n)){reply(0xc3,0x42,0);break;}
            model_dirs.insert(n);mkdirs++;reply(0xc3,0,0);break;
        }
        case 0x44: { // RMDIR
            string n;for(unsigned i=0;i<11;i++)n.push_back(char(mem.fetch_mem(tx+4+i)));
            if(!model_dirs.count(n)){reply(0xc4,0x40,0);break;}
            model_dirs.erase(n);reply(0xc4,0,0);break;
        }
        case 0x38: // OPENDIR
            dir_open=true;dir_index=0;if(++dir_cookie>255)dir_cookie=1;
            listing.clear();listing_at=0;
            if(use_file_model) for(auto&f:model) listing.push_back(f.first);
            reply(0xb8,0,2);put16(rx+4,(dir_cookie<<8)|1);break;
        case 0x39: { // READDIR: a directory first, then one ordinary file
            token=get16(tx+4);
            if(!dir_open||token!=((dir_cookie<<8)|1)){reply(0xb9,0x48,0);break;}
            if(use_file_model){
                if(listing_at>=listing.size()){reply(0xb9,0x41,0);break;}
                const string n=listing[listing_at++];
                reply(0xb9,0,16);
                for(unsigned i=0;i<11;i++)mem.store_mem(rx+4+i,n[i]);
                mem.store_mem(rx+15,0);put32(rx+16,model[n].size());
                break;
            }
            if(dir_index==0){const string n="TESTDIR    ";reply(0xb9,0,16);for(unsigned i=0;i<11;i++)mem.store_mem(rx+4+i,n[i]);mem.store_mem(rx+15,0x10);put32(rx+16,0);dir_index++;break;}
            if(dir_index==1){const string n="LESSON  MD ";reply(0xb9,0,16);for(unsigned i=0;i<11;i++)mem.store_mem(rx+4+i,n[i]);mem.store_mem(rx+15,0);put32(rx+16,mock_dir_file_size);dir_index++;break;}
            reply(0xb9,0x41,0);break;
        }
        case 0x3a: dir_open=false;reply(0xba,0,0);break; // CLOSEDIR
        default: throw runtime_error("unexpected mock IOC command "+to_string(cmd));
        }
        fake_return(0);
    }
    void mock_iocbulk(){
        unsigned dst=cpu.regs.HL.get_pair16(),len=cpu.regs.DE.get_pair16();
        for(unsigned i=0;i<len;i++){
            unsigned v=(pending_offset+i)&255;
            if(use_file_model){
                const vector<unsigned char>&d=model[open_name];
                v=(pending_offset+i<d.size())?d[pending_offset+i]:0;
            }
            mem.store_mem(dst+i,v);
        }
        bulks++;fake_return(0);
    }
    // Z80 -> MCU: the record the host staged in the common bulk buffer.
    void mock_iocbulkw(){
        unsigned src=cpu.regs.HL.get_pair16(),len=cpu.regs.DE.get_pair16();
        vector<unsigned char>&d=model[open_name];
        // Extending must NOT produce zeros here.  FatFs allocates clusters
        // holding whatever was on the card, so filling with zeros would make
        // function 40's guarantee untestable -- the gap would read back clean
        // whether or not anything zeroed it.
        if(d.size()<pending_write_off+len)d.resize(pending_write_off+len,0xCC);
        for(unsigned i=0;i<len;i++)d[pending_write_off+i]=(unsigned char)mem.fetch_mem(src+i);
        bulks++;fake_return(0);
    }
    void call(const string&k){auto sp=cpu.regs.SP.get_pair16();mem.store_mem16(sp-2,0xd100);cpu.regs.SP.set_pair16(sp-2);cpu.regs.PC.set_pair16(at(k));unsigned b=400000;while(cpu.regs.PC.get_pair16()!=0xd100&&b--){auto pc=cpu.regs.PC.get_pair16();if(pc==at("IOCALL"))mock_iocall();else if(pc==at("IOCBULK"))mock_iocbulk();else if(pc==at("IOCBULKW"))mock_iocbulkw();else cpu.execute();}need(b,"timeout "+k);need(cpu.regs.SP.get_pair16()==sp,"stack "+k);}
};
int main(int ac,char**av)try{
    need(ac==3,"usage");Rig t(av[1],av[2]);auto&r=t.cpu.regs;unsigned fcb=0x8840,dma=0x88c0;
    // Scratch must sit outside RESOURCE_CACHE_POOL (6600h-7FFFh): the read
    // cache leases a line from there, and 6600h/6700h used to be unowned.
    // 8840h is past the boot banner text and has no owner.
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
    unsigned desc=0x8900;   // likewise outside the poolfor(unsigned i=0;i<32;i++)t.mem.store_mem(desc+i,0);t.mem.store_mem(desc,1);t.mem.store_mem(desc+1,9);const string dirname="TESTDIR    ";for(unsigned i=0;i<11;i++)t.mem.store_mem(desc+18+i,dirname[i]);t.mem.store_mem(t.at("fat_current_user"),8);r.DE.set_pair16(desc);t.call("fat_native_entry");need(t.mem.fetch_mem(desc+2)==0,"native CHDIR failed, status="+to_string(t.mem.fetch_mem(desc+2))+" cwd="+to_string(t.mem.fetch_mem(t.at("fat_cwd_count")))+" resolver-components="+to_string(t.resolver.size()));need(t.resolver.size()==4&&t.resolver[0]=="CPM        "&&t.resolver[1]=="D          "&&t.resolver[2]=="@8         "&&t.resolver[3]==dirname,"native CHDIR was not USER-relative");need(t.mem.fetch_mem(t.at("fat_cwd_count"))==1&&t.mem.fetch_mem(t.at("fat_cwd_user"))==8,"native CHDIR did not retain its USER-owned CWD");t.mem.store_mem(t.at("fat_current_user"),15);

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
    for(unsigned record=0;record<8;record++){r.DE.set_pair16(fcb);r.HL.set_pair16(dma);t.call("fat_bdos_read_seq");need(r.AF.get_high()==0,"multi-record read "+to_string(record));need(t.mem.fetch_mem(dma)==((record*128)&255),"record data "+to_string(record));need(t.live_slots()<=1,"more than the cached read handle held after record "+to_string(record));}
    r.DE.set_pair16(fcb);r.HL.set_pair16(dma);t.call("fat_bdos_read_seq");need(r.AF.get_high()==1,"genuine EOF result");// Nine records now cost three controller round trips, not nine: four
    // records share one 512-byte line, and the ninth probes past the end.
    // Each "open" is really RESET/ROOT/PUSH/OPEN, so the real saving is
    // larger than the count suggests.  If this ever reads 9 again, the
    // deblocking has stopped working.
    // One OPEN for the whole stream, not one per line and certainly not one
    // per record: the handle is reused while the FCB names the same file, so
    // a line costs a READ and a bulk and nothing else.
    need(t.opens==base_opens+1,"handle reuse: 9 records took "+to_string(t.opens-base_opens)+" opens");
    need(t.reads==base_reads+3&&t.bulks==base_bulks+2,
         "deblocking: 9 records took "+to_string(t.reads-base_reads)+" reads");need(t.max_open==1,"temporary reads consumed concurrent slots");
    // Filesystem and close failures are errors, never EOF, and a failed read
    // still attempts to release its temporary context.
    // These exercise the read-through path's error handling.  Without
    // dropping the cached line the record would be served from memory and the
    // injected failure would never be reached -- which is exactly what the
    // cache is for, but not what is being tested here.
    t.mem.store_mem(t.at("fat_cache_valid"),0);
    t.mem.store_mem(fcb+12,0);t.mem.store_mem(fcb+14,0);t.mem.store_mem(fcb+32,0);t.fail_next_read=true;unsigned oldclose=t.closes;r.DE.set_pair16(fcb);r.HL.set_pair16(dma);t.call("fat_bdos_read_seq");need(r.AF.get_high()==0xff,"READ error masqueraded as EOF");need(t.live_slots()==0,"a failed read kept its handle");
    // A read no longer closes -- it keeps the handle -- so what matters now is
    // that a close which FAILS during a flush does not leave us believing we
    // still own a handle the controller has already thrown away.
    t.mem.store_mem(t.at("fat_cache_valid"),0);
    r.DE.set_pair16(fcb);r.HL.set_pair16(dma);t.call("fat_bdos_read_seq");
    need(t.mem.fetch_mem(t.at("fat_hcache_valid"))==1,"a read should leave its handle cached");
    t.fail_next_close=true;
    t.call("fat_cache_flush");
    need(t.mem.fetch_mem(t.at("fat_hcache_valid"))==0,
         "a failed close left the handle marked valid");
    t.mem.store_mem(t.at("fat_cache_valid"),0);
    t.fail_next_open=true;r.DE.set_pair16(fcb);r.HL.set_pair16(dma);t.call("fat_bdos_read_seq");need(r.AF.get_high()==0xff,"OPEN error masqueraded as EOF");
    // Stream the reported SONG.ZVG size across every EXM=1 boundary.
    t.mock_file_size=624*128;for(unsigned i=0;i<36;i++)t.mem.store_mem(fcb+i,0);for(unsigned i=0;i<11;i++)t.mem.store_mem(fcb+1+i,rdname[i]);
    for(unsigned record=0;record<624;record++){r.DE.set_pair16(fcb);r.HL.set_pair16(dma);t.call("fat_bdos_read_seq");need(r.AF.get_high()==0,"624-record read "+to_string(record));if(record==127||record==128||record==255||record==256||record==511||record==512)need(t.mem.fetch_mem(dma)==((record*128)&255),"boundary data "+to_string(record));need(t.live_slots()<=1,"boundary slot leak "+to_string(record));}
    // 624 records across 156 lines: the whole stream cost 163 opens counting
    // everything earlier in this run, against 625 before deblocking.
    need(t.opens<20,"handle reuse: 624 records took "+to_string(t.opens)+" opens");
    // The handle must be handed back when anything invalidates it, or the
    // controller's two file slots leak away one program at a time.
    need(t.live_slots()==1,"the read cache should be holding its handle here");
    t.call("fat_cache_flush");
    need(t.live_slots()==0,"flush did not return the cached handle");
    need(t.mem.fetch_mem(fcb+12)==4&&t.mem.fetch_mem(fcb+32)==112,"624-record final FCB position");r.DE.set_pair16(fcb);r.HL.set_pair16(dma);t.call("fat_bdos_read_seq");need(r.AF.get_high()==1,"624-record EOF");
    // Native OPEN records the path identity of the handle it just issued so a
    // stale token can be reopened after a media-generation change.  At the
    // drive root the relative component count is zero, and the copy recording
    // it must not run at all: LDIR decrements BC before testing, so a zero
    // count transfers 65536 bytes and walks the OS out of bank 7.  That froze
    // the machine on the FIRST native OPEN from D:, whatever the mode.  The
    // FCB path above never reached it, and the CHDIR cases above are the only
    // other fat_native_entry op exercised here, so nothing caught it.
    auto native_open=[&](unsigned mode,unsigned cwd_count){
        for(unsigned i=0;i<32;i++)t.mem.store_mem(desc+i,0);
        t.mem.store_mem(desc+0,1);
        t.mem.store_mem(desc+t.at("ZNATIVE_OFF_OP"),1);            // ZNATIVE_OPEN
        t.mem.store_mem(desc+t.at("ZNATIVE_OFF_FLAGS"),mode);
        const string n="LESSON  MD ";
        for(unsigned i=0;i<11;i++)t.mem.store_mem(desc+t.at("ZNATIVE_OFF_NAME")+i,n[i]);
        t.mem.store_mem(t.at("fat_current_user"),0);
        t.mem.store_mem(t.at("fat_cwd_user"),0);
        t.mem.store_mem(t.at("fat_cwd_count"),cwd_count);
        for(unsigned i=0;i<cwd_count*11u;i++)t.mem.store_mem(t.at("fat_cwd_components")+i,'A'+i%26);
        t.mem.store_mem(t.at("fat_native_active"),0);
        t.mem.store_mem(t.at("fat_native_active")+1,0);
        r.DE.set_pair16(desc);t.call("fat_native_entry");
        return t.mem.fetch_mem(desc+t.at("ZNATIVE_OFF_STATUS"));
    };
    // Canaries outside every buffer the copy legitimately touches.  A runaway
    // LDIR wraps the whole address space, so any of these would be rewritten.
    const unsigned canary[]={0x0040,0x1234,0x7000,0xc000};
    for(unsigned a:canary)t.mem.store_mem(a,0x5a);
    need(native_open(0,0)==0,"native OPEN at the drive root");
    need(t.mem.fetch_mem(desc+t.at("ZNATIVE_OFF_HANDLE"))==1,"native OPEN handle");
    need(t.mem.fetch_mem(t.at("fat_native_cwd0")+1)==0,"root identity recorded a component count");
    for(unsigned a:canary)need(t.mem.fetch_mem(a)==0x5a,"native OPEN at the root clobbered "+to_string(a));
    // The non-zero case must still copy exactly count*11 bytes, and no more.
    t.mem.store_mem(0xc000,0x5a);
    need(native_open(0,2)==0,"native OPEN below the drive root");
    need(t.mem.fetch_mem(t.at("fat_native_cwd0")+1)==2,"two-component identity count");
    for(unsigned i=0;i<22u;i++)need(t.mem.fetch_mem(t.at("fat_native_cwd0")+2+i)==unsigned('A'+i%26),"identity component byte "+to_string(i));
    need(t.mem.fetch_mem(0xc000)==0x5a,"two-component copy overran its 22 bytes");
    // Native READ must report the byte count and advance the handle position.
    // It returned status 0 with ZN_RESULT untouched for every successful read:
    // the STALE check before it left the flags set from its own CP, and the
    // success path tested those instead of A.  The FCB read path has its own
    // caller, so nothing here covered it.
    auto native=[&](unsigned op,unsigned mode,unsigned len,unsigned handle){
        for(unsigned i=0;i<32;i++)t.mem.store_mem(desc+i,0);
        t.mem.store_mem(desc+0,1);
        t.mem.store_mem(desc+t.at("ZNATIVE_OFF_OP"),op);
        t.mem.store_mem(desc+t.at("ZNATIVE_OFF_FLAGS"),mode);
        t.mem.store_mem(desc+t.at("ZNATIVE_OFF_HANDLE"),handle);
        t.put16(desc+t.at("ZNATIVE_OFF_LENGTH"),len);
        t.put16(desc+t.at("ZNATIVE_OFF_BUFFER"),0x7000);
        const string n="LESSON  MD ";
        for(unsigned i=0;i<11;i++)t.mem.store_mem(desc+t.at("ZNATIVE_OFF_NAME")+i,n[i]);
        r.DE.set_pair16(desc);t.call("fat_native_entry");
        return t.mem.fetch_mem(desc+t.at("ZNATIVE_OFF_STATUS"));
    };
    t.mem.store_mem(t.at("fat_current_user"),0);t.mem.store_mem(t.at("fat_cwd_user"),0);
    t.mem.store_mem(t.at("fat_cwd_count"),0);
    t.mem.store_mem(t.at("fat_native_active"),0);t.mem.store_mem(t.at("fat_native_active")+1,0);
    // The identity cases above left handles open on the controller side.
    t.slot_open={{false,false}};
    t.mock_file_size=1024;
    need(native(1,0,0,0)==0,"native OPEN for read");
    unsigned nh=t.mem.fetch_mem(desc+t.at("ZNATIVE_OFF_HANDLE"));
    need(native(3,0,100,nh)==0,"native READ status");
    need(t.get16(desc+t.at("ZNATIVE_OFF_RESULT"))==100,"native READ reported "+to_string(t.get16(desc+t.at("ZNATIVE_OFF_RESULT")))+" bytes, not 100");
    // The position must have moved, so a second read continues where it stopped.
    need(native(5,0,0,nh)==0,"native TELL status");
    need(t.get32(desc+t.at("ZNATIVE_OFF_POSITION"))==100,"native READ did not advance the position");
    // A read that runs off the end still succeeds, with a short count.
    need(native(4,0,0,nh)==0&&true,"native SEEK status");
    t.put32(desc+t.at("ZNATIVE_OFF_POSITION"),1000);t.mem.store_mem(desc+t.at("ZNATIVE_OFF_OP"),4);
    r.DE.set_pair16(desc);t.call("fat_native_entry");
    need(native(3,0,100,nh)==0&&t.get16(desc+t.at("ZNATIVE_OFF_RESULT"))==24,"short native READ at EOF");
    // A file whose length is not a multiple of 128 must still deliver its
    // last record padded with 1Ah.  The deliver path copies first and pads
    // only the tail, so this is the case that exercises the padding at all.
    {
        t.mem.store_mem(t.at("fat_cache_valid"),0);
        t.call("fat_cache_flush");
        t.mock_file_size=100;
        for(unsigned i=0;i<36;i++)t.mem.store_mem(fcb+i,0);
        for(unsigned i=0;i<11;i++)t.mem.store_mem(fcb+1+i,rdname[i]);
        for(unsigned i=0;i<128;i++)t.mem.store_mem(dma+i,0x5A);
        r.DE.set_pair16(fcb);r.HL.set_pair16(dma);t.call("fat_bdos_read_seq");
        need(r.AF.get_high()==0,"short final record");
        for(unsigned i=0;i<100;i++)
            need(t.mem.fetch_mem(dma+i)==(i&255),"short record data at "+to_string(i));
        for(unsigned i=100;i<128;i++)
            need(t.mem.fetch_mem(dma+i)==0x1a,
                 "short record tail not padded at "+to_string(i));
        r.DE.set_pair16(fcb);r.HL.set_pair16(dma);t.call("fat_bdos_read_seq");
        need(r.AF.get_high()==1,"EOF after a short final record");
        t.mock_file_size=1024;
        t.call("fat_cache_flush");
    }
    // The cached line must not survive a write to the same file, or a program
    // that writes then reads gets what was there before.
    {
        t.use_file_model=true; t.slot_open={{false,false}};
        t.mem.store_mem(t.at("fat_current_user"),0);
        t.mem.store_mem(t.at("fat_cwd_user"),0);
        t.mem.store_mem(t.at("fat_cwd_count"),0);
        t.mem.store_mem16(t.at("fat_ro_vector"),0);
        const string cn="CACHE   TST";
        t.model[cn]=vector<unsigned char>(512,0x11);
        for(unsigned i=0;i<36;i++)t.mem.store_mem(fcb+i,0);
        for(unsigned i=0;i<11;i++)t.mem.store_mem(fcb+1+i,cn[i]);
        r.DE.set_pair16(fcb);r.HL.set_pair16(dma);t.call("fat_bdos_read_seq");
        need(t.mem.fetch_mem(dma)==0x11,"cached read before write");
        // Rewrite record 0 through the FCB path.
        for(unsigned i=0;i<36;i++)t.mem.store_mem(fcb+i,0);
        for(unsigned i=0;i<11;i++)t.mem.store_mem(fcb+1+i,cn[i]);
        for(unsigned i=0;i<128;i++)t.mem.store_mem(dma+i,0x22);
        r.DE.set_pair16(fcb);r.HL.set_pair16(dma);t.call("fat_bdos_write_seq");
        need(r.AF.get_high()==0,"write over a cached line");
        for(unsigned i=0;i<36;i++)t.mem.store_mem(fcb+i,0);
        for(unsigned i=0;i<11;i++)t.mem.store_mem(fcb+1+i,cn[i]);
        r.DE.set_pair16(fcb);r.HL.set_pair16(dma);t.call("fat_bdos_read_seq");
        need(t.mem.fetch_mem(dma)==0x22,
             "a stale cached line survived a write: got "+to_string(t.mem.fetch_mem(dma)));
        // And with the pool full, every read must still be correct -- the
        // contract is that a lease may be refused, not that it is optional.
        for(unsigned i=0;i<13;i++)t.mem.store_mem(t.at("res_owners")+i,0xEE);
        t.mem.store_mem16(t.at("fat_cache_line"),0);
        t.mem.store_mem(t.at("fat_cache_tried"),0);
        t.mem.store_mem(t.at("fat_cache_valid"),0);
        for(unsigned i=0;i<36;i++)t.mem.store_mem(fcb+i,0);
        for(unsigned i=0;i<11;i++)t.mem.store_mem(fcb+1+i,cn[i]);
        r.DE.set_pair16(fcb);r.HL.set_pair16(dma);t.call("fat_bdos_read_seq");
        need(r.AF.get_high()==0&&t.mem.fetch_mem(dma)==0x22,
             "read-through fallback with no cache line available");
        need(t.get16(t.at("fat_cache_line"))==0,"a line was leased from a full pool");
        // Give the pool back for the tests that follow.
        for(unsigned i=0;i<13;i++)t.mem.store_mem(t.at("res_owners")+i,0);
        t.mem.store_mem(t.at("fat_cache_tried"),0);
        t.model.erase(cn);
    }
    // ---------------- Milestone 6: the writable FCB personality -------------
    // These run against the real file model, so a record written through the
    // FCB path is read back through it and must be the same bytes.
    t.use_file_model=true; t.slot_open={{false,false}};
    t.mem.store_mem(t.at("fat_current_user"),0);
    t.mem.store_mem(t.at("fat_cwd_user"),0);
    t.mem.store_mem(t.at("fat_cwd_count"),0);
    t.mem.store_mem16(t.at("fat_ro_vector"),0);
    t.mem.store_mem(t.at("fat_current_drive"),3);
    const string wname="NEWFILE TXT";
    auto set_fcb=[&](const string&n){
        for(unsigned i=0;i<36;i++)t.mem.store_mem(fcb+i,0);
        for(unsigned i=0;i<11;i++)t.mem.store_mem(fcb+1+i,n[i]);
    };
    auto fcb_call=[&](const char*sym){
        r.DE.set_pair16(fcb);r.HL.set_pair16(dma);t.call(sym);return r.AF.get_high();
    };
    // MAKE creates an empty file and resets the position fields, so the first
    // sequential write lands at record zero.
    set_fcb(wname);
    t.mem.store_mem(fcb+12,9);t.mem.store_mem(fcb+32,7);   // stale EX/CR
    need(fcb_call("fat_bdos_make")==0,"MAKE result");
    need(t.model.count(wname)==1&&t.model[wname].empty(),"MAKE did not create an empty file");
    need(t.mem.fetch_mem(fcb+12)==0&&t.mem.fetch_mem(fcb+15)==0&&t.mem.fetch_mem(fcb+32)==0,"MAKE left stale FCB position");
    // Three sequential records, each a distinct pattern.
    for(unsigned rec=0;rec<3;rec++){
        for(unsigned i=0;i<128;i++)t.mem.store_mem(dma+i,(rec*128+i)&255);
        need(fcb_call("fat_bdos_write_seq")==0,"WRITE SEQUENTIAL record "+to_string(rec));
    }
    need(t.model[wname].size()==384,"sequential writes produced "+to_string(t.model[wname].size())+" bytes");
    for(unsigned i=0;i<384;i++)
        need(t.model[wname][i]==((i)&255),"sequential write content at "+to_string(i));
    need(t.mem.fetch_mem(fcb+32)==3,"CR did not advance past three records");
    // Read the same records back through the FCB path.
    set_fcb(wname);
    for(unsigned rec=0;rec<3;rec++){
        need(fcb_call("fat_bdos_read_seq")==0,"read back record "+to_string(rec));
        for(unsigned i=0;i<128;i++)
            need(t.mem.fetch_mem(dma+i)==((rec*128+i)&255),"read back content rec "+to_string(rec));
    }
    // WRITE RANDOM addresses record 5 => byte 640, extending the file.
    set_fcb(wname);
    t.mem.store_mem(fcb+33,5);
    for(unsigned i=0;i<128;i++)t.mem.store_mem(dma+i,0xA5);
    need(fcb_call("fat_bdos_write_random")==0,"WRITE RANDOM result");
    need(t.model[wname].size()==768,"WRITE RANDOM wrote to the wrong offset");
    need(t.model[wname][640]==0xA5&&t.model[wname][767]==0xA5,"WRITE RANDOM content");
    // WRITE RANDOM WITH ZERO FILL must leave the gap readable as zeros, which
    // is the only thing that distinguishes it from function 34.
    t.model[wname].resize(384);
    set_fcb(wname);
    t.mem.store_mem(fcb+33,5);
    for(unsigned i=0;i<128;i++)t.mem.store_mem(dma+i,0x5A);
    need(fcb_call("fat_bdos_write_random_zf")==0,"WRITE RANDOM ZERO FILL result");
    need(t.model[wname].size()==768,"zero fill produced "+to_string(t.model[wname].size())+" bytes");
    for(unsigned i=384;i<640;i++)need(t.model[wname][i]==0,"gap byte "+to_string(i)+" was not zeroed");
    need(t.model[wname][640]==0x5A,"zero fill clobbered the record itself");
    // Again with the DMA pointing AT the common bulk buffer.  That is not a
    // contrived case: the facade stages a hidden caller DMA into FAC_DMA_BUF,
    // which is the same address as FAC_BULK_BUF, so on real hardware this is
    // the normal path.  Using a separate dma above is what let a zero fill
    // that overwrote the caller's record pass here and fail on the machine.
    {
        const unsigned bulk=t.at("FAC_BULK_BUF");
        t.model[wname].resize(384);
        set_fcb(wname);
        t.mem.store_mem(fcb+33,5);
        for(unsigned i=0;i<128;i++)t.mem.store_mem(bulk+i,0x6B);
        r.DE.set_pair16(fcb);r.HL.set_pair16(bulk);t.call("fat_bdos_write_random_zf");
        need(r.AF.get_high()==0,"zero fill with an aliased DMA");
        need(t.model[wname].size()==768,"aliased zero fill size");
        for(unsigned i=384;i<640;i++)
            need(t.model[wname][i]==0,"aliased zero fill gap byte "+to_string(i));
        for(unsigned i=640;i<768;i++)
            need(t.model[wname][i]==0x6B,
                 "the zero fill overwrote the caller's record at "+to_string(i));
    }
    // RENAME moves the contents, not just the name.
    set_fcb(wname);
    const string rname="MOVED   TXT";
    for(unsigned i=0;i<11;i++)t.mem.store_mem(fcb+17+i,rname[i]);
    need(fcb_call("fat_bdos_rename")==0,"RENAME result");
    need(t.model.count(rname)==1&&t.model.count(wname)==0&&t.model[rname].size()==768,"RENAME");
    // DELETE takes ambiguous names: ERA *.TXT must remove every match.
    t.model["A       TXT"]=vector<unsigned char>(10,1);
    t.model["B       TXT"]=vector<unsigned char>(10,2);
    t.model["KEEP    DAT"]=vector<unsigned char>(10,3);
    set_fcb("????????TXT");
    need(fcb_call("fat_bdos_delete")==0,"wildcard DELETE result");
    need(t.model.count("KEEP    DAT")==1,"wildcard DELETE removed a non-match");
    need(t.model.count("A       TXT")==0&&t.model.count("B       TXT")==0&&
         t.model.count(rname)==0,"wildcard DELETE left a match behind");
    // A name that matches nothing is an error, not a silent success.
    set_fcb("NOSUCH  FIL");
    need(fcb_call("fat_bdos_delete")==0xff,"DELETE of a missing file reported success");
    // ZSDOS software write protection is enforced above ZSDOS, so every
    // mutation has to check it independently.
    t.mem.store_mem16(t.at("fat_ro_vector"),0x0008);
    set_fcb("WP      TXT");
    need(fcb_call("fat_bdos_make")==0xff,"MAKE ignored write protection");
    need(fcb_call("fat_bdos_write_seq")==0xff,"WRITE ignored write protection");
    need(fcb_call("fat_bdos_delete")==0xff,"DELETE ignored write protection");
    need(fcb_call("fat_bdos_rename")==0xff,"RENAME ignored write protection");
    need(t.model.count("WP      TXT")==0,"a protected drive was written to");
    t.mem.store_mem16(t.at("fat_ro_vector"),0);
    // A full disk is its own result: callers must be able to tell it from a
    // broken link, so it is 2 and not 255.
    t.model["FULL    TXT"]=vector<unsigned char>();
    set_fcb("FULL    TXT");
    t.write_status=0x45;   // IOC_STATUS_FS2_NO_SPACE
    need(fcb_call("fat_bdos_write_seq")==2,"disk full was not reported as 2");
    t.write_status=0;
    // Lazy @N: the first file created in a USER area materialises it.
    t.mem.store_mem(t.at("fat_current_user"),3);
    t.model_dirs.clear();
    set_fcb("USERFILETXT");
    need(fcb_call("fat_bdos_make")==0,"MAKE in a USER area");
    need(t.model_dirs.count("@3         ")==1,"MAKE did not create the USER directory");
    t.mem.store_mem(t.at("fat_current_user"),0);
    cout<<"PASS: FAT BDOS routing, all-USER raw SEARCH, USER-relative CHDIR, 624-record FS2 lifecycle, error mapping, native OPEN identity and READ, and the writable FCB personality\n";
}catch(const exception&e){cerr<<"FAIL: "<<e.what()<<'\n';return 1;}
