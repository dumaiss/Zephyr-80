# LunchCrema V9958 Direct-Console Bring-Up

This document records the hardware settings required when a CP/M console
driver talks directly to the LunchCrema V9958 card. It does not change the
Virtual Drip packet protocol or the emulated V9958 backend.

These settings were validated on Zephyr-80 hardware with a 10 MHz Z80 and four
64K×4 DRAMs providing 128 KiB of VDP VRAM.

## Non-negotiable settings

| Item | Required setting | Reason |
|---|---:|---|
| V9958 R#8 `VR` | `1` (`R#8 = 08h` with other mode-2 bits clear) | Selects the installed 64K×4 DRAM organization. |
| V9958 R#25 `WTE` | `1` (`R#25 = 04h` with other added features clear) | Enables native V9958 WAIT generation. |
| V9958 R#25 `VDS` | `0` | Keeps pin 8 as CPUCLK for the U11 porch state machine. |
| LunchCrema `/WS_EN` | Low after initialization | Enables the U11 front-porch WAIT generator. |

Do not leave R#8 at its reset value of `00h`. That selects the 16K-DRAM
addressing scheme. On the production 64K×4 hardware this caused addresses
`00000h` and `08000h` to alias, so later bitmap rows overwrote earlier rows.
The observed diagnostic signature was `exp=12 act=56 @0123` after writing
`56h` at `08123h`.

## I/O address mapping

LunchCrema connects V9958 MODE0 to CPU A0 and MODE1 to CPU A1:

| Address | Function |
|---:|---|
| `A0h` | VDP VRAM data |
| `A1h` | VDP command write / status read |
| `A2h` | VDP palette data |
| `A3h` | VDP indirect-register data |
| `A4h` | LunchCrema configuration latch write |

The configuration latch captures D0 and D1 together:

- D0 selects the VDP interrupt route. The driver must keep a software shadow
  and preserve the selected value on every configuration write.
- D1 drives physical `/WS_EN`: D1=0 enables the U11 porch; D1=1 bypasses only
  the porch.

The current U11 equations always pass native V9958 `/WAIT` during a VDP
transaction. Raising `/WS_EN` does **not** bypass native WAIT. With D0 at its
reset/default value of zero, write `02h` to `A4h` for porch off and `00h` for
porch on. If D0 is changed, preserve it in both values.

## Required initialization order

Use software-paced VDP control writes during bootstrap. The tested sequence is:

1. Write the configuration latch with D1=1 to disable the PLD porch while
   preserving D0.
2. Write `00h` to R#25, explicitly establishing `WTE=0` and `VDS=0`.
3. Write `08h` to R#8 to select the 64K×4 DRAM organization.
4. Initialize the remaining display registers and VRAM addresses.
5. Write `04h` to R#25 to set `WTE=1` while retaining `VDS=0`.
6. Write the configuration latch with D1=0 to enable the PLD porch while
   preserving D0.
7. Begin normal accelerated VDP traffic, and program the palette here.

Program the palette in step 7, not in the paced bootstrap phase. `MANDELV5.COM`
never disables the porch, so every palette byte it writes is held by a real
hardware WAIT, and that is the only sequence proven on this card. A console
driver that loaded the palette with `WTE=0` and the porch bypassed, paced only
by software delays, produced palette entries with the low RB (blue) bits wrong:
entry 15 (`77h,07h`, white) displayed as yellow. Software pacing spaces
successive accesses but does not widen `/CSW` or extend the data-valid window
of the access itself.

Do not assume a CP/M warm boot reset R#8, R#25, R#14, or the configuration
latch. The console initializer must establish every value it relies on.

For the hardware-validated GRAPHIC 6 baseline used by `MANDELV5.COM`, the key
display values are:

| Register | Value | Purpose |
|---|---:|---|
| R#0 | `0Ah` | M5+M3: GRAPHIC 6 |
| R#1 | `40h` | Display enabled |
| R#2 | `1Fh` | Real-V9958 bitmap addressing from VRAM base zero |
| R#8 | `08h` | `VR=1`, 64K×4 DRAMs |
| R#9 | `88h` | 212 source lines with interlace |
| R#25 | `04h` | `WTE=1`, `VDS=0` |

Other registers remain the responsibility of the console mode and its sprite,
scroll, interrupt, and palette design.

## Timing discipline

The U11 porch catches the 10 MHz Z80's first WAIT sampling point and then
hands the transaction to native V9958 `/WAIT`. It does not replace every V9958
control-port and palette inter-access requirement. In particular, initial
register writes made with WTE disabled must be software paced. Keep explicit,
documented spacing in the bootstrap helpers rather than relying on incidental
instruction timing.

Normal operation requires both ends:

```text
R#25.WTE = 1
R#25.VDS = 0
/WS_EN   = 0
```

## Validation before integrating the console driver

The standalone `V9958TST.COM` diagnostic produced the following with native
WAIT and the PLD porch enabled. The complete suite, including expanded 128 KiB
coverage, passed on the hardware in both slow and fast modes on 2026-09-04:

```text
DATABUS:     OK
MARCH:       OK
AUTOINC:     OK
R14-BANK:    OK
VRAM-128K:   OK
OTIR-STRESS: OK
```

`R14-BANK` checks offset `0123h` in all eight 16 KiB R#14 regions, from
`00123h` through `1C123h`. A pass validates R#14 bits A16:A14 and distinguishes
both 64 KiB halves of VRAM. `VRAM-128K` then writes and verifies an
address-dependent byte at every address from `00000h` through `1FFFFh`. Both
tests are destructive to existing VDP VRAM contents.

During first console-driver bring-up, also scope these signals during repeated
VDP reads and writes:

- V9958 pin 26 native `/WAIT`
- U11 pin 21 `WAIT_SINK`
- Z80 pin 24 bus `/WAIT`
- V9958 pin 8 CPUCLK, approximately 3.58 MHz
- `/CSR` and `/CSW`

Native `/WAIT` may remain low while the VDP is legitimately busy, but it must
release and allow the active Z80 I/O cycle to complete.
