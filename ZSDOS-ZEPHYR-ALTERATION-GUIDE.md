# Zephyr / ZSDOS Alteration Guide

> **Audience:** Developers who want to modify the Zephyr-80 operating system,
> add storage personalities, extend BDOS/native services, alter BIOS behavior,
> or change the IOC protocol without accidentally breaking CP/M/ZSDOS
> compatibility.
>
> **Source of truth:** The current repository, generated memory map, and
> hardware behavior are authoritative for implementation details. This guide
> records the architectural contracts and procedures that should survive code
> movement and refactoring.
>
> For the history behind these rules, including the bugs and experiments that
> exposed them, see
> [FAT-BRINGUP-LESSONS-LEARNED.md](FAT-BRINGUP-LESSONS-LEARNED.md).

---

# Part I — The Architectural Constitution

These are invariants. A contribution may extend them deliberately, but should
not violate them accidentally.

## 1. Extend ZSDOS around its interfaces

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

If an actual ZSDOS source modification becomes necessary, document before
making it:

- what cannot be achieved at the facade, dispatcher, or BIOS boundary;
- why it cannot be achieved there;
- the minimum ZSDOS change required;
- the compatibility consequences.

---

## 2. State has one authority

Do not create a second authoritative copy of CP/M state.

| State | Authority | Zephyr may do |
|---|---|---|
| Current drive | ZSDOS | mirror/cache it |
| USER | ZSDOS function 32 | mirror it |
| Software write protect | ZSDOS | mirror it for intercepted mutations |
| DMA semantics | CP/M/ZSDOS facade contract | stage/copy as required |
| DPH/DPB/ALV | BIOS/ZSDOS-visible model | synthesize where a backend requires |
| FAT current directory | Zephyr FAT backend | own it |
| IOC/FS2 handles | Zephyr implementation | cache opportunistically |
| Media/context generation | FS2/IOC | mirror and invalidate local state |
| Application bank identity | Zephyr memory model | preserve across crossings/interrupts |

A mirror must be disposable and reconstructible.

If losing a value would break correctness, it should not exist only as a
mirror.

### Current ZSDOS write-protect wrinkle

The present ZSDOS build is configured with the hard read-only behavior enabled
in its flags. Once a drive is software write-protected, the normal reset-disk
paths may deliberately leave that protection asserted until the relevant ZSDOS
flag is changed or the system is cold-booted.

Therefore:

- query ZSDOS directly before blaming a stale FAT-side mirror;
- diagnostics that set software write protection must restore the prior ZSDOS
  state deliberately;
- FAT/native code must never reinterpret software write protection as a FAT
  file attribute.

---

## 3. Bank 7 is implementation space; common memory is ABI space

> **Bank 7 is the normal implementation space for the OS. Common bank-0 memory
> exists for crossing and ABI requirements.**

New OS logic, tables, and persistent implementation state belong in bank 7 by
default.

Common memory is justified only for objects that genuinely must remain visible
while application mapping is active, such as:

- CALL 5 / BDOS facade entry;
- bank-transition helpers;
- interrupt-entry infrastructure;
- caller-visible returned objects;
- staging buffers;
- cross-mode stack/state.

Free common memory is not by itself a reason to place implementation code
there.

The generated memory map and allocator ownership are authoritative. Historical
free ranges are not.

Reclaimable 512-byte arenas remain allocator-owned and must not silently become
permanent module storage.

### The facade is an ABI boundary, not a trampoline

Before adding a crossing, answer:

```text
What must remain visible in the caller mapping?
What can remain entirely in bank 7?
Does the caller expect a pointer back?
Can that returned pointer legally refer to bank-7 storage?
Can source and destination aliases occur on real hardware?
```

Normally, application-visible pointers may not refer directly to private
bank-7 objects.

Reuse the existing staging/crossing machinery. Do not invent a new crossing
framework for each subsystem.

### Aliasing is part of the machine model

The test harness must model real address aliasing, not merely function
interfaces.

A concrete current example is:

```text
FAC_DMA_BUF = FAC_BULK_BUF
```

When bank 7 is selected, an application DMA buffer in the TPA disappears and
the facade stages it into common memory. Code that subsequently treats the DMA
staging area and the bulk buffer as independent buffers is wrong on hardware
even if a unit test with two scratch addresses passes.

