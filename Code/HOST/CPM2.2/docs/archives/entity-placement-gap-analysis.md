# Entity Placement — Taxonomy and Gap Analysis

Where each kind of thing in the operating system is supposed to live, where it
actually lives today, and what it would take to close the difference.

This is analysis, not a plan of record. Nothing here has been moved. Addresses
and sizes are from the default build (`CONSOLE=v9958 STORAGE_A=rom`); regenerate
`docs/memory-map.md` before relying on any of them.

---

## 1. The taxonomy

Two address classes, five kinds of entity.

### Bank 7 — `2000h-DFFFh`, visible only in mode 11

| Entity | Definition |
|---|---|
| **Core OS** | The layer that *defines* a contract and dispatches on it. ZSDOS, the facades, the dispatchers, the boot path, assets. Identical in every build configuration. |
| **Private OS state** | State no application or other processor can observe. Disk structures, buffers, queues, stacks, scratch, caches. |
| **Drivers** | The backends that *implement* a contract, placed in slots. One or more may be swappable for another implementing the same contract. |

### Common memory — `E000h-FFFFh`, mapped in both modes

Two entity types, both admitted by the same rule: their addresses must resolve
to the same bytes under more than one latch state. The residency rule below says
when that is true; the split here is only code versus state, because the two are
organized differently (section 6.3).

| Entity | Definition |
|---|---|
| **Public OS state** | State whose value must be seen under more than one latch state — written under one mapping and read under another, touched by an ISR, or recording the transition itself. Stacks are state. |
| **Code that must survive a bank switch** | Code whose address must remain valid under more than one latch state — interrupt handlers and everything they reach, code that moves the latch, and entry points reached in one mode that continue in another. |

### Core and driver

Core and driver are not about whether something varies between builds. **Core
defines an interface; a driver implements it.** A backend that has exactly one
implementation today is still a driver — the SD card backend implements the
storage contract and could be swapped for a VDrip backend, and the HID path
implements the input side of the console contract.

### The residency rule

There is one rule, and it comes from the hardware rather than from a list of
observed cases:

> **Common memory is the only address range whose contents do not depend on the
> latch. An object belongs in common if its address must resolve to the same
> bytes under more than one latch state. Everything else belongs in bank 7.**

Three situations produce that requirement. They are a checklist, not three
separate rules:

| | Situation | What it puts in common |
|---|---|---|
| 1 | **Unknown latch** — an interrupt may arrive under any mode and any bank | the handler, everything it reaches, its stack, the vector page |
| 2 | **Changing latch** — code that moves the latch | the switching code, the stack it runs on, and the state recording what the latch was |
| 3 | **Two known latches** — an object written under one mapping and read under another | staged inputs, returned outputs, and entry points reached in one mode that continue in another |

Situation 3 is the one that is easiest to state badly, so it is worth being
precise about direction. It is **not** "caller-visible." The staging buffer is
the clearest case: the caller never holds its address and cannot observe it at
all. It is common because the facade copies the caller's DMA or FCB into it
*while mode 10 is mapped*, and bank-7 code reads it *after the switch to mode
11*. Written under one latch state, read under another. The same phrasing covers
the opposite direction — the ALV copy that function 27 returns is written by the
OS and read by the application — and it covers the facade entry point itself,
which is reached at `EC06h` in the caller's mapping and continues into mode 11,
so it cannot live in bank 7 because bank 7 is not mapped when the caller calls.

Two consequences worth stating, because both have been got wrong in this tree:

**Residency is per routine, not per module.** An interrupt-reachable driver is
not an exception to "drivers live in bank 7": the part an ISR reaches is in
common under situation 1, and the rest is an ordinary bank-7 driver. Section 2
is the record of what happens when whole modules are placed by their
most-constrained routine.

**The IO Controller is not a reason for anything to be in common.** It is a
serial peer, not a bus master: it never dereferences a Z80 address, and every
byte crosses under Z80 control through `IN`/`OUT` on SIO1. No latch state of the
Z80 is involved on its side, so it cannot create a two-latch object. The command
and bulk lanes run in bank 7 and their buffers are in bank 7 with them —
`FAT_TX` at `C300h`, `FAT_RX` at `C320h`, the transport stack at `C300h`.

The two IOC-related objects that do live in common — the link failure record at
`F298h` and the transport level byte at `F530h` — are there under situation 3,
because the BDOS function 203 sysinfo block hands an application a pointer that
it dereferences in mode 10. A bulk transfer whose destination is an
application's DMA buffer needs staging for the same reason, and a receive ring
is common under situation 1. None of these is a property of the controller.

### An audit this document has not done

Sections 3.3 and 4 audit **code** residency routine by routine. Nothing here has
audited **state** residency the same way, and the runtime state block at
`FE01h-FE7Fh` is visibly mixed when read against the rule above:

```text
FE01  CURRENT_BANK, SAVED_LATCH, XMOVE/MOVE state   situation 2, clearly
FE02  cbios_dma_addr                                situation 3, clearly
FE40  storage track/sector/unit, storage_caller_sp  situation 2 or 3 — unaudited
FE04  CONSOLE_DRIVER, CONSOLE_CALLER_SP             unaudited
FE70  SIO sinks, IRQ enable flag                    situation 1, clearly
FE78  SERCON flags and receive queue                situation 1 for the queue;
                                                    the flags are unaudited
```

Some of that is certainly correct. Some of it may be bank-7 state that followed
its module into common, which is exactly the failure section 2 describes — and
until someone walks it per field, the 127 bytes cannot be claimed as justified.
It is the same audit, applied to data.

