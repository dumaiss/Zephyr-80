/* Host model for zep_fs.c.  This tests the public C wrapper without a card.
 * The fake is deliberately descriptor-shaped so a wrong offset, operation,
 * chunk boundary or status source is visible here. */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <zephyr/fs.h>

uint8_t zep__fs_pack_name(uint8_t packed[11], const char *name);

enum {
    OP_OPEN=1, OP_CLOSE, OP_READ, OP_SEEK, OP_TELL, OP_STAT,
    OP_OPENDIR, OP_READDIR, OP_CHDIR, OP_WRITE, OP_SYNC, OP_TRUNCATE,
    OP_DELETE, OP_RENAME, OP_MKDIR, OP_RMDIR, OP_CWD, OP_SPACE, OP_CDUP,
    OP_CLOSEDIR, OP_SPACE_KIB
};
enum {
    D_STATUS=2, D_FLAGS=3, D_HANDLE=4, D_POSITION=6, D_LENGTH=10,
    D_BUFFER=12, D_RESULT=16, D_NAME=18, D_NAME2=6
};

static unsigned calls;
static unsigned chunks[160];
static unsigned pointers[160];
static uint8_t transfer_op;
static unsigned fail_call;
static uint8_t fail_status;
static unsigned short_call;
static unsigned short_result;
static uint8_t forced_op;
static uint8_t forced_status;
static uint8_t unsupported;
static uint32_t file_position;
static uint32_t file_size=4096;
static uint8_t cwd_depth;
static uint8_t cwd[16][11];
static uint8_t dir_open;
static uint8_t dir_at;
static uint8_t last_op;
static uint8_t last_name[11],last_name2[11];
static uint8_t max_buffer[65535];

static uint16_t word(const uint8_t *p)
{
    return (uint16_t)p[0]|((uint16_t)p[1]<<8);
}
static uint32_t dword(const uint8_t *p)
{
    return (uint32_t)word(p)|((uint32_t)word(p+2)<<16);
}
static void putword(uint8_t *p,uint16_t v)
{
    p[0]=(uint8_t)v;p[1]=(uint8_t)(v>>8);
}
static void putdword(uint8_t *p,uint32_t v)
{
    putword(p,(uint16_t)v);putword(p+2,(uint16_t)(v>>16));
}
static void die(const char *message)
{
    fprintf(stderr,"FAIL: %s\n",message);exit(1);
}
#define NEED(v,m) do { if(!(v)) die(m); } while(0)

static void reset_fake(void)
{
    calls=0;memset(chunks,0,sizeof(chunks));memset(pointers,0,sizeof(pointers));
    transfer_op=0;fail_call=0;fail_status=0;short_call=0;short_result=0;
    forced_op=0;forced_status=0;unsupported=0;last_op=0;
}

