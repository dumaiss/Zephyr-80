# Zephyr-80 — MAME Bring-Up Plan

*Working spec, distilled from design discussion. Intended as input to a code-tree
gap analysis. Nothing here is external fact unless cited in §10.*

---

## 0. How to use this document

Hand this to Claude Code alongside the MAME source tree. Ask it to:

1. **Inventory** what exists against each numbered item below.
2. **Classify** each as **Present / Partial / Missing**, citing the file(s) and
   class/method names it found.
3. **Flag deviations** from the design invariants in §6 (these are the load-bearing
   rules; a violation is worth calling out even if code "works").
4. **Report open dependencies**: which blocking inputs (§8) and verification items
   (§9) are still unresolved in the code.
5. Output a short **"where we are"** summary + a suggested next-step ordering.

The device architecture (§5) is the part most likely to be under-built or built
differently — spend analysis effort there.

---

## 1. Approach & rationale

- **Tool: MAME.** Chosen for (a) device reuse across the Coffee Series lineup —
  every planned CPU has a core — and (b) mature, accurate stock devices (especially
  the V9958) so that CP/M video code stabilized against the emulator is trustworthy
  for the real silicon. Fidelity of the emulated peripheral is the point, not a
  side benefit.
- **Behavior-only, not cycle-accurate.** Stock devices give accuracy for free;
  "behavioral" applies only to custom glue (the IO controller / bridge). We are not
  chasing cycle exactness.
- **Everything is a MAME `device_t`.** "Driver" in MAME = the top-level machine
  definition (the whole Zephyr-80). Our custom parts are *devices*, not drivers.

---

## 2. Target environment (MAME 0.289, docs dated 2026-07-01 — verify current)

- Systems live in per-manufacturer/system folders under `src/mame/<group>/`
  (the old flat `drivers/ machine/ video/ audio/` split is gone).
- Drivers registered in `src/mame/mame.lst` via `@source:` directives.
- Build a subset with e.g.
  `make SUBTARGET=zephyr SOURCES=src/mame/<group>/zephyr80.cpp REGENIE=1`.
- **Check:** confirm the folder chosen for these files and that it's wired into
  `mame.lst`.

---

## 3. Milestones (staging)

| ID | Scope | Unblocks |
|----|-------|----------|
| **M1** | Z80 + 512 KiB banking + CTC + one SIO channel exposed to host serial | CP/M over serial console; **video + storage via existing host VDrip tooling** — a fully usable dev platform with *no* video/sound chip emulated |
| **M2** | V9958 (stock `v9958_device`) | Migrate video from VDrip-over-serial to native emulated card; stabilize the real V9958 CP/M driver |
| **M3** | 4× SN76489 (verify `SN76489A` variant) + AD7801 DAC | PETSCII Robots audio, GameOS sound |
| **M4** | Native IO controller device (two-layer, §5) replacing the host-side VDrip endpoint: storage + HID + command/bulk channels | Self-contained machine; no external host tooling required |

**Key M1 insight:** because the BIOS ships video (and dev-time storage) as VDrip
packets over the serial link to a host-side TMS9918 emulator + VNC, exposing one SIO
channel to the host lets the **unmodified BIOS VDrip driver** run. M1 alone is a
usable machine. M4 later replaces that host endpoint with an in-MAME device.

The M1 host-serial console path and the M4 native IO-controller device attach to the
*same kind of SIO port* but are different things — don't conflate them.

---

## 4. M1 detail

### 4.1 CPU + memory
- `Z80(config, m_maincpu, XTAL)`; `set_addrmap(AS_PROGRAM, &mem_map)` and
  `(AS_IO, &io_map)`.
- **512 KiB banking.** Target is the existing banked model (512 KiB / 8 banks /
  16 KiB common area, `LAUNCH` cross-bank primitive). Implement with a
  `memory_view` for the boot-ROM → all-RAM overlay plus `memory_bank` entries for
  the paged windows; the bank-register write handler decodes from the CPU-board PLD.
- `memory_view` vs `address_map_bank_device` is decided by the reset-overlay logic.
- **Blocked on** the CPU-board address-decode PLD + bank-register PLD (§8). CUPL
  product terms map almost 1:1 onto address-map ranges + the bank write handler.

### 4.2 Serial console to host
- Attach an `rs232_port_device` to the console SIO channel in the machine config.
- At runtime: `-<port> null_modem -bitb socket.127.0.0.1:1234` (TCP, for the VDrip
  host tool), or `-<port> pty` (pseudo-terminal on *nix), or `-bitb file.txt`
  (capture). `null_modem` does behavioral stream↔baud with RTS flow control by
  default; baud set in Machine Configuration.