Any change that introduces a second use of an existing common buffer must be
reviewed for aliasing.

---

## 4. Preserve personalities instead of collapsing them

Zephyr deliberately presents more than one view of the same storage.

```text
                         FatFs / media
                              |
                     +--------+--------+
                     |                 |
              CP/M compatibility   native Zephyr
                     |                 |
                 FCB / USER         paths / bytes
                 128-byte records   larger transfers
                 synthetic extents directories
```

The CP/M personality exists for unmodified software.

The native personality exists so Zephyr software does not inherit CP/M's
128-byte record and FCB limitations.

A native call may still enter through CALL 5. That does **not** make it a CP/M
filesystem operation. Function 218 is a syscall gateway to native Zephyr
semantics.

Resource services belong above the native filesystem API:

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

The resource layer may add caching, prefetching, decompression, streaming,
symbolic asset lookup, and eviction. It should not become another filesystem.

---

## 5. Synthetic BIOS personalities participate in ZSDOS state

A backend does not need to be a real CP/M block filesystem to participate in
the CP/M disk model.

The FAT-backed personality uses synthetic BIOS behavior so ZSDOS can select and
log the drive normally:

```text
SELDSK  -> validate drive root and return synthetic DPH
READ    -> harmless synthetic empty-disk view
WRITE   -> failure when a real BIOS write is inappropriate
DPB     -> synthetic geometry
ALV     -> synthetic capacity view
```

Real FAT file access happens above this BIOS layer.

This gives two important properties:

1. ZSDOS remains authoritative for current-drive/login bookkeeping.
2. If a FAT-dependent operation accidentally falls through to ordinary ZSDOS
   disk processing, it sees an empty synthetic disk rather than the previously
   selected conventional drive.

### SELDSK tests drive availability, not the current directory

For a FAT personality, SELDSK should validate the configured drive root (for
example `/CPM/D`) and return the synthetic DPH.

It must **not** make drive availability depend on the currently selected USER
subdirectory or relative CWD. A renamed or missing subdirectory is a path
problem, not evidence that the logical drive disappeared.

---

## 6. CP/M-visible state remains reconstructible

### FCBs are authoritative

Applications may copy FCBs.

Therefore an FCB must remain sufficient to reconstruct a CP/M file operation.

Do not hide an IOC/FS2 token inside an FCB or make correctness depend on a
specific controller handle surviving.

IOC handles may be cached by identity, for example:

```text
drive
USER
current-directory generation
packed 8.3 filename
```

but the handle is opportunistic.

If it disappears, becomes stale, or is retired by a namespace mutation, reopen
from authoritative FCB/path state.

Writable operations must acquire appropriate writable state separately. Never
silently reuse a stale or read-only cached token for mutation.

### Explicit-drive operations may temporarily reselect drives

A ZSDOS operation on an explicit B: FCB while D: is current may internally
behave like:

```text
remember D
select B
perform operation
restore D
return
```

An error reported during BDOS READ on B: therefore does not prove the B: read
itself failed. The later restoration of D: may have failed.

When debugging this class of problem, trace actual SELDSK transitions.

### USER and hierarchy are separate layers

The accepted FAT compatibility projection is:

```text
USER 0: /CPM/D/<relative-CWD>/<name>
USER N: /CPM/D/@N/<relative-CWD>/<name>
```

The USER namespace precedes the saved relative CWD.

The current build supports USER 0 through 15. Do not assume 0 through 31 merely
because another CP/M-family system does.

A relative CWD selected under one USER must not silently become the relative CWD
of another USER.

Native path access is not required to apply the CP/M USER projection.

---

## 7. SEARCH is an observable ABI

Do not reduce SEARCH FIRST/NEXT to "find matching filenames."

Legacy software may observe:

- A = 0..3 selecting a 32-byte DMA slot;
- the selected entry at `DMA + A * 32`;
- USER;
- packed 8.3 name;
- EX/S1/S2/RC;
- attribute high bits where applicable;
- caller-FCB mutation/preservation behavior;
- continuation across SEARCH NEXT;
- end-of-search return behavior.

The FAT personality is allowed to choose a simpler valid representation. The
hardware-accepted implementation currently uses:

```text
DMA[0..127] = E5h
DMA[0..31]  = one synthetic directory entry
A           = 00h
```