uint8_t zep__fs_native(uint8_t d[32])
{
    uint8_t op=d[1];
    unsigned n;

    NEED(d[0]==1,"descriptor version");
    NEED(d[D_STATUS]==ZEP_FS_UNSUPPORTED,"descriptor was not initialized");
    ++calls;last_op=op;
    if(unsupported)return d[D_STATUS];
    if(forced_op==op){d[D_STATUS]=forced_status;return d[D_STATUS];}
    if(op==OP_READ||op==OP_WRITE){
        NEED(!transfer_op||op==transfer_op,"wrong transfer operation");
        n=word(d+D_LENGTH);
        NEED(n>0&&n<=512,"wrapper issued an invalid chunk");
        chunks[calls-1]=n;pointers[calls-1]=word(d+D_BUFFER);
        if(fail_call==calls){d[D_STATUS]=fail_status;return d[D_STATUS];}
        if(short_call==calls)n=short_result;
        putword(d+D_RESULT,(uint16_t)n);
        file_position+=n;d[D_STATUS]=ZEP_FS_OK;return d[D_STATUS];
    }
    switch(op){
    case OP_OPEN:
        memcpy(last_name,d+D_NAME,11);d[D_HANDLE]=2;
        putdword(d+D_POSITION,file_size);file_position=0;break;
    case OP_CLOSE: case OP_SYNC:
        if(d[D_HANDLE]!=2){d[D_STATUS]=ZEP_FS_NO_HANDLE;return d[D_STATUS];}
        break;
    case OP_SEEK:
        file_position=dword(d+D_POSITION);break;
    case OP_TELL:
        if(!d[D_HANDLE]){d[D_STATUS]=ZEP_FS_NO_HANDLE;return d[D_STATUS];}
        putdword(d+D_POSITION,file_position);break;
    case OP_TRUNCATE:
        file_size=dword(d+D_POSITION);break;
    case OP_STAT:
        memcpy(last_name,d+D_NAME,11);putdword(d+D_POSITION,file_size);
        d[D_FLAGS]=0;break;
    case OP_DELETE: case OP_MKDIR: case OP_RMDIR:
        memcpy(last_name,d+D_NAME,11);break;
    case OP_RENAME:
        memcpy(last_name,d+D_NAME,11);memcpy(last_name2,d+D_NAME2,11);break;
    case OP_CHDIR:
        if(d[D_NAME]==0||d[D_NAME]==' '){cwd_depth=0;break;}
        if(cwd_depth>=16){d[D_STATUS]=ZEP_FS_RANGE;return d[D_STATUS];}
        memcpy(cwd[cwd_depth++],d+D_NAME,11);break;
    case OP_CDUP:
        if(cwd_depth)
            --cwd_depth;
        break;
    case OP_CWD:
        putword(d+D_RESULT,cwd_depth);
        if(d[D_FLAGS]<cwd_depth)memcpy(d+D_NAME,cwd[d[D_FLAGS]],11);
        break;
    case OP_OPENDIR:
        dir_open=1;dir_at=0;d[D_HANDLE]=1;break;
    case OP_READDIR:
        if(!dir_open||d[D_HANDLE]!=1){d[D_STATUS]=ZEP_FS_NO_HANDLE;return d[D_STATUS];}
        if(dir_at++){d[D_STATUS]=ZEP_FS_END;return d[D_STATUS];}
        memcpy(d+D_NAME,"MAXNAM88EXT",11);d[D_FLAGS]=ZEP_FS_FLAG_DIRECTORY;
        putdword(d+D_POSITION,123456);break;
    case OP_CLOSEDIR:
        if(!dir_open||d[D_HANDLE]!=1){d[D_STATUS]=ZEP_FS_NO_HANDLE;return d[D_STATUS];}
        dir_open=0;break;
    case OP_SPACE:
        putdword(d+D_POSITION,0x12345678);putdword(d+D_NAME,0x23456789);break;
    case OP_SPACE_KIB:
        putdword(d+D_POSITION,0x00123456);putdword(d+D_NAME,0x00234567);break;
    default:
        die("unexpected operation");
    }
    d[D_STATUS]=ZEP_FS_OK;return d[D_STATUS];
}

static void name_tests(void)
{
    uint8_t guard[13];
    static const char *bad[]={"","ABCDEFGHI.TXT","NAME.ABCD",".TXT","NAME.",
                              "A..B","A*B","DIR/FILE","A B",0};
    unsigned i;
    memset(guard,0xa5,sizeof(guard));
    NEED(zep__fs_pack_name(guard+1,"abcdefgh.xyz")==ZEP_FS_OK,"max 8.3 rejected");
    NEED(!memcmp(guard+1,"ABCDEFGHXYZ",11),"8.3 packing or uppercase");
    NEED(guard[0]==0xa5&&guard[12]==0xa5,"name converter crossed destination");
    for(i=0;bad[i];++i){
        memset(guard,0x5a,sizeof(guard));
        NEED(zep__fs_pack_name(guard+1,bad[i])==ZEP_FS_BAD_NAME,"bad name accepted");
        NEED(guard[0]==0x5a&&guard[12]==0x5a,"bad name crossed destination");
    }
}

static void transfer_case(uint8_t op,uint16_t length)
{
    uint8_t buffer[1200];
    uint16_t actual=0xffff;
    zep_fs_status_t s;
    unsigned expected=(length+511u)/512u;
    unsigned i;
    uint16_t base=(uint16_t)(uintptr_t)buffer;
    reset_fake();transfer_op=op;
    s=op==OP_READ?zep_fs_read(2,buffer,length,&actual):
                  zep_fs_write(2,buffer,length,&actual);
    NEED(s==ZEP_FS_OK&&actual==length,"transfer count");
    NEED(calls==expected,"transfer chunk count");
    for(i=0;i<calls;++i){
        unsigned want=length-i*512u;if(want>512u)want=512u;
        NEED(chunks[i]==want,"transfer chunk size");
        NEED(pointers[i]==(uint16_t)(base+i*512u),"transfer pointer advance");
    }
}