---

## 2. Where the gap comes from

Every misplacement found so far is the same failure, and it is not a gap in the
taxonomy. The taxonomy classifies **routines**; the tree places **modules**.

A module was placed by its most-constrained routine — or, twice, by wherever a
hole happened to be — and the rest of the module inherited an address class it
did not qualify for:

- **SIO core**: the ISR body must be common, so the initialization routines and
  the polled IOC byte helpers came with it.
- **SERCON**: the registered RX sink must be common, so the whole console tee
  came with it.
- **Boot banner printer**: needed 56 bytes, went where a hole was, and the hole
  was in common.

The same effect explains the driver slots. During the Phase 1/2 migration
modules moved to bank 7 as whole files; a module with an interrupt-reachable
part could not move at all, and the numbered slot array — defined when the
machine was flat and `E000h-FA7Fh` was simply the top of the BIOS — was left
describing addresses that now hold the CCP, the facade and the BIOS.

---

## 3. Gap analysis

### 3.1 Drivers outside the slot system

Classified by contract, the driver population is:

| Contract | Implementation | Where | Size | In a slot? |
|---|---|---|---:|---|
| console, output | V9958 (or VDrip) | `4800h` | 3191 | **yes**, slot 0 |
| console, input | HID input | `3D00h` | 186 | no |
| console, tee | SERCON | `F830h` | 295 | no — *and in common* |
| storage, A: | ROM disk (or VDrip) | `4330h` | 164 | no |
| storage, B:/C:/D: | SD backend | `4000h` | 745 | no |
| storage, selection | B: select probe | `4300h` | 23 | no |
| storage, personality | FAT BDOS / FS2 client | `9000h` | 5128 | no |
| IOC link | command lane | `3400h` | 1037 | no |
| IOC link | bulk lane | `3A00h` | 558 | no |

**Nine drivers; one is in a slot.** Every other one is at an address chosen when
it was written, several derived arithmetically from whatever preceded them —
the A: backend's base is `SD probe base + probe size`, so it moves whenever the
probe changes size.

It is tempting to conclude that the declared regions
`generate_memory_docs.py` already validates are the slot mechanism under another
name. They are not — they are its opposite. Thirteen of the fifteen bank-7
regions are bounded by *their neighbour's base*:

```text
Console facade      limit = CBIOS_STORAGE_CODE_BASE
Storage facade      limit = CBIOS_BIOS_EXT_CODE_BASE
IOC command lane    limit = CBIOS_XPORT_SHIM_CODE_BASE
...
```

Only the SD backend and the FAT personality have a ceiling of their own. So a
region's "free" column is not reserved headroom; it is whatever the next thing
happened to leave, and it evaporates the moment the next thing moves. Bank 7 is
the same card castle as common memory, and the tree records a case of it:
`CBIOS_XPORT_SHIM_CODE_BASE` carries the note that its base *"is the V9958
console's code end, not a fixed boundary: it was ECA6h until the console's
idle-spin delay grew the driver by eight bytes."* Eight bytes moved a boundary.

That is exactly what fixed slots exist to prevent, and it is why the slot
population needs slots rather than tighter regions. Section 7 sizes them.

### 3.2 Core in bank 7 — no gap

The facades and dispatchers are correctly placed and appropriately thin:

| Core entity | Where | Size |
|---|---|---:|
| console facade | `3040h` | 125 |
| storage facade | `3100h` | 26 |
| `VIDEO_SEND` | `3200h` | 40 |
| `IOCALL` | `3280h` | 140 |
| drive dispatcher | `4400h` | 179 |
| ZSDOS | `2000h` | 4096 |

**`VIDEO_SEND` is live, despite the name.** It reads as a Virtual Drip remnant
and is not one: it is published as **BDOS function 215** (`ZB_EXT_VIDEO_SEND` in
`Utilities/src/zbdos.inc`, documented in `Utilities/README.md`), and three CP/M
transients call it — `video_smiley_v9958.asm` and both `mandelbrot_v9958`
variants in the HelloWorld project. The extension-table entry at
`ZBIOS_EXT_BASE + 0Fh` is its implementation, not a second public path.

Its job is core: it is the contract by which a transient borrows the display
from the console driver, dispatching to `console_backend_send_frame`,
`console_backend_data_write_block` and `console_backend_reset_display`. A
program cannot simply write ports `A0h-A4h` instead — the console driver owns
the VDP and renders the text console into the same chip, `A = 00h` is how the
display is handed back (text mode, font atlas and cursor restored), and under
`CONSOLE=vdrip` there is no local VDP at all.

What *is* a fossil is the interface's shape. `A` is a Virtual Drip packet type,
callers hardcode the protocol's codes, and every type except `0Bh`
(`VDP_DATA_BLOCK`) is capped at `VIDEO_SINGLE_PAYLOAD_MAX = 0x10` — a limit the
source itself calls "the historical 16-byte limit", which describes a serial
frame rather than anything about a directly attached chip. A future video
backend therefore inherits Virtual Drip's packet vocabulary in order to satisfy
a contract that has nothing to do with that transport. Function 215 is frozen
because compiled programs use it; the symbol and file names are not.

### 3.3 Common memory — three modules holding bank-7 material

This is where the gap is concentrated. Measured from the current listing:

| Module | Range | Must stay common | Belongs in bank 7 |
|---|---|---|---|
| Boot banner printer | `F2A9h-F2E1h` | nothing | **56 bytes**, all of it |
| SIO core | `F2F0h-F4FBh` | **246 bytes** — the ISR block `F471h-F4FBh` (139), plus `sio_init`/`sio_core_init` (50) and `sio_send_byte` (57), which boot needs *before* `bank7_check` and which the bank-7 failure path calls | **278 bytes** — `sio1_ioc_init`, `sio_register_rx_sink`, `sio_recv_byte`, the IOC RTS/put/get helpers, `sio_rx_kick` |
| SERCON | `F830h-F957h` | `F903h-F957h`, 85 B — `sercon_rx_sink`, `sercon_rx_esc`, `sercon_rx_store`, `sercon_rx_buffer` | **211 bytes** — driver table, `sercon_init`, `sercon_install`, `sercon_call_backend`, the `CONST`/`CONIN`/`CONOUT` tee, TX and CTS handling |
| VDrip transport *(`CONSOLE=vdrip` only)* | `F680h-F90Eh` | `F7A9h-F90Eh`, 357 B — `vdrip_rx_sink` and, because the sink parses inline, the whole `vdrip_parse_byte` state machine and packet dispatch | **297 bytes** — `register_sink`, `set_idle_mode`, `wait_ready`, `begin`/`end_storage`, `wait_reply`, `send_packet`, `send_frame`, `putc` |

Two of these are justified in part. The banner is not justified at all: it reads
`BOOT_BANNER_TEXT` at `8800h`, which is in bank 7, and cold boot calls it
immediately after `console_backend_cold_init` at `4800h` — so bank 7 is already
mapped when it runs. Its own comment records why it is where it is: it was
evicted from bank 7 because the slot it occupied was packed against the console
facade.

`sio_rx_kick` and the SIO0/B RTS helpers are listed as movable on the strength
of their call sites, but they sit adjacent to the ISR block and want a
per-routine check before anyone moves them.

### 3.4 Not a gap, worth recording

- **`E000h-EBFFh` is not OS memory**, so the taxonomy does not have to account
  for it. The interrupt-callback reservation at `E000h-E3FFh` belongs to the
  running program, and the CCP at `E400h-EBFFh` is a user program that happens
  to sit at a fixed high address — page zero's `0006h` holds `EC06h`, so the
  transient program area runs to `EC05h` and the CCP is inside it. A transient
  may walk over the whole region, which is precisely why warm boot restores the
  CCP from the pristine asset at `C400h` in bank 7. That asset is core OS; the
  instance at `E400h` is not. The OS's share of common memory begins at the BDOS
  facade.
- **Driver slot constants 1-5** describe the flat machine. Nothing outside
  `cbios_defs.inc` references slots 1-4 at all; slot 5's constants survive
  because `CBIOS_VDRIP_TRANSPORT_CODE_BASE`, `CBIOS_SCRATCH_BASE` and
  `CBIOS_CODE_LIMIT` are still derived from them inside that same file.

---

## 4. Objects that need moving

In dependency order. Each is a placement change only: no behavior change, no
public entry point moves, no jump-table entry is touched.

| # | Object | From | To | Bytes reclaimed |
|---|---|---|---|---:|
| 1 | boot banner printer | `F2A9h-F2E1h` common | bank 7, beside its text | 56 |
| 2 | SIO core, movable half | `F322h-F470h` common | bank 7, core | 278 |
| 3 | SERCON, non-ISR half | `F830h-F902h` common | bank 7, driver slot | 211 |
| 4 | HID input | `3D00h` bank 7 | a declared driver slot | 0 (already bank 7) |
| 5 | SD backend + B: probe | `4000h`, `4300h` bank 7 | a declared driver slot | 0 |
| 6 | A: backend | `4330h` bank 7 | a declared driver slot, fixed base | 0 |
| 7 | FAT personality | `9000h` bank 7 | a declared driver slot | 0 |
| 8 | IOC command and bulk lanes | `3400h`, `3A00h` bank 7 | declared driver slots | 0 |

Item 2 is smaller than a byte count of the non-ISR half suggests. Boot calls
`sio_core_init` *before* `bank7_check` — nothing in bank 7 may be called until
the image there is verified — and `bank7_check`'s failure path emits its message
through `sio_send_byte`. Those 107 bytes therefore stay in common alongside the
139-byte ISR block. See the implementation plan, section 4.

Items 1-3 reclaim **545 bytes of common memory**. Items 4-8 move nothing; they
bring drivers that are already in the right bank under a single placement
discipline.

### `CONSOLE=vdrip` is the same failure, not a separate problem

The 654-byte figure quoted in the Makefile is the whole transport module. Only
part of it has any claim on common memory, and the split is at the same ISR
boundary as items 2 and 3:

```text
F680h-F7A8h   297 bytes   foreground -> bank 7
F7A9h-F7D4h    44 bytes   vdrip_rx_sink + raw-callback trampoline -> common
F7D5h-F90Eh   313 bytes   parser and packet dispatch -> common, today
```

The parser is common-resident only because `vdrip_rx_sink` calls
`vdrip_parse_byte` inline rather than enqueuing the byte — its own header says
*"ISR-safe: bounded byte parsing/queue dispatch."* That is also a standing
departure from the project's SIO rule, which says the sink enqueues and the
foreground parses. Making the sink a true sink would leave roughly 44 bytes plus
a receive queue in common and move the other 610 to bank 7.

Two corrections to the story recorded in the Makefile:

- **The serial console tee is not one of the colliders.** `cbios_sercon.asm` is
  guarded by `.ifeq VDRIP_TRANSPORT_LINKED`, so it is not linked in a VDrip
  build at all, and `F830h-F957h` is already free in exactly the configuration
  that needs it. A real link of `CONSOLE=vdrip` reports collisions only at
  `F680h-F712h` (tail of the crossing gates, near `bank7_ch` and `bank7_ex`) and
  `F730h-F81Dh` (interrupt dispatch, near `ctc0_isr` and `irq_ff_u`). Nothing
  above `F81Dh` collides.
