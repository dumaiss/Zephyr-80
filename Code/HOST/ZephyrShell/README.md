# ZephyrShell

ZephyrShell is the first ZephyrOS command environment.  It is deliberately a
small ASH-like C program rather than another ZCPR modification: commands use
the native FS2 hierarchy, byte sizes and status values, while ordinary CP/M
`.COM` programs remain executable during the migration away from ZSDOS/ZCPR.

This milestone is still hosted by the current CP/M/ZSDOS runtime.  It does not
attempt to be the complete ZephyrOS.

## Architecture

See [ARCHITECTURE.md](ARCHITECTURE.md) for the detailed runtime, filesystem,
loader, memory, failure, and extension architecture.

The parser, command loop, path handling, built-ins, error formatting and
executable policy are C modules under `src/`.  `ZSH.COM` is an ordinary
ZephyrC application linked with:

```sh
zcc +cpm -compiler=sdcc -O2 \
    -pragma-define:CRT_ENABLE_COMMANDLINE=0 \
    -I../ZephyrC/include -L../ZephyrC/build -lzephyr
```

The fixed `E400h-EBFFh` CCP slot contains only a 200-byte compatibility shim,
padded to the existing 2 KiB image contract.  Cold and warm boot enter that
shim through the traditional `CCP_ENTRY` / `CCP_CLEARBUF_ENTRY` jumps.  It
loads `A:ZSH.COM` at `0100h`, selects the transitional native drive B:, and
enters the C shell.  The shell itself is not constrained by the old CCP slot.

External commands may be named by basename or by an absolute or relative
native path.  A final component without a dot gets `.COM`; one containing a dot
is tried exactly.  The shell temporarily enters the path's parent to open the
executable through FS2, restores the caller's native CWD, prepares the command
tail at `0080h` and best-effort default FCBs at `005Ch` and `006Ch`, then calls
private BDOS operation 219.  Its protected common-memory loader reads 512-byte
chunks via the existing native FS2 staging gate while the C shell is
overwritten, closes the handle, installs a WBOOT return word, and jumps to
`0100h`.

`RET`, BDOS exit, or `JP 0000h` therefore reaches WBOOT.  WBOOT discards native
handles, preserves the FAT current directory, restores the pristine CCP shim,
and reloads `ZSH.COM`.  ZCPR is not a runtime dependency.

The largest loadable `.COM` image is 60,160 bytes (`0100h-EBFFh`).  The six
bytes at `EC00h-EC05h` are the live BDOS serial preceding the `EC06h` entry and
are not executable-image storage.  Programs may still use the documented
memory below `FBASE` after entry subject to the existing CP/M ABI.

## Native filesystem rules

All shell filesystem commands use `<zephyr/fs.h>`; none uses stdio or CP/M FCB
file I/O.  `ZSH_IO_SIZE` is 512 and the copy, cat and destructive executable
load paths transfer in 512-byte requests with a legal short final read.
Copying never accumulates a 16-bit total, so files larger than 64 KiB work.

FS2 ordinary operations accept one 8.3 component.  `path.c` handles `/`, `.`,
`..`, absolute and relative parents by saving the authoritative native CWD,
navigating to a parent, operating on its final component and restoring the CWD
on every path.  `cd` also rolls back a partially completed native CHDIR.

The native root remains the controller FS2 tree associated with CP/M drive B:.
Function 218 also exposes USER 0 of the immutable recovery drive as the
read-only mount `/CPM/A`; for example, `cd /CPM/A`, `ls`, and a bare recovery
utility name all use the provider-backed path.  CP/M record storage has no exact
byte length, so displayed A-file sizes are rounded up to 128 bytes.

`ZSH_NATIVE_DRIVE` in `src/shell.c` still selects B: as the compatibility
drive for legacy `.COM` programs.  USER remains compatibility state, not a
shell directory model.

## Commands

```text
cd [path]       pwd             ls [-l] [path]
cp SRC DST      mv SRC DST      rm FILE [FILE ...]
mkdir PATH      rmdir PATH      cat FILE [FILE ...]
stat PATH       df (KiB)        echo [ARGS ...]
help
```

Aliases: `dir` = `ls`, `del` = `rm`, `md` = `mkdir`, `rd` = `rmdir`, and
`type` = `cat`.  Command names are case-insensitive.  Arguments may be
unquoted, single quoted, or double quoted.

`Ctrl-L` clears the screen and redraws the prompt plus any input already typed.
Up-arrow (`ESC [ A`) replaces the current input with the last non-empty command.
History has one process-local entry; it is reset when an external `.COM` command
overwrites the shell and WBOOT reloads it.

An existing directory is accepted as the destination of `cp` or `mv`; the
source basename is appended automatically.  Cross-directory `mv` is copy,
successful close, then delete.  A failed or `ZEP_FS_UNKNOWN_WRITE` copy never
deletes the source.  Cross-parent directory moves are rejected; same-parent
native rename is supported.  Copying a file onto itself is rejected before the
destination can be truncated.

## Build and tests

```sh
cd Code/HOST/ZephyrShell
make                 # build/ZSH.COM and build/ccp-zshell.bin
make host-tests      # mocked FS2 host suite

cd ../CPM2.2
make CCP=zshell      # bootable ROM with shim plus A:ZSH.COM
make CCP=zcpr2       # retained recovery configuration
```

The host suite covers empty/quoted/maximum/overlong parsing; path splitting and
CWD rollback; 0, 1, 511, 512, 513, multi-KiB and >64-KiB copies; read, write
and unknown-write failures; same/cross-parent moves; and directory iterator
closure after END and errors.

## Hardware acceptance

Use a disposable FAT card and verify:

```text
boot
Ctrl-L
pwd
Up-arrow
mkdir TEST
cd TEST
pwd
mkdir SUB
ls
ls -l
cp ../SOMEFILE.TXT COPY.TXT
cat COPY.TXT
stat COPY.TXT
mv COPY.TXT MOVED.TXT
ls
mv MOVED.TXT SUB/MOVED.TXT
ls
ls SUB
rm SUB/MOVED.TXT
rmdir SUB
cd /
rmdir TEST
df
```

Also copy a file larger than 64 KiB and compare its byte count and contents.
Run `SYSID` and a representative ordinary `.COM` such as `SDBENCH` from the
native current directory.  Confirm the program runs, exit reaches the shell
through WBOOT, the native CWD survives, no FS2 handles are exhausted after
repetition, and the console remains usable.

## Deliberate v1 omissions

There is no PATH, ZEX, globbing, environment, scripting, redirection, pipes,
background jobs, process scheduling, resource management, GameOS facility or
resident-parent process model.  Line editing deliberately remains minimal: no
cursor movement, completion, persistent history, or multi-entry history.

## Future

- PATH and executable search
- ZEX
- a native executable loader
- shell variables and scripting
- redirection and pipes
- hosted child execution returning to a resident native parent
- cursor editing, completion and persistent multi-entry history