static void transfer_tests(void)
{
    static const uint16_t sizes[]={0,1,127,128,129,511,512,513,1025};
    uint8_t buffer[1200];
    uint16_t actual;
    unsigned i;
    for(i=0;i<sizeof(sizes)/sizeof(sizes[0]);++i){
        transfer_case(OP_READ,sizes[i]);transfer_case(OP_WRITE,sizes[i]);
    }
    reset_fake();transfer_op=OP_READ;short_call=2;short_result=7;
    NEED(zep_fs_read(2,buffer,1025,&actual)==ZEP_FS_OK&&actual==519&&calls==2,
         "short final read");
    reset_fake();transfer_op=OP_READ;short_call=1;short_result=0;
    NEED(zep_fs_read(2,buffer,513,&actual)==ZEP_FS_OK&&actual==0&&calls==1,
         "EOF read");
    reset_fake();transfer_op=OP_WRITE;fail_call=2;fail_status=ZEP_FS_UNKNOWN_WRITE;
    NEED(zep_fs_write(2,buffer,1025,&actual)==ZEP_FS_UNKNOWN_WRITE&&
         actual==512&&calls==2,"UNKNOWN_WRITE propagation/replay");
    reset_fake();transfer_op=OP_WRITE;fail_call=1;fail_status=ZEP_FS_NO_SPACE;
    NEED(zep_fs_write(2,buffer,513,&actual)==ZEP_FS_NO_SPACE&&actual==0&&calls==1,
         "NO_SPACE propagation");
    reset_fake();transfer_op=OP_READ;
    NEED(zep_fs_read(2,max_buffer,65535,&actual)==ZEP_FS_OK&&actual==65535&&
         calls==128&&chunks[127]==511,"uint16 maximum read");
    reset_fake();transfer_op=OP_WRITE;
    NEED(zep_fs_write(2,max_buffer,65535,&actual)==ZEP_FS_OK&&actual==65535&&
         calls==128&&chunks[127]==511,"uint16 maximum write");
}