and on exhaustion:

```text
A           = FFh
DMA         = unspecified
```

It emits one synthetic entry per FAT file. For a large file the entry carries
the terminal EX/S2/RC representation; function 35 remains the authority for the
complete rounded-up record count. Allocation bytes are synthetic/zero because
there is no physical CP/M allocation layout to expose.

This is intentional restraint: reproduce observable compatibility, not a
fictional CP/M allocator.

### `FCB[0] = '?'` is a real SEARCH mode

For SEARCH, `FCB[0] = 3Fh ('?')` is not an invalid drive number.

On this ZSDOS build it means a raw current-drive search across supported USER
areas.

The FAT dispatcher must preserve that mode across SEARCH NEXT, skip missing
`@N` directories, and return the source USER in each synthetic entry.

This behavior is required by real software such as CRC.

### FAT metadata is not CP/M metadata

Do not project FAT HIDDEN/SYSTEM/ARCHIVE bits into synthetic CP/M directory
attributes.

The semantic models are different and real CP/M software noticed the mismatch.

ZSDOS software write protection remains a separate authority.

---

## 8. Interrupt, transport, and mutation safety are OS contracts

### BIOS/core owns interrupt architecture

Programs register callbacks through Zephyr mechanisms rather than taking
ownership of the I register or rewriting the IM2 vector table.

Drivers may own device-specific handling policy. They do not automatically own
the global interrupt architecture.

### The receive critical section begins at the first RX-ready

The IOC is clock master. Once the first reply byte arrives, the rest of the
reply continues whether the Z80 is ready or not.

The required shape is:

```text
wait for first RX-ready     interrupts enabled
first RX-ready observed
DI
marker recognition
reply body
bulk phase
EI
```

Masking only after marker recognition is too late: a timer interrupt can allow
the SIO FIFO to overflow before the supposedly protected region begins.

A transport failure can surface as a high-level filesystem or ZSDOS error. The
layer reporting the failure is not necessarily the layer that caused it.

### Reads and writes have different recovery rules

Reads are generally safe to reopen/reconstruct and retry once.

Writes may be:

```text
definitely not committed
definitely committed
completion unknown
```

Unknown completion must not be converted into "retry."

For bulk writes:

```text
WRITE reply / READY
    -> IOC has armed receive

IOCBULKW completes
    -> bytes crossed the link

XFER_STATUS / DONE with matching transfer ID
    -> final commit status is known
```

READY and a successful bulk transfer are not proof of commit.

If DONE is lost, malformed, or refers to another transfer, return an
unknown-write outcome and invalidate the writable context.

Writable stale handles do not use the read-side reopen-and-retry policy.

---

# Part II — Subsystem Implementation Protocols

This part is organized by contributor task: "I want to change X; what is the
safe procedure?"

## 9. General alteration workflow

Before changing OS behavior:

1. **Identify the authority.**  
   Decide which component owns the state or semantic contract.

2. **Choose the lowest safe extension boundary.**  
   Prefer BIOS, facade, dispatcher, or native-service boundaries over ZSDOS
   internals.

3. **Classify memory placement.**  
   Default to bank 7. Justify any new common-memory object.

4. **Characterize observable legacy behavior.**  
   Especially for BDOS, FCB, SEARCH, drive selection, USER, and error behavior.

5. **Keep implementation state reconstructible.**  
   Cached handles and caches must not become hidden ABI.

6. **Make correctness independent of optimization.**

7. **Add focused tests before broad application tests.**

8. **Run conventional-drive regressions as well as the new personality.**

9. **Measure before altering transport or facade architecture.**

10. **Update this guide when the change establishes a new durable rule.**

---

## 10. How to add or intercept a BDOS call

Use the existing common facade and bank-7 dispatcher.

### Step 1 — decide whether interception is necessary

Intercept when the operation's semantics differ for a Zephyr personality.

Do not intercept ZSDOS bookkeeping merely because doing so is convenient.

Examples:

- FAT OPEN/READ/SEARCH: alternate semantics, intercept.
- current-drive selection: ZSDOS already owns it, preserve ZSDOS authority.
- USER: preserve function 32 authority and mirror only as needed.

### Step 2 — define staging requirements

Determine which arguments/pointers live in the application mapping and which
must be staged before entering bank 7.

