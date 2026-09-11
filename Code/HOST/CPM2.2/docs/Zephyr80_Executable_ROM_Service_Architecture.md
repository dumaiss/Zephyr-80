# Zephyr-80 Executable ROM Service Architecture

## Purpose

This note captures a proposed Zephyr-80 memory architecture for increasing the
CP/M transient program area (TPA) without moving ZCPR2 or ZSDOS into ROM.

The central idea is:

> Keep ZCPR2, ZSDOS, mutable operating-system state, stacks, interrupt-critical
> code, and a very small BIOS service gate in high RAM. Move bulky Zephyr BIOS
> and device-specific implementation code into executable ROM, temporarily
> exposing that ROM in the low address space only while a firmware service is
> running.

This is intended to reclaim RAM permanently, for every program the platform
will ever run.

SNTracker in Turbo Modula-2 is the **stress test**, not the justification. It is
the largest, most timing-sensitive workload currently available, and it is being
pushed deliberately so that the operating system is optimized now -- rather than
discovering, partway into writing a game, that the OS itself has to be reopened.

The architecture should therefore be judged on permanent platform properties:
contiguous TPA available to any program, banked storage for assets, and how
little the BIOS interferes with an application that owns the machine. A single
program compiling or running is evidence, not the goal.

The current CP/M build uses ZCPR2 as the command processor and ZSDOS as the
BDOS replacement. They are not candidates for this first-stage ROM migration.

---

## Current Zephyr-80 memory behavior

During normal CP/M execution the Zephyr runs in RAM-only mode:

```text
0000h-BFFFh   selected SRAM bank
C000h-FFFFh   SRAM bank 0, fixed/common
```

The hardware therefore provides a 16 KiB common window at `C000h-FFFFh`.

The current CP/M layout begins the resident operating-system area at `C400h`.
The range `C000h-C3FFh` is application-owned common RAM.

The important alternate memory mode for this proposal is the existing
shadow/copy mode:

```text
0000h-BFFFh   reads from selected ROM page
              writes still go to selected SRAM bank

C000h-FFFFh   reads/writes SRAM bank 0
```

This means code executing from high common RAM can temporarily expose ROM in
the lower 48 KiB while retaining access to:

- its stack;
- BIOS variables;
- mutable driver state;
- interrupt infrastructure located in high RAM;
- high-RAM buffers;
- the ROM-call trampoline itself.

After the ROM routine returns, the trampoline restores RAM-only mode and the
original low RAM becomes visible again.

---

## Proposed resident-memory model

The resident base moves to **`DC00h`**:

```text
0000h-DBFFh   application / TPA

DC00h-FFFFh   resident RAM  (9216 bytes)
```

Application-visible memory becomes:

```text
nominal     0100h-DBFFh = 54.75 KiB
effective   0100h-E405h = 56.76 KiB   (FBASE = E406h)
```

`C000h-DBFFh` remains physically common RAM because of the Zephyr hardware
decoder, but under this model it is simply application-owned memory.