- **The VDrip storage backend is not competing for common memory.** It registers
  no sink and has no ISR entry; it is driven from the storage facade in the
  foreground, so all 356 bytes of it belong in bank 7. The
  `649 + 41 + 356 = 1046` arithmetic measures a slot that was only ever a
  common-memory slot because of where the flat design put slot 5.

So restoring `CONSOLE=vdrip` needs no relocation work and no new arithmetic: it
needs the transport split at `F7A9h`, which is the same operation as items 2 and
3, and a declared home for the 357-byte ISR tail. Section 7 provides that home.

---

## 5. The relocation problem

Items 4-8 above are not currently expressible. Every module is assembled as:

```asm
	.area CODE (ABS)
	.org CBIOS_DRIVER_SLOT0_BASE
```

`ABS` plus `.org` bakes the address at assembly time, so a driver is bound to
one location. Slot assignment is a source edit, combinations have to be verified
by hand, and two drivers that could each fit somewhere cannot be swapped without
recomputing a chain of derived constants.

Half the prerequisite for fixing this is already done: the facades bind drivers
by neutral name — `console_backend_*`, `stg_a_*` — so a driver is already
addressed by contract rather than by location. Relocation is the other half.

### The toolchain already supports it

`sdldz80` advertises:

```text
Relocation:
  -b   area base address = expression
```

which is the standard ASxxxx mechanism and is exactly "the build system rewrites
the origins." Give each driver its own relocatable area and drop its `.org`:

```asm
	.area DRV_CONSOLE (REL)
```

then place it at link time from the Makefile:

```sh
sdldz80 -i firmware.ihx firmware.rel -b DRV_CONSOLE=0x4800 ...
```

Slot assignment becomes a link-time decision. The same driver object goes into
any slot large enough to hold it, and the slot map becomes data in the build
rather than constants duplicated across sources.

### What it costs — measured, not estimated

This was attempted. Two of the three things predicted here were wrong.

- **Symbol extraction does not move to the linker map.** The ASxxxx symbol table
  truncates names to eight characters: 622 truncated, 285 of them ambiguous,
  with `fat_nati` appearing 79 times and nine distinct `sio_core*` symbols
  collapsing to `sio_core`. The map cannot identify a symbol. The correct source
  is the linker's *updated listing*, `sdldz80 -u`, which rewrites the `.lst` as
  `.rst` with resolved addresses and full names. It is a drop-in —
  `parse_listing` needs no change (2016 symbols from each, zero differing) —
  so this is far cheaper than predicted. **Done.**
- **`check_overlap.py` is unaffected**, as predicted. It reads emitted bytes
  from the linked `.ihx`, after placement.
- **Mixed `ABS` and `REL` is *not* workable in this build.** This was the
  prediction that mattered and it is false. Converting one 164-byte driver to
  `.area DRV_STORAGE_A (REL)` places it correctly with
  `-b DRV_STORAGE_A=0x4330`, but the REL attribute propagates into the
  auto-numbered areas that `.org` creates after it, and the linker then chains
  them consecutively instead of honouring their origins:

  ```text
  original build      59 areas, ALL ABS, 0 REL
  one REL area added  29 areas became REL
                      WORK1d  43D4h  24 607 bytes (REL,CON)
                      WORK1f 10505h  65 093 bytes (REL,CON)
  ```

  The image runs past 64 KiB and `makebin` fails. In a single translation unit
  whose layout is ~59 `.org` directives, relocatable and absolute areas cannot
  coexist. One REL area contaminates everything following it.
- **Relocation does not decide residency**, as predicted. It lets a driver go
  anywhere it fits; it does not say whether it may leave common memory.

A prerequisite discovered on the way, and worth doing regardless: seven `.org`
directives inherited whatever area happened to be current instead of declaring
one. Harmless while everything is ABS, fatal with any REL area. They are
explicit now.

### The consequence

**Relocation is deferred, and it is a source-organization change, not a layout
change.** REL areas work the way they are meant to when each driver is its own
translation unit assembled to its own `.rel` — which is precisely what the
directory structure in section 8 sets up. Until the sources are split that way,
`-b` placement is unavailable.

Nothing else depends on it. Fixed slots are declared bases and ceilings, which
`ABS` already provides; the bank-7 regions added while moving the SIO services
and the serial console tee demonstrate the pattern. Relocation only makes
*changing* a slot assignment cheaper, so it belongs with the work that makes it
possible.

### Status

Items 1-3 of that sequence are done and confirmed on hardware; see
`docs/memory-model-implementation-plan.md` for the execution log. Symbol
extraction now reads `build/firmware.rst`, the banner printer is in bank 7, and
the SIO core, the serial console tee and the VDrip transport are each split at
their ISR boundary. 460 bytes returned to common memory.

Converting drivers to relocatable areas is **deferred to the source
reorganization** (section 8.5, step 6) for the reason above: it needs one
translation unit per driver, which is what that reorganization creates.

---

## 6. Organizing common memory

Sections 3 and 4 say what should leave common memory. This section says what the
remainder should look like, because reclaiming 545 bytes into the current
arrangement produces three more holes rather than usable room.

### 6.1 The problem, measured

```text
17 OS code regions in common
203 bytes free in total
 39 bytes = the largest single hole
 16 of 17 holes are under 32 bytes
```