Do not return bank-7 pointers to applications.

### Step 3 — preserve ZSDOS state transitions

If the operation needs normal ZSDOS pre/post behavior, call through or
post-process rather than emulating the state transition independently.

### Step 4 — preserve the semantic return value

Common crossing code is mechanical. If it uses A/flags/registers to decide
whether to copy data, save and restore the semantic result first.

A real bug in the native gate successfully completed CHDIR, then replaced the
returned status with the operation number while deciding whether a payload
copy was needed.

Test both:

- the returned register/status;
- any status copied into the request/response descriptor.

### Step 5 — verify complete crossing behavior

Do not test only the bank-7 worker. At least one test must exercise the
application -> common facade -> bank 7 -> common facade -> application path.

---

## 11. How to add a native Zephyr operation

Function 218 is the current native-filesystem precedent.

### Required properties

- versioned request descriptor;
- byte-oriented semantics;
- caller pointers staged safely across banking;
- no IOC token exposed to applications;
- operation-specific state in bank 7;
- exact result preserved across the common gate.

### Pointer/count validation

Validate lengths before any `LDIR`.

On Z80:

```text
BC = 0
LDIR
```

copies 65536 bytes, not zero bytes.

Reject or skip zero-length transfers before `LDIR`, and reject lengths above
the supported staging size before changing memory mode.

Apply the same rule to lengths computed internally. A computed zero count is
just as dangerous as a caller-supplied zero.

### Flags are not durable state

Any `CP`, `OR`, `AND`, arithmetic operation, etc. changes condition flags.

Do not:

```text
call worker
cp SOME_SPECIAL_STATUS
...
jp nz,return_worker_result
```

and assume NZ still describes the worker's result.

Store/retest the semantic status explicitly.

### Native operations need native tests

Adding a native operation means adding a direct bank-7 harness case in the same
change.

FCB-path tests do not substitute for native API coverage even when both
personalities reach the same file.

---

## 12. How to extend FS2 or the IOC protocol

Protocol growth is additive.

### Checklist

When adding a command:

1. define the command/frame fields;
2. add dispatcher handling;
3. add external-sync/admission handling;
4. add capability advertisement;
5. move the IOC firmware level where required;
6. update host-side expected levels/capabilities;
7. add an end-to-end diagnostic;
8. test against firmware that lacks the capability.

Do not rely only on a firmware version when a capability bit can answer the
actual question.

A controller that silently does not admit a command can look like a hung
transport. Capability probing makes "unsupported" distinguishable from
"transport dead."

### Reuse the proven bulk lane

For new 512-byte-class transfers, prefer the existing bulk mechanism unless a
measured requirement proves it insufficient.

Writable FS2 reused the established receive-buffer + commit callback + DONE
lifecycle rather than inventing another transport.

### Generation semantics

Generation covers media/context invalidation that can occur while the Z80 keeps
running.

An MCU reset resets the whole machine. Do not invent a recoverable MCU-session
nonce for host-side state that cannot survive such a reset in reality.

---

## 13. How to add or change a storage personality

A storage personality must separate three concerns:

```text
drive availability/login
filesystem/path resolution
actual data operations
```

### Step 1 — participate in SELDSK

Provide the synthetic DPH/DPB/ALV behavior required for ZSDOS to maintain
normal current-drive state.

### Step 2 — keep SELDSK narrow

SELDSK validates the logical drive/root, not a USER-specific CWD or a particular
file path.

### Step 3 — define the compatibility projection

Specify:

- drive root;
- USER mapping;
- relative-CWD mapping;
- FCB naming/filtering rules;
- SEARCH representation;
- synthetic free-space/geometry behavior.

### Step 4 — intercept only personality-specific file semantics

Preserve ZSDOS ownership of drive/USER/write-protect bookkeeping.

### Step 5 — keep destructive tools backend-oriented

A provisioning/destructive utility that addresses a physical backend directly
should name the backend, not a drive letter that can be reassigned in one
constant.

"Erase the SD backend" is stable. "Erase drive B:" may become dangerously
false after a drive-map change.

---

## 14. How to implement writable behavior

Writable support should be brought up in semantic layers.

### Stage A — native writable filesystem

First validate:

```text
FS2 create/open-for-update/write/truncate/sync/close
    -> native function 218 API
    -> hardware validation
```

