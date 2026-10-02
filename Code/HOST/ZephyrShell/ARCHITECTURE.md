# ZephyrShell architecture

This document describes the architecture of the current ZephyrShell v1 implementation. It is an implementation reference, not a proposal: paths, limits, call numbers, and lifecycle behavior are derived from the shell, ZephyrC, and Zephyr-80 BIOS sources that ship together.

ZephyrShell is the first native-filesystem command environment for Zephyr-80. It is a normal CP/M transient program written in C, but its filesystem model is FS2 rather than CP/M FCB I/O. The existing CP/M/ZSDOS runtime remains the boot, console, compatibility, and transient-program substrate while the system moves toward ZephyrOS.

## Design goals and invariants

The v1 design has five central goals:

1. Present the hierarchical, byte-oriented FS2 namespace as the shell's native filesystem.
2. Keep ordinary CP/M `.COM` programs executable during the migration.
3. Keep the fixed 2 KiB CCP slot as a small bootstrap rather than forcing the C shell into it.
4. Preserve CP/M page-zero and warm-boot conventions for child programs.
5. Handle failures conservatively, especially when a write may have reached storage but its completion cannot be confirmed.

The resulting invariants are:

- Shell file and directory operations go through `<zephyr/fs.h>` and BDOS 218. They do not use stdio or CP/M FCB file operations.
- CP/M FCB I/O is used only by the CCP bootstrap to load `A:ZSH.COM`.
- Native current-directory state is authoritative. CP/M drive and USER values remain compatibility state and are displayed in the prompt.
- Each low-level FS2 file or namespace operation acts on one packed 8.3 component. Multi-component paths are handled by ZephyrC and `path.c`.
- A child `.COM` replaces the shell in the TPA. There is no resident shell parent; WBOOT restores the bootstrap and starts a fresh shell instance.
- The existing BIOS jump table and CP/M ABI remain unchanged. BDOS 218 is the public native-filesystem gate; BDOS 219 is a private shell loader.

## System context

```text
                        cold boot or WBOOT
                                |
                                v
                 protected BIOS boot/WBOOT path
                 - prepares bank 0 and page zero
                 - restores pristine CCP shim on WBOOT
                 - resets transient FS2 handles
                                |
                                v
                    CCP shim at E400h-EBFFh
                    - reads A:ZSH.COM with FCB I/O
                    - selects compatibility drive B:
                    - jumps to 0100h
                                |
                                v
                    ZephyrShell C program in TPA
                 +--------------+---------------+
                 |                              |
                 v                              v
          built-in command                external command
                 |                              |
                 v                              v
       ZephyrC FS API / BDOS 218      validate/open through FS2
                 |                    prepare page zero
                 v                    invoke private BDOS 219
       common-memory native gate                |
                 |                              v
                 v                    protected destructive loader
       bank-7 provider router          - reads 512-byte chunks
          /                 \          - overwrites shell
         v                   v         - closes handle
   writable FS2 root    /CPM/A provider - jumps to 0100h
   on storage card      recovery ROM             |
                                                v
                                       child exits through WBOOT
```

The shell depends on three neighboring projects:

- `ZephyrC` provides the typed FS2 wrappers and CP/M C runtime.
- `CPM2.2` provides the BDOS facade, common-memory crossing gates, native provider router, destructive loader, boot/WBOOT path, and ROM image builder.
- The IO Controller implements the physical FS2 service used by the writable native provider.

## Build products and image integration

The shell build produces two independent artifacts:

| Artifact | Role |
|---|---|
| `build/ZSH.COM` | The C shell, linked as an ordinary CP/M transient for `0100h`. |
| `build/ccp-zshell.bin` | A 2 KiB, `E400h`-based CCP compatibility image containing the bootstrap and padding. |

`ZSH.COM` is built with z88dk's CP/M target and SDCC, with CRT command-line parsing disabled. It links against `libzephyr`:

```sh
zcc +cpm -compiler=sdcc -O2 \
    -pragma-define:CRT_ENABLE_COMMANDLINE=0 \
    -I../ZephyrC/include -L../ZephyrC/build -lzephyr
```