There are 203 free bytes and nothing larger than 39 bytes can be placed in them.
Two structural causes, both visible in the declarations:

**Every region's ceiling is its neighbour's floor.** `BIOS tables` is limited by
`CBIOS_BANKING_CODE_BASE`, `Banking services` by `CBIOS_SPARE_CODE_BASE`, and so
on down the chain. No region has headroom of its own; its "free" column is
whatever its author left before the next thing began. This is exactly the card
castle the driver-slot comment says slots exist to prevent — common memory never
got slots.

**Code and data alternate three times.** `EC00h` code, `F958h` data, `FC98h`
code, `FD00h` data, `FF60h` code. The interrupt subsystem is spread over six
addresses: dispatch `F730h`, policy `FC98h`, CTC mapping `FCE0h`, registration
`FF60h`, vector page `FD00h`, ISR stack `FE82h`.

### 6.2 What actually constrains placement

Only two things:

| Constraint | Kind |
|---|---|
| IM2 vector page plus its guard byte is 257 bytes and must be 256-byte aligned | hardware; the location is free and `I` follows from it |
| stacks live at the top and grow down | direction |

Everything else that looks fixed is a *consumer set*, and the build already
derives rather than duplicates each one:

| Address | What follows it | How |
|---|---|---|
| `FBASE` / BDOS serial number | page zero `0006h`; ZSDOS's `CCPLO`/`CCPHI` | written by the BIOS at boot; derived by `gen_zsdos_bios.py` from the linker map |
| BIOS jump table | the ZCPR2 build | `CBIOS_BASE_ADDR` extracted from `cbios_defs.inc` by the Makefile |
| IOC diag record | the CP/M utilities | mirrored in `../Utilities/src/ioc_diag_record.inc`, and `check_diag_record.py` fails the build on drift |
| IM2 page | the `I` register value | derived from the page address |

Moving any of these is a coupled release, in the same sense as a drive-map
change — not an excavation.

### 6.3 Two entity types, two growth directions

Common memory holds **code** and **state**; stacks are state. Code grows up from
the bottom of the OS's share, state grows down from the top, and the free space
is the single block between them.

```text
FFFFh  +==========================================+
       |  STATE — grows DOWN                      |
       |    stacks: facade, gate, ISR             |
       |    BIOS runtime state                    |
       |    IM2 vector page + guard (256-aligned) |
       |    facade copies                         |
       |    staging buffer                        |
       +------------------------------------------+
       |                                          |
       |   HEADROOM — the only free space in      |
       |   common; one number the build reports   |
       |                                          |
       +------------------------------------------+
       |  Z4  common driver slots — ISR tails     |
       |  Z3  interrupt                           |
       |  CODE — grows UP    Z2  crossing         |
       |                     Z1  ABI surface      |
EC00h  +==========================================+
       |  E400h-EBFFh  CCP — a user program       |
       |  E000h-E3FFh  application cross-bank code|
E000h  +==========================================+
```

**The bottom of the OS's share is `EC00h`, and the TPA is not negotiable.**
`E000h-EBFFh` stays application-owned: the interrupt-callback reservation and
the CCP, both inside the transient program area, which remains `0100h-EC05h` at
58.8 KiB. Starting the OS code run lower would reclaim the CCP's 2 KiB of common
at the cost of TPA and of making the CCP per-bank. That trade is rejected: it
spends application address space to buy operating-system address space, which is
the trade the banked design exists to avoid.

Z1 sits at the bottom deliberately. The ABI surface is what changes least, so it
anchors the run and everything above it can shift without disturbing a published
address.

### 6.4 The zones

| Zone | Holds | Why it is common |
|---|---|---|
| **Z1 ABI surface** | facade entry and `FBASE`, BIOS jump table, Zephyr extension table, IOC diag record, transport level byte | addresses are contractual |
| **Z2 Crossing** | facade body, native file gate, crossing layer, crossing gates, banking services, SIO ownership return | changes the memory mode, or stages caller objects |
| **Z3 Interrupt** | dispatch, IRQ policy, CTC channel mapping, IRQ registration, CTC reset | reached from an interrupt |
| **Z4 Common driver slots** | the ISR-reachable tail of the linked console driver — SERCON's sink, or the VDrip sink and parser | driver code that an interrupt reaches |
| **Z5 State** | staging buffer, facade copies, IM2 page, BIOS runtime state, the three stacks | touched by an ISR, *is* the mode transition, or dereferenced by an application in mode 10 |

Z4 is the piece that does not exist today, and its absence is why SERCON ended
up with one byte of slack and why the VDrip transport has nowhere to go. Sized
for the largest ISR tail across configurations — 357 bytes as VDrip is written,
85 for SERCON — a 384-byte Z4 makes any console driver's sink a declared
placement that the build validates, instead of a hole to be found.

### 6.5 What it comes to

For the default build, with items 1-3 of section 4 carried out:

```text
OS common (EC00h-FFFFh)        5120
  code, today                  3477
  code, after moving 545       2932
  state                        1440
  contiguous headroom           748
  less a 384-byte Z4            364
```

That is the arithmetic if the state block packs densely. It does not. The IM2
vector page must sit on a 256-byte boundary with its guard byte immediately
after, which strands about 96 bytes inside the state block, so the realistic
outcome is **~267 bytes contiguous plus ~96 usable only by state** — still
better than seventeen crumbs whose largest is 39, but not one clean block.

The TPA is untouched either way, and the VDrip ISR tail does not depend on any
of this: it lives in Z4, which is reserved at 384 bytes for exactly that.

