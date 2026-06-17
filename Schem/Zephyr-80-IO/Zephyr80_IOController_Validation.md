# Zephyr-80 IO Controller — Schematic Validation (net-trace)

Fresh validation of the current KiCad schematics, traced pin-by-pin from the S-expressions. Same status legend/format as the platform's other card reviews.

> **Correction note (supersedes my first pass):** an earlier draft of this review claimed SIO1 was absent. That was a **tooling miss** on my side — the IC3 placement carries a `(lib_name "Z80SIO_1")` line ahead of its `(lib_id)`, which my instance parser didn't accept, so IC3 was dropped from the netlist. Fixed. **IC3 (SIO1) is present and the SDLC link is fully wired.** Everything below reflects the corrected trace (pin-endpoint coincidence 295/316 = 93%).

---

## Board under review

| Field | Value |
|---|---|
| Board | Zephyr-80 IO Controller (`Zephyr-80-IO`) |
| Sheets | root · IO Controller · Baud Clock · Device Select Decode · Console Port · GPIOs and User Serial · pBITz Bus Interface |
| Serial ICs | **IC2 = Z80 SIO0 (async)** · **IC3 = Z80 SIO1 (sync/SDLC)** · IC1 = Z80 CTC · U15 = PIC18F57Q84 · U1 = 74AHCT125 (SPI mux) · U7 = FT230XS · U14 = MAX202 · U8 = 74HC4040 · Y1 = 14.7456 MHz |
| Method | Calibrated S-expression net trace; 295/316 pin-endpoint hits, misses confirmed as unused pins |
| Review date | 2026-06-16 |
| Net result | **✅ schematic PASS** — SIO1/PIC SDLC link, SIO0 console, and SIO0 user-serial all wired correctly. Remaining items are firmware-side (§4,5,7,8); no hard schematic blockers. |

**Legend:** ✅ pass · ❌ fail · ⚠️ verify / open · ➖ n/a · 🔧 polish
**Confidence:** schematic connectivity **high** (direct trace); runtime **medium** (no firmware/PPS/SIO register init supplied).

---

## 0. Findings (the lens)

| ID | Finding | Status |
|---|---|---|
| A | **SIO1 SDLC link is correctly wired** end-to-end (PIC SPI ↔ IC3 via U1 mux). No gross connectivity fault. | ✅ |
| B | **All three of your corrections are present and verified** (§1). | ✅ |
| C | **SIO0 console (FT230) and user-serial (MAX202/RS-232) both wired correctly** — TX/RX & RTS/CTS crossover on the root sheet, connector-perspective net naming. Console proven; RS-232 untested but correct. | ✅ |
| D | **Remaining risk is firmware + one HW budget item**: PPS mapping, `/SYNC` as input, CS mutual-exclusion, buffered-clock idle/sequencing, SDLC bit-order parity, and the MAX202 driver/receiver count. | ⚠️ |

---

## 1. Your three corrections — verified

| # | Correction | Status | Evidence |
|---|---|---|---|
| 1.1 | Clock-sheet typos fixed | ✅ | Baud Clock outputs now `CLK_7M3728 / CLK_3M6864 / CLK_1M8432` (14.7456 ÷ 2/4/8), matching IO Controller inputs. |
| 1.2 | SIO0 DCD pulled low | ✅ | `IC2.19 (DCDA)→R32→GND`, `IC2.22 (DCDB)→R31→GND`. |
| 1.3 | SIO1 DCD & CTS → MCU, pulled low | ✅ | `CTSA→RB0 +R39↓`, `DCDA→RB4 +R34↓`, `DCDB→RE0 +R33↓`, `CTSB→RB5 +R41↓` — each to a PIC GPIO **and** a pull-down to GND. Exactly as described. |

## 2. SIO1 (IC3) — sync/SDLC link to the PIC  ✅

The "firmware-SDLC over SPI, two virtual targets" architecture is wired correctly. IC3 is on the Z80 bus (register access) with its serial side driven by the PIC through the U1 (74AHCT125) mux.