- *Confidence: high on the mechanism; medium that VDrip runs unmodified — loosen
  the driver if it assumes tight handshake/flow-control timing.*

### 4.3 CTC + SIO + interrupts
- `Z80CTC` + two `Z80SIO`.
- **IM2 daisy chain:** a `z80_daisy_config` array listing CTC + SIOs in hardware
  priority order; `m_maincpu->set_daisy_config(...)`.
- CTC channel outputs → SIO baud inputs (`zc_callback` → `rxca_w`/`txca_w`). The
  CTC-owned sim/music tick is another `zc_callback` routed to an interrupt.
- **Blocked on** IO-controller decode PLD (SIO/CTC port addresses) + the interrupt
  topology / daisy priority order (§8).

---

## 5. IO controller device architecture (two layers)

This is the native endpoint (M4) but its interface should be designed now. It is
**not** an RX660 emulation — see §7. It is a command-protocol endpoint; the RX660 is
an implementation note.

### 5.1 Layer 1 — Core device (stable, shared)
- Owns the **command interpreter** (a byte-fed packet parser) and its downstream
  devices, instantiated as children via `device_add_mconfig()`: storage
  (`harddisk_image_device` or a `generic_slot` block device) and HID.
- **Two channels, each a method-pair — not one tagged stream.** Only the command
  channel carries an interrupt (unsolicited traffic):

  **Command channel**
  - down: `command_w(u8)`, `command_can_accept()`
  - up: `out_command_irq` (a `devcb_write_line`) + `command_r()` pull

  **Bulk channel**
  - down: `bulk_w(u8)`, `bulk_can_accept()`
  - up: `out_bulk_ready` (a plain line, **no IRQ**) + `bulk_r()` pull

- The core sees two ports only. It never learns "which channel/which chip" —
  demux stays in the glue.
- **Personalities** (derived from a shared base holding ingest/FIFO/status/handshake):
  - IO-controller personality → storage/HID effects
  - VDP personality → framebuffer/register effects
  - Lean toward **two derived devices** over one mode-flagged device (effect
    backends are completely different).

### 5.2 Layer 2 — Glue device (variable, one per transport)
- Where framing / deframing / sync-hunt / handshake with the stock glue chip happens.
- **Owns its core as a subdevice** (a composite, e.g. `coffee_io_sio` news up the
  core + the SIO adapter) and binds the core's `out_command_irq` in its own
  `device_add_mconfig()`.
- **Downstream (glue → core): direct method calls**, not devcb (fixed parent→child
  ownership makes devcb unnecessary ceremony).
- **SIO variant (Zephyr-80):** implements `device_serial_interface`; wires to a
  `z80sio` channel exactly like a `null_modem` endpoint (SIO `out_txd` → glue rx;
  glue tx → SIO `rxd`); deframes; calls the core.
- **VIA variant (future machines):** port/handshake handlers wired to `via6522`
  callbacks; latches a byte on the active CA2/CB1 edge; same downstream calls.

### 5.3 The seam contract (core ⇄ glue)
- **Direction asymmetry is deliberate:** downstream = direct calls; upstream =
  abstract devcb (`out_command_irq`, `out_bulk_ready`). The core must never know the
  glue's concrete type; the dependency points glue → core only.
- **Return path is pull-on-signal, not push.** The core signals "I have data"
  (command IRQ line / bulk ready line); the glue **pulls** with `command_r()` /
  `bulk_r()` at its own transport pace. The core never pushes — it stays ignorant of
  baud rate / handshake timing.
- **Interrupt realization is the glue's job.** `out_command_irq` binds to the
  **glue, never to the CPU** — the core never touches the daisy chain. Flow: core
  asserts `out_command_irq` → glue pulls response bytes → glue injects them into the
  SIO's receive path → the SIO raises its own RX interrupt through the daisy chain
  already wired in §4.3. On a VIA machine the same core IRQ instead drives a
  CA1/CB1 edge / the VIA's interrupt.

### 5.4 Framing split (critical)
- **Transport framing** (SIO sync bytes / hunt mode; VIA handshake edges) → **glue**.
- **Command framing** (opcodes / args / length / checksum) → **core**. Stable.
- Bytes crossing the seam are payload, in order, transport framing already stripped.
- **Decision: in-band command framing** (length-prefix or in-payload delimiter),
  **not** the SIO's out-of-band sync/hunt as a delimiter. The VIA machines have no
  sync/hunt equivalent, so out-of-band framing would force every glue to synthesize
  one. In-band keeps the core parser truly transport-agnostic and every glue dumb.

---

## 6. Design invariants (flag any deviation)