**Contiguity is deferred.** What the zones actually buy — a build that refuses to
let an entity sit in a memory class its kind forbids — does not require them to
occupy disjoint address ranges. That check is implemented and enforcing;
consolidating the ranges is section 8.5, step 7.

### 6.6 Enforcement

The scheme is only worth having if the build maintains it. `Region` in
`generate_memory_docs.py` now carries a `zone`, every one of the 34 regions
declares one, and the build refuses a region whose zone is not permitted in its
memory class:

```text
common   abi | crossing | interrupt | driver-isr
bank 7   core | driver | state | asset
```

`core` is absent from the common set deliberately — core defines contracts and
has no reason to be addressable under more than one latch state — and
`crossing`/`interrupt` are absent from bank 7 for the mirror reason. A driver
may appear in common only as `driver-isr`, which forces the question "which part
of this driver does an interrupt reach?" to be answered in the declaration.

Mutation-tested: tagging a common region `core`, tagging the SERCON sink as an
ordinary `driver`, and removing a zone entirely each fail the build with a named
error. This checks *classification*, not contiguity, and classification is what
stops the drift this document records.

The build already refuses overlapping bytes and over-limit regions. It has no
opinion about whether something belongs in common at all — which is precisely
how three modules came to live there unnoticed, and why the free space is in
crumbs. That check is the difference between an organized common region and one
that will need this analysis again in two years.

---

## 7. Sizing the driver slots

### 7.1 A driver is code *and* its private state

A slot holds both. That is what makes a slot a unit: moving a driver moves its
state with it, and a driver's footprint is one number rather than an
archaeology exercise.

Today only the V9958 console does this — its region at `4800h-5FFFh` is
described as "parser, renderer, cursor **and state**." The rest are scattered:

```text
SD backend     code 4000h-42FFh   DPH 6020h  ALV 6300h/6400h  DPH 6500h
                                  deblock line CC00h-CDFFh   tag CE00h
A: backend     code 4330h-43FFh   DPH 6000h  ALV 6100h
FAT            code 9000h-A7FFh   persistent state CE10h-D60Fh
HID            code 3D00h-3DFFh   state 3E00h-3FFFh          (adjacent)
```

Some of that is genuinely shared — the directory buffer at `6040h` serves every
drive and belongs to the storage core, not to a driver. But a driver's *own*
DPH, ALV, deblock line and persistent reservation are the driver's, and they
should travel with it.

This is the one place where bank 7 and common memory are organized
differently, and deliberately so. Common memory separates code from state
(section 6.3) because that state is shared infrastructure with no single owner:
stacks, the staging arena, the IM2 page. A bank-7 slot unites them because the
state has exactly one owner. Ownership decides the organization.

### 7.2 Two ways to stop the card castle

**Fixed slots.** Each driver gets a whole number of granules, sized with
deliberate headroom. The slack inside a slot is *reserved*, not leftover, so a
driver can grow without moving anything — which is precisely what a
neighbour-bounded region cannot promise.

**Packed end-to-end.** Relocatable areas and a build that lays drivers out
contiguously, recomputing every boundary. Nothing is hand-computed, so nothing
ripples: change a driver's size and the next build re-lays the map.

| | Fixed slots | Packed |
|---|---|---|
| wasted space | real, by design | none |
| addresses across builds | stable | every driver moves when any driver changes size |
| map/listing diffs between builds | meaningful | mostly noise |
| hardware debugging, monitor breakpoints | addresses hold | re-read the map each build |
| build complexity | today's build | needs the symbol-extraction change (section 5) |
| a driver outgrowing its allocation | build names the slot; reassign | absorbed silently |

The last row cuts both ways. Packing absorbing growth silently is convenient
until a driver doubles and nobody notices until bank 7 is full.

### 7.3 These are not really alternatives

Relocation is what makes a slot policy *maintainable*. Today, reassigning a slot
means editing `.org` directives and recomputing the derived constants that hang
off them by hand — which is exactly why nobody did it, and why eight drivers
ended up at ad-hoc addresses in the first place. With `-b AREA=addr` a slot map
becomes a table in the Makefile:

```make
SLOTS = DRV_CONSOLE=0x4800 DRV_STORAGE_A=0x4400 DRV_HID=0x4000 ...
```

Change one number, rebuild, done. The slot *policy* provides address stability
and reserved headroom; the relocation *mechanism* makes changing the policy
cheap.

With one precondition, established by measurement rather than assumption: `-b`
placement requires **one translation unit per driver**. In the present one-file
build a single REL area turns 29 of 59 areas relocatable and the image runs past
64 KiB (section 5). So the slot policy is available now, under `ABS` and `.org`;
the cheap-reassignment half of it arrives with the source split (section 8.5,
step 5). Adopting relocation and then packing everything end-to-end would throw
away the stability for a space saving this machine does not currently need.

Recommendation: fixed slots as the policy, relocation as the mechanism, and
packing held in reserve for the day bank 7 gets tight.

### 7.4 Granularity and what it costs

Bank 7 is 48 KiB visible. Committed today:

```text
ZSDOS                    4096      shared data 6000h-7FFFh  8192
core facades             1024      assets                   4096
runtime C000h-D60Fh      5648      unallocated              8688
                                   driver regions          17408
```