| Signal | Path (traced) | Status |
|---|---|---|
| PIC→SIO1 data | `SIO_MOSI` (RB1) → **IC3 RXDA (12) + RXDB (28)** (multidrop) | ✅ |
| SIO1→PIC data | `IC3 TXDA (15) → SIOA_TX → U1(2A/2Y, OE=~SIOA_CS)`; `IC3 TXDB (26) → SIOB_TX → U1(3A/3Y, OE=~SIOB_CS)` → shared `SIO_MISO` (RB2), R36 100k pull-up | ✅ |
| Bit clock | `SIO_SCK` (RB3) → `U1(1A/4A)` → `SIOA_SCK` (→ IC3 RXCA/TXCA) and `SIOB_SCK` (→ IC3 RXTXCB), gated by CS, R37/R38 100k pull-ups | ✅ |
| Channel select | `~SIOA_CS` (RA5) → U1 4OE+2OE; `~SIOB_CS` (RA4) → U1 1OE+3OE | ✅ |
| /SYNC sense | `IC3 SYNCA (11) → ~SYNCA → RA6`; `IC3 SYNCB (29) → ~SYNCB → RA7` (point-to-point, no contention) | ✅ |
| Per-channel attention | `IC3 RTSA (17) → ~SIO1A_INT → RF1`; `IC3 RTSB (24) → ~SIO1B_INT → RF0` (+pull-ups). SIO **RTS used as a ready/attention line to the PIC** — distinct from the Z80-side `INT`. | ✅ note |
| Modem inputs | `CTSA/DCDA/CTSB/DCDB` → PIC GPIO + pull-downs (correction 1.3) | ✅ |
| Bus | `CE←~CE_SIO1`, `C/D←A0`, `B/A←A1`, `RD←~RD`, `IORQ←~IORQ`, `M1←~M1`, `CLK←CLK_10M`, `RESET←~RESET`, `INT→~INT`, `W/RDYA·B→~WAIT` | ✅ |

Channel A and channel B map to your two SDLC ports ("bulk" / "commands") — the mux/CS scheme keeps them independently selectable. The earlier external review was correct on this connectivity (MOSI→RXDA+RXDB, TXDA/TXDB→125 buffers→MISO, RTS→PIC); credit to it.

## 3. SIO0 (IC2) — async console + user serial

| # | Check | Status | Notes |
|---|---|---|---|
| 3.1 | Ch B = Console / FT230 | ✅ | `RXDB/TXDB/RTSB/CTSB ↔ CONS_UART_*`; clock `RXTXCB ← CLK_1M8432` (÷16 = 115200). DCDB low. Proven-good reference. |
| 3.2 | Ch A = User serial / MAX202 | ⚠️ | `RXDA/TXDA/RTSA/CTSA ↔ USR_UART_*`; clock `RXCA/TXCA ← CTC TO0`. DCDA low. Symmetric with the working channel; untested — see §11 for the transceiver budget. |
| 3.3 | Bus / interrupt | ✅ | Shares decode + IM2 chain with IC1/IC3 (see §9). |

## 4. PIC ports / PPS / SPI separation

| # | Check | Status | Notes |
|---|---|---|---|
| 4.1 | Two SPI domains separate | ✅ | SIO-side RB1/RB2/RB3; IO/mezzanine RC5/RC4/RC3. No shared pins, no ICSP (RB6/RB7) conflict. |
| 4.2 | "Wrong port" history | ⚠️ firmware | Pins are PPS-valid and conflict-free in the schematic. Confirm `SPIxSCK/SDI PPS` + output `RxyPPS` target exactly RB1/2/3 and RC3/4/5, and `ANSELx` cleared on all SDLC-link pins. |

## 5. /SYNC direction

| # | Check | Status | Notes |
|---|---|---|---|
| 5.1 | No contention | ✅ | `~SYNCA/~SYNCB` point-to-point IC3→RA6/RA7. |
| 5.2 | Direction | ⚠️ firmware | SIO drives /SYNC as an **output** in SDLC/internal-sync, so **RA6/RA7 must be TRIS inputs**. Driving them from the PIC recreates the original contention. |

## 6. Auto-enable / modem control  ✅