The `CPM2.2` build selects the shell with `CCP=zshell`, which is also the default. It builds both artifacts, installs the shim in the fixed CCP slot, stores a pristine copy in protected bank-7 SRAM for WBOOT, and adds `ZSH.COM` to USER 0 of the read-only A: recovery ROM.

The image patcher verifies that the CCP artifact is exactly 2 KiB, begins with the two required jump entries, and does not overwrite the six-byte BDOS serial at `EC00h-EC05h`.

At the time this document was written, `ZSH.COM` is 15,895 bytes and the shim image is 2,048 bytes. Those are build observations, not ABI constants.

## Runtime components

| Source | Responsibility |
|---|---|
| `src/main.c` | Minimal C entry point; calls `zsh_run()`. |
| `src/shell.c` | Startup policy, prompt, BDOS line input, parse/dispatch loop. |
| `src/parser.c` | In-place tokenization and quote removal. |
| `src/path.c` | Path splitting, CWD save/restore scopes, atomic `cd`, same-parent resolution. |
| `src/builtins.c` | Built-in dispatch and all native file/directory operations. |
| `src/exec.c` | `.COM` lookup policy, CP/M page-zero preparation, BDOS 219 handoff. |
| `src/status.c` | FS2 status-to-text mapping and error formatting. |
| `src/tinyio.c` | Console output and small decimal/hexadecimal formatters. |
| `stubs/ccp.asm` | Fixed-address recovery-volume bootstrap. |
| `tests/mock_fs.c` | In-memory host implementation of the FS2 calls used by the shell. |
| `tests/test_shell.c` | Parser, path, copy, move, and iterator regression tests. |

The shell modules do not allocate dynamic memory. Long-lived storage consists of fixed-size static arrays; short-lived state is automatic. The largest shared data buffer is the single 512-byte `io_buffer` in `builtins.c`.

## Boot and shell reload lifecycle

### Cold boot

The BIOS cold-boot path initializes hardware, prepares runnable bank 0, installs page-zero vectors, resets the BDOS facade and transient FS2 context, and enters `CCP_CLEARBUF_ENTRY` at `E403h`.

Both shim entries at `E400h` and `E403h` jump to the same bootstrap. It:

1. sets its stack to `EC00h`;
2. opens `A:ZSH.COM` using a conventional CP/M FCB;
3. reads sequential 128-byte records into memory beginning at `0100h`;
4. refuses a record that would overlap the live shim at `E400h`;
5. closes the FCB and restores default DMA address `0080h`;
6. selects CP/M drive B:, the transitional FS2 compatibility drive;
7. sets the initial application stack to `B000h` and pushes a zero return word;
8. jumps to `0100h`.

The bootstrap removes the old 2 KiB CCP-size constraint, although the shell image must still end below the live shim while it is being loaded. If `A:ZSH.COM` is missing or too large, the shim prints a fatal diagnostic and halts; there is no second command processor to fall back to.

### Warm boot

An external program normally exits by returning to the installed WBOOT word, calling the CP/M termination service, or jumping to `0000h`. WBOOT executes from protected common memory and:

1. forces bank 0 before using a stack or helper;
2. returns application interrupts and devices to OS ownership;
3. restores the pristine 2 KiB shell shim from bank-7 SRAM;
4. recreates page zero and default DMA state;
5. resets the BDOS facade and closes/discards transient native handles and the active directory iterator;
6. preserves the writable provider's bank-7 current-directory components;
7. resets the synthetic `/CPM/A` provider state to native root;
8. reinitializes the console; and
9. enters the shim again, which reloads `A:ZSH.COM`.

Consequently shell globals, parser storage, and built-in state never survive a child command. The writable native CWD does survive. A shell that launched a program while positioned in `/CPM/A` returns at `/` because the recovery provider's CWD is reset with its handles.

## Memory model

These are the architectural boundaries used by the shell path, not a complete system memory map.

