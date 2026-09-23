# Zephyr / ZSDOS Alteration Guide

> **Status:** Initial working version.
>
> This guide starts from the FAT-backed BDOS bring-up and the current Zephyr-80
> implementation. It is intended to become the normative maintenance guide for
> altering ZSDOS integration, BIOS behavior, BDOS interception, native Zephyr
> extensions, and related OS infrastructure.
>
> The current repository is authoritative for implementation details. This
> document records architectural rules and compatibility contracts that should
> remain stable even as addresses, symbols, and module layouts evolve.
>
> For historical context and the failures that led to many of these rules, see
> [FAT-BRINGUP-LESSONS-LEARNED.md](FAT-BRINGUP-LESSONS-LEARNED.md).

---

## 1. Core design principle

Zephyr should extend ZSDOS **around its interfaces**, not gradually turn into a
private fork of ZSDOS.

The preferred layering is:

```text
application
    |
    v
CALL 5 / common facade
    |
    v
bank-7 dispatcher
    |
    +-- Zephyr-specific semantics
    |
    +-- ZSDOS_ENTRY
            |
            v
           BIOS
```

If a change can be implemented at the facade/dispatcher or BIOS boundary,
prefer that to modifying ZSDOS internals.

The FAT-backed drive is the reference example: Zephyr added a fundamentally
different filesystem while leaving ZSDOS authoritative for normal CP/M state.

---

## 2. State ownership must remain unambiguous

Do not create a second authoritative copy of CP/M state.

| State | Authority | Zephyr may do |
|---|---|---|
| Current drive | ZSDOS | mirror/cache it |
| USER | ZSDOS function 32 | mirror it |
| Software write protect | ZSDOS | mirror for intercepted mutations |
| DMA semantics | CP/M/ZSDOS facade contract | stage/copy as required |
| DPH/DPB/ALV | BIOS/ZSDOS-visible model | synthesize where a backend requires |
| FAT current directory | Zephyr FAT backend | own it |
| IOC/FS2 handles | Zephyr implementation | cache opportunistically |
| Media generation | FS2/IOC | mirror and invalidate local state |

A mirror must be disposable and reconstructible.

If losing a value would break correctness, it should not exist only as a
mirror.

---

## 3. Bank 7 is implementation space; common memory is ABI space

This is a Zephyr architectural rule.

> **Bank 7 is the normal implementation space for the OS. Common bank-0 memory
> exists for crossing and ABI requirements.**

New OS logic, tables, and persistent implementation state belong in bank 7 by
default.

Common memory is justified only for things that genuinely must remain visible
while application mapping is active, such as:

- CALL 5 / BDOS facade entry
- bank-transition helpers
- interrupt-entry infrastructure
- caller-visible returned objects
- staging buffers
- cross-mode stack/state

Free common memory is not by itself a reason to place implementation code
there.

The generated memory map and allocator ownership are authoritative. Historical
free ranges are not.

Reclaimable 512-byte arenas remain allocator-owned and must not silently become
permanent module storage.

---

## 4. The facade is an ABI boundary, not just a trampoline

The common facade exists because application-visible pointers and buffers
cannot simply be handed to arbitrary bank-7 implementation code.

Before adding a new BDOS extension or intercepted service, answer:

```text
What must cross between application mapping and bank 7?
What can remain entirely in bank 7?
Does the caller expect a pointer back?
Can that returned pointer legally refer to bank-7 storage?
```

Normally, application-visible pointers may not refer directly to private
bank-7 objects.

Reuse the existing facade staging and crossing mechanism. Do not invent a
second crossing framework for each new subsystem.

---

## 5. Intercept semantics, not bookkeeping

Zephyr should intercept calls where the **meaning of the operation changes**.

It should not duplicate ordinary ZSDOS bookkeeping merely because that is
possible.

The FAT personality is the model:

- FAT-backed OPEN/READ/SEARCH need alternate semantics, so they are intercepted.
- Current-drive selection remains ZSDOS function 14.
- USER remains ZSDOS function 32.
- ZSDOS software write protection remains authoritative.

When practical, let ZSDOS continue to maintain the state it already owns.

---

## 6. Synthetic BIOS personalities are preferred to parallel OS state