static void api_tests(void)
{
    static const uint8_t native_errors[]={
        ZEP_FS_NOT_FOUND,ZEP_FS_END,ZEP_FS_EXISTS,ZEP_FS_BAD_NAME,
        ZEP_FS_READ_ONLY,ZEP_FS_NO_SPACE,ZEP_FS_NOT_DIR,ZEP_FS_IS_DIR,
        ZEP_FS_NO_HANDLE,ZEP_FS_STALE,ZEP_FS_RANGE,ZEP_FS_NO_MEDIA,
        ZEP_FS_TRANSPORT,ZEP_FS_UNKNOWN_WRITE,ZEP_FS_IO
    };
    zep_fs_handle_t h;
    zep_fs_dir_t dir;
    zep_fs_dirent_t ent;
    zep_fs_stat_t st;
    uint32_t value,free_bytes,total_bytes,free_kib,total_kib;
    char path[40],tiny[2];
    unsigned i;

    reset_fake();unsupported=1;
    NEED(zep_fs_tell(1,&value)==ZEP_FS_UNSUPPORTED,"unsupported API detection");
    reset_fake();NEED(zep_fs_tell(0,&value)==ZEP_FS_NO_HANDLE,"bad handle");
    reset_fake();NEED(zep_fs_stat("TOOLONG99.TXT",&st)==ZEP_FS_BAD_NAME&&calls==0,
                      "bad name should not call BDOS");
    for(i=0;i<sizeof(native_errors)/sizeof(native_errors[0]);++i){
        reset_fake();forced_op=OP_STAT;forced_status=native_errors[i];
        NEED(zep_fs_stat("FILE.BIN",&st)==native_errors[i],
             "native status was collapsed");
    }
    reset_fake();NEED(zep_fs_open("file.bin",ZEP_FS_OPEN_READ,&h)==ZEP_FS_OK&&h==2,
                      "open");
    forced_op=OP_OPEN;forced_status=ZEP_FS_EXISTS;
    NEED(zep_fs_open("FILE.BIN",ZEP_FS_OPEN_CREATE_NEW,&h)==ZEP_FS_EXISTS,
         "create-new EXISTS");
    forced_status=ZEP_FS_READ_ONLY;
    NEED(zep_fs_open("FILE.BIN",ZEP_FS_OPEN_UPDATE,&h)==ZEP_FS_READ_ONLY,
         "read-only propagation");
    forced_op=0;
    NEED(zep_fs_seek(2,0x10203040)==ZEP_FS_OK,"seek");
    NEED(zep_fs_tell(2,&value)==ZEP_FS_OK&&value==0x10203040,"tell");
    NEED(zep_fs_sync(2)==ZEP_FS_OK,"sync");
    NEED(zep_fs_truncate(2,777)==ZEP_FS_OK,"truncate");
    NEED(zep_fs_stat("FILE.BIN",&st)==ZEP_FS_OK&&st.size==777,"stat");
    NEED(zep_fs_close(2)==ZEP_FS_OK,"close");

    cwd_depth=0;reset_fake();
    NEED(zep_fs_chdir("/foo/bar")==ZEP_FS_OK&&cwd_depth==2,"path walk");
    NEED(zep_fs_getcwd(path,sizeof(path))==ZEP_FS_OK&&!strcmp(path,"/FOO/BAR"),
         "getcwd");
    NEED(zep_fs_getcwd(tiny,sizeof(tiny))==ZEP_FS_RANGE&&tiny[0]==0,
         "getcwd capacity");
    NEED(zep_fs_chdir("../.")==ZEP_FS_OK&&cwd_depth==1,"dot and dot-dot");
    NEED(zep_fs_cdup()==ZEP_FS_OK&&cwd_depth==0,"cdup");
    NEED(zep_fs_cdup()==ZEP_FS_OK&&cwd_depth==0,"cdup at root");
    NEED(zep_fs_root()==ZEP_FS_OK&&cwd_depth==0,"root");

    NEED(zep_fs_mkdir("DIR")==ZEP_FS_OK&&last_op==OP_MKDIR,"mkdir");
    NEED(zep_fs_rmdir("DIR")==ZEP_FS_OK&&last_op==OP_RMDIR,"rmdir");
    NEED(zep_fs_rename("OLD.BIN","NEW.BIN")==ZEP_FS_OK&&last_op==OP_RENAME,
         "rename");
    NEED(!memcmp(last_name,"OLD     BIN",11)&&!memcmp(last_name2,"NEW     BIN",11),
         "rename names");
    NEED(zep_fs_delete("NEW.BIN")==ZEP_FS_OK&&last_op==OP_DELETE,"delete");

    dir_open=0;NEED(zep_fs_opendir(&dir)==ZEP_FS_OK&&dir==1,"opendir");
    NEED(zep_fs_readdir(dir,&ent)==ZEP_FS_OK&&!strcmp(ent.name,"MAXNAM88.EXT")&&
         ent.size==123456&&(ent.flags&ZEP_FS_FLAG_DIRECTORY),"readdir");
    NEED(zep_fs_readdir(dir,&ent)==ZEP_FS_END,"directory END");
    NEED(zep_fs_closedir(dir)==ZEP_FS_OK&&!dir_open,"closedir");
    NEED(zep_fs_readdir(dir,&ent)==ZEP_FS_NO_HANDLE,"readdir after close");
    NEED(zep_fs_opendir(&dir)==ZEP_FS_OK&&zep_fs_closedir(dir)==ZEP_FS_OK,
         "directory context reuse");
    NEED(zep_fs_space(&free_bytes,&total_bytes)==ZEP_FS_OK&&
         free_bytes==0x12345678&&total_bytes==0x23456789,"space");
    NEED(zep_fs_space_kib(&free_kib,&total_kib)==ZEP_FS_OK&&
         free_kib==0x00123456&&total_kib==0x00234567,"space KiB");
}

int main(void)
{
    name_tests();transfer_tests();api_tests();
    puts("PASS: ZephyrC native filesystem wrapper");
    return 0;
}