| Range/address | Ownership and shell significance |
|---|---|
| `0000h` | `JP WBOOT`; also the return target supplied to transient programs. |
| `0005h` | `JP FBASE`; entry for BDOS calls including 218 and 219. |
| `005Ch` | First 36-byte default FCB prepared before child launch. |
| `006Ch` | Second default FCB in the conventional CP/M page-zero layout. |
| `0080h` | Default DMA and CP/M command tail. |
| `0100h` | Entry/load address for `ZSH.COM` and child `.COM` programs. |
| `E400h-EBFFh` | Live 2 KiB CCP shim; a destructively loaded child may overwrite it. |
| `EC00h-EC05h` | Live ZSDOS serial; never child-image storage. |
| `EC06h` | `FBASE`, the BDOS facade entry. |
| `EFB1h-EFF7h` | Protected common-memory BDOS 219 loader. |
| `FA00h-FBFFh` | Common 512-byte bulk staging buffer used by native transfers. |
| bank 7 `C400h-CBFFh` | Pristine shell-shim restore asset used by WBOOT. |

The general CP/M TPA is `0100h-EC05h`. ZephyrShell limits an external `.COM` file to 60,160 bytes (`EB00h` bytes), so loading at `0100h` ends at `EBFFh` and leaves the serial and `FBASE` intact. Once started, a child may use memory below `FBASE` according to the normal CP/M ABI.

The protected loader sets the child's stack to `EFF8h`, pushes WBOOT, and jumps to `0100h`. This stack remains valid even though the shell and CCP area may have been overwritten.

## Main command loop

`zsh_run()` is intentionally linear:

```text
select CP/M drive B:
print banner
forever:
    query drive, USER, and native CWD
    print prompt
    read one edited line through BDOS 10
    parse line in place
    if command is built in:
        execute it
    else:
        resolve and execute a native .COM name or path
```

There is no asynchronous job table, pipeline graph, subprocess object, or resident parent. A built-in returns to this loop; an external command does not.

### Prompt

The prompt is `B0:/PATH$ `. The drive letter is queried through BDOS 25, USER through BDOS 32 with `FFh` as the query argument, and the path independently through `zep_fs_getcwd()`. If the CWD query fails, `?` replaces the path.

The `B0:` prefix is compatibility information. It does not select a separate shell namespace, and USER numbers are not modeled as native directories.

### Input and parser

Input uses CP/M edited-console call BDOS 10. The shell accepts at most 127 input characters plus NUL in its 128-byte line buffer. It has no history, completion, incremental parser, or custom editor.

The parser compacts the line in place. `argv` entries point into that buffer and remain valid only until the next line is read. Its grammar is small:

- spaces and tabs separate arguments;
- single and double quotes preserve embedded whitespace and are removed;
- quoted and unquoted spans can be adjacent within one argument;
- there is no escape character or variable expansion;
- an empty line produces zero arguments;
- unterminated quotes, more than 16 arguments, and overlong lines are errors.

Command names are matched case-insensitively. FS2 components are validated and uppercased by ZephyrC when packed into the descriptor.

## Native filesystem boundary

### Public C layer

The shell calls `ZephyrC/include/zephyr/fs.h`. This provides byte-oriented file handles, component-based stat/mutation calls, path-aware chdir, an explicit directory iterator, and byte/KiB space queries.

ZephyrC constrains each native transfer to at most 512 bytes. Larger caller requests are split into multiple descriptors. ZephyrShell requests 512 bytes, so each copy or `cat` iteration maps to one native transfer except for a short final result.

### BDOS 218 descriptor and crossing gate

ZephyrC marshals each operation into a 32-byte, version-1 descriptor and calls BDOS 218:

| Offset | Field | Meaning |
|---:|---|---|
| `0` | version | `1` |
| `1` | operation | OPEN, READ, CHDIR, SPACE_KIB, and so on |
| `2` | status | FS2 result; initialized to `FFh` so an old OS reads as unsupported |
| `3` | flags | Open mode, attributes, or CWD component index |
| `4` | handle | File or directory handle |
| `6` | position/name2 | 32-bit offset, or second packed name for rename |
| `10` | length | Requested byte count |
| `12` | buffer | Caller buffer address |
| `16` | result | Actual byte count or returned CWD depth |
| `18` | name/space total | Packed 11-byte 8.3 name or second 32-bit space value |