This isolates dangerous transport/commit behavior from CP/M FCB mutation rules.

### Stage B — CP/M writable personality

Only after native mutation is proven should the FCB personality add:

- MAKE;
- sequential write;
- random write;
- random write with zero fill;
- DELETE;
- RENAME;
- close/flush semantics;
- lazy USER-directory creation where applicable.

### Write protection

Check both:

- physical/filesystem read-only state;
- ZSDOS software write-protect state.

A previously opened writable context must not bypass newly asserted protection.

### Mutation invalidation

Namespace mutations and policy changes must retire incompatible cached state.

At minimum review invalidation for:

- CREATE / create-always;
- DELETE;
- RENAME;
- CHDIR/CWD generation change;
- USER change;
- media generation change;
- software write-protect assertion/reset;
- explicit FS2 context reset.

### Unknown completion

Never blindly replay a mutation whose commit outcome is unknown.

The application may need to reopen/re-stat and decide what recovery is safe.

---

## 15. How to manage caches, leases, and scarce handles

Correctness must not depend on caches.

If a cache lease cannot be obtained, use a slower path.

### Reclaimable memory

A reclaimable 512-byte line belongs to the allocator until leased. Do not turn
it into permanent FAT/backend state.

State read before initialization must be initialized explicitly. In assembler,
`.ds` reserves bytes; it does not guarantee they contain zero.

A resource pool whose uninitialized owner table happens to look "fully owned"
can silently disable an optimization forever while the correct fallback path
hides the defect.

### Cached FS2 read handle

A cached FCB-side read handle is a lease against a pool used by other clients.

Rules:

- at most the intended number of opportunistic slots may remain held;
- native opens/mutations may force the opportunistic read handle to be closed;
- namespace mutation may retire controller-side handles underneath the cache;
- `NO_HANDLE`/`STALE` on a read may reopen once and retry once;
- a second failure is a real error;
- clear the local cache tag before/best-effort close so a failed close cannot
  leave false ownership;
- writable operations never reuse the cached read token.

If the controller exposes only a tiny handle pool, treat opportunistic
performance handles as lower priority than explicit native/application
handles.

### Performance precedent

The FAT read path improved most by reducing setup round trips, not by inventing
larger transfers.

For a measured 64 KiB sequential read, the compatibility path fell from
hundreds of setup/transfer transactions to roughly one mailbox plus one bulk
operation per 512-byte line after deblocking and cached-handle reuse.

The practical lesson is:

> Count transactions before widening transfers or redesigning the transport.

---

## 16. How to manage USER, CWD, and drive mappings

For the current FAT personality:

```text
USER 0: /CPM/D/<relative-CWD>/<name>
USER N: /CPM/D/@N/<relative-CWD>/<name>
```

### Rules

- USER is owned by ZSDOS.
- FAT maintains only the mirror/state required to avoid re-querying on every
  file operation.
- USER change invalidates SEARCH state and any identity whose namespace changed.
- A relative CWD is associated with the USER that selected it.
- SELDSK verifies the drive root, not the USER/CWD path.
- native filesystem operations decide explicitly whether they apply the CP/M
  USER projection.

### Fixed-width component formatting

For packed fields, test the first value that changes width and the maximum
accepted value.

For USER directories that means at least:

```text
@9
@10
@15
```

and the byte immediately after the packed component.

A single off-by-one in an 11-byte component can corrupt unrelated persistent
state and make later path replay fail far from the formatter.

---

## 17. How to write CP/M/ZCPR utilities

Utilities that sit above the new native services still run under CP/M/ZCPR and
must obey its transient conventions.

### Preserve the entry stack

ZCPR2 invokes a transient with `CALL 0100h`.

If a utility switches to a private stack:

```text
save entry SP
use private stack
restore entry SP
RET
```

Jumping to page zero merely to escape a broken return forces an unnecessary
warm boot and hides the actual problem.

### Do not trust the default FCB for every command-line distinction

The CCP's filename parser consumes dots.

For example, `CD ..` and a bare `CD` can become indistinguishable in FCB1.

Use the untouched command tail when syntax such as `..`, path components, or
DU-style prefixes matters.

### DU parsing

ZCPR may place drive/name information in the default FCB while USER information
from a DU prefix remains elsewhere/private.