A backend does not need to be a real CP/M block filesystem to participate in
the CP/M disk model.

The FAT-backed drive provides enough synthetic BIOS behavior for ZSDOS to
select and log the drive normally:

```text
SELDSK  -> valid synthetic DPH
READ    -> harmless synthetic empty-disk view
WRITE   -> appropriate failure during read-only operation
DPB     -> synthetic CP/M geometry
ALV     -> synthetic capacity view
```

Real FAT file access occurs above this BIOS layer.

This has two important benefits:

1. ZSDOS keeps authoritative current-drive/login state.
2. If a FAT-dependent operation accidentally escapes interception, it fails
   against an empty synthetic drive instead of touching a previously selected
   conventional disk.

This pattern should be considered for future nontraditional storage
personalities.

---

## 7. FCBs are part of the ABI; IOC handles are not

Applications may copy FCBs.

Therefore an FCB must remain sufficient to reconstruct the file operation.

Do not hide an IOC/FS2 token inside an FCB or make correctness depend on a
specific controller handle surviving.

IOC handles may be cached for performance using an identity such as:

```text
drive
USER
current-directory generation
packed 8.3 filename
```

The handle is opportunistic.

If it disappears, becomes stale, or is invalidated by a namespace operation,
reopen the file and reconstruct the operation from authoritative FCB/path
state.

This rule allowed the FAT implementation to gain substantial performance from
cached FS2 handles without changing CP/M semantics.

Writable operations must acquire appropriate writable state separately. Never
silently reuse a stale or read-only cached token for mutation.

---

## 8. SEARCH FIRST / SEARCH NEXT form a rich compatibility contract

Do not reduce CP/M SEARCH to "find filenames matching a wildcard."

Legacy software may observe:

- A = 0..3 identifying the matching 32-byte slot
- the matching entry at `DMA + A * 32`
- the complete 128-byte DMA directory image
- USER byte
- packed 8.3 filename
- EX/S1/S2/RC
- attribute high bits where applicable
- FCB mutation/preservation behavior
- SEARCH NEXT continuation state
- end-of-search return behavior

Large files require synthetic CP/M extent behavior even when the backing FAT
filesystem stores a single byte-stream file.

The FAT bring-up also established that:

```text
FCB[0] = '?'
```

has a legitimate special SEARCH meaning under ZSDOS and must not be dismissed
as an invalid drive number.

When changing SEARCH behavior, characterize actual ZSDOS observable behavior
rather than relying only on simplified CP/M documentation.

---

## 9. Existing utilities may not test what the command line appears to test

A shell command can hide important BDOS behavior.

For example, ZCPR2 TYPE can temporarily log into an explicitly named drive and
then perform file access using an FCB whose drive byte is zero.

Therefore:

```text
D> TYPE B:FILE
```

does not necessarily test the same path as an application holding an explicit
B: FCB while D: remains current.

VGMPLAYER exposed this distinction during FAT bring-up.

Before using a utility as a conformance test, determine which BDOS calls and
FCB values it actually generates.

Dedicated characterization tools are often more reliable than shell commands.

---

## 10. Explicit-drive FCB operations may contain hidden drive transitions

A ZSDOS call using an explicit B: FCB while D: is current may internally
behave like:

```text
remember D
select B
perform operation
restore D
return
```

Therefore an error reported during a BDOS READ on B: does not prove that the B:
data read itself failed.

The later restoration of D: may have failed.

When debugging drive-selection problems, trace actual SELDSK transitions rather
than inferring the failing physical operation from the high-level BDOS call
that reports the error.

---

## 11. High-level filesystem errors may originate below the filesystem

The FAT bring-up exposed an IOC receive race that appeared at first to be a
filesystem or drive-state failure.

The important transport rule is:

```text
waiting for first RX byte:
    interrupts enabled

first RX-ready indication:
    DI

marker recognition
reply reception
bulk phase

    EI
```

The MCU is the clock master. Once the first byte of a reply arrives, the timing
deadline has begun.

Masking interrupts only after marker recognition is too late if an interrupt
can allow the SIO FIFO to overflow.

A transport failure may surface as a ZSDOS "No Drive" or filesystem error.
Do not assume that the layer reporting the failure is the layer that caused it.

