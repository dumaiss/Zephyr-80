/* FSTEST.COM -- conservative real-card acceptance for <zephyr/fs.h>.
 *
 * Run on the FAT-backed current drive.  The test owns /ZCFSTEST and the files
 * below it.  Known results are cleaned up.  UNKNOWN_WRITE stops immediately:
 * the uncertain chunk is never replayed and no cleanup guesses at its state.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <zephyr/fs.h>

static uint8_t failures;
static uint8_t uncertain;
static uint8_t model[2600];
static uint8_t readback[2600];

static uint8_t status(const char *what, zep_fs_status_t got,
                      zep_fs_status_t want)
{
    if (got == ZEP_FS_UNKNOWN_WRITE) {
        printf("  %-22s FAIL %02X (completion unknown; stopping)\n",what,got);
        failures++;uncertain=1;
        exit(1);                 /* normal C termination; no guessed cleanup */
    }
    if (got != want) {
        printf("  %-22s FAIL %02X (wanted %02X)\n",what,got,want);
        failures++;return 0;
    }
    printf("  %-22s ok %02X\n",what,got);
    return 1;
}

static void value(const char *what, uint8_t ok)
{
    printf("  %-22s %s\n",what,ok?"ok":"FAIL");
    if(!ok)failures++;
}

static uint8_t write_piece(zep_fs_handle_t h,uint16_t at,uint16_t length,
                           const char *label)
{
    uint16_t actual=0xffff;
    zep_fs_status_t s=zep_fs_write(h,model+at,length,&actual);
    if(!status(label,s,ZEP_FS_OK))return 0;
    value("write byte count",actual==length);
    return actual==length;
}

static uint8_t read_piece(zep_fs_handle_t h,uint16_t at,uint16_t length,
                          uint16_t want,const char *label)
{
    uint16_t actual=0xffff;
    zep_fs_status_t s=zep_fs_read(h,readback+at,length,&actual);
    if(!status(label,s,ZEP_FS_OK))return 0;
    value("read byte count",actual==want);
    return actual==want;
}