A utility that accepts `D8:NAME` may need to parse USER from the original
tail, apply function 32 temporarily, perform the operation, then restore the
caller's USER.

### Prevent self-copy destruction

A copy utility must reject source == destination before MAKE/truncate.

Include both:

- identical explicit source/destination;
- an implicit destination that resolves to the same drive/name.

For a move, delete the source only after destination close/commit succeeds.

---

## 18. How to optimize without breaking compatibility

Optimize from the bottom of the cost stack upward.

### Preferred sequence

1. establish a correct simple implementation;
2. measure controller transactions and host-side work;
3. add deblocking/read-line caching;
4. eliminate repeated path/open/close work with disposable cached handles;
5. measure again;
6. only then consider transport or facade surgery.

The FAT bring-up demonstrated this order:

- 512-byte deblocking produced a substantial improvement;
- cached FS2 handle reuse removed most remaining setup work;
- FAT-backed FCB reads reached practical parity with the optimized conventional
  CP/M volume;
- native byte-oriented reads can still approach the direct `/SHARED` path
  because they avoid four 128-byte BDOS crossings per 512 bytes.

The remaining CP/M/FAT gap is therefore not automatically evidence that the
transport is slow.

Do not optimize away compatibility semantics merely to make a benchmark look
better.

---

# Part III — The Hacker's Test Harness and Verification Suite

A contributor should be able to prove both "my feature works" and "I did not
quietly redefine CP/M."

## 19. Characterize before emulating

Documentation is not the complete BDOS compatibility contract.

Use the existing characterization tools and the real ZSDOS build.

### BDOSCHAR.COM

`BDOSCHAR.COM` and its generated fixtures exist to capture observable behavior
such as:

- return A;
- DMA contents;
- selected SEARCH slot;
- caller FCB before/after;
- USER;
- EX/S1/S2/RC;
- attributes;
- extent/file-size boundaries.

The repository also contains captured characterization material under the CP/M
documentation tree.

When a legacy behavior is unclear, characterize it before adding an emulation
rule.

---

## 20. Test both personalities

CP/M FCB access and the native byte API are two views of the same files.

Neither one's tests substitute for the other's.

A complete change should have coverage at the level it modifies:

```text
bank-7 native worker
common crossing/native gate
FCB/BDOS personality
IOC/FS2 protocol
real application path where relevant
```

A milestone accepted only through DIR/TYPE/CRC/VGMPlayer can still contain bugs
in native OPEN/READ/WRITE/SEEK if no test invokes those operations.

Adding a native operation therefore requires a direct native harness case.

---

## 21. Model the real memory path

A harness must model the machine, not only the function signature.

At minimum review:

- application memory hidden by bank 7;
- common staging aliases;
- DMA/bulk-buffer identity;
- bank-7 persistent state;
- exact caller-visible pointer ranges.

If the real path commonly uses aliased buffers, add an aliased-buffer test.
Do not treat it as an exotic edge case.

---

## 22. Mutation-test the tests

A passing assertion is not evidence that the test can detect the defect.

For every important new guarantee:

1. deliberately remove/break the behavior;
2. confirm the test fails;
3. restore the behavior;
4. confirm the test passes.

Mocks must not provide the expected behavior by default.

For example, a zero-fill test is worthless if the mock file extension already
fills new bytes with zero. Use a non-zero/default poison value so the
implementation itself must establish the guarantee.

---

## 23. Boundary-value checklist

For byte/record/file operations, include boundaries around the actual
abstractions:

```text
0
1
127
128
129
511
512
513
```

Also include:

- zero-length file;
- short final read;
- exact EOF and beyond EOF;
- sequential extent rollover;
- random-record boundaries;
- random write with zero fill;
- maximum supported native transfer;
- computed `LDIR` count of zero;
- packed USER/path width transitions 9 -> 10 and maximum USER 15;
- byte immediately after fixed-width structures;
- handle-pool exhaustion;
- stale generation;
- no-space/error status injection.

For block moves, specifically audit every `LDIR` whose count is computed at
runtime.

---

## 24. Use the conventional drive as an oracle

A standard-BDOS compatibility test should run on both:

- the FAT-backed personality;
- a conventional CP/M volume.

This turns "does it work?" into "does it differ?"

That comparison has already caught faulty tests:

- file size checked before the conventional CLOSE that commits metadata;
- zero-fill expectations stronger than CP/M actually promises;
- write-protect cases that cannot return normally because conventional ZSDOS
  takes the console and reports a BDOS error.

When both personalities fail identically, inspect the test expectation before
blaming the new backend.

When only one differs, the difference is much more localizable.

Document intentional compatibility differences rather than letting them remain
accidental.

---

## 25. Cross-drive and USER regression matrix

Always test both directions of explicit drive crossing.

For example:

```text
conventional drive current
    -> explicit FAT FCB/path

FAT drive current
    -> explicit conventional FCB
```

These are not redundant.

Also test:

- drive 0/current-drive FCBs;
- explicit-drive FCBs;
- USER 0 and non-zero USER;
- transition across USER 9/10;
- CWD change and return;
- missing USER directory;
- all-USER SEARCH;
- conventional drive behavior after FAT activity.

The accepted read-only hardware suite included:

- DIR/TYPE/CRC on a small FAT file;
- CRC and uninterrupted VGMPlayer on a large FAT file;
- VGMPlayer in both cross-drive directions;
- ZCD + DIR/CRC in a FAT subdirectory;
- USER isolation and restoration;
- DIR/TYPE/CRC again on a conventional volume.

Keep an equivalent asymmetric matrix as the system evolves.

---

## 26. Application probes complement unit tests

Different programs expose different assumptions.

| Probe | Useful coverage |
|---|---|
| DIR | synthetic SEARCH representation |
| TYPE | ordinary sequential FCB reads |
| CRC | raw all-USER SEARCH and catalogue semantics |
| VGMPlayer | large streaming, explicit-drive FCBs, interrupt timing |
| ZCD/CD | native CHDIR, USER/CWD projection, transient return |
| native filesystem diagnostic | OPEN/READ/WRITE/SEEK/SYNC/TRUNCATE |
| conventional-drive suite | unintended compatibility regressions |

Do not assume a shell command tests exactly what its text suggests.

For example, ZCPR2 TYPE may temporarily log the explicit drive and then use
FCB drive zero. If the distinction matters, inspect or instrument the program's
actual BDOS calls.

---

## 27. Failure triage

When a command fails, separate the layers before changing code.

### A reported failure may follow a successful state change

A state-changing operation can succeed while its status is corrupted during the
return crossing.

Check independently:

- did the operation execute?
- did persistent state change?
- did completion status cross the boundary intact?
- did the next consumer interpret the new state correctly?

This is especially important for mutations, where a false failure can provoke
an unsafe retry.

### High-level errors can be lower-layer failures

A ZSDOS "No Drive" may be caused by:

- an actual SELDSK failure;
- restore-to-current-drive failure after an explicit-drive operation;
- transport reply corruption;
- an availability probe accidentally coupled to CWD/USER.

Trace the actual lower-level sequence before rewriting filesystem semantics.

### Verify firmware/capabilities early

Before debugging a new IOC feature:

- query firmware level;
- query FS2 capability bits;
- distinguish unsupported command from dead transport.

---

## 28. Minimum pre-commit regression checklist

For a change touching BDOS/native storage integration, the minimum useful
pre-commit suite is:

### Build/layout

- host build succeeds;
- IOC normal/diagnostic builds succeed where applicable;
- generated memory map has no overlap;
- common-memory growth is intentional and justified;
- allocator-owned/reclaimable ranges remain allocator-owned.

### Host harness

- bank-7 tests pass;
- native API tests pass for any affected operation;
- aliasing case passes where relevant;
- boundary cases pass;
- mutation-test of any new assertion has been demonstrated at least once.

### Protocol

- capability/firmware level is updated for protocol additions;
- stale/no-handle/error mappings are covered;
- write completion distinguishes known failure from unknown commit.

### Hardware/personality

- new FAT/native path passes;
- conventional CP/M drive regression passes;
- cross-drive cases pass in both directions;
- USER/CWD behavior passes where affected;
- one application-level probe appropriate to the change passes.

### Documentation

- durable new invariant goes into this guide;
- debugging history/rationale goes into the lessons-learned document;
- current implementation notes go into the subsystem-specific docs.

---

# Appendices

## Appendix A — Current implementation landmarks

These names describe the current tree and are starting points, not permanent
ABI.