1. Core is transport-agnostic; it never references a glue/chip concrete type.
2. Dependency direction is glue → core only.
3. Downstream = direct calls; upstream = devcb lines. No pushing bytes from core.
4. `out_command_irq` binds to glue, not CPU. Core never touches the daisy chain.
5. Command framing lives in the core; transport framing lives in the glue.
6. Framing is in-band (transport-neutral), not SIO-sync-derived.
7. Command and bulk are separate method-pairs; only command has an IRQ.
8. RX660 internals (instruction set, on-chip peripherals, firmware algorithms) are
   **out of scope** for the device — only the boundary contract is modeled.

---

## 7. RX660 stance (scope boundary)

- MAME has **no Renesas RX core** (its Renesas coverage is H8/H8S and SuperH).
  Do not emulate the RX660 as a CPU.
- The IO controller is a **command-protocol endpoint** ("a thing on the far end of
  the SIO that processes commands"). Model only: ingress packet format, egress
  effects (storage r/w, HID injection, serial passthrough; framebuffer effects on
  the VDP side), and host-synchronized state (FIFO full/empty, busy/ready, ping-pong
  ownership on the VDP side, ack handshake).
- Test RX660 **firmware** separately (Renesas e² studio RXv3 ISS, or real silicon via
  E2/E2 Lite). RX660 is an RXv3 part; QEMU's RX target is RX62N/RXv1 with RX62N
  peripherals, so it does not model this MCU.
- Later payoff: the behavioral core can act as a **conformance oracle** — run the
  same command stream through it and the real firmware, diff the framebuffer/IO
  effects.

---

## 8. Blocking inputs still needed (from Sebastien)

- **CPU-board address-decode PLD** + **bank-register PLD** → `mem_map`/`io_map` +
  banking decode.
- **IO-controller decode PLD** → SIO/CTC port addresses.
- **Interrupt topology / daisy priority order** (and where the V9958 VBlank IRQ lands
  — needed at M2).
- **Command/bulk packet format spec** (the protocol at the connector) → the core's
  packet parser and opcode table.

Claude Code: report which of these are already encoded (as constants, address maps,
or comments) in the tree vs. still absent.

---

## 9. Open verification items (confirm against MAME source, not memory)

- **`z80sio` external-sync framing:** how much sync framing the device exposes vs.
  what the glue must reassemble. *(medium confidence)*
- **`z80sio` receive-injection API:** the exact call the glue uses to present an
  unsolicited byte as received RX data upstream. *(medium confidence)*
- **`SN76489A` vs `SN76489`** variant class name (M3) — noise/clock divider differs.
- Later machines: confirm `arm920t` core presence (Pacamara-920) and `hd63484`
  device (Nitro-30 VDP) class names.

---

## 10. Immediate next code artifact (skeleton)

Draft, as the M1/M4 stand-in:

- **Core device**: the four method-pairs from §5.1 (`command_w`/`command_can_accept`
  + `out_command_irq` + `command_r`; `bulk_w`/`bulk_can_accept` + `out_bulk_ready` +
  `bulk_r`), a byte-fed packet-parser stub, and storage/HID child stubs.
- **Abstract transport-adapter seam.**
- **`coffee_io_sio` glue**: owns the core, implements `device_serial_interface`,
  wires to a `z80sio` channel, binds `out_command_irq`, injects RX for the upstream
  path.
- **`via6522` glue stub**: so the seam is exercised by two transports from day one.
- **v0 behavior**: ACK everything + model "FIFO not full" + the sync/ack handshake so
  the driver runs without deadlocking — unblocks GameOS / CP/M dev before opcodes are
  filled in.

---

## Sources

- MAME 0.289 build/subtarget + source layout (docs dated 2026-07-01):
  <https://docs.mamedev.org/initialsetup/compilingmame.html>
- Host serial (null_modem / bitbanger socket + pty, RTS flow-control default):
  <https://blog.thestateofme.com/2022/05/25/attaching-a-terminal-emulator-to-a-mame-serial-port/>;
  <https://wahki.mameau.com/index.php?title=Guides:MAME_-_driver_-_apple2p>
- No RX core in MAME (CPU tree = H8/SH/6809/etc.), viewed 2026-07-08:
  <https://github.com/mamedev/mame/tree/master/src/devices/cpu>
- QEMU RX target = RX62N/RXv1: <https://www.qemu.org/docs/master/system/target-rx.html>
- RXv3 = RX66x generation, E2 debug support:
  <https://www.renesas.com/en/software-tool/e2-emulator-rte0t00020kce00000r>

*Confidence: high on §2 layout, §7 (no RX core), host-serial mechanism; medium on
VDrip-unmodified and the two `z80sio` items in §9; banking geometry is from the
hardware design and pinned exactly only once the PLDs (§8) are in hand.*