---

## 12. BIOS interrupt ownership is an architectural boundary

The current Zephyr design makes the BIOS/core the owner of the IM2 vector page.

Programs register callbacks through Zephyr mechanisms rather than taking
ownership of the I register or rewriting the vector table.

When adding interrupt sources:

- preserve BIOS/core ownership of the interrupt architecture;
- let drivers own device-specific handling policy, not the global vector model;
- account for devices such as the V9958 whose interrupt behavior does not map
  naturally onto the same vectored model as CTC/SIO sources.

Any alteration to interrupt behavior should be reviewed as an OS architecture
change, not merely a device-driver detail.

---

## 13. Native extensions bypass CP/M semantics, not necessarily CALL 5

BDOS function 218 is the current native-filesystem precedent.

A Zephyr-native program may still enter through CALL 5, but operations such as:

```text
ZOPEN
ZCLOSE
ZREAD
ZSEEK
ZTELL
ZSTAT
ZOPENDIR
ZREADDIR
ZCHDIR
```

are not CP/M FCB operations.

This allows the same FAT files to have two personalities:

```text
Legacy CP/M view
    FCB
    USER
    128-byte records
    synthetic extents

Zephyr native view
    paths
    byte offsets
    larger transfers
    directories
```

Do not contaminate the native API with CP/M record semantics merely because
CALL 5 is currently the syscall gateway.

A future OS such as GameOS may expose the same underlying native services
through another entry mechanism without changing FS2 or FatFs.

---

## 14. Resource services belong above the native filesystem API

The resource manager should not become another filesystem.

The intended layering is:

```text
RESOURCE_OPEN / READ / SEEK
        |
        v
ZOPEN / ZREAD / ZSEEK
        |
        v
FS2
        |
        v
FatFs
```

The resource layer may add:

- caching
- decompression
- prefetching
- streaming
- symbolic asset lookup
- eviction policy

It should not duplicate path resolution or file allocation.

---

## 15. Optimize implementation work below the compatibility boundary first

The FAT performance work provides a useful pattern.

First, 512-byte deblocking converted four 128-byte CP/M reads into one expensive
filesystem operation and produced a substantial improvement.

Then an opportunistic cached FS2 read handle changed repeated lifecycle work
from approximately:

```text
OPEN
READ
CLOSE
OPEN
READ
CLOSE
...
```

to:

```text
OPEN
READ
READ
READ
...
```

This brought FAT-backed CP/M reads to practical parity with the optimized
native CP/M volume.

The lesson is broader than FAT:

> Remove repeated implementation work below the compatibility boundary before
> changing the compatibility boundary itself.

Only after measuring remaining overhead should more invasive changes, such as
a cheaper facade crossing, be considered.

---

## 16. Correctness must not depend on caches

Deblocking slots, cached handles, and similar accelerators are optimizations.

If a cache lease cannot be obtained, the operation must still work through a
slower path.

If a cached read handle becomes stale or disappears, safe read operations may
reconstruct state and reopen.

A cache failure should reduce performance, not correctness.

---

## 17. Writes have a different recovery model from reads

Reads can generally be retried after reconstructing state.

Writes cannot always be retried safely.

A failed write transaction may be:

```text
definitely not committed
definitely committed
completion unknown
```

The third state must not be silently converted into "retry."

Writable FS2/native/BDOS work must preserve this distinction through the API
and invalidate any state whose commit status is no longer known.

This rule should be expanded as writable FAT milestones mature.

---

## 18. Similar metadata bits are not automatically equivalent

FAT HIDDEN/SYSTEM/ARCHIVE were initially projected into CP/M attribute bits.

That proved incorrect.

The semantics do not line up cleanly and real CP/M software noticed.

Current policy:

- do not project FAT HIDDEN/SYSTEM/ARCHIVE into synthetic CP/M attributes;
- keep FAT metadata internal to the FAT filesystem;
- treat ZSDOS software write protection as a separate OS-level concept.

General rule:

> Similar-looking metadata fields are not equivalent unless their behavior is
> equivalent.

---

## 19. Characterization utilities are executable specifications