`DC00h` is a decision, not a placeholder. It was chosen by measurement rather
than convention, from the built sizes of ZCPR2 and ZSDOS, the irreducible
RAM-resident BIOS, mutable disk and console state, buffers, resident interrupt
code and vectors, and stack reservation. The full derivation is in
[Measured resident budget](#measured-resident-budget).

`E000h` -- one kilobyte higher, and the boundary this document originally
proposed -- was rejected. It clears the intended B:/C: volume set by only 46
bytes and fails outright if the IOC bulk transmit loop cannot be ROM-resident.
`DC00h` holds the same set with 305 bytes of margin, once the bulk-write region
is split and the serial tee moves to ROM.

---

## What remains in RAM

ZCPR2 and ZSDOS remain ordinary resident RAM components.

The high resident region should contain only things that must remain accessible
while low RAM is hidden by ROM or that must directly access arbitrary caller
memory.

Likely RAM-resident components are:

```text
ZCPR2
ZSDOS

minimal BIOS jump table / facade
ROM service dispatcher and trampoline
bank-selection helpers

interrupt vectors
interrupt entry points and critical ISR code

mutable BIOS and driver state
disk geometry / allocation state that must be writable
high-RAM scratch buffers required by resident services

BIOS / firmware stack
```

Some BIOS routines may also have to remain resident because they operate on
addresses supplied by applications.

Examples include routines that need to inspect or modify arbitrary memory below
`C000h`, such as:

- disk DMA transfers;
- FCB-related data paths;
- `MOVE` / `XMOVE`;
- general IOC transfers involving caller-owned low-memory buffers.

These cannot simply execute while ROM is overlaid on `0000h-BFFFh`, because
that low RAM would not be readable during the ROM service.

---

## What moves to ROM

The best ROM candidates are bulky routines whose inputs can be passed in
registers or high-RAM structures and which do not need to read arbitrary low
application RAM while executing.

The first and most attractive candidate is the direct V9958 console.

The current direct console contains substantial code for:

- ANSI / VT100-light parsing;
- terminal state-machine handling;
- V9958 command generation;
- CP850 translation / atlas support;
- cursor handling;
- printable-run processing;
- device-specific initialization.

Most of that logic is effectively firmware and does not need to consume
resident RAM continuously.

A proposed split is:

```text
RAM-resident console state

    current parser state
    cursor coordinates / attributes
    printable-run buffer
    mutable mode flags
    small CONOUT facade
    ROM service gate


ROM-resident console implementation

    VT100 parser
    escape-sequence handlers
    V9958 rendering routines
    lookup / translation tables
    CP850 tables
    initialization routines
    uncommon terminal operations
```

Other good ROM candidates include:

- hardware initialization code;
- diagnostic strings and uncommon error paths;
- SD-card probe / recovery code that does not require caller RAM;
- rarely used device setup code;
- fixed lookup tables;
- character translation tables;
- firmware self-test code;
- other bulky Zephyr-specific services that can operate from registers and
  high-RAM state.

The objective is not merely to copy the current BIOS layout into ROM. The BIOS
should be intentionally divided into a very small always-resident core and a
much larger set of firmware services.

---

## ROM service call mechanism

The ROM call gate resides in high common RAM.

Conceptually:

```text
application / ZSDOS / BIOS
          |
          | call resident BIOS facade
          v
    high-RAM ROM gate
          |
          | save bank/mode state
          | expose selected ROM page
          v
0000h-BFFFh becomes ROM
          |
          | call fixed ROM service entry
          v
    execute firmware service
          |
          | RET to high-RAM gate
          v
    restore RAM-only mode
          |
          v
application RAM visible again
```

A simplified assembly sketch:

```asm
rom_service_gate:
        ; Preserve caller state as required.
        ; Preserve interrupt-enable state.
        di

        ; Save/select the current RAM bank and desired ROM page.
        ; Enter shadow/copy mode:
        ;
        ;   0000-BFFF -> ROM reads
        ;   C000-FFFF -> common RAM
        ;
        out     (00h),a

        call    ROM_SERVICE_ENTRY

        ; Restore RAM-only mode and original selected RAM bank.
        out     (00h),a

        ; Restore original interrupt-enable state.
        ret
```

The actual implementation should not blindly execute `EI` on exit. It should
preserve the caller's interrupt state.

The gate may eventually provide a small firmware ABI, for example:

```text
service number in A
arguments in BC/DE/HL
results in registers
mutable service state in DC00h-FFFFh
```

or use fixed entry stubs for frequently used services.

The exact ABI should be kept deliberately small.

---

## Why ZCPR2 and ZSDOS stay in RAM

The purpose of this proposal is not to ROM-ize CP/M.

ZSDOS frequently operates on pointers supplied by transient programs:

- FCBs;
- command strings;
- DMA buffers;
- application data.

If ZSDOS itself were executing with ROM overlaid on low RAM, many of those
objects would become unreadable.

ZCPR2 similarly interacts heavily with transient-program state and the normal
CP/M low-memory environment.

Keeping ZCPR2 and ZSDOS resident avoids turning ordinary CP/M semantics into a
bank-switching problem.

The optimization target is therefore the Zephyr-specific BIOS and driver
implementation, not the OS personality.

---

## Interrupt considerations

This proposal has one important interaction with application-owned interrupts.

While a ROM service is active:

```text
0000h-BFFFh = ROM
C000h-FFFFh = common RAM
```

Any ISR or IM2 vector table located below `C000h` is therefore temporarily
hidden.

This is the load-bearing part of the design, not a detail.

Any application that owns the machine -- a game, a tracker, anything with music
or raster timing -- keeps its own IM2 vector table and ISR inside the transient
program, below `C000h`. That is precisely the memory a ROM service hides. An
interrupt taken during a ROM overlay vectors into ROM instead of the
application's handler.

So the target workload is defined up front: an application with a private CTC
ISR running a music tick, doing console and disk I/O through the BIOS, must not
lose or delay its interrupts noticeably. If the architecture cannot meet that,
it is not ready for a game regardless of how much TPA it recovers.

### Interrupts disabled: a scaffold, not the answer

The simplest implementation is:

> ROM services execute with maskable interrupts disabled.

This is acceptable while bringing the gate up, and for services such as handling
one console output byte. The gate must preserve the caller's interrupt-enable
state rather than blindly executing `EI` on return.

It is not acceptable as the shipped behaviour. Two known constraints bound the
`DI` window, and both must be measured, not assumed:

- the SIO0 FIFO overruns when the IOC lane holds `DI` for milliseconds, which is
  an existing, observed failure on this machine;
- a music tick at 50-60 Hz tolerates only tens of microseconds of jitter before
  it is audible.

Every ROM service therefore needs a stated worst-case `DI` duration, and the
console repaint and scroll paths are the ones most likely to exceed it.

### Measured: the DI budget, and why the answer is not a deferral layer

The console settles this, and it settles it against the blanket-`DI` scaffold.
T-state analysis of the console region is not where the cost is -- a character
render is a few hundred T-states. The cost is the V9958 command wait:
`v9958_wait_command` busy-polls the command engine, and `v9958_fill_cells`, the
scroll path and `clear_screen` all block on whole-screen operations. That is
milliseconds. Holding `DI` across it reproduces the SIO0/B receive overrun this
machine has already produced from the IOC lane, for exactly the same reason.

So a `DI`-only gate cannot carry the console, and the question becomes what to
do instead. The answer turned out to be cheaper than this document assumed.

**The BIOS interrupt path is already entirely in the common window.** The IM2
vector table is at `DD10h`, `sio_core_isr` is at `DD10h-DF2Bh`, and the RX sinks
it dispatches to are in the resident transports. An interrupt taken *during* a
ROM service therefore vectors correctly, runs correctly, and returns correctly --
with ROM mapped over the low 48 KiB the whole time. Nothing needs deferring,
because nothing is hidden.

What is hidden is an **application's** IM2 table, if it installed one in the TPA.
And the gate can test for precisely that, because `LD A,I` reports the vector
page:

```text
I >= C0h   table and handler are in the common window.  The BIOS runs I = DDh.
           Leave interrupts alone; the service runs with EI.

I <  C0h   table is in the TPA, which is ROM for the duration.  An application
           put it there.  Disable, and accept the latency.
```

`LD A,I` yields both halves of the decision in one instruction: `A` is the
vector page, `P/V` is `IFF2`. The gate no longer disables interrupts as policy;
it disables them only when it cannot prove the interrupt path survives.

This removes the resident interrupt layer from the critical path. It is still
the answer for an application that owns its interrupts *and* wants long ROM
services, but that is a later problem with a known shape, not a prerequisite for
moving the console.

### The gap the gate cannot close: IM1

There is no instruction that reports the interrupt mode. The gate can read the
IM2 vector page but cannot tell whether an application has switched to IM1,
where an interrupt vectors to `0038h` -- inside the service page while a service
runs.

The service page carries a `RETI` at offset `0038h` for that case. It is not a
handler: it acknowledges the interrupt to the Z80 daisy chain and returns with
the device still requesting, `IFF1` still clear. The gate's exit path re-enables
interrupts and the real handler runs a few microseconds later. The interrupt is
deferred by the length of the service rather than lost, and an application in
IM1 that calls a ROM service gets late interrupts instead of a jump into the
middle of a lookup table.

The BIOS owns IM2 and sets it at boot, so this is a backstop rather than an
expected path.

### The resident interrupt layer is a requirement

A small resident interrupt layer in high RAM is required before the platform can
claim to support applications that own their own interrupts *and* long ROM
services. The vector-page rule above covers everything else, so this is no longer
a prerequisite for the console migration -- but it is still what an application
with its own IM2 table in the TPA will eventually need:

- resident interrupt entry stubs that defer application events while ROM is
  active;
- a resident ISR dispatcher;
- pending-event flags serviced immediately after low RAM is restored.

The first console-ROM experiment can be built without it. Nothing that a game
would run on should be.

---

## Console as the first proof of concept

The direct V9958 console is the ideal first migration target because it is:

- relatively large;
- strongly machine-specific;
- naturally firmware-like;
- called through a narrow BIOS interface;
- mostly driven by one output character at a time;
- largely independent of arbitrary transient-program memory.

The experiment should proceed by splitting console implementation from console
state.

A small RAM-resident `CONOUT` facade should:

1. receive the CP/M output character;
2. enter the ROM service gate;
3. call the ROM-resident console parser;
4. return after RAM mode has been restored.

The ROM parser may freely use:

- registers;
- high-RAM parser state;
- high-RAM stack;
- V9958 I/O ports;
- ROM-resident lookup tables.

It must not depend on reading application memory below `C000h`.

If this works cleanly, the same mechanism can be extended to other BIOS
services.

---

## Relationship to the current Zephyr boot model

Zephyr already treats ROM primarily as the boot image and copies it into RAM
before normal execution.

This proposal changes that philosophy slightly:

```text
current model

ROM -> boot source
       copied into RAM
       mostly unused during normal execution


proposed model

ROM -> boot source
    + firmware service store
```

RAM remains the primary execution environment for applications, ZCPR2, ZSDOS
and mutable system state.

ROM becomes an actively callable firmware resource.

No hardware change is required because the existing banking latch and
shadow/copy mode already provide the required mapping behavior.

---

## Target architecture

Conceptually:

```text
NORMAL RAM-ONLY MODE
====================

0000h
+------------------------------------+
| banked transient-program RAM       |
|                                    |
| Turbo Modula-2 program / CP/M app  |
|                                    |
+------------------------------------+
C000h
| application-owned common RAM       |
|                                    |
+------------------------------------+
DC00h                        boundary
| ZCPR2                              |
| ZSDOS                              |
| minimal BIOS                       |
| mutable system state               |
| interrupt-critical code            |
| stack                              |
| ROM service gate                   |
+------------------------------------+
FFFFh


DURING ROM SERVICE
==================

0000h
+------------------------------------+
| selected ROM page                  |
|                                    |
| VT100 / V9958 firmware             |
| tables                             |
| initialization / diagnostics       |
| other ROM services                 |
+------------------------------------+
C000h
| common SRAM still visible          |
| application-owned but not normally |
| touched by ROM services            |
+------------------------------------+
DC00h
| ZCPR2 / ZSDOS / BIOS RAM           |
| mutable service state              |
| stack                              |
| ROM return trampoline              |
+------------------------------------+
FFFFh
```

---

## Measured resident budget

Measured 2026-09-10 against `build/ccp-zcpr2.bin`, `build/bdos-zsdos.bin`, and
the generated [memory map](memory-map.md) for the current `zcpr2-zsdos` build.
These are recorded so the arithmetic does not have to be redone. Regenerate
them whenever the drive set, the ZSDOS configuration, or the scratch layout
changes.

### Verdict

**The resident boundary is `DC00h`.** A 9216-byte window holds ZCPR2, ZSDOS, the
resident BIOS, and the state of the intended A:/B:/C: drive set with 305 bytes of
margin, and gains 6.0 KiB of effective TPA. That margin is measured, not
estimated, and it depends on three things: ISR bodies moving to ROM, the bulk
write region being split so only the `OUTI` transmit core stays resident, and the
serial console tee folding into the ROM console service.

`E000h` was evaluated and rejected. It clears the same drive set by 46 bytes --
inside the error bars of the code estimate below -- and fails by 526 bytes if the
IOC bulk transmit loop cannot be ROM-resident, which is still open. One kilobyte
of TPA is not worth fixing the boundary before that is known, on a change that
cannot be undone without rebuilding and reflashing every component.

Throughout, the binding constraint is resident **data**, not resident code. The
tables below size the code and the fixed data; the drive count sizes the rest.

### Budget

```text
DC00h-FFFFh window                      9216
ZCPR2 (build/ccp-zcpr2.bin)            -2048
ZSDOS (build/bdos-zsdos.bin)           -3584
                                       -----
available for the BIOS                  3584
```

Resident data that cannot move to ROM under any arrangement, because ZSDOS or
the interrupt path may read or write it at any time:

| Item | Bytes |
| --- | ---: |
| `MOVE_BUFFER` | 192 |
| Shared atlas / render staging buffer (was `command_buffer`) | 96 |
| DPH/DPB window at `FB40h` | 64 |
| `DIRBUF` | 128 |
| A: ALV, SD ALV, ALV2, DPH2 | 784 |
| B: and C: checksum vectors, 128 each (removable media) | 256 |
| Runtime state `FE00h-FE74h` | 117 |
| HID input state `F642h-F67Ah` | 57 |
| Serial console tee state | 5 |
| Driver control block | 64 |
| Stack window `FE80h-FFFFh` | 384 |
| **Total** | **2147** |

The checksum vectors are not in the current build -- today's drives are all
`CKS = 0` -- and are included because B: and C: live on a removable SD card and
must carry one.

That leaves **1437 bytes for all resident code**, against a measured requirement
of 1132:

| Item | Bytes | Basis |
| --- | ---: | --- |
| `IOCBULKW` transmit core, `ED00h-EE51h` | 338 | measured |
| BIOS jump table plus per-entry service stubs | ~200 | estimate |
| Cold/warm boot, page zero, CCP restore residue | ~180 | from 305 measured, part ROM-able |
| `MOVE` / `XMOVE`, `DC03h-DCB0h` | 174 | measured |
| ISR stubs and the IM2 table entry | ~60 | estimate |
| ROM gate: latch/IFF save, `DI`, `OUT`, `CALL`, `OUT`, restore | ~50 | estimate |
| Disk-write staging stub | ~50 | estimate |
| Console facade stub, from 71 measured | ~40 | estimate |
| Storage facade, `DBC3h-DBDCh` | 26 | measured |
| `SELMEM` / `SETBNK` / bank helpers, `DA9Fh-DAACh` | 14 | measured |
| **Total** | **~1132** | |

```text
resident data                     2147
resident code                     1132
                                  ----
total                             3279
available at DC00h                3584
margin                             305
```

Margin at `DC00h`: **305 bytes**, and only with the two work items in
[Resident budget at `DC00h`, measured](#resident-budget-at-dc00h-measured)
completed. Without them the total is 3795 and `DC00h` overflows by 211.

### Why the ISR body does not have to be resident

An interrupt service routine can be a resident stub that saves the latch,
enters shadow mode, calls the ROM-resident ISR body, and restores the latch
before `RETI`. Because the stub reads the live latch value it is correct
whether or not a ROM service was already active when the interrupt fired.

The SIO RX sinks are already indirect (`SIO0B_RX_SINK`, `SIO1_RX_SINK` in
`sio_core.asm`) and deliver into high-RAM queues, so the entire receive path
ROM-izes without an interface change. This removes the 540-byte SIO core from
the resident budget, and it is what brings the boundary within reach at all.

### Direction, not size, decides what can leave RAM

In shadow/copy mode, **writes to `0000h-BFFFh` still reach the selected SRAM
bank**; only reads are replaced by ROM. See the shadow/copy table in
[Memory Management](../../../../Memory%20Management.md).

Consequences:

- Services that only **write** caller memory — disk read, IOC bulk read, HID
  delivery, page-zero install — run entirely from ROM with no staging.
- Services that **read** caller memory — disk write, IOC bulk transmit, the
  `MOVE` source side, any FCB inspection — need either a resident loop or
  staging through `MOVE_BUFFER`.

Size is therefore the wrong selection criterion, and so is "is it firmware-like".
Ask only which direction the service moves caller data.

### The gate must select the DMA bank, not the current bank

Shadow-mode low writes follow the latch's bank bits. A ROM-resident disk read
must therefore execute with `DMA_BANK` selected, not `CURRENT_BANK`. This is
part of the gate ABI, not a caller responsibility.

### Resolved: IOC bulk transmit stays resident

`IOCBULKW` transmits the caller's buffer with an `OUTI` loop whose timing is
bound to the Tx Underrun/EOM latch, and `cbios_ioc_command.asm` records that
`OTIR` was rejected outright because a stalled MCU would hang the machine with
no way back to CP/M. Staging that buffer through `MOVE_BUFFER` would inject bank
flips into precisely that loop.

The transmit core therefore **stays in RAM**. Measurement narrows that to
`ED00h-EE51h`, 338 bytes: link bringup, diagnostic capture, reject handling and
the `IOCBULK_GET` helpers in the rest of the region do not touch the caller's
buffer and move to ROM. See the split table under
[Resident budget at `DC00h`, measured](#resident-budget-at-dc00h-measured).

This is what decided the boundary. `E000h` cannot hold it; `DC00h` can, with 305
bytes left over.

### Measured region sizes

From `build/firmware.lst`, classified by T-state annotation: instruction lines
are code, everything else is data. These replace the estimates this document
carried previously.

| Region | Code | Data | Span |
| --- | ---: | ---: | --- |
| V9958 console | 2947 | 230 | `E000h-ECADh` |
| IOC bulk (write helper) | 571 | 2 | `ED00h-EF3Ch` |
| IOC command | 988 | 53 | `F000h-F414h` |
| SD backend | 491 | 0 | `F430h-F61Ah` |
| Serial console tee | 263 | 20 | `F760h-F882h` |
| HID input | 186 | 0 | `EF3Eh-EFF7h` |
| SD probe | 20 | 0 | `F680h-F693h` |
| Drive A backend | 162 | 0 | `F6B0h-F751h` |
| Core BIOS | 1461 | 23 | `DA00h-DFFFh` |

### The driver control block is 64 bytes

The V9958 console holds 142 bytes of mutable state, but 96 of that is
`command_buffer` at `EB7Ah` (`ATLAS_ROW_BYTES`) -- a transient atlas and render
staging buffer, not per-driver state. It becomes a **shared** BIOS scratch
buffer alongside `MOVE_BUFFER`.

What remains is genuinely per-driver:

```text
cursor_visible + cursor_sat                    9
parser / CSI / cursor-save state (EC6Ah-EC8Ah) 33
config_shadow, scroll_origin, text_col/row     4
                                              --
per-driver mutable state                      46
```

A further 90 bytes in that region are constants -- palette, G6 register table,
cursor pattern and colours, pair-colour table, driver vector table -- and belong
in ROM.

**The control block is therefore 64 bytes**, which covers the console with
headroom. Folding the staging buffer in would have forced 192 for no benefit,
since only one driver stages at a time.

### Resident budget at `DC00h`, measured

```text
resident data                     2147
resident code                     1132
                                  ----
total                             3279
available at DC00h                3584
margin                             305
```

Resident data includes the two CSVs, HID state (57), the serial tee's state (5),
the 64-byte control block and the 96-byte shared staging buffer.

Reaching 1132 bytes of resident code requires two pieces of work. Neither is
optional; `DC00h` does not close without them.

**1. Split the bulk write region.** `ED00h-EF3Ch` is not uniformly resident:

| Sub-range | Bytes | Disposition |
| --- | ---: | --- |
| `ED00h-EE51h` `IOCBULKW` body, `OUTI` loop, CTS and underrun handling | 338 | resident |
| `EE52h-EE90h` link init and bringup | 63 | ROM |
| `EE91h-EEDEh` diagnostic capture | 78 | ROM |
| `EEDFh-EF0Ah` reject markers and handlers | 44 | ROM |
| `EF0Bh-EF3Ch` `IOCBULK_GET` helpers | 50 | ROM |

Only the transmit core touches the caller's buffer under underrun-bound timing.
The rest moves, recovering 235 bytes.

**2. Move the serial console tee into ROM**, by folding it into the ROM console
service so a single gate entry drives both consoles. This is better than a
separate tee call: it adds no gate overhead and recovers 283 bytes. It must stay
resident during Phase 2, because it is the instrument that proves the gate.

### Measured: the stack window is not the constraint

Measured on hardware 2026-09-11 with `STKCHK.COM`, against the fill cold boot
paints across `FE80h-FFEFh`:

| Stack | Top | Used | Capacity | Free |
| --- | --- | ---: | ---: | ---: |
| boot / warm boot | `FFF0h` | 16 | 112 | 96 |
| console and storage | `FF80h` | 28 | 128 | 100 |
| `IOCALL` / `IOCBULK` | `FF00h` | 16 | 128 | 112 |
| **Total** | | **60** | **384** | **324** |

Guard byte at `FE80h` intact. The figures were identical at rest and after
alternating A: and B:, running a transient, and repainting the screen -- which
is the expected result rather than a stuck measurement: cold boot already
initialises the V9958 console and probes the SD card through `IOCALL`, so the
deepest paths are marked before the first prompt appears and later activity
re-enters the same code.

**This confirms `DC00h`.** The stack was the one figure that could have taken
the 305-byte margin, and it uses 16% of its window. A ROM service adds only the
gate's frame on top of whatever the migrated routine already nested, so the
headroom absorbs the architecture comfortably.

Two cautions against treating 324 free bytes as reclaimable:

- The measurement covers exercised paths only. Error and recovery paths, SD
  write retries and bulk transfer failures are not represented, and this
  machine's failure paths are largely untestable on hardware.
- Shrinking the window to convert it into TPA would trade a measured-safe
  margin for a kilobyte the boundary does not need. `DC00h` already closes.

If a later change does need space, right-sizing the three stacks is available
and worth roughly 128-192 bytes. It is not needed now.

### Phase 2 result: the mechanism works on hardware

Built and run on the machine 2026-09-11. `ROMTEST.COM` on the A: rescue disk,
against ROM page 4:

```text
gate prologue at F883h   PASS
IDENT     returns 5Ah    PASS
ECHO      HL crosses     PASS
WRITE_SIG ROM to low RAM PASS
LATCH     restored       PASS
```

**`WRITE_SIG` is the result that matters.** Until it ran, the read/write
asymmetry of shadow/copy mode was an inference from `MEM_DECODER.pld`. It is now
an observation: a service executing from ROM page 4, which cannot read the
caller's memory, copied sixteen bytes it read from ROM into a buffer in the
caller's TPA, and the caller read them back after the latch was restored. Reads
below `C000h` are replaced; writes are not.

Everything downstream rests on that. It is why direction rather than size
decides what can leave RAM, why a disk read can deliver a sector straight to the
caller's DMA address with no staging buffer, and why the resident budget closes
at `DC00h` at all.

`LATCH` passing matters for a quieter reason: a gate that restored the latch
imperfectly would not fail here. It would fail later, somewhere else, as a
machine that had silently changed memory map.

### Phase 2 measurements

| | |
| --- | --- |
| Gate code | 69 bytes at `F883h-F8C7h`, in a declared 77-byte region |
| Gate state | 5 bytes at `FE08h-FE0Ch`, in previously free work-area space |
| Gate stack depth | 2 bytes of 64, measured |
| Service page | `build/romservices.bin`, ROM page 4, image now 320 KiB |

The 2-byte stack depth is the structural maximum, not a light workload: the
`CALL` into the service is the only push, the compare-chain dispatcher adds
none, and the gate's `PUSH AF` reuses the same two bytes because `SP` is back at
the top by then. It will not stay 2. When the console moves to ROM its nesting --
28 bytes on the console stack today -- lands on the gate stack instead, which is
why the run is 64 bytes rather than trimmed to what Phase 2 needs.

The gate came in 19 bytes over the 50-byte estimate in the budget above, so the
resident total is about 1151 and the margin at `DC00h` about 286 rather than
305. The gate state fits inside the already-counted `FE00h-FE74h` span, so the
data floor is unchanged.

### Implementation decisions

Settled before Phase 2, recorded so they are not revisited:

| Decision | Choice |
| --- | --- |
| Resident boundary | `DC00h`; `FBASE` `E406h`; `MEM=62` |
| Service store | ROM pages 4-7 on a 512 KiB part. Services start on page 4 and never compete with the A: ROM disk on pages 1-3 or the firmware on page 0. |
| Development vehicle | Built directly against shadow-mode ROM. No intermediate SRAM-bank overlay stage. |
| Bring-up target | Physical hardware. The serial console is a tee running alongside the V9958 backend, not a fallback, so it is a live instrument from the first gate call. |
| Driver control block | 64 bytes, with the 96-byte atlas staging buffer shared rather than per-driver. |
| IOC bulk transmit | Stays RAM-resident; see above. |

Two consequences follow from building straight to ROM and bringing up on
hardware, and they shape Phase 2:

- **The first ROM routine is verified over the serial tee.** The tee mirrors
  `CONOUT` alongside the V9958 backend, so it is already live and independent of
  the console being migrated. The trivial ROM routine returns a known constant
  and the resident test reports it there.
- **Stack depth is measured on hardware, not in an emulator.** Done: cold boot
  paints `FE80h-FFEFh` (`cbios_stack_probe_start`, `DF2Ch`) and `STKCHK.COM` on
  the A: rescue disk reports the high-water mark of each stack. Re-run it once
  the console is ROM-resident and service calls nest on those stacks.

### The driver ceiling, and why the boundary should not be the maximum

There is a second constraint the TPA arithmetic hides, and for the platform's
future it is the more important one: **the resident driver budget is already
full.** Slots `E000h-FA7Fh` total roughly 6.5 KiB and are fully allocated. The
VDrip transport is not linked into the current build because it does not fit.

VDrip exists to simulate the capabilities of a real upcoming expansion card, and
there are more cards to come. Each needs a driver. Under the present layout
there is nowhere to put one.

ROM-izing driver code removes that ceiling outright: ROM pages 4-7 are unused,
and driver implementation stops competing for resident space at all. This is
arguably the architecture's main payoff, ahead of the 7 KiB of TPA.

It comes with a trap. Driver *code* becomes free; driver *state* becomes
scarcer, because the same change shrinks the resident window by 6.5 KiB and
state can never move to ROM. A disk-like device costs roughly:

```text
allocation vector        ~256
DPH + DPB                 ~32
driver state / mailbox    ~64
                         -----
per device                ~350-400 bytes
```

At `E000h` the margin would be tens of bytes -- less than one new card. The
architecture would then be able to ROM-ize every driver and have nowhere to put
the state of the cards it was built to support.

### Drivers are swapped, not all resident

The trap above assumes every supported driver needs its state resident
simultaneously. It does not. The requirement is the ability to *swap* drivers,
not to run them all at once, and that changes the budget fundamentally.

Devices fall into two classes, and they behave differently:

**Exclusive devices** -- console, HID, video, sound, transports. One is active at
a time. A single fixed resident state slot serves any number of supported
drivers, because binding a driver means pointing the slot at a different ROM
page and entry table. The BIOS already works this way: `CONSOLE_DRIVER` at
`FE04h` is exactly that indirection. Supporting ten console backends costs one
slot, not ten. Resident cost does not grow with the number of drivers the
platform supports.

**Concurrent devices** -- mounted CP/M drives. These cannot be swapped on demand.
ZSDOS may select any logged drive at any moment and reads its DPH, DPB, ALV and
directory buffer directly; a drive cannot be unbound while a file is open on it.
Their state is therefore per *concurrently mounted drive*, not per supported
driver.

More drive letters is not the axis that grows. CP/M 2.2 has no subdirectories,
but ZCPR2 supplies 16 user areas per drive with named-directory registers over
them, and **a user area costs zero resident bytes** -- the user number lives in
the directory entry, not in any resident vector. Another drive letter costs an
allocation vector plus a DPH and DPB; another user area costs nothing. With
8 MiB volumes, partitioning belongs on the user-area axis.

The current three letters (A: ROM, B: and C: at 8 MiB) are therefore likely to
remain roughly the count, and the 1669-byte data floor is close to stable.

The criterion that actually matters is not how many drives, but what kind:

> Will any upcoming card present **removable** media as a CP/M drive?

The answer for this platform is settled: **A: is fixed forever; every other
volume lives on the SD card and is therefore removable.**

Every drive in the current build is `CKS = 0` -- ROM is permanent and the SD
volumes are presently treated as fixed, so none carries a checksum vector. A
removable volume must have one, because CP/M detects media swaps through it and
sets the drive read-only on mismatch; without it a card swap corrupts the
directory through a stale allocation vector. CSV is sized `(DRM + 1) / 4`.

From the actual DPB, not the diskdef: `SD_STORAGE_DIR_ENTRIES` is `01FFh`, so
512 entries and a 128-byte CSV; `SD_STORAGE_MAX_BLOCK` is `07FFh`, so 2048
blocks of 4 KiB and a 256-byte ALV.

```text
fixed volume (A:, ROM)        DPH 16 + shares DPB              =  ~16 bytes
removable SD volume           ALV 256 + CSV 128 + DPH 16       =   400 bytes
same volume today (no CSV)    ALV 256 + DPH 16                 =   272 bytes
```

Repricing the resident floor with removable SD volumes, against the measured
1132 bytes of resident code and 400 bytes per additional volume:

| SD volumes | Data | Total | `E000h` (2560) | `DC00h` (3584) | `D800h` (4608) |
| ---: | ---: | ---: | --- | --- | --- |
| 2 (B, C) -- the intended set | 2147 | 3279 | **fails by 719** | 305 spare | 1329 spare |
| 3 (B, C, D) | 2547 | 3679 | **fails** | **fails by 95** | 929 spare |
| 4 (B, C, D, E) | 2947 | 4079 | **fails** | **fails** | 529 spare |

Two volumes, B: and C:, is the intended configuration, and `DC00h` is sized
exactly for it. `E000h` fails outright once the measured figures replace the
estimates this document originally carried.

The table also shows the cost of changing the drive plan later: a third SD volume
does not fit at `DC00h`. If the volume count is ever likely to grow, the boundary
is `D800h` and the decision has to be made now -- raising the resident base later
means rebuilding and reflashing every component.

| Boundary | Effective TPA | Gain over today | |
| --- | ---: | ---: | --- |
| `E000h` | 57.76 KiB | +7.0 KiB | rejected |
| `DC00h` | 56.76 KiB | +6.0 KiB | **chosen** |
| `D800h` | 55.76 KiB | +5.0 KiB | fallback if volumes grow to four |

**`DC00h` is the target.** It holds the intended two-volume set with 305 bytes
of margin, absorbs the resident bulk-transmit core, and leaves
room for exclusive-device control blocks as cards arrive. `D800h` is the fallback
if the volume count later grows to four.

One lever if that kilobyte is wanted back: moving the SD volumes from 4 KiB to
8 KiB blocks halves DSM and drops each ALV from 256 to 129 bytes, refunding
about 127 bytes per volume -- very nearly what the CSV costs. The price is up to
8 KiB of slack per file, roughly 10% of an 8 MiB volume at typical CP/M file
sizes. Worth doing only if the boundary decision turns on it.

Raising the resident base is not reversible without rebuilding and reflashing
every component, so this is decided once, before Phase 4.

### The driver-slot ABI must fix the state size

The swap model has one failure mode, and it is silent: a future driver that needs
more resident state than the slot provides reintroduces per-device growth through
the back door, after the boundary has already been fixed and the TPA handed to
applications.

Prevent it in the ABI rather than by convention:

- define a **fixed-size resident driver control block** per exclusive slot --
  64 or 128 bytes, decided once and measured against the existing console and
  storage state;
- a ROM driver that cannot fit its mutable state in its control block does not
  bind, and this is a build-time check, not a runtime discovery;
- the control block records the driver's **ROM page and entry table**, so the
  gate selects the page from the bound slot rather than from a global. This also
  answers cross-page dispatch: a call targets a slot, and the slot knows its
  page. Nested calls across pages remain prohibited unless the gate saves and
  restores the page, which it should, since it already saves the full latch.

Binding a driver then becomes: select its ROM page, call its init entry, record
page and entry table in the slot. Unbinding is the same in reverse. Neither
touches the resident budget.

### The three risks to the resident-window target

1. **Resident data, not code.** 1669 bytes is 65% of the non-CP/M budget and
   grows per drive: roughly 256 bytes of ALV, 16 bytes of DPH, plus a CSV when
   `CKS` is non-zero. This is the reason `DC00h` was chosen over `E000h`; see
   the driver-ceiling section above.
2. **Stack.** 384 bytes cover three private stacks, and the console/storage
   margin is unmeasured. ROM services add call depth to those same stacks.
   This is the most likely silent failure in the design and it is measurable
   today, before any ROM work starts.
3. **ZSDOS is 3584 bytes — 44% of the window.** If a build without the
   datestamper is viable, that is the cheapest space in the project: a
   configuration change rather than an architecture.

---

## Development plan

### Phase 1 - Measure

Generate exact current sizes for:

```text
ZCPR2 binary
ZSDOS binary
BIOS core
V9958 console
IOC command/bulk support
storage support
mutable state
scratch buffers
stack reservation
```

Do not assume that stock CCP/BDOS sizes represent ZCPR2/ZSDOS.

Use the built binaries and generated linker/map files as authoritative values.

This is done. The results are in
[Measured resident budget](#measured-resident-budget): exact region sizes, the
64-byte driver control block, the bulk-write split, and the stack high-water
measurement. Both items that once gated the boundary are settled -- the bulk
transmit core stays resident at 338 bytes, and the stack window uses 60 of its
384 bytes.

`DC00h` is confirmed against measurement rather than estimate.

### Phase 2 - Introduce ROM-call infrastructure -- DONE

Add a high-RAM service gate that can:

- save the current RAM bank;
- select a ROM page;
- enter shadow mode;
- call a known ROM entry;
- restore RAM-only mode;
- restore the caller's bank;
- preserve interrupt state.

Test this first with a trivial ROM routine -- one that returns a known constant
in `A`, reported over the serial console tee. Do not validate the gate through
the V9958 backend: it is the next thing to be migrated, and it cannot be both
the instrument and the subject.

### Phase 3 - Move the V9958 console implementation -- DONE

**First slice done and building: the font atlas builder.**

The console occupies `E000h-EBF6h`, which is the *common* window, so it stays
mapped while a ROM service runs. Migrated code can therefore keep calling what
it left behind, and the console can move a piece at a time instead of in one
jump. `tools/gen_romsvc_bios.py` generates the resident addresses the page calls
back into, from the firmware listing rather than from a written-down table --
the same discipline `gen_zsdos_bios.py` applies to the ZSDOS side, and for the
same reason.

The atlas builder was the right first piece: bulky, called only from console
init and reset rather than per character, and dependent on nothing the caller
owns.

| | Before | After |
| --- | ---: | ---: |
| Resident console | 3073 | 2835 |
| Font in the TPA at `8000h` | 2048 | 0 |
| Free space in the driver slots | -- | +183 at `EBF7h-ECADh` |

**The font moved with the code, which removes a staging step.** The glyph fetch
reads `8000h`, and that is ROM page 4 while the service runs, so a RAM font was
no longer reachable.

This is a simplification, not a repair. The font was in the TPA by design: ROM
to `8000h` at boot, `8000h` to VRAM, and from then on the glyphs live in VRAM
and the RAM copy is disposable -- a transient overwriting it is harmless,
because the next boot re-copies before the next upload. Reading the font
straight from ROM makes both the copy and the boot-time refresh that fed it
unnecessary, which is where `restore_font_from_rom` went.

It is also the case blanket `DI` could not have carried: 128 scanline passes,
each streaming 96 bytes to VRAM. It runs under the vector-page rule instead.

**Second slice done and building: the init and reset cluster.**

`reset_display`, `init_g6`, the paced palette upload, the hardware-wait and
porch sequencing, the cursor sprite setup, and the four constant tables they
read. The call graph was checked rather than assumed, and it found exactly one
routine inside the block that had to stay behind: `v9958_write_register`, which
the per-character path reaches through `v9958_start_command` and
`v9958_write_vram_small`. It is called from ROM at its resident address.

| | Original | After slice 1 | After slice 2 |
| --- | ---: | ---: | ---: |
| Resident console | 3073 | 2835 | 2512 |
| Console region ends | `ECADh` | `EBF6h` | `EA77h` |

561 bytes returned so far, and 566 bytes of the driver slots are now free at
`EA78h-ECADh`.

`console_init_common` keeps its state clearing and crosses the gate once for the
display bring-up, rather than eight times for the eight calls it used to make.

### The gate is not reentrant

Slice 2 found this the way such things are usually found: `v9958_reset_display`
calls the atlas builder, and in RAM that name had become a stub that enters the
gate. Calling it from inside a service would have been a second gate entry
within the first.

The gate keeps the caller's SP, the saved latch and the saved interrupt state in
single slots at `FE08h-FE0Ch`. A nested entry overwrites the outer call's return
path, and the machine comes back with the wrong memory map -- which would not
fail at the call site but later, somewhere unrelated.

The rule, and it is now in `romsvc_abi.inc`: **a service that wants another
service calls it directly on the ROM side, never through its resident entry
point.** That is also one fewer map switch. Enforcing it in the gate costs
around ten bytes for a guard flag, and the gate currently has one byte of its
declared region spare; the check belongs in the rebased gate when it moves into
core BIOS.

**Third slice done and building: the terminal layer.**

The VT100/CSI parser, the ANSI handlers and the text-layer semantics -- 96
labels, one contiguous run with nothing foreign inside it. The line this slice
draws is **terminal semantics in ROM, VDP primitives in RAM**: everything moved
decides what to draw, and what it calls decides how to get it into VRAM.

| | Original | Slice 1 | Slice 2 | Slice 3 |
| --- | ---: | ---: | ---: | ---: |
| Resident console | 3073 | 2835 | 2512 | 1269 |
| Console region ends | `ECADh` | `EBF6h` | `EA77h` | `E59Ch` |

**1804 bytes returned**, and 1809 bytes of the driver slots are free at
`E59Dh-ECADh`.

### The hot path did not move, and that was the point

A gate crossing is 381 T-states -- 38us at 10 MHz. That is roughly what
`term_process_byte` cost per byte in the first place, and 84ms across a full
85x26 repaint. Relocating the parter wholesale would have doubled the cost of
every character the machine prints.

So the resident side keeps a fast path and enters the gate only when something
has to happen that is not "put this character in the run buffer". Four
conditions, all of which must hold:

```text
normal state         mid-escape, every byte belongs to the parser
printable byte       20h..FFh except 7Fh; CP850 high bytes are printable
room in the run      a full buffer has to flush, and flush is in ROM
not the last column  the last column wraps, which can scroll
```

The cursor advance is inlined rather than called, and only because of the last
condition: while `text_col < TEXT_LOG_COLUMNS - 1`, `text_advance_cursor` is an
increment and a store. Everything that can wrap, scroll or flush is punted
across the gate to code that did not change.

Line-oriented output now crosses the gate two or three times per line instead of
once per character -- roughly 115us per line rather than 3ms.

`CONST` needed no gate call of its own: it already tested `print_run_count`
before flushing, so a polling program with no pending output never enters ROM.

**Fourth slice done and building: the VDP primitive layer.**

The run accumulator, the glyph renderer, the cell fill, the row copy, the
scroll, line insert and delete, the screen clear, the VRAM writer and the cursor
sprite.

| | Original | S1 | S2 | S3 | S4 |
| --- | ---: | ---: | ---: | ---: | ---: |
| Resident console | 3073 | 2835 | 2512 | 1269 | 431 |
| Console region ends | `ECADh` | `EBF6h` | `EA77h` | `E59Ch` | `E24Eh` |

**2642 bytes returned.** What remains is 368 bytes of code and 63 of data: the
driver table, the CP/M entries, the per-character fast path, `VIDEO_SEND`, and
the state. 2655 bytes of the driver slots are free at `E24Fh-ECADh`, and ROM
page 4 now carries 3079 bytes of service code plus the font.

### What stayed, and why it had to

`VIDEO_SEND` and `v9958_data_write_block` take `HL` as a pointer into the
**caller's** memory. That makes them read-direction services, and shadow mode
replaces reads below `C000h` -- a ROM copy would stream ROM bytes instead of the
application's buffer. This is the direction rule deciding a case rather than a
preference deciding it; how much `VIDEO_SEND` is used never entered into it.
`v9958_present` is reachable from `VIDEO_SEND`, so it stays alongside and is
called from the page at its resident address.

### `CONST` keeps its guard

`CONST` and `CONIN` both called `flush_print_run`, `cursor_write_sat` and
`present` back to back. Those are one service now, so the pair crosses once
rather than three times -- but the test of `print_run_count` stayed on the
resident side deliberately. BDOS calls `CONST` once per character printed, and a
program polling for input with nothing pending must not pay 38us to find that
out.

### The generated address list caught the slice's real bug

Moving these routines invalidated the `RES_` references that slices 1 to 3 had
made to them -- they were resident then and are page-local now.
`gen_romsvc_bios.py` refused to emit a stale address and named all twelve. The
symbol list is now derived from the `RES_` references in the page sources rather
than maintained by hand, so the two sides cannot drift apart silently.

### Re-costing the boundary

The `DC00h` budget assumed the console shrank to roughly a 40-byte facade. It is
431 bytes, so the resident code total is about 360 bytes higher than budgeted and
the margin is nearer **-55 than 305**: `DC00h` does not currently close.

That was closed by migrating the SD storage transaction layer -- see below.

### Fifth slice: the SD storage transaction layer

The record arithmetic, the request builder, the command exchange, the read,
write and flush transactions, and the three card probes.

```text
SD backend region     491 -> 210 bytes
probe region F680h    48 bytes, now entirely free
resident driver code  3067 bytes across E000h-FA7Fh
```

The IOC command transport was the larger target and was rejected: it and the
bulk lane are one subsystem split across two address ranges and mutually
recursive -- `iocbulk_body` lives in the command region while the bulk region
calls back into it, and `IOCBULK_RTS_OFF` is reached from the transmit path
mid-transfer. Splitting it would put gate crossings inside a timing-critical
lane.

### A ROM service must never touch the bank latch

This slice found the third hard rule, after direction and reentrancy, and it is
the one with the worst failure mode.

`sd_copy_to_dma` and `sd_copy_from_dma` stage a record through `MOVE_BUFFER`,
and to do it they select the caller's DMA bank -- they write the banking latch.
Inside a ROM service that drops the machine out of shadow mode and unmaps the
ROM it is currently executing from, mid instruction stream. Not a wrong result:
a crash with no return path.

So staging brackets the gate rather than living inside it:

```text
read    gate -> service fills MOVE_BUFFER -> resident sd_copy_to_dma
write   resident sd_copy_from_dma -> gate -> service sends MOVE_BUFFER
```

Those two routines would have had to stay resident for a second, independent
reason: they read the caller's memory on the write side, which shadow mode
replaces with ROM. Either reason alone is sufficient. The rule is in
`romsvc_abi.inc`.

`IOCALL`, `IOCBULK` and `IOCBULKW` are still called from the service at their
resident addresses, which is safe because in this path they touch only
`MOVE_BUFFER` and the SIO ports -- both reachable with ROM mapped low.

Phase 2 established the gate, the ABI (`src/romsvc_abi.inc`), the page-4 build,
and `ROMTEST.COM`. Three things carry forward into this phase:

- the 64-byte driver control block gets its first real occupant, and the
  console's 46 bytes of per-driver state is what sized it;
- the 96-byte atlas staging buffer becomes shared BIOS scratch rather than
  console-private;
- the `DI` budget is still unmeasured. Phase 2's services are a few dozen
  T-states; a console service is where the question becomes real, and the
  answer decides whether the resident interrupt layer is needed before or after
  this phase.


Separate mutable console state from executable console logic.

Keep mutable state high.

Move parsing, lookup tables and rendering implementation to ROM.

Test:

- ordinary CP/M console output;
- cursor movement;
- clear-screen;
- VT100 sequences used by TM2, WordStar and other software;
- long output streams;
- warm boot;
- repeated ROM entry/exit.

### Phase 4 - Reclaim the freed RAM

After ROM migration has reduced the resident BIOS size, move the CP/M resident
base upward.

The goal is approximately:

```text
TPA:       0100h-DBFFh   (effective 0100h-E405h)
Resident:  DC00h-FFFFh
```

Rebuild ZCPR2, ZSDOS and BIOS for the new base rather than creating a hole in
the old memory map.

### Phase 5 - Hardware and software acceptance

Verify:

- ZCPR2 operation;
- ZSDOS disk access;
- console correctness;
- IOC/HID operation;
- SD storage;
- warm boot;
- bank switching;
- interrupt behavior;
- Turbo Modula-2 compilation.

The decisive acceptance test is a runtime one, not a compile: the tracker
playing audio from a private CTC ISR while console and disk I/O run through the
BIOS. That exercises the interrupt layer, the `DI` budget, and the two-SIO
coupling at once, which is the combination a game will actually produce.

A particularly useful acceptance test is to retry compiling `PLAYER.MOD`
natively on the Zephyr. A successful compile would demonstrate that the TPA
increase solved a real development constraint.

### Phase 6 - Move additional BIOS services to ROM

After the console architecture is stable, inspect remaining high-RAM code and
move additional eligible services one at a time.

Do not move routines merely because they are large. The deciding criterion is
whether they can safely execute while low application RAM is hidden.

---

## Design rules

1. **ZCPR2 and ZSDOS remain resident in RAM.**
2. **The application owns all RAM below the final resident boundary.**
3. **ROM services must not depend on reading low application RAM while ROM is
   mapped.**
4. **Mutable firmware state remains in high common RAM.**
5. **The ROM call gate must restore the exact caller bank/memory mode.**
6. **Interrupt state must be preserved across ROM calls.**
7. **Interrupts disabled is a bring-up scaffold, not a shipping behaviour.**
   Every ROM service carries a measured worst-case `DI` window, bounded by the
   SIO FIFO overrun threshold and by audible music-tick jitter. Applications
   owning interrupts require the resident interrupt layer.
8. **Interrupt handlers required during a ROM call must reside in high common
   RAM.**
9. **The generated memory map remains authoritative for exact addresses.**
10. **The resident boundary is derived from measured size, not chosen by
    convention.**
11. **ROM is an execution resource, not merely a boot-time backing store.**
12. **The first goal is a smaller RAM-resident Zephyr BIOS, not a ROM-based
    CP/M implementation.**

---

## Expected payoff

The present design starts the resident CP/M area at `C400h`; the proposal moves
it to `DC00h`. The gain is the difference between those two boundaries:

```text
DC00h - C400h = 1800h = 6144 bytes = 6.0 KiB
```

That 6 KiB is the committed figure. An earlier draft proposed `E000h` and 7 KiB;
that boundary was rejected on the resident-data budget. The absolute TPA numbers on either side of it,
however, depend on which of two conventions is used, and the two must not be
mixed.

**Nominal TPA** — everything strictly below the resident base:

```text
current    0100h-C3FFh = 49.75 KiB
proposed   0100h-DBFFh = 54.75 KiB
```

**Effective TPA** — everything below `FBASE`, the value a transient reads at
`0006h`. `cbios_boot.asm` states the rule: a transient may use memory up to the
BDOS base and overwrite the CCP, which `WBOOT` reloads from ROM. The CCP
allocation is reclaimable TPA in both layouts.

```text
current    0100h-CC05h = 50.76 KiB   (FBASE = CC06h)
proposed   0100h-E405h = 56.76 KiB   (FBASE = E406h, ZCPR2 at DC00h)
```

Either convention yields the same 6.0 KiB gain. The figure to quote to a
program is the effective one, because that is what `0006h` reports: a
well-behaved transient sees roughly **56.8 KiB** after the move, not 54.75.

In `MOVCPM` terms a `CBASE` of `DC00h` is a `MEM=62` build, against the current
`MEM=56`.

On an 8-bit system, recovering 6 KiB of contiguous TPA is substantial.

### Reference point: RunCPM

Turbo Modula-2 runs well on the Zephyr today and is responsive; it fails only by
running out of memory on large projects that compile successfully under RunCPM.
RunCPM is therefore the upper bound on the requirement, and the gap to it is the
figure that matters -- not an abstract "56 KiB".

Measured from the local RunCPM checkout (`RunCPM/globals.h` `TPASIZE 60` with
`CCP_ZCPR3`, and `RunCPM/cpm.h` line 198 writing `BDOSjmppage + 6` to `0006h`):

```text
RunCPM            FBASE = EC06h   TPA 0100h-EC05h = 58.76 KiB
Zephyr today      FBASE = CC06h   TPA 0100h-CC05h = 50.76 KiB
Zephyr committed  FBASE = E406h   TPA 0100h-E405h = 56.76 KiB
```

```text
gap to RunCPM today       2000h = 8192 bytes = 8.0 KiB
closed at DC00h           1800h = 6144 bytes = 6.0 KiB
remaining gap             0800h = 2048 bytes = 2.0 KiB
```

`DC00h` closes six of the eight kilobytes. It cannot close all eight: matching
RunCPM would require `CBASE` at `E400h`, leaving 1536 bytes for a BIOS whose
measured floor is about 2514 bytes with the two removable volumes.

Whether two kilobytes short is good enough is therefore the entire acceptance
question, and it is answerable before any ROM work is done.

### Phase 0 - Settle the acceptance question first

Do this before Phase 2. It is a one-line change and a single compile.

In `RunCPM/cpm.h`, line 198 reads:

```c
_RamWrite16(0x0006, BDOSjmppage + 0x06);
```

Change the value to `0xE406` -- the committed Zephyr `FBASE` at `DC00h`. The real
BDOS stays at `EC00h`; only the memory ceiling that transients read from `0006h`
moves, so nothing else in RunCPM needs to change and no relocated CCP is
required. The two kilobytes between the fake ceiling and the real BDOS simply go
unused.

Rebuild RunCPM and compile the project that currently OOMs on the Zephyr.

- **It compiles.** The proposed layout is sufficient. Proceed with the full
  plan; `PLAYER.MOD` is then a meaningful Phase 5 acceptance test.
- **It OOMs.** The proposed layout does not solve that particular compile, and
  no further BIOS ROM-ization on a 64 KiB Z80 will. The answer for that project
  is Modula-2 separate compilation -- splitting it into more definition and
  implementation modules. This does not invalidate the architecture: the 7 KiB
  is permanent and applies to every program the platform will run. It only means
  the compile is not the test that settles it.

### The runtime stress test matters more than the compile

Execution, not compilation, is the harder constraint. `SNTRACK.COM` is 33,792
bytes and the fixed Turbo Modula-2 runtime floor is about 16.9 KiB (measured
from `TIMTEST.COM`, built from 589 bytes of source). Loading at `0100h`:

```text
today      8500h-CC05h = 18,182 bytes = 17.8 KiB free for heap, stack, song
at DC00h   8500h-E405h = 24,326 bytes = 23.8 KiB   (+34%)
RunCPM     8500h-EC05h = 26,374 bytes = 25.8 KiB
```

Two consequences for the platform, independent of this architecture:

- **Unbounded data belongs in a bank, not the TPA.** Song data, and later game
  assets, should live in one of the seven spare SRAM banks -- 336 KiB -- reached
  through the `MOVE` / `XMOVE` / `SELMEM` / `SETBNK` entries the BIOS already
  exports. The safe structure is that the application pulls a working unit into
  a small TPA buffer, and the audio ISR touches only that buffer, never the bank
  latch.
- **The fixed runtime floor is worth investigating once.** 16.9 KiB of payload
  for 589 bytes of source suggests whole-library linking. If TM2's linker can
  drop unreferenced modules, that lever may be larger than this entire
  architecture and costs a link option.

Neither substitutes for the OS work. They are the same programme: get the
platform out of the application's way before a game depends on it.

Sweeping the value downward from `EC06h` also gives the project's actual
requirement in bytes, which is worth recording here once it is known.

The immediate motivation is Turbo Modula-2 compiler workspace, but the gain
would benefit every large CP/M application and would make Zephyr's extensive
ROM capacity useful during normal operation rather than only during boot.