Against roughly **13.5 KiB** of driver code and state actually in use, plus the
842 bytes arriving from common memory (section 4: 545 reclaimed plus the
VDrip transport's 297). That leaves about
**26 KiB of slot space for 14.5 KiB of drivers — a ratio of 1.8**, so every
driver can be given comfortably more than it uses and the array still fits.

A single 1 KiB granule fits the large drivers and wastes most of a granule on
the small ones — HID is 243 bytes, the A: backend 164, the B: probe 23. Either a
512-byte granule, or two slot classes, packs the population better:

```text
granule 512B     FAT 13 used / allocate 18      console  7 / 12
                 SD   4 / 6                     cmd lane 3 / 4
                 A:   1 / 2                     HID      1 / 2
```

The choice is a tuning decision, not an architectural one. What matters is that
the allocation is declared, the headroom inside it is reserved rather than
inherited from a neighbour, and the build reports per-slot utilization so a
driver approaching its ceiling is visible before it collides — the way the qkz80
harness already reports the ISR stack high-water mark.

---

## 8. Source organization

The placement work above is hard to review partly because the tree does not say
what anything is. This section proposes a layout that matches the entities.

### 8.1 What the names say today

Twenty of twenty-seven live sources carry a `cbios_` prefix, and most are not
the CP/M BIOS:

| File | Actually is |
|---|---|
| `cbios_facade.asm` | the **BDOS** facade — `CALL 5`, not BIOS |
| `cbios_defs.inc` | the entire memory layout, 1698 lines — the address authority |
| `cbios_fat_layout.asm` | 3352 lines of FAT personality, FS2 client and native API — neither BIOS nor a layout |
| `cbios_bios_ext.asm` | says BIOS twice; it is the `VIDEO_SEND` entry — live, and section 3.2 says why |
| `cbios_xing.asm` | the crossing layer |

And nothing in any name or path distinguishes **core** from **driver**, or says
which memory class a file belongs to. `cbios_console.asm` is the facade and
`cbios_console_v9958.asm` is a driver; the names differ by a suffix.

### 8.2 Dead weight, verified

| Item | Evidence |
|---|---|
| `cpm22/` (vanilla CP/M 2.2 + patches) | `make -n image` never references it. The conversion rule at Makefile:267 exists, but nothing depends on `$(CPM22_ASXXXX_SRC)`. The banked OS assembles neither the stock CCP nor the stock BDOS. |
| `tools/convert_cpm22_asxxxx.py` | only consumer is that dead rule |
| Makefile lines 12, 127, 191, 267-268 | the same dead chain |
| `src/cbios_console_sio.asm`, 322 lines | not in `VALID_CONSOLES`; the only reference in the tree is a comment in `cbios_defs.inc:1681` |
| `src/vdrip_font.asm`, 17 lines | referenced by nothing |
| `src/msxfont.inc`, 107 lines | referenced by nothing |

One caveat before deleting `cpm22/DRI-LicenseAgreement.txt`: the ROM disk ships
stock DRI tools (PIP, STAT, ZSID, DUMP) from the Software volumes, so the
licensing question exists independently of this directory and should be settled
on its own terms. The patched CP/M source itself is preserved by git history.

### 8.3 Proposed layout

The directory is the declaration: the path answers *what is this, and where does
it run.*

```text
src/
  zephyr.asm                  assembly root: the include order and nothing else

  layout/
    memory.inc                was cbios_defs.inc — the address authority
    platform.inc              was platform_zephyr80.inc
    modes.inc                 was memory_modes.inc

  common/                     mapped in both modes; every byte costs TPA
    facade.asm                was cbios_facade.asm — the BDOS facade
    native_gate.asm           function 218 crossing
    native_stage.asm          caller staging
    crossing.asm              was cbios_xing.asm
    gates.asm                 was cbios_gate.asm
    irq.asm                   IM2 dispatch, policy, registration
    sio_isr.asm               ISR half, split out of sio_core.asm

  core/                       bank 7; defines the contracts
    boot.asm                  rom_copy.asm     banking.asm
    console.asm               the console facade and driver dispatch
    storage.asm               the storage facade and drive dispatcher
    video_send.asm            iocall.asm       sio.asm

  drivers/
    console/    v9958.asm  vdrip.asm  sercon.asm  hid_input.asm
    storage/    sd.asm  rom.asm  vdrip.asm  fat_personality.asm
    transport/  ioc_command.asm  vdrip.asm

  assets/
    font_cp850_6x8.inc
```

Three naming rules fall out:

1. **No `cbios_` prefix anywhere.** The directory carries that information, and
   it carries it accurately.
2. **A driver is named for what it is** — `v9958`, `sd`, `rom` — not for the
   contract it implements. `drivers/console/v9958.asm` already says both.
3. **`layout/` owns the address authority.** Nothing else declares addresses.

### 8.4 The path becomes checkable

Same theme as the `zone` field in section 6.6. `Region` gains a `source` field,
and the documentation generator asserts:

```text
a file under common/   may emit only into E000h-FFFFh
a file under core/     may emit only into bank 7
a file under drivers/  may emit only into bank 7, inside a declared slot
a file under drivers/<contract>/ must define that contract's neutral entry points
```

That makes the convention something the build enforces rather than something a
reviewer remembers — which matters, because the current arrangement is what a
reasonable person gets after five years of adding files next to similar files.

Note the dependency: **this check is only expressible once the mixed modules are
split.** `sio_core.asm`, `cbios_sercon.asm` and `vdrip_transport.asm` each span
both memory classes today, so no single directory is correct for them. The
section 4 splits and this reorganization are the same work seen from two sides.

### 8.5 Migration, in seven steps

1. **Delete the dead weight** (8.2). No behavior change; git keeps it.
2. **Pure moves and renames.** No content edits at all.
3. **Split the three mixed modules** (section 4, items 1-3).
4. **Placement and slots** (sections 6 and 7).
5. **Split the drivers into their own translation units,** and place them with
   `-b AREA=addr` at link time instead of `.org` in the source.

   This is the step that makes relocation possible, and it belongs here rather
   than in the memory-model work because it *is* a source-organization change.
   Measured: adding a single relocatable area to the present one-file build
   turns 29 of 59 areas REL and pushes the image past 64 KiB, because the REL
   attribute propagates into the auto-numbered areas that `.org` creates after
   it (section 5). REL areas behave correctly only when each driver assembles to
   its own `.rel`, which the `drivers/` directory above sets up.

   Prerequisite, already done: every `.org` declares its own `.area`. Seven of
   them used to inherit whichever area happened to be current.

   Order within this step: one `.rel` per driver first, verified byte-identical
   at its current address; then `-b` placement; then retire the numbered slot
   constants in favour of the declared regions.

6. **Make the zone ranges contiguous.** The zone *classification* is enforced
   already; what is deferred is making each zone occupy one disjoint address
   range, so the free space in common becomes a single block instead of the
   fragments it is today.

   This belongs here rather than in the memory-model work because it is a
   rewrite of `cbios_defs.inc` — which this reorganization renames to
   `layout/memory.inc` and is the natural moment to restructure it. Measured
   obstacles, so nobody re-discovers them:

   - sixteen code bases spread across ~900 lines, half expressed as
     `CBIOS_BASE + offset`, so they cannot be reordered independently until that
     expression is abandoned;
   - each wrapped in commentary explaining its current position, most of which
     becomes false on the move;
   - ~30 state constants including live vestigial aliases from the flat design
     (`CBIOS_SCRATCH_*`, `CBIOS_DRIVER_SLOT5_*`, `RESERVED_*`) that should be
     retired first, as their own byte-identical step;
   - the IM2 vector page has to move for the headroom to consolidate, which
     changes the `I` register value.

   Worth about 64 bytes of extra contiguous headroom over leaving it alone, so
   it is a tidiness change, not a capacity one. Schedule it for the value of
   having one reserved headroom number the build reports, not because anything
   needs the space.

7. **De-VDrip the console backend contract.** `console_backend_send_frame`
   takes a Virtual Drip packet type, and `VIDEO_SINGLE_PAYLOAD_MAX = 0x10` is a
   serial frame size. Every console backend must therefore speak a transport's
   vocabulary — including a future video card with no serial link on it. This
   is the only item on this list that changes an interface rather than an
   address, and it belongs here because it lands naturally when the console
   drivers move to `drivers/console/` in step 2. BDOS function 215 stays frozen;
   only the internal backend contract changes. The guide's section 15 carries
   the note for whoever writes the next video driver.

Step 2 has an unusually strong verification available: a pure rename **must
produce a byte-identical image**. The current baseline is

```text
build/zephyr80.bin   93975a652a703a6e0775965f67585069
build/firmware.bin   11c898d763cee7f150f0f4dacc02405e
build/bank7.bin      37ecc0babf7e19c9ac151d9eb6cb58a5
```

If step 2 changes a byte, something was edited that should not have been. Steps
3 and 4 do change addresses, which is why they come after the checkpoint.

The consumers to update in step 2 are known and few: the ~25 `RUNTIME_SRCS`
lines, the `sed` include-rewrite rules, four `src/cbios_defs.inc` references in
the Makefile and `check_diag_record.py`, and the `CBIOS_BASE_ADDR` extraction at
Makefile:306. The sibling mirror `../Utilities/src/ioc_diag_record.inc` mirrors
*content*, not a path, so it is unaffected.

### 8.6 What it buys a contributor

| Question | Answer becomes |
|---|---|
| "I want to write a driver for my video card" | `drivers/console/` — copy `v9958.asm` |
| "Where is the memory map declared?" | `layout/memory.inc`, and only there |
| "Is this core or a driver?" | the path |
| "Why is this change expensive?" | it touches `common/` |

The last row is the one that compounds. A diff under `common/` is costly by
construction — 8 KiB shared with every program — and a layout that makes that
visible in the file path gets it the scrutiny it deserves, without anyone having
to know the history.

---

## 9. Summary

| | Correct today | Needs moving |
|---|---|---|
| Core OS in bank 7 | facades, dispatchers, ZSDOS, assets | — |
| Private state in bank 7 | disk structures, buffers, stacks, caches | — |
| Drivers in slots | 1 of 9 (console) | 8 drivers into declared slots |
| Public state in common | IOC failure record, transport level, BIOS state | — |
| Not OS at all | `E000h-EBFFh`: callback reservation and the CCP, inside the TPA | — |
| Bank-switch-surviving code in common | facade, crossing, gates, IM2, IRQ, banking, SIO ISR, SERCON sink | 545 bytes that do not qualify |
| Source layout reflects the entities | — | the whole tree; 3 dead files and `cpm22/` to delete first |

The taxonomy holds. What it is missing is enforcement: nothing in the build
checks that an entity is in the address class its kind requires, which is why
three modules drifted without anyone noticing and why the free space in common
is in crumbs. Two changes turn the placement rule into something the build
asserts rather than something a reviewer has to remember — a `zone` field on
each common region (section 6.6), and, once the drivers are separate translation
units, relocatable areas so a slot assignment is a link-time decision
(section 8.5, step 5).

The slots themselves stay fixed-size and carry each driver's private state
alongside its code. Their internal slack is the point, not waste: it is what
lets a driver grow without moving anything else, which is the one guarantee a
neighbour-bounded region cannot make.

Section 8 applies the same taxonomy to the source tree, so that the entity a
file belongs to is visible in its path rather than inferred from its history.