The common-memory gate copies the descriptor from the caller's bank. For WRITE it copies caller data into the common 512-byte bulk buffer before OS mode. For READ it copies returned data back after restoring the caller mapping. It copies the updated descriptor back and returns status in `A`.

This is a synchronous, process-global service. Descriptor staging, the bulk buffer, handle tables, CWD, and directory iterator are not reentrant or ISR-safe.

### Provider routing and namespace

In bank 7, `native_vfs_entry` routes by current provider and handle ownership:

```text
native root /
|-- ordinary FS2 entries              -> writable FAT/FS2 provider
'-- CPM/                              -> synthetic router directory
    '-- A/                            -> read-only CP/M recovery provider
        '-- USER-0 files from ROM A:
```

The native root is the writable FS2 tree associated with transitional CP/M drive B:. `CPM` need not exist on the card; the router injects it into root listings and intercepts stat/chdir.

`/CPM/A` exposes the same immutable recovery ROM that supplies `A:ZSH.COM`, but through FS2. It parses the CP/M 2.2 directory and allocation extents directly in bank 7 and reads through the ROM-disk backend. It never recursively calls BDOS. The mount:

- exposes only USER 0;
- is read-only for file and namespace mutation;
- rounds file lengths to complete 128-byte CP/M records;
- reports zero free and 144 KiB total;
- reserves native handle `80h`; and
- permits one recovery-file handle and one recovery iterator alongside writable-provider resources.

### Space reporting

`df` first calls `zep_fs_space_kib()`. KiB units let a 16 GiB card fit exactly in unsigned 32-bit values while preserving the card's 8 KiB allocation-block granularity.

If an older BIOS returns `FS2 FF`, `df` falls back to bytes. Byte counts saturate at `FFFFFFFFh`; the shell displays `>=4 GiB` and appends `(32-bit API limit)` instead of presenting `4294967295` as exact.

## Path architecture

Most FS2 namespace calls accept one 8.3 component, while users pass multi-component paths. `path.c` temporarily navigates to the operation's parent:

```text
getcwd() -> saved CWD
split path -> parent "/A/B", leaf "FILE.TXT"
chdir(parent)
operate on packed leaf
chdir(saved CWD)
```

`zsh_path_scope_t` owns the saved canonical CWD, leaf, and active flag. A failed traversal triggers best-effort restoration. If the operation succeeds but restoration fails, restoration becomes the reported error; an opened handle is closed rather than leaked.

`zep_fs_chdir()` handles `/`, repeated separators, `.`, and `..` one component at a time, so a later failure can leave a partial CWD change. `zsh_path_chdir_atomic` saves and rolls back failed `cd` operations.

Same-parent move detection resolves both parents and compares their canonical CWD strings rather than their textual spelling.

| Path resource | Limit |
|---|---:|
| Shell path buffer | 208 bytes |
| FS2 CWD depth | 16 components |
| Printable component | 12 characters plus NUL |
| Packed 8.3 component | 11 bytes |

## Built-in command architecture

A recognized built-in returns to the main loop; a false dispatch result delegates to `.COM` execution.

| Command | Native behavior |
|---|---|
| `help` | Prints the built-in summary. |
| `echo` | Prints parsed arguments separated by one space. |
| `pwd` | Prints authoritative FS2 CWD. |
| `cd [path]` | Atomically changes CWD; no argument means `/`. |
| `ls [-l] [path]` | Lists a directory or stats one file. Long form shows type, byte size, and name. |
| `cp SRC DST` | Copies a regular file; an existing destination directory receives the source basename. |
| `mv SRC DST` | Native same-parent rename; otherwise copy, close, then delete. Existing destination directories receive the source basename. |
| `rm FILE...` | Refuses directories, then deletes each regular file. |
| `mkdir PATH` | Enters the parent and creates one component. |
| `rmdir PATH` | Enters the parent and removes one component. |
| `cat FILE...` | Reads 512-byte chunks and writes bytes to the console. |
| `stat PATH` | Reports type and byte size. |
| `df` | Reports space, preferring exact KiB values. |

Aliases are `dir`, `del`, `md`, `rd`, and `type`.

