# Zephyr-80 MAME — Bring-Up Fix Log

Chronicles the changes that took the `zephyr80` machine from "loads a placeholder
ROM" to "runs the real 128 KiB CP/M firmware and drives the SIO0/B console + VDrip
link". All changes are in `src/mame/pbitz/` (`zephyr80.cpp`, `zephyr80_map.h`) plus
one build-script change in `scripts/target/mame/pbitz.lua`.

The authoritative hardware references used throughout:

- `HDL/WinCUPL/src/MEM_DECODER.pld` (Rev 09) — CPU-board memory decode.
- `HDL/WinCUPL/src/IO_DECODER.pld` (Rev 03) — I/O port decode.
- `HOST/CPM2.2/src/platform_zephyr80.inc` — firmware's port/latch/bit definitions.
- `HOST/CPM2.2/src/boot_shadow_copy.asm`, `sio_core.asm`, `cbios_boot.asm`,
  `vdrip_transport.asm` — the firmware itself.

---

## Part A — Make the firmware run (memory decode)

### Symptom
The 128 KiB firmware's reset vector is `JP $DA48`, but the emulator halted
immediately: it mapped ROM only at `$0000-$5FFF`, so `$DA48` fetched from
unmapped RAM. Nothing ran.

### Root cause
The emulator's memory decode was an early approximation that did not match
`MEM_DECODER.pld` Rev 09. Three things were missing:

1. **High ROM window.** Rev 09 makes ROM readable in **both** the BIOS window
   (`$0000-$5FFF`) **and** the high common window `SAFE_RAM` (`$C000-$FFFF`) in
   normal mode: `BOOT_ROM = BIOS_RANGE # SAFE_RAM`. `$DA48` lives in `SAFE_RAM`.
2. **ROM paging.** The banking latch's high three bits select a ROM page
   (`ROM A16-A18`); the emulator ignored them.
3. **Force-bank-0 region.** Rev 09 forces the high 16 KiB to SRAM bank 0 when
   shadow or ROM-disabled: `FORCE_BANK0 = SAFE_RAM & (ROM_DIS # RAM_SHADOW)`.
   The old code forced the *low* `$0000-$1FFF` instead.

The latch bit layout (I/O port `$00`, a 74HC273) comes from the firmware's
`platform_zephyr80.inc`:

    D0-D2 = SRAM bank 0-7      (RAM A16-A18)
    D3    = shadow / copy mode
    D4    = ROM disable
    D5-D7 = ROM page 0-7       (ROM A16-A18)

### Fix
- `mem_r` implements Rev 09's `ROM_CS` exactly; `mem_w` writes SRAM
  unconditionally (Rev 09's `SRAM_CS` has an unconditional `WR` term).
- Added `rom_r()` with ROM paging: `rom_addr = (rom_page << 16) | (A0..A15)`.
- `selected_ram_bank()` implements the `SAFE_RAM & (ROM_DIS | RAM_SHADOW)` force.
- Latch layout and `SAFE_RAM`/ROM-page constants added to `zephyr80_map.h`;
  `ROM_LOAD` now loads the full 128 KiB into a 512 KiB region.
- Removed the non-Rev-09 `PROG`/`CART` decode paths.

### Verified
An I/O write-tap on the bank latch (`$00`) shows the firmware executing the exact
`boot_shadow_copy.asm` sequence:

    08  29 4A 6B 8C AD CE EF  10

i.e. copy-mode + pages 1-7 into banks 1-7 (`(N<<5)|SHADOW|N`), then ROM-disable and
continue from SRAM bank 0 into the CBIOS.

---

## Part B — Make the console work (SIO register order, interrupts, baud)

### Symptom
After Part A the firmware boots into the CBIOS, but the SIO0/B VDrip console was
dead — the proxy's `PROXY_READY` sequence did nothing.

### Root causes & fixes

1. **SIO register order was wrong (the big one).**
   The firmware addresses each SIO as `ba_cd` (channel on A1, data/control on A0):
   `SIOA_DATA=$20, SIOA_CTRL=$21, SIOB_DATA=$22, SIOB_CTRL=$23`. The emulator used
   MAME's `cd_ba` accessor, which swaps `$21`/`$22` — so every WR2/data write hit
   the wrong channel and the whole console init was scrambled.
   **Fix:** `sio0_r/w` and `sio1_r/w` now use `ba_cd_r/w`; the register-offset
   constants in `zephyr80_map.h` were corrected (A data / A ctrl / B data / B ctrl).

2. **No IM2 interrupt daisy chain.**
   The console RX is interrupt-driven: `I = 0xDD`, SIO0/B `WR2 = 0x10`, so RX must
   vector to `0xDD10` (`sio_core_isr`). The old code used a wired-OR IRQ with no
   vectoring, so the interrupt could never reach the ISR.
   **Fix:** added `Z80CTC` at `$40-$43` and a real IM2 daisy chain
   (`z80_daisy_config { ctc, sio0, sio1 }`, `set_daisy_config`), with each device's
   interrupt callback wired to `INPUT_LINE_IRQ0`. The daisy supplies the vector on
   interrupt-acknowledge.

3. **Console baud was 9600, hardware is 115200.**
   The firmware programs SIO0/B WR4 for a ×16 clock at 115200.
   **Fix:** SIO0/B clock set to `115200 × 16`; the `sio0b_rs232` pty/loopback
   options default to 115200 (`DEVICE_INPUT_DEFAULTS`) so both ends match. Per the
   hardware, the console baud is fixed (not CTC-derived); only the **user** channel
   (SIO0/A) takes its clock from the CTC (`ctc.zc_callback<0>()` → SIO0/A rx/tx).

### Verified
An I/O trace of the boot shows the firmware now programming the SIO correctly via
the right ports: WR2 vector `0x10`, WR1 `0x18` (Rx int, all chars, no parity
vector), WR9 MIE `0x08`, RTS asserted — then entering the `PROXY_READY` wait.
End-to-end interactive console (CP/M reading storage over VDrip) confirmed against
the real host-side VDrip proxy.

### PROXY_READY frame (for reference)
VDrip framing is `A5 5A LEN_LO LEN_HI TYPE PAYLOAD…` (LEN = 16-bit LE count of
TYPE+PAYLOAD). The readiness packet the proxy sends is `PACKET_PROXY_READY = 0x0A`
with zero payload:

    A5 5A 01 00 0A

The proxy must open the pty in **raw** mode — the link is binary.

---

## Open items / assumptions to confirm against hardware

- **Daisy priority order** `{ ctc, sio0, sio1 }` is the conventional Z80 arrangement
  but the true IEI/IEO order is a hardware detail. It is functionally moot today
  (the firmware disables the CTC and polls SIO1; only SIO0/B interrupts).
- **CTC clock crystal** and the exact CTC-channel → user-baud / tick assignment are
  placeholders; the firmware only disables the CTC at boot.
- **`/DCD` tied low on SIO0/B.** On real hardware `/DCD` is hardwired asserted so
  the WR3 Auto-Enables receiver is always enabled. In MAME the pty asserts DCD, but
  note the interaction between the SIO channel reset and the latched DCD state if a
  future RX-gating issue appears.