Keep tools such as `BDOSCHAR.COM`, transport stress programs, filesystem
diagnostics, and application-level regression tests in the tree.

They are not disposable bring-up artifacts.

Future changes to:

- ZSDOS integration
- banking
- the facade
- BIOS behavior
- filesystem personalities
- caching
- transport
- interrupt handling

can silently violate old assumptions.

The tools provide executable documentation of those contracts.

Different applications also make useful compatibility probes:

| Probe | What it exposed |
|---|---|
| DIR | synthetic SEARCH/extent behavior |
| TYPE | ordinary sequential access |
| CRC | raw SEARCH semantics and `FCB[0]='?'` |
| VGMPLAYER | large streaming, explicit-drive FCBs, interrupt timing |
| ZCD | per-drive hierarchical current-directory state |
| conventional-drive regressions | accidental damage outside FAT personality |

---

## 20. Current implementation landmarks

These names describe the current tree and are useful starting points when
altering the OS. They are implementation landmarks, not permanent ABI.

```text
Code/HOST/CPM2.2/src/cbios_facade.asm
    common/application crossing
    fac_bdos
    Zephyr extension routing

Code/HOST/CPM2.2/src/cbios_fat_layout.asm
    bank-7 FAT personality
    fat_bdos_dispatch
    fat_bdos_post
    fat_bdos_or_zsdos
    fat_native_entry

ZSDOS_ORG   = 2000h
ZSDOS_ENTRY = 2006h
BIOS7_BASE  = 3000h

BDOS function 218
    versioned native filesystem descriptor
    ZOPEN/ZCLOSE/ZREAD/ZSEEK/...

Code/MCU/IOController/src/fs2.c
    IOC native filesystem service

FS2
    additive to the existing /SHARED service

Code/HOST/CPM2.2/src/cbios_irq.asm
    BIOS-owned IM2 infrastructure
```

Before modifying code, re-check the current generated maps and source. Do not
assume that addresses or exact symbol layouts recorded here remain fixed.

---

## 21. Practical alteration workflow

When adding or changing OS behavior:

1. **Identify the authority.**  
   Decide which existing component owns the state or semantic contract.

2. **Choose the lowest safe extension boundary.**  
   Prefer BIOS/facade/dispatcher/native service boundaries over ZSDOS internals.

3. **Classify memory placement.**  
   Default to bank 7. Justify any new common-memory object.

4. **Characterize observable legacy behavior.**  
   Especially for BDOS, FCB, SEARCH, drive-selection, and USER semantics.

5. **Keep implementation state reconstructible.**  
   Cached handles and caches must not become hidden ABI.

6. **Preserve conventional-drive regressions.**  
   New personalities must not change A:/B:/C: behavior accidentally.

7. **Separate correctness from optimization.**  
   Make the simple path correct first, then add deblocking/caching/handle reuse.

8. **Measure before altering transport or facade architecture.**

9. **Document any reason to patch ZSDOS itself.**  
   If a change cannot be achieved at the existing boundaries, record:
   - what cannot be achieved;
   - why;
   - the minimum ZSDOS change required;
   - compatibility consequences.

10. **Add the resulting lesson to this guide or the lessons-learned document.**

---

## 22. Guiding principle

The strongest lesson from the FAT-backed drive work is:

> **Keep ZSDOS authoritative for CP/M semantics, and insert Zephyr-specific
> implementations underneath or beside those semantics wherever possible.**

That principle explains the successful use of:

- synthetic BIOS drives
- bank-7 dispatch
- facade staging
- native function 218
- disposable FS2 handles
- separate native and CP/M filesystem personalities
- characterization rather than invasive ZSDOS patching

The goal of future alterations should be to preserve that separation unless a
measured, documented requirement proves it insufficient.

---

## 23. Planned future additions

This first version should be expanded as other development sessions contribute
their own findings.

Useful additions include:

- detailed write-completion and unknown-commit rules
- MAKE/CLOSE/write-random semantics
- warm boot and reset behavior
- exact USER and write-protect mirroring rules
- driver-slot / core / state ownership rules
- how to add a new storage personality
- how to add a new BDOS-native extension
- interrupt-registration rules
- memory-map change procedure
- regression matrices for BIOS, BDOS, and native APIs