```text
Code/HOST/CPM2.2/src/cbios_facade.asm
    common/application crossing
    fac_bdos
    native/Zephyr extension routing

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

Code/MCU/IOController/src/fs2.c
    IOC native filesystem service

FS2
    additive to the existing /SHARED service

Code/HOST/CPM2.2/src/cbios_irq.asm
    BIOS-owned IM2 infrastructure

Code/HOST/Utilities/src/bdoschar.asm
    BDOS characterization utility

Code/HOST/CPM2.2/docs/characterization/
    captured compatibility observations
```

Re-check the current source and generated maps before relying on an address,
buffer size, or exact region boundary.

---

## Appendix B — Ownership and interception quick reference

| Concern | Owner / preferred layer |
|---|---|
| Current CP/M drive | ZSDOS |
| USER | ZSDOS function 32 |
| Software write protect | ZSDOS |
| Synthetic DPH/DPB/ALV | BIOS/personality |
| FAT CWD | bank-7 FAT/native layer |
| FCB file position | FCB |
| Native byte position | native Zephyr handle state |
| IOC token | private implementation cache |
| SEARCH continuation | personality/search implementation |
| Media generation | IOC/FS2 |
| CALL 5 crossing | common facade |
| CP/M-specific alternate semantics | bank-7 BDOS dispatcher |
| Native filesystem semantics | function 218 + bank-7 native layer |
| Filesystem implementation | FS2/FatFs on IOC |
| Resource abstraction | above native filesystem API |
| Interrupt vector architecture | BIOS/core |

---

## Appendix C — Cache/handle invalidation matrix

Review this table whenever a new cached object is added.

| Event | FCB read-line cache | Cached read FS2 token | Native writable handle | SEARCH state |
|---|---|---|---|---|
| CWD change | invalidate | invalidate/close | operation-specific | invalidate |
| USER change | invalidate | invalidate/close | operation-specific | invalidate |
| DELETE | matching/all relevant | controller may retire; clear | invalidate affected | invalidate |
| RENAME | matching/all relevant | controller may retire; clear | invalidate affected | invalidate |
| CREATE/MAKE | namespace-sensitive | preferably release | new context | invalidate |
| media generation change | invalidate | stale | fail stale | invalidate |
| FS2 reset | invalidate | no handle/stale | fail | invalidate |
| software WP assertion | data may remain readable | read token may remain | close/invalidate | normally unchanged |
| native open needing a slot | unchanged | opportunistic token yields slot | acquire | unchanged |

This table describes policy, not an excuse to skip status checks. Controller-side
namespace operations may retire handles independently, so reads must still
handle `NO_HANDLE`/`STALE`.

---

## Appendix D — Useful characterization/regression assets

- `BDOSCHAR.COM` and generated fixture suite
- FAT read-only milestone acceptance document
- FAT bring-up lessons learned
- native writable diagnostics such as `ZFW.COM` / focused probes where present
- transport/bulk diagnostics
- DIR / TYPE / CRC / VGMPlayer / ZCD application probes
- conventional CP/M volume as a compatibility control

Keep these tools after bring-up. They are executable specifications.

---

## Appendix E — Z80/assembler sharp edges worth re-checking

### `LDIR` with BC = 0

Copies 65536 bytes. Guard zero explicitly.

### Condition flags are ephemeral

A comparison performed after a worker call replaces the worker's flags. Store or
retest semantic status explicitly.

### `.ds` reserves; it does not initialize

State read before explicit initialization must be emitted/initialized
accordingly.

### Reader/writer asymmetry is suspicious

If paired routines manipulate the same structure and one guards a boundary while
the other does not, inspect the asymmetric one first.

### Packed fields need neighbor checks

At width transitions, test the first larger value, the maximum value, and the
byte immediately after the field.

---

## Appendix F — History versus prescription

Use this guide for **what a contributor should do now**.

Use
[FAT-BRINGUP-LESSONS-LEARNED.md](FAT-BRINGUP-LESSONS-LEARNED.md)
for **why these rules exist and which failures exposed them**.

When the two documents appear to disagree:

1. current code/hardware behavior wins for implementation facts;
2. this guide should be updated to the final accepted rule;
3. the lessons document should keep the historical path, including superseded
   hypotheses, when that history remains useful.