### Copy, move, and iterator guarantees

Copy uses one 512-byte buffer and never accumulates a 16-bit total, so files over 64 KiB work. Each write must report exactly the bytes read. Both handles are closed on every exit; a close error is reported if no earlier error exists.

If the destination resolves as a directory, the source basename is appended before any file is opened. The explicit source and destination parents are compared canonically; copying a file onto itself is rejected before create-always can truncate it.

A non-directory destination uses create-always semantics. Failure can leave a new, truncated, or partial destination; v1 has no temporary-file transaction.

A cross-parent move resolves directory destinations the same way, rejects source directories, copies, requires the data loop and both closes to succeed, and only then deletes the source. `ZEP_FS_UNKNOWN_WRITE` is never retried and never causes source deletion.

Every successful `opendir` is paired with `closedir`, including END and error paths. `ZEP_FS_END` becomes successful command completion.

## External `.COM` execution

### Lookup and compatibility setup

There is no PATH search. The command may be a basename or an absolute or relative native path. The shell enters the path's parent transactionally, applies executable-name policy to the final component, stats and opens it, and restores the original native CWD before invoking the loader.

- A final component without a dot must be at most eight characters and gets `.COM`.
- A dotted final component is tried exactly and may contain at most 12 characters.
- Backslash and colon remain invalid in the final component.
- The candidate must be a regular file.
- Reported size must not exceed 60,160 bytes.

Thus `/CPM/A/sdput`, `CPM/A/sdput.com`, and bare `sdput` while inside `/CPM/A` are all valid. Loading by path does not change the CWD inherited by the child.

Before transfer, `exec.c` prepares default FCBs at `005Ch` and `006Ch` from the first two arguments and builds the counted command tail at `0080h`. FCB preparation is best effort: path-like arguments produce a blank FCB name, while base/extension fields are uppercased and truncated to 8.3.

The command tail is reconstructed from parsed arguments with one leading space per argument. Original quoting is lost. The tail is capped at 126 characters and terminated with carriage return.

### Destructive loader

The shell opens through FS2, creates a version-1 READ descriptor with the handle and 512-byte request, and calls BDOS 219.

BDOS 219 runs at `EFB1h` in protected common memory:

```text
copy descriptor to common memory
destination = 0100h
repeat:
    READ through the bank-7 provider
    on error: close and WBOOT
    on zero bytes: finish
    copy FA00h staging bytes to destination
    advance destination
close handle
set protected stack, push WBOOT
jump 0100h
```

The shell is overwritten, so success or load failure cannot return to it. If BDOS 219 unexpectedly returns on an incompatible OS, the still-live shell closes the handle and prints `protected loader unavailable`.

The size check occurs before launch. The protected loader trusts the opened file and has no second load bound. The single-process model has no concurrent writer, so size is expected to remain stable.

## Console and output

Input is BDOS 10 and output is byte-at-a-time BDOS 6, leaving the BIOS in control of the selected V9958, Virtual Drip, or serial backend.

`zsh_putc()` converts a lone LF to CR/LF and avoids a duplicate CR when one was just printed. This prevents staircase newlines. It also means `cat` is a display command, not a byte-transparent device copy.

`tinyio.c` uses small decimal and hexadecimal emitters instead of stdio formatting.

## Status and failure model

`status.c` preserves FS2 results, maps `00h`, `40h-4Eh`, and `FFh` to text, and includes the numeric status:

```text
command: path: message (FS2 XX)
```

| Status | Meaning | Shell consequence |
|---:|---|---|
| `00h` | success | Continue. |
| `40h` | not found | Missing path or `command not found`. |
| `41h` | end of directory | Normal end of `ls`. |
| `44h` | read only | Expected beneath `/CPM/A`. |
| `45h` | no space | Copy stops; move source remains. |
| `48h`/`49h` | no/stale handle | Report; no retry. |
| `4Ch` | transport error | Fail without replay. |
| `4Dh` | completion unknown | Warn destination may have changed; never replay/delete source. |
| `4Eh` | I/O error | Fail and clean up. |
| `FFh` | unsupported | `df` selects legacy fallback. |