| # | Check | Status | Notes |
|---|---|---|---|
| 6.1 | SIO1 CTS/DCD defined | ✅ | All four pulled low + MCU-driven (1.3). Auto-Enables won't silently gate the link; if firmware also wants flow control it can drive these. |
| 6.2 | SIO0 | ✅ | DCD low; CTS = real FT230/MAX202 handshake. |

## 7. Buffered SIO1 clock — idle-state / sequencing

| # | Check | Status | Notes |
|---|---|---|---|
| 7.1 | Gated-clock park level | ⚠️ firmware | `SIOA_SCK/SIOB_SCK` are 74AHCT125 outputs with 100k pull-ups → an unselected channel parks **high**. Idle `SIO_SCK` **high** and assert CS *before* shifting, so enabling the buffer injects no high→low edge ahead of bit 0. The SIO sync receiver has no start-bit recovery, so a stray enable edge can shift a bit boundary. |

## 8. Mux discipline (firmware)

| # | Check | Status | Notes |
|---|---|---|---|
| 8.1 | CS mutual exclusion | ⚠️ firmware | `~SIOA_CS` and `~SIOB_CS` are independent PIC pins. Never assert both: that would enable both TX buffers onto `SIO_MISO` (contention) and both clocks. Enforce one-hot in firmware. |
| 8.2 | Return-data float | ✅ | When neither CS active, `SIO_MISO` is held by R36; SIO TXD idles mark/high anyway. |

## 9. Interrupts / daisy chain

| # | Check | Status | Notes |
|---|---|---|---|
| 9.1 | Shared INT | ✅ | `~INT` = IC1+IC2+IC3 INT (open-drain wired-OR to Z80). |
| 9.2 | IM2 chain order | ✅ | `[bus IEI] → CTC(IC1) → SIO0(IC2) → SIO1(IC3) → [bus IEO]`. /M1 present. Note SIO1 is **lowest priority** — fine functionally; reconsider only if VDrip latency ever competes with console IRQs. |

## 10. Clock / baud / decode