int main(void)
{
    zep_fs_handle_t h;
    zep_fs_dir_t dir;
    zep_fs_dirent_t ent;
    zep_fs_stat_t st;
    zep_fs_status_t s;
    uint16_t actual;
    uint16_t i;
    uint32_t pos,free_bytes,total_bytes,free_kib,total_kib;
    char cwd[48];
    uint8_t saw_file=0,saw_dir=0;

    printf("FSTEST - ZephyrC native filesystem\n");
    for(i=0;i<sizeof(model);++i)model[i]=(uint8_t)(i*37u+11u);
    memset(readback,0,sizeof(readback));

    /* A real function 218 answers NO_HANDLE.  An older BIOS leaves the
     * descriptor sentinel at FF, so this is also the API-presence check. */
    if(!status("native API / bad handle",zep_fs_tell(0,&pos),ZEP_FS_NO_HANDLE))
        return 1;
    status("empty name",zep_fs_stat("",&st),ZEP_FS_BAD_NAME);
    status("long basename",zep_fs_stat("ABCDEFGHI.TXT",&st),ZEP_FS_BAD_NAME);
    status("long extension",zep_fs_stat("NAME.ABCD",&st),ZEP_FS_BAD_NAME);
    status("malformed dot",zep_fs_stat("A..B",&st),ZEP_FS_BAD_NAME);
    status("wildcard",zep_fs_stat("*.TXT",&st),ZEP_FS_BAD_NAME);

    if(!status("root",zep_fs_root(),ZEP_FS_OK))return 1;
    s=zep_fs_mkdir("ZCFSTEST");
    if(s!=ZEP_FS_OK&&s!=ZEP_FS_EXISTS) {
        status("mkdir ZCFSTEST",s,ZEP_FS_OK);return 1;
    }
    printf("  %-22s ok %02X\n","mkdir ZCFSTEST",s);
    if(!status("chdir ZCFSTEST",zep_fs_chdir("ZCFSTEST"),ZEP_FS_OK))return 1;
    s=zep_fs_mkdir("NEST");
    if(s!=ZEP_FS_OK&&s!=ZEP_FS_EXISTS)status("mkdir NEST",s,ZEP_FS_OK);
    status("chdir ./NEST",zep_fs_chdir("./NEST"),ZEP_FS_OK);
    if(status("getcwd nested",zep_fs_getcwd(cwd,sizeof(cwd)),ZEP_FS_OK))
        value("nested path",!strcmp(cwd,"/ZCFSTEST/NEST"));
    status("cdup",zep_fs_cdup(),ZEP_FS_OK);
    if(status("getcwd parent",zep_fs_getcwd(cwd,sizeof(cwd)),ZEP_FS_OK))
        value("parent path",!strcmp(cwd,"/ZCFSTEST"));

    if(!status("create-always",zep_fs_open("DATA.BIN",
               ZEP_FS_OPEN_CREATE_ALWAYS,&h),ZEP_FS_OK))goto cleanup;
    actual=0xffff;
    status("write 0",zep_fs_write(h,model,0,&actual),ZEP_FS_OK);
    value("write 0 count",actual==0);
    if(!write_piece(h,0,1,"write 1")||
       !write_piece(h,1,511,"write 511")||
       !write_piece(h,512,512,"write 512")||
       !write_piece(h,1024,513,"write 513")||
       !write_piece(h,1537,1025,"write 1025"))
        goto write_failed;
    if(uncertain)return 1;
    status("sync",zep_fs_sync(h),ZEP_FS_OK);
    if(status("tell after write",zep_fs_tell(h,&pos),ZEP_FS_OK))
        value("write position",pos==2562);
write_failed:
    if(uncertain)return 1;
    status("close written file",zep_fs_close(h),ZEP_FS_OK);

    status("create-new exists",zep_fs_open("DATA.BIN",
           ZEP_FS_OPEN_CREATE_NEW,&h),ZEP_FS_EXISTS);
    if(!status("reopen read",zep_fs_open("DATA.BIN",
               ZEP_FS_OPEN_READ,&h),ZEP_FS_OK))goto cleanup;
    actual=0xffff;
    status("read 0",zep_fs_read(h,readback,0,&actual),ZEP_FS_OK);
    value("read 0 count",actual==0);
    read_piece(h,0,1,1,"read 1");
    read_piece(h,1,127,127,"read 127");
    read_piece(h,128,128,128,"read 128");
    read_piece(h,256,129,129,"read 129");
    read_piece(h,385,511,511,"read 511");
    read_piece(h,896,512,512,"read 512");
    read_piece(h,1408,513,513,"read 513");
    read_piece(h,1921,900,641,"short final read");
    read_piece(h,2562,1,0,"EOF read");
    value("readback data",!memcmp(model,readback,2562));
    status("seek 100",zep_fs_seek(h,100),ZEP_FS_OK);
    if(status("tell 100",zep_fs_tell(h,&pos),ZEP_FS_OK))
        value("seek position",pos==100);
    status("write on read handle",zep_fs_write(h,model,1,&actual),
           ZEP_FS_READ_ONLY);
    status("close read file",zep_fs_close(h),ZEP_FS_OK);

    if(status("open update",zep_fs_open("DATA.BIN",
              ZEP_FS_OPEN_UPDATE,&h),ZEP_FS_OK)) {
        status("truncate smaller",zep_fs_truncate(h,600),ZEP_FS_OK);
        status("sync truncate",zep_fs_sync(h),ZEP_FS_OK);
        status("close truncate",zep_fs_close(h),ZEP_FS_OK);
    }
    if(status("stat 600",zep_fs_stat("DATA.BIN",&st),ZEP_FS_OK))
        value("smaller size",st.size==600);
    if(status("open extend",zep_fs_open("DATA.BIN",
              ZEP_FS_OPEN_UPDATE,&h),ZEP_FS_OK)) {
        status("truncate larger",zep_fs_truncate(h,900),ZEP_FS_OK);
        status("sync extend",zep_fs_sync(h),ZEP_FS_OK);
        status("close extend",zep_fs_close(h),ZEP_FS_OK);
    }
    if(status("stat 900",zep_fs_stat("DATA.BIN",&st),ZEP_FS_OK))
        value("larger size",st.size==900);

    if(status("max 8.3 create",zep_fs_open("MAXNAM88.EXT",
              ZEP_FS_OPEN_CREATE_ALWAYS,&h),ZEP_FS_OK))
        status("max 8.3 close",zep_fs_close(h),ZEP_FS_OK);
    status("max 8.3 delete",zep_fs_delete("MAXNAM88.EXT"),ZEP_FS_OK);
    status("rename",zep_fs_rename("DATA.BIN","RENAMED.BIN"),ZEP_FS_OK);
    status("stat renamed",zep_fs_stat("RENAMED.BIN",&st),ZEP_FS_OK);

    if(status("opendir",zep_fs_opendir(&dir),ZEP_FS_OK)) {
        while((s=zep_fs_readdir(dir,&ent))==ZEP_FS_OK) {
            if(!strcmp(ent.name,"RENAMED.BIN"))saw_file=1;
            if(!strcmp(ent.name,"NEST")&&(ent.flags&ZEP_FS_FLAG_DIRECTORY))
                saw_dir=1;
        }
        status("directory END",s,ZEP_FS_END);
        status("closedir",zep_fs_closedir(dir),ZEP_FS_OK);
        value("enumerated file",saw_file);
        value("enumerated directory",saw_dir);
    }
    /* Reopening proves CLOSEDIR did not leak the controller context. */
    if(status("opendir again",zep_fs_opendir(&dir),ZEP_FS_OK))
        status("closedir again",zep_fs_closedir(dir),ZEP_FS_OK);
    if(status("space",zep_fs_space(&free_bytes,&total_bytes),ZEP_FS_OK))
        value("space ordering",free_bytes<=total_bytes);
    if(status("space KiB",zep_fs_space_kib(&free_kib,&total_kib),ZEP_FS_OK))
        value("space KiB ordering",free_kib<=total_kib);

cleanup:
    if(uncertain)return 1;
    status("delete renamed",zep_fs_delete("RENAMED.BIN"),ZEP_FS_OK);
    status("rmdir NEST",zep_fs_rmdir("NEST"),ZEP_FS_OK);
    status("root cleanup",zep_fs_root(),ZEP_FS_OK);
    status("rmdir ZCFSTEST",zep_fs_rmdir("ZCFSTEST"),ZEP_FS_OK);
    printf(failures?"FSTEST: %u FAILED\n":"FSTEST: all passed\n",failures);
    return failures!=0;
}