There is no exception mechanism or global command status. Helpers return the primary FS2 error; cleanup/restoration errors replace success only.

## State ownership and fixed limits

The design is single-threaded and synchronous.

| State | Owner | Lifetime |
|---|---|---|
| Input line and `argv` | `shell.c` | Reused each prompt. |
| 512-byte I/O buffer | `builtins.c` | Shell instance. |
| Saved CWD/path scope | caller stack | One operation. |
| Native handles/iterator | bank-7 providers | Until close/reset. |
| Writable native CWD | FAT provider | Preserved over WBOOT. |
| `/CPM/A` state | mount provider | Reset over WBOOT. |
| Descriptor/staging | common facade | One BDOS call. |
| Shell image | TPA | Until BDOS 219 overwrites it. |

| Resource | Limit |
|---|---:|
| Edited command line | 127 characters |
| Parsed arguments | 16 including command |
| Shell path buffer | 208 bytes |
| Native CWD depth | 16 components |
| Native transfer | 512 bytes |
| External `.COM` | 60,160 bytes |
| Writable native files | 2 simultaneous slots |
| Writable directory iterators | 1 |
| Recovery files | 1 |
| Recovery iterators | 1 |

Copy consumes both writable file slots. Built-ins must not nest directory enumeration or assume another task can change CWD during a saved-CWD transaction. FS calls are not ISR-safe.

## Verification strategy

`make host-tests` builds shell policy against `tests/mock_fs.c`. It covers:

- empty, quoted, maximum/excessive-argument, overlong, and unterminated-quote parsing;
- path splitting and rollback after partial `chdir` failure;
- absolute executable-path resolution, `.COM` suffixing, and CWD restoration;
- copies of 0, 1, 511, 512, 513, 4,097, and 70,000 bytes;
- copy/move to existing directories and same-file copy protection;
- read, write, and unknown-write failures;
- same-parent rename and cross-parent move;
- source preservation on failed/ambiguous moves; and
- iterator closure after END and error.

The mock suite does not emulate banking, page zero, the ROM provider, or protected loader.

`make CCP=zshell` in `CPM2.2` verifies the shim, patches the fixed CCP slot, places `ZSH.COM` on A:, links the native gate/loader, checks fixed-region overlap, and regenerates authoritative memory maps.

Hardware acceptance additionally covers boot/WBOOT reload, writable-CWD persistence, `/CPM/A` listing and execution, repeated launches without handle exhaustion, real-media files over 64 KiB, exact KiB `df` on cards over 4 GiB, and console recovery.

## Extension boundaries

- Add shell syntax in `parser.c` and path policy in `path.c`.
- Keep leaf FS2 operations component-oriented.
- Add built-ins only when they fit the synchronous process model.
- Extend filesystems through ZephyrC and BDOS 218, not fixed bank-7 labels.
- Add namespace providers behind `native_vfs_entry` with distinct handle/reset policy.
- Change child execution through the protected loader contract; never load destructively from code inside the shell image.
- Keep CP/M compatibility setup localized to `exec.c` and `stubs/ccp.asm`.

A resident-parent or native-process model would change TPA ownership, returns, resource lifetime, and the execution API; it is not an incremental v1 extension.

## Deliberate v1 omissions

There is no PATH search, ZEX, globbing, variables, scripting, redirection, pipes, background jobs, process scheduling, native executable format, GameOS integration, or resident shell parent.

## Source-of-truth references

When this document and generated addresses disagree, use:

1. `src/` and `stubs/ccp.asm` for shell policy;
2. `../ZephyrC/include/zephyr/fs.h` and `../ZephyrC/src/zep_fs.c` for the C API and descriptor;
3. `../CPM2.2/src/common/native_gate.asm`, `native_stage.asm`, and `exec_loader.asm` for crossing/loading;
4. `../CPM2.2/src/drivers/storage/native_vfs.inc` and `cpm_mount.asm` for provider routing;
5. `../CPM2.2/src/common/boot.asm` for boot/WBOOT; and
6. generated `../CPM2.2/docs/memory-map.md` and `symbol-map.md` for current addresses.