| # | Check | Status | Notes |
|---|---|---|---|
| 10.1 | Osc + divider | ✅ | 14.7456 MHz → 74HC4040 → 7.3728/3.6864/1.8432 MHz, names correct. |
| 10.2 | Decode | ✅ | 4× 74HC688 + coded switches → `~CE_CTC/~CE_SIO0/~CE_SIO1/~CE_CTRL`; all four now land on their targets (IC1/IC2/IC3/'138). |

## 11. Backplane / transceivers

| # | Check | Status | Notes |
|---|---|---|---|
| 11.1 | Backplane SPI | ✅ | J1 carries the IO-side SPI (`IO_MOSI/IOI_MISO/SPI_CLK/SPI_CS0/1/SPI_CD/~SPI_INT`). SIO1's SDLC link is intentionally **local** (PIC bridges it), not on the bus. |
| 11.2 | FT230X console | ✅ | Single-supply USB-UART; proven path. |
| 11.3 | MAX202 channel budget | ✅ | MAX202 = **2 drivers + 2 receivers** (4 channels, 8 signal pins). TX + RTS use the two drivers; RX + CTS use the two receivers — all four lines fit. |
| 11.4 | MAX202 / console TTL-side direction | ✅ | The TX↔RX and RTS↔CTS crossover is done on the **root sheet** (sheet-pin wiring), with the transceiver-side nets named from the **RS-232/connector perspective**. Resolved through the root: SIO `TXDA → DIN2(10)`, SIO `RXDA ← ROUT2(9)`, SIO `RTSA → DIN1(11)`, SIO `CTSA ← ROUT1(12)` — every SIO output to a driver input, every SIO input from a receiver output. **Correct.** The console (FT230) path uses the same pattern (`CONS_UART_TX↔CONSOLE_RX`, etc.). *(An earlier draft flagged a swap; that was a cross-sheet trace artifact on my side — sheet pins connect via root wiring, not by name — not a board fault.)* |

---

## Reconciliation with the external report

With IC3 correctly in the netlist, the external report's SIO1 connectivity claims **match the trace**: `SIO_MOSI → IC3 RXDA + RXDB`; `TXDA/TXDB → 74AHCT125 → SIO_MISO`; `SIOA_SCK/SIOB_SCK` gated with 100k pull-ups; `~SIO1A/B_INT` on RTSA/RTSB; point-to-point `/SYNC` on RA6/RA7. Its firmware-risk list (PPS, `/SYNC` TRIS, Auto-Enables, clock-idle discipline, bit order) is valid and is folded into §4–§8. The one place it's now out of date: it flagged SIO1 CTS/DCD as **unstrapped** — your correction 1.3 fixes exactly that, so that trap is closed.

Net: the report's architectural read was right. My first-pass "SIO1 absent" was a parser defect, not a board defect.

---

### Sources

- **Z80 SIO** — no internal BRG (external TxC/RxC); WR4 x1 for sync/SDLC; **/SYNC is an output in SDLC/internal-sync, input only in external-sync**; Auto-Enables (WR3 D5) gate Tx on /CTS, Rx on /DCD; RTS is a WR5-controlled GP output; IEI/IEO IM2 chain via /M1·/IORQ. *Zilog Z80 SIO Technical Manual (UM0081). Confidence: high.*
- **SDLC bit order** — LSB-first on the wire vs MSB-first default SPI; firmware-SDLC parity (flag 0x7E, CRC-CCITT, NRZ/NRZI) must match the SIO config. *ISO 13239 / Zilog SIO manual + Microchip MSSP shift order. Confidence: high.*
- **PIC18F57Q84** — dual PPS-routable SPI; ANSEL/TRIS/ODCON/INLVL per-pin; no native HDLC. *Microchip DS40002213. Confidence: high.*
- **74AHCT125** — independent 3-state buffers; OE low ⇒ A→Y, OE high ⇒ Hi-Z. *TI SN74AHCT125 datasheet. Confidence: high.*
- **FT230X / MAX202 / ECS-2100AX (14.7456 MHz) / 74HC4040** — vendor datasheets. *Confidence: high.* MAX202 = 2 drivers + 2 receivers + charge-pump caps.

> Stable reference docs — not web-searched this pass. Ask for live datasheet revision dates if needed.

### Reproducibility

Calibrated KiCad S-expression net tracer: union-find over wire endpoints + on-segment taps + same-name local/hierarchical label merge; instance parser now tolerates `(lib_name …)` before `(lib_id …)`; transform auto-calibrated; 295/316 pin-endpoint hits. Re-run per sheet as `python3 trace.py IO_Controller.kicad_sch <REFS…>`. Script available on request.

---

## Revision log

| Rev | Date | Reviewer | Result | Key notes |
|---|---|---|---|---|
| net-trace 1 | 2026-06-16 | Claude | (withdrawn) | Erroneously reported SIO1 absent — parser dropped IC3 (`lib_name` before `lib_id`). |
| net-trace 2 | 2026-06-16 | Claude | ✅ conditional PASS | IC3/SIO1 fully traced. SDLC link correct; all 3 corrections verified. Open items are firmware (PPS, /SYNC TRIS, CS one-hot, clock idle/sequencing, bit order) + MAX202 channel budget. |
| net-trace 3 | 2026-06-16 | Claude | ❌ on RS-232 | MAX202 budget was a non-issue (2 drv + 2 rcv handles all 4 lines). But TTL-side appears **direction-swapped** (§11.4) — likely root cause of the untested RS-232 channel. SIO1/SIO0-console unaffected. |
| net-trace 4 | 2026-06-16 | Claude | ✅ schematic PASS | **Retracted the §11.4 swap.** The UART TX↔RX / RTS↔CTS crossover is intentional and done on the **root sheet** (verified for both `USR_UART_*` and `CONS_UART_*`); transceiver-side nets are named from the RS-232 perspective. RS-232 wiring is correct. No hard schematic blockers; remaining items firmware-side. *Lesson: sheet pins connect through parent wiring, not by name — per-sheet traces must resolve cross-sheet nets via the root, which the earlier passes did not.* |

> **Firmware bring-up shortlist:** (1) PPS → RB1/2/3 + RC3/4/5, ANSEL cleared; (2) RA6/RA7 inputs; (3) one-hot CS; (4) SIO_SCK idles high, CS before shift; (5) SDLC bit order/flag/CRC parity; (6) Auto-Enables off until proven.
