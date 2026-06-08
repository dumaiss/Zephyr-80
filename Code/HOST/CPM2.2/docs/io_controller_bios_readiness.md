# IO Controller BIOS Readiness Assessment
## Zephyr-80 CP/M 2.2 — SIO1 SDLC Path

**Assessment date:** 2026-06-01  
**Scope:** IO Controller transport (SIO1/A Bulk, SIO1/B Command).

**Current-status note (2026-06-03):** This is a 2026-06-01 pre-implementation readiness snapshot. Phase 1 source now contains a fixed-frame SIO1/B IOCALL path and the corrected SIO1 port map. Keep this document as historical planning context; use the current Phase 1 failure-analysis report for the active debug state.

**VDrip status:** VDrip is the current working development proxy. It will be removed entirely once the IO Controller architecture is complete and proven. It is not a permanent coexistent path. During the IOC bring-up phases documented here, VDrip is not touched — it remains the active console and storage backend. Replacing the VDrip console and storage drivers is the final step, not an early one.

---

## Executive Summary

The BIOS has meaningful scaffolding for the IO Controller path but is not yet ready to communicate with the IO Controller MCU over SDLC.

**What is already there:**

- SIO1/A (Bulk) is initialized in synchronous mode and has a complete byte-by-byte polled transport (`IOCALL`).
- The `IOCALL` entry exists in the extended BIOS jump table at `DA3Fh → DF7Bh`, with a well-defined request-block calling convention.
- `SIO_CH_IOCTRL` is defined, `SIO1_RX_SINK` is allocated in runtime state, and `sio_core_dispatch_rx` already handles `SIO_CH_IOCTRL`.
- `textq_put_ascii` is ISR-safe and ready to receive Port B TEXT_EVENT payload bytes.
- ~703 bytes of unallocated resident code space exist between the VDrip console driver tail and the VDrip storage backend (`F52Ch–F7EAh`).

**What is missing:**

- SIO1/B (Command/control channel) has **zero initialization code** — it is the intended interrupt-driven fixed-frame SDLC control channel and does not exist in the BIOS yet.
- SDLC mode is not configured on any SIO1 channel. SIO1/A is in external-sync mode, not SDLC.
- No IM2 vector entry exists for SIO1/B interrupts.
- No IOC event ring exists. The ISR needs a small fixed-depth ring of 32-byte frame slots to land unsolicited frames without blocking.
- No frame dispatcher or subscriber model exists. The ISR must not decode frame content; a foreground dispatcher routes complete frames to the appropriate subscriber by class/type.
- SIO1 WR9 master interrupt enable is held disabled.
- No WAIT/READY mode configured, no INIR/OTIR block-transfer helpers.
- The current IOCALL calling convention (variable-length request block) does not match the intended fixed-frame model (caller provides 32-byte TX frame + 32-byte RX frame).

The gap between the working VDrip baseline and a minimal Phase 1 SIO1/B SDLC init is approximately 150–200 bytes of new resident code.

---

## 1. Current SIO Architecture

### Clock architecture

**The MCU is the synchronous clock master for SIO1.**

The Z80 SIO1 is externally clocked. TXC and RXC for both SIO1/A (Bulk) and SIO1/B (Command) are driven by the MCU, not by the SIO itself, not by a CTC channel, and not by any free-running oscillator. The clock is gated: the MCU provides it only when it is actively participating in a transaction. The SIO cannot shift any bits — in either direction — unless the MCU is supplying a clock.

Consequences for the BIOS:

- **TX never completes if the MCU is not clocking.** A polled TX loop will spin until its software timeout expires. An OTIR with WAIT mode enabled will stall the Z80 indefinitely.
- **RX never produces a byte if the MCU is not clocking.** A polled RX loop will spin until timeout. An INIR with WAIT mode enabled will stall the Z80 indefinitely.
- **RTS is the gating signal.** Z80 asserts RTS → MCU detects the service request and starts clocking → transaction runs → MCU stops clocking when done → Z80 releases RTS. This is the only safe sequencing.
- **There is no safe polling without a preceding RTS handshake.** Any foreground byte-send or byte-receive that does not follow the RTS-assert-first discipline risks spinning against a silent SIO.
- **INIR/OTIR requires the MCU to be clocking for the entire block.** The MCU must commit to supplying clock for all N bytes before INIR/OTIR is issued. If the MCU stops mid-transfer, the Z80 stalls.

### SIO chips and channels

| Channel | Ports | Owner | Clock source | Mode | Role |
|---|---:|---|---|---|---|
| SIO0/A | `20h/21h` | Application | Not applicable | Not configured by BIOS | Application-owned; WR1 masked |
| SIO0/B | `22h/23h` | BIOS | Internal (×16, CTS-gated TX) | Async 115200 8N1 | VDrip console / CP/M CONIN/CONOUT |
| SIO1/A | `30h/31h` | BIOS | **MCU-supplied external clock** | Synchronous external-sync | Future Bulk (bulk data); currently IOCALL polled |
| SIO1/B | `32h/33h` | (unallocated) | **MCU-supplied external clock** | **None — never initialized** | Intended Command (command/control/events) |

### SIO1/A initialization (current)

`sio1_ioc_init` at `DD4Dh` programs SIO1/A as follows:

| Register | Value | Meaning |
|---|---|---|
| WR0 | `18h` | Channel reset |
| WR1 | `00h` | No interrupts, no WAIT/DMA |
| WR9 | `00h` | SIO1 master interrupt enable = 0 (chip-wide disabled) |
| WR4 | `30h` | **External sync mode, ×1 clock, no parity** — NOT SDLC; ×1 is correct for external clock |
| WR6 | `00h` | Sync byte 0 cleared |
| WR7 | `00h` | Sync byte 1 cleared (not set to SDLC flag `7Eh`) |
| WR3 | `D1h` | 8-bit RX, Enter Hunt, no CRC, Rx enabled |
| WR5 | `E8h` | 8-bit TX, RTS inactive, no CRC |

**WR4 ×1 clock note:** ×1 divider is the correct setting for an externally supplied clock. The SIO uses whatever clock appears on TXC/RXC pins at a 1:1 ratio. No baud rate generation happens inside the SIO on this channel.

**Critical gap:** WR4 bits 5:4 = `11` = External sync, not `10` = SDLC. SDLC frame detection, flag sync, CRC, and zero-insertion are not active. The SIO hardware is not doing any SDLC framing yet.

### SIO1/B initialization

None. SIO1/B (ports `32h/33h`) receives no BIOS write at any point in boot, warm boot, or the SIO core init sequence. All SIO1 init code touches ports `30h/31h` (SIO1/A) only.

### IM2 interrupt dispatch

The IM2 table is exactly 2 bytes at `DD10h–DD11h`:

```
DD10h:  .dw sio_core_isr   ; for SIO0/B console RX
```

`I = DDh`, SIO0/B WR2 = `10h` → Z80 reads `DD10h` → vectors to `sio_core_isr`.

`sio_core_isr` services SIO0/B only. It does not check SIO1/A or SIO1/B.

**To add SIO1/B Command interrupts**, two bytes must be appended:

```
DD12h:  .dw ioc_cmd_isr  ; for SIO1/B Command RX  (new)
```

SIO1 WR2 would be set to `12h`, and SIO1 WR9 MIE enabled. The IM2 table extension is the key gating change for interrupt-driven Port B receive.

### Synchronous mode / SDLC

- No SDLC mode anywhere in the BIOS.
- No WR10 or WR14 (those are Z85C30 ESCC registers; the Zephyr-80 uses a plain Z80 SIO).
- WR7 sync byte is cleared to `00h`; the SDLC flag `7Eh` has never been written.
- WR3/WR5 CRC-enable bits are clear on both SIO1 channels.

---

## 2. Existing IOCALL Support

### Entry point

| Symbol | Address | Path |
|---|---:|---|
| `IOCALL` (jump table) | `DA3Fh` | Extended BIOS table entry |
| `IOCALL` (implementation) | `DF7Bh` | `IOCTRL_CODE_START` |
| `IOCTRL_CODE_END` | `DFFCh` | Core BIOS limit − 4 bytes |

Code size: `DFFCh − DF7Bh = 81h = 129 bytes`.

### Calling convention

```
In:  DE = pointer to caller-owned IOCALL request block in visible RAM.
Out: A  = BIOS transport status (0 = OK, non-zero = error).
```

### Request block layout (10 bytes, caller-owned)

| Offset | Name | Meaning |
|---:|---|---|
| +00 | `IOCALL_CHAN` | SIO channel id (`SIO_CH_IOCTRL` = 1) |
| +01 | `IOCALL_CMD` | Command opcode |
| +02 | `IOCALL_TX_LEN` | TX payload byte count (max 128) |
| +03 | `IOCALL_RX_MAX` | Max RX payload byte count |
| +04 | `IOCALL_TX_PTR` | 16-bit pointer to TX payload in app RAM |
| +06 | `IOCALL_RX_PTR` | 16-bit pointer to RX buffer in app RAM |
| +08 | `IOCALL_STATUS` | Filled by BIOS with MCU reply status |
| +09 | `IOCALL_RX_LEN` | Filled by BIOS with received byte count |

### Current behavior

IOCALL currently:

1. Validates TX and RX lengths (≤ 128).
2. Asserts SIO1/A RTS.
3. Sends 3-byte header (CHAN, CMD, TX_LEN) byte-by-byte via `sio1_ioc_put_byte`.
4. Sends TX payload byte-by-byte.
5. Receives 2-byte reply header (STATUS, RX_LEN) byte-by-byte via `sio1_ioc_get_byte`.
6. Receives RX payload byte-by-byte into caller buffer.
7. Releases SIO1/A RTS.

All transfers are foreground-polled with a timeout counter `SIO_IOCTRL_TIMEOUT = 0xFFFF`. There is no interrupt-driven path, no DMA, no buffering.

### Intended fixed-frame IOCALL contract

The current IOCALL calling convention (variable-length request block with CHAN/CMD/TX_LEN/RX_MAX fields) predates the fixed-frame architecture. The intended contract is simpler:

```
In:
    HL = pointer to caller-owned 32-byte TX frame
    DE = pointer to caller-owned 32-byte RX frame buffer
Out:
    RX frame buffer contains the complete 32-byte reply
    A  = BIOS transport status (0 = OK)
```

The caller builds the entire TX frame, including the frame class, sequence number, flags, and payload. IOCALL sends it and synchronously waits for one matching reply frame. IOCALL does not decode the TX or RX frames. The caller decodes the RX frame.

This is compatible with user-land tools:

```
PING.COM:
    build 32-byte PING request frame in app RAM
    provide 32-byte reply buffer in app RAM
    call IOCALL (HL=tx_frame, DE=rx_frame)
    decode RX frame itself — inspect byte 0 class, byte 2 status, etc.
```

And with BIOS-owned drivers:

```
storage driver:
    build 32-byte storage command frame in driver scratch
    provide 32-byte reply frame buffer in driver scratch
    call IOCALL or internal IOC transport helper
    decode storage-specific reply fields itself
```

IOCALL never needs to know what PING, RESET, GET_VERSION, or READ_SECTOR mean.

**Migration from current calling convention:** The current 10-byte request block is a foreground-only mechanism that would be replaced by the fixed-frame interface. A compatibility shim or a clean replacement is a design decision for the implementation phase. The important invariant is that **IOCALL must not grow a command vocabulary**.

### Reusability for the SDLC design

| Piece | Reuse for Port A (Bulk) | Reuse for Port B (Command) |
|---|---|---|
| `sio1_ioc_put_byte` | Yes — evolves to Port A TX | No — Port A only |
| `sio1_ioc_get_byte` | Yes — evolves to Port A RX | No |
| `sio1_ioc_rts_assert/release` | Yes | Separate Port B RTS if needed |
| Byte-by-byte loop structure | Port A foreground; replace with INIR/OTIR later | Not used for interrupt-driven frame RX |
| IOCALL foreground TX/wait structure | Reuse: assert RTS, send frame, wait for event ring | Replace byte-by-byte RX with event ring poll |

The existing IOCALL byte transport is reusable as the skeleton for the foreground Port A TX path and the foreground "wait for reply in event ring" pattern. The variable-length request block format will be replaced by fixed 32-byte frame pointers.

---

## 3. Interrupt Readiness

### Current ISR dispatch

`sio_core_isr` at `DEAFh`:

- Pushes AF, BC, DE, HL.
- Reads SIO0/B RR0 for RX_READY.
- If byte available, reads `SIO0B_DATA_PORT`, records RR1 diagnostics, calls `sio_core_dispatch_rx(SIO_CH_CONSOLE, byte)`.
- Issues RESET_HIGHEST_IUS through SIO0 master control port.
- Re-checks RR0 once (race window), issues second RESET_HIGHEST_IUS.
- Pops AF, BC, DE, HL and RETI.

Only SIO0/B is serviced. SIO1/A and SIO1/B are not polled in the ISR.

### SIO1_RX_SINK

Allocated at `FE72h–FE73h`, initialized to `0000h`. The dispatch infrastructure in `sio_core_dispatch_rx` has a live arm for `SIO_CH_IOCTRL` that reads this slot. The slot exists and is correct; it is simply null because no SIO1 ISR yet drives it.

### What needs to be added for Port B interrupt-driven receive

1. **IM2 table extension (2 bytes):** Append `.dw ioc_cmd_isr` at `DD12h`.
2. **SIO1 WR2 = 12h:** Written during SIO1/B SDLC init.
3. **SIO1 WR1 RX interrupt mode:** Enable `SIO_WR1_RX_INT_ALL` for SIO1/B.
4. **SIO1 WR9 MIE:** Enable SIO1 master interrupt.
5. **`ioc_cmd_isr` body:** New ISR to read one received byte from SIO1/B, detect end-of-frame, and dispatch payload bytes to `textq_put_ascii` or an IOCALL_REPLY buffer.

### ISR latency and safety

The existing `sio_core_isr` is bounded: at most 2 byte reads per entry. A Command ISR must follow the same discipline. SDLC end-of-frame is indicated by RR1 bit 7 (End of Frame) on the Z80 SIO.

**The ISR does not interpret frame content. It does not push bytes to textq. It does not decode PING, keyboard, or storage semantics.** Its only job is to receive the complete frame into safe storage and make it available to the foreground dispatcher.

The ISR should:

- Read one byte from SIO1/B data port.
- Store into the in-progress receive slot (a 32-byte staging buffer).
- Check RR1 for End of Frame or error condition.
- On End of Frame: copy/move the complete 32-byte frame into the next available IOC event ring slot; advance event ring head; set overflow flag if ring is full (frame is dropped).
- On error (CRC, abort, overrun): discard the in-progress frame and reset the staging buffer.
- Issue RESET_HIGHEST_IUS through the SIO1 master control port (`SIO1A_CTRL`).
- RETI.

The foreground dispatcher (called from CONST, CONIN, or an explicit `ioc_dispatch_pending` call) drains the event ring:

- For each pending frame in the ring, read `frame[0]` (class/type).
- Route the complete 32-byte frame to the registered subscriber for that class.
- Advance the event ring tail.

The console subscriber (one of potentially several) handles `CONSOLE_INPUT` frames:

```
In: HL = pointer to 32-byte CONSOLE_INPUT frame
    read frame[3] as terminal byte count (n)
    for i = 0 to n-1: call textq_put_ascii(frame[4+i])
```

No other subscriber pushes to textq. The generic IOC transport does not push to textq.

### Risk: two SIO chips, one IM2 table

With `I = DDh`:
- SIO0/B vector = `10h` → reads `DD10h` ✓
- SIO1/B vector = `12h` → reads `DD12h` (new)

These are different IM2 table entries in the same page. No conflict, but both are in the SIO core code area. The IM2 table must grow from 2 bytes to 4 bytes; the SIO core code body remains unchanged.

---

## 4. textq / Console Input Readiness

### Location and structure

`textq_buffer` is a 128-byte ring buffer inside the VDrip console driver (`E000h` area).

| Symbol | Value | Meaning |
|---|---:|---|
| `TEXTQ_SIZE` | `80h = 128` | Ring capacity |
| `TEXTQ_MASK` | `7Fh` | Modulo mask |
| `TEXTQ_RTS_HIGH_WATER` | `40h = 64` | Release RTS on VDrip side |
| `TEXTQ_RTS_LOW_WATER` | `00h = 0` | Re-assert RTS after drain |

State variables: `textq_head`, `textq_tail`, `textq_count` (all 1 byte), and `textq_buffer` (128 bytes). These are inside the VDrip console driver state area.

### textq_put_ascii

Located at approximately `E1D5h` within the VDrip console driver code.

**ISR safety:** Yes. The function is bounded and non-blocking:

1. Load `textq_count`; if full, release VDrip RTS and return.
2. Compute `textq_buffer + textq_head`, store byte.
3. Increment `textq_head` mod 128.
4. Increment `textq_count`.
5. If `textq_count >= TEXTQ_RTS_HIGH_WATER`, release VDrip RTS.

Steps 2–4 are not atomic, but they are safe from ISR context because CONIN disables interrupts around `textq_count`/`textq_tail` updates and the producer ISR only updates `textq_head`/`textq_count`. The Z80 SIO ISR already saves AF/BC/DE/HL around the sink call.

**Note:** `textq_put_ascii` releases VDrip RTS at the high-water mark. This is VDrip-specific backpressure. Port B SDLC input does not use that RTS line, so the side effect is harmless for the IOC console subscriber. When VDrip is eventually removed, the `textq_put_ascii` high-water RTS logic will be removed or updated along with the rest of the VDrip console driver.

### Multi-byte VT100 sequences

`textq_put_ascii` stores one raw byte per call. Multi-byte sequences (e.g., Arrow-Up = `1Bh 5Bh 41h`) are enqueued as three separate bytes in three calls. CONIN returns one byte per call; the CP/M application or CCP reassembles sequences. No change to `textq` is required.

### Console subscriber: CONSOLE_INPUT frame → textq

`textq_put_ascii` is not called by the ISR or the generic transport. It is called by the console subscriber, a foreground function that receives a pointer to a complete 32-byte `CONSOLE_INPUT` frame:

```
ioc_console_subscriber:
    In: HL = pointer to 32-byte CONSOLE_INPUT frame
    read frame[3] = n (terminal byte count)
    HL += 4            ; point at frame[4]
    loop n times:
        A = (HL)
        call textq_put_ascii
        inc HL
    return
```

The foreground dispatcher calls `ioc_console_subscriber` when it dequeues a `CONSOLE_INPUT` frame from the IOC event ring. This keeps ISR time minimal and separates byte-enqueue work from interrupt delivery.

No changes to `textq_put_ascii` are required. The new code is the subscriber wrapper above and the dispatcher that calls it.

---

## 5. Fixed 32-Byte Port B Frame and Event Ring Feasibility

### Storage model

Two buffers are needed for Port B Command receive:

**1. In-progress staging buffer (1 × 32 bytes, ISR-owned):**

The ISR writes bytes here as they arrive from SIO1/B, one byte per interrupt. When SIO RR1 signals End of Frame, the ISR copies the complete staging buffer into an event ring slot.

**2. IOC event ring (N × 32 bytes, foreground-consumed):**

A shallow fixed-depth ring of complete 32-byte frames. The ISR writes into it; the foreground dispatcher reads from it. Suggested depth:

| Depth | Total bytes | Notes |
|---:|---:|---|
| 2 slots | 64 bytes | Adequate for most cases — CP/M is single-threaded |
| 4 slots | 128 bytes | More headroom for bursts or slow CONST polling |

Recommended starting depth: **2 slots (64 bytes)**. This is sufficient because CP/M calls CONST frequently in interactive loops; frames rarely accumulate. A depth-4 ring can be used if bring-up reveals overflow.

Event ring state variables (~8 bytes):

```
ioc_ring_head     ; ISR write index (byte)
ioc_ring_tail     ; dispatcher read index (byte)
ioc_ring_count    ; pending frames (byte)
ioc_ring_overflow ; dropped frame flag (byte)
```

### Buffer placement

**Staging buffer (32 bytes):** Must be resident because the ISR writes into it. The unused scratch window `FD00h–FDFFh` (256 bytes) is the natural home. No pressure on runtime state.

**Event ring (64 bytes for depth=2):** Also comfortable in `FD00h–FDFFh`. Total scratch usage: 32 + 64 + 8 = 104 bytes out of 256.

**Runtime state gaps (73 bytes):** Sufficient for the ring state variables (~8 bytes) and small IOC control flags. The larger buffers should go in scratch.

**MOVE_BUFFER (`FA80h`, 192 bytes) is not used for ISR receive.** MOVE_BUFFER is foreground-only (storage staging, bulk transfers). Mixing ISR writes into MOVE_BUFFER with foreground storage use would require careful mutual exclusion and is unnecessarily complex.

### INIR inside ISR

INIR for 32 bytes blocks the CPU for 32 × 4 T-states (≈ 56 µs at 6 MHz). During this time no other interrupt can be serviced. For the first implementation:

- Use **byte-by-byte reads** in the ISR. Each call handles one SDLC byte.
- The SIO delivers one byte per interrupt; the ISR stores it and returns.
- End-of-frame detection comes from RR1 bit 7 (End of Frame) checked after each byte read.
- INIR can be evaluated for a later optimization after the byte-by-byte path is proven.

---

## 6. /WAIT and Block I/O Feasibility

### Clock dependency comes first

**Before any WAIT or INIR/OTIR question: the MCU must be supplying TXC/RXC.**

Without an active MCU clock on SIO1/A or SIO1/B, no transfer can proceed regardless of whether WAIT mode is enabled or disabled:

- Polling loop: spins until software timeout (`SIO_IOCTRL_TIMEOUT = 0xFFFF`).
- WAIT mode + `INIR`/`OTIR`: Z80 stalls indefinitely with no escape path.

The correct precondition for any SIO1 transfer is: Z80 has asserted RTS, MCU has acknowledged by starting its clock. The BIOS must not issue any byte send, byte receive, `INIR`, or `OTIR` to SIO1 until this handshake has occurred.

### Current WAIT state

SIO1/A WR1 = `00h` — no interrupts, no WAIT/DMA mode. The `/WAIT` line from SIO1/A is not driven. `SIO_IOCTRL_TIMEOUT = 0xFFFF` is a software timeout used as a fallback for the case where the MCU does not clock within a bounded window.

### Required conditions for WAIT-paced INIR/OTIR

All three of these must hold simultaneously:

1. **MCU is actively supplying clock.** Z80 has asserted RTS; MCU has started TXC/RXC. The MCU must commit to clocking for the entire block (128 bytes for a sector transfer).
2. **Interrupts disabled.** The console ISR must not fire during SIO1 block I/O. Any interrupt between bytes in an OTIR/INIR loop could corrupt SIO1/A state or cause the ISR to access SIO1/A ports.
3. **SIO1/A WR1 WAIT mode enabled** (bracketed, not persistent). Enable just before `INIR`/`OTIR`, disable immediately after. The SIO deasserts `/WAIT` when the shift register is ready for the next byte, pacing the Z80 naturally.

The sequence is:

```
di
call sio1_ioc_rts_assert          ; signal MCU to start clock
; (MCU must acknowledge — how this is detected is TBD; may be a brief delay,
;  a READY signal, or implicit: MCU starts clock synchronously with RTS edge)
call ioc_bulk_wait_enable       ; write SIO1/A WR1 WAIT mode on
INIR / OTIR                       ; block transfer, paced by /WAIT
call ioc_bulk_wait_disable      ; write SIO1/A WR1 WAIT mode off
call sio1_ioc_rts_release         ; signal MCU clock done
ei
```

If WAIT mode is omitted, the Z80 executes INI/OUTI faster than the SIO can shift. Without /WAIT pacing, the BIOS must insert polling or use the existing byte-by-byte loop.

### MCU clock acknowledgement — resolved

**Policy (homebrew YOLO):** After asserting RTS, the BIOS waits a fixed number of T-states before issuing any transfer. The MCU is expected to start clocking within that window. No CTS polling, no protocol handshake.

```asm
call sio1_ioc_rts_assert
; fixed delay — X T-states TBD; a short djnz loop or a few NOPs
; then proceed with byte send / OTIR / INIR
```

The delay constant (`IOC_RTS_SETTLE_DELAY` or equivalent) will be determined during Phase 1/Phase 4 bring-up by measuring MCU response time on real hardware or in MAME. It lives in one place so it is easy to tune.

If the MCU is not running (e.g., not connected, firmware wedged), the subsequent polled transfer will hit its software timeout and return an error. There is no deadlock risk for polled paths. For WAIT-mode INIR/OTIR the MCU being absent remains a deadlock; the delay does not protect against that. WAIT-mode block transfers must only be used when the MCU is confirmed active.

### Safety analysis

| Path | INIR/OTIR safe? | Prerequisite |
|---|---|---|
| Port A sector read (128 bytes, foreground, MCU clocking) | Yes — after /WAIT confirmed | MCU committed for full 128-byte block |
| Port A sector write (128 bytes, foreground, MCU clocking) | Yes — after /WAIT confirmed | Same |
| Port A byte-by-byte polled (existing `sio1_ioc_get/put_byte`) | Safe today | Software timeout limits hang duration |
| Port B frame receive (32 bytes, byte-by-byte ISR) | Acceptable for first impl. | MCU clocks during Command frame delivery |
| Port B frame receive (ISR + INIR) | Risky | Blocks CPU for full 32-byte frame duration |
| Port B TEXT_EVENT enqueue (ISR) | No block I/O needed | Byte-by-byte in ISR |

**Enabling WAIT mode persistently** is unsafe regardless of clock state. Any BIOS code, ISR, or CP/M transient that inadvertently reads from SIO1/A data or control port while WAIT mode is on will stall the Z80 with no escape.

### Existing INIR/OTIR usage

None. No `INIR`, `OTIR`, `INDR`, or `OTDR` instructions exist anywhere in the current BIOS. The first use will require explicit confirmation on real hardware that the MCU clock is running and /WAIT behaves as expected before production use.

---

## 7. Port A (SIO1/A) Bulk Path Readiness

### Current state

SIO1/A has:
- Synchronous external-sync mode (not SDLC — see section 1).
- Byte-by-byte polled send (`sio1_ioc_put_byte`) and receive (`sio1_ioc_get_byte`).
- RTS control (`sio1_ioc_rts_assert/release`).
- Finite timeout (`SIO_IOCTRL_TIMEOUT = 0xFFFF`).

No bulk transfer helpers. No WAIT mode. No INIR/OTIR.

### Candidate code for Port A evolution

`MOVE_BUFFER` at `FA80h` (192 bytes) is the natural staging area for sector payloads. `vdrip_storage_copy_dma_to_write` and `vdrip_storage_copy_read_to_dma` already use `MOVE_BUFFER` and LDIR for 128-byte bank-switched copies.

A Port A sector read would:

1. Use the existing DMA-to-buffer LDIR path.
2. Replace byte-by-byte `sio1_ioc_get_byte` with an INIR loop.

A Port A sector write would:

1. Copy from DMA buffer to `MOVE_BUFFER`.
2. Replace byte-by-byte `sio1_ioc_put_byte` with an OTIR loop.

### Estimated code for block helpers

```
ioc_bulk_send_128:         ; HL = source, SIO1/A WAIT enabled, OTIR 128, WAIT disabled
    ~30-40 bytes

ioc_bulk_recv_128:         ; HL = dest, SIO1/A WAIT enabled, INIR 128, WAIT disabled
    ~30-40 bytes
```

These would replace the `IOCALL_TX_LOOP`/`IOCALL_RX_LOOP` for the Bulk path.

### Storage transaction model (eventual)

```
READ sector:
  Port B (Command): Z80 sends READ_SECTOR command frame
  Port A (Bulk): 128-byte sector payload received via INIR
  Port B (Command): OK/error frame received

WRITE sector:
  Port B (Command): Z80 sends WRITE_SECTOR command frame
  Port A (Bulk): 128-byte sector payload sent via OTIR
  Port B (Command): OK/error frame received
```

---

## 7b. Corrected IOC Frame Delivery Architecture

This section documents the intended architecture against which the gap analysis in Section 8 is measured.

### Core principle

The transport layer delivers complete 32-byte frames. Consumers interpret frames. The BIOS does not grow a command vocabulary.

```
Transport delivers a complete 32-byte IOC frame.
Consumer receives a pointer to that 32-byte frame.
Consumer interprets the frame.
```

### Frame layout

All Port B frames are fixed at 32 bytes:

```
byte 0      frame class / event type / command opcode
byte 1      sequence number
byte 2      status / flags
byte 3      payload length (consumer's concern)
byte 4-19   payload bytes, up to 16 bytes
byte 20-31  reserved / frame-specific
```

### Solicited frames (foreground, reply to a request)

Caller provides a TX frame and an RX frame buffer. IOCALL is a dumb synchronous transport:

```
IOCALL:
    In:  HL = pointer to 32-byte TX frame (caller-owned)
         DE = pointer to 32-byte RX frame buffer (caller-owned)
    Out: RX buffer = complete 32-byte reply frame
         A = BIOS transport status

    Sends the 32-byte TX frame over SIO1/A (Bulk) or SIO1/B (Command).
    Waits synchronously for one matching 32-byte reply frame from Port B.
    Stores the reply frame in the caller-provided RX buffer.
    Does not decode frame content.
    Returns.
```

The caller (user-land tool or BIOS driver) decodes the RX frame. IOCALL never knows whether the frame is a PING reply, a storage command reply, or any future type.

### Unsolicited frames (interrupt-driven, no waiting foreground caller)

ISR receives complete frame → event ring → foreground dispatcher → subscriber:

```
[SIO1/B interrupt]
    ioc_cmd_isr:
        read one byte from SIO1/B data port
        store in 32-byte staging buffer
        check RR1 End-of-Frame
        on EoF: copy staging buffer → next IOC event ring slot
                advance ring head
                set overflow if ring full (drop frame)
        on error: discard staging buffer, reset
        RESET_HIGHEST_IUS (SIO1A_CTRL)
        RETI

[Foreground, called from CONST/CONIN or explicit dispatch]
    ioc_dispatch_pending:
        while ioc_ring_count > 0:
            HL = pointer to ring[tail] frame
            class = frame[0]
            route HL to subscriber[class]
            advance ring tail

[Console subscriber]
    ioc_console_subscriber:
        In: HL = pointer to 32-byte CONSOLE_INPUT frame
        n = frame[3]
        for i in 0..n-1: textq_put_ascii(frame[4+i])
```

The ISR does not call `textq_put_ascii`. The ISR does not decode frame class. The dispatcher reads frame class and calls the subscriber. Only the console subscriber touches textq.

### Consumer API

All subscribers receive a frame pointer:

```
In:  HL = pointer to 32-byte IOC frame
Out: A  = consumer status (optional, may be ignored)
```

The subscriber is responsible for interpreting all fields. No separate length, status, or type is passed outside the frame.

### MOVE_BUFFER vs IOC event ring

```
MOVE_BUFFER (FA80h, 192 bytes):
    foreground BIOS-owned use only
    storage staging, Port A bulk payloads
    temporary BIOS driver scratch

IOC event ring (FD00h area, 64-128 bytes):
    ISR-written, foreground-consumed
    Port B unsolicited frame landing zone
    never used for foreground storage or MOVE operations
```

These two areas must not overlap and must not be used interchangeably.

### Homebrew reliability policy

This is a homebrew CP/M machine. The first implementation may:

- Drop unsolicited frames on event ring overflow (acceptable).
- Use a short software timeout if the MCU does not respond to IOCALL.
- Lack retry logic or multi-stage ACK negotiation.

The BIOS must still avoid:
- Leaving WAIT mode enabled persistently.
- Deep frame parsing in the ISR.
- Making IOCALL decode command semantics.
- Mixing ISR event ring buffers with foreground MOVE_BUFFER usage.

---

## 8. SDLC-Specific Missing Pieces

The following items are not present in any form and must be added before SDLC communication can begin.

### SIO1/B init sequence (Command — entirely new)

| Step | Register | Value Needed | Purpose |
|---|---|---|---|
| Channel reset | WR0 | `18h` | Clean state |
| Interrupts/WAIT | WR1 | `18h` (RX int all, no parity mod) | Enable per-byte RX interrupt |
| Vector | WR2 | `12h` | Points to `DD12h` in IM2 table |
| SDLC mode | WR4 | `20h` (bits 5:4 = 10, x1 clock) | SDLC framing |
| SDLC flag | WR7 | `7Eh` | Standard HDLC/SDLC flag byte |
| CRC + RX | WR3 | `C9h` (8-bit, CRC enable, Rx enable, Enter Hunt) | Enables CRC checking and frame sync |
| CRC + TX | WR5 | `6Ah` (8-bit TX, CRC enable, RTS inactive) | Enables CRC generation |
| Master IRQ | WR9 | `08h` (MIE) | Enable SIO1 chip interrupt |

### SIO1/A SDLC init (Bulk — modify existing sio1_ioc_init)

Change WR4 from `30h` (external sync) to `20h` (SDLC). Add WR7 = `7Eh`. Enable CRC in WR3/WR5.

### Missing operational items

| Item | Present? | Notes |
|---|---|---|
| Command SDLC init (`sio1_cmd_init`) | No | Entirely new |
| IM2 entry for SIO1/B (`DD12h–DD13h`) | No | 2 bytes of IM2 table extension |
| Command ISR (`ioc_cmd_isr`) | No | Byte-by-byte receive into staging buffer; EoF → event ring |
| 32-byte ISR staging buffer | No | In scratch `FD00h` area |
| IOC event ring (2–4 × 32 bytes) | No | In scratch; ISR writes, foreground dispatcher reads |
| Event ring state (`head`, `tail`, `count`, `overflow`) | No | ~4 bytes in runtime state gaps |
| Foreground frame dispatcher (`ioc_dispatch_pending`) | No | Routes frame by `frame[0]` class to subscriber |
| Console subscriber (`ioc_console_subscriber`) | No | CONSOLE_INPUT → loop textq_put_ascii; foreground only |
| Fixed-frame IOCALL interface (32-byte TX + 32-byte RX pointers) | No | Replaces current variable-length request block |
| IOCALL solicited reply wait (poll event ring for matching seq) | No | Foreground; after TX, wait for reply frame in ring |
| End-of-frame detection (RR1 bit 7) | No | Inside Command ISR |
| CRC error / abort detection | No | RR1 bit 6 (CRC error), RR0 bit 3 (Break/Abort) |
| Frame timeout | No | Foreground timeout if MCU does not reply |
| SIO reset/recovery after line error | No | WR0 error reset command |
| TX frame over Port B (32-byte send path) | No | For IOCALL foreground TX; may use SIO1/A or SIO1/B depending on architecture decision |
| Port A (Bulk) SDLC mode (change WR4) | No | Modify `sio1_ioc_init` |
| WAIT/READY for Bulk | No | WR1 WAIT mode enable/disable around INIR/OTIR |
| INIR/OTIR block transfer helpers | No | New foreground helpers |
| SIO1 WR9 MIE enable | No | Currently 0 |
| Test hooks for loopback / frame echo | No | Useful for hardware bring-up |

---

## 9. Minimal First Implementation Proposal

### Phase 1 — SIO1/B SDLC init only

**Goal:** Configure SIO1/B in SDLC mode and confirm interrupt/status behavior with a logic analyzer or MAME trace. No command protocol.

**Files likely touched:**
- `src/sio_core.asm`: Add `sio1_cmd_init` after `sio1_ioc_init`. Add IM2 table entry at `DD12h`. Extend `sio_core_enable_interrupts` to also enable SIO1/B WR1 and WR9.

**Symbols likely added:**
- `sio1_cmd_init`, `SIO1B_CTRL_PORT` = `33h`, `SIO1B_DATA_PORT` = `32h`

**Estimated resident bytes:** ~60–80 bytes (init sequence + IM2 entry extension)

**Risk:** Medium. Wrong WR4/WR3/WR5 order or missing WR9 sequence can leave SIO1/B in an indeterminate state. Standard SIO initialization sequence must be followed exactly.

**Validation:** After boot, read SIO1/B RR0 from a monitor command. Confirm no spurious interrupts. MAME trace confirms IM2 dispatch to stub ISR.

---

### Phase 2 — Port B ISR + event ring + user-land poll API

**Goal:** The full interrupt-driven frame receive chain is in place in BIOS. User-land code polls for pending frames and processes them. The VDrip console driver and the textq path are **not touched in this phase.** The console driver replacement is a separate, later project.

**What this phase establishes:**

```
SIO1/B interrupt → ioc_cmd_isr → staging buffer → EoF → event ring
user-land .com → BIOS IOC_POLL call → returns pointer/copy of next pending frame → user-land decodes it
```

The BIOS adds a foreground polling entry point that user-land code can call to retrieve the next pending IOC frame. This does not require callback registration or interrupt-time user-land calls — it is a simple synchronous poll:

```
IOC_POLL:
    In:  nothing (or optional frame class filter in A, 0 = any)
    Out: if frame pending:
             copy 32-byte frame to caller-provided buffer (or return pointer)
             A = BIOS_OK
         if no frame pending:
             A = BIOS_ERR (or a distinct "no frame" status)
```

`IOC_POLL` would be exposed as a new extended BIOS jump table entry after `VIDEO_SEND` (appended, never reordering existing entries per AGENTS.md).

**Files likely touched:**
- `src/sio_core.asm` or new `src/cbios_ioc_cmd.asm`:
  - `ioc_cmd_isr`: byte-by-byte receive into staging buffer, EoF → copy to event ring.
  - `ioc_dispatch_pending` / `ioc_poll_frame`: foreground call; if ring non-empty, copy oldest frame to caller buffer, advance tail, return OK; else return no-frame status.
  - Event ring state: `ioc_ring_head`, `ioc_ring_tail`, `ioc_ring_count`, `ioc_ring_overflow`.
  - Staging buffer and event ring in scratch `FD00h` area.
- `src/zephyr.asm`: Append `jp IOC_POLL` to the extended BIOS jump table after `VIDEO_SEND`.
- `src/cbios_defs.inc`: Add `IOC_POLL` address constant.

**Symbols likely added:**
- `ioc_cmd_isr`, `ioc_cmd_staging_buf`, `ioc_event_ring`, `ioc_ring_head`, `ioc_ring_tail`, `ioc_ring_count`, `ioc_ring_overflow`, `IOC_POLL`, `ioc_poll_frame`

**Estimated resident bytes:** ~170–220 bytes (ISR body + ring state + poll function + jump table entry)

**Risk:** Medium–high. First live SDLC interrupt path. RESET_HIGHEST_IUS for SIO1 must be correct.

**Key invariant:** `ioc_cmd_isr` does not decode frame content. `ioc_poll_frame` does not decode frame content. The `.com` program that calls `IOC_POLL` interprets the 32-byte frame itself.

**VDrip:** Completely untouched. VDrip remains the active console and storage backend throughout this phase. It will be removed after Phase 5, not before. The existing console continues to work exactly as before.

**Validation:** A small test `.com` (e.g., `IOCTEST.COM`) loads from drive A. It loops calling `IOC_POLL`. MCU artificially generates one or more unsolicited frames of a test class. `IOCTEST.COM` receives each frame and prints the raw bytes. Confirms ISR, event ring, and poll API are all working end-to-end without any console driver changes.

---

### Phase 3 — User-land IOCALL: solicited request/reply (PING, RESET, STATUS, etc.)

**Goal:** User-land tools send solicited command frames and receive reply frames. IOCALL is a dumb fixed-frame synchronous transport. The tools decode their own replies. The BIOS never knows what PING or RESET means.

```
PING.COM:
    build 32-byte TX frame in app RAM  (class=PING, seq=01h, payload=...)
    provide 32-byte RX buffer in app RAM
    call IOCALL (HL=tx_frame, DE=rx_buffer)
    check RX buffer fields directly — byte[0]=class, byte[2]=status, etc.
    print result
```

IOCALL sends the TX frame over SIO1/B (or SIO1/A — architecture decision TBD for this path), waits `IOC_RTS_SETTLE_DELAY`, then polls the event ring for a reply frame matching the expected sequence number. Matching reply is copied to the caller RX buffer. IOCALL returns. Caller decodes.

Unsolicited frames that arrive while IOCALL is waiting for a reply are stored in the event ring and remain available to `IOC_POLL` after IOCALL returns. They are not discarded.

**Files likely touched:**
- `src/cbios_iocall.asm`: Update to fixed-frame calling convention (HL=tx_frame, DE=rx_frame). After TX, poll event ring for reply with matching sequence number. Copy to caller RX buffer. Return transport status.

**Symbols likely added:**
- Updated `IOCALL` body, `ioc_iocall_wait_reply`

**Estimated resident bytes:** ~60–80 bytes (updated IOCALL; Phase 2 provides ISR and event ring)

**Risk:** Low–medium. Phase 2 provides all the infrastructure. The main new risk is sequence-number matching: stale reply frames from a prior call must not satisfy a new IOCALL. A simple sequence counter per IOCALL call handles this.

**VDrip:** Completely untouched. VDrip remains the active console and storage backend throughout this phase. It will be removed after Phase 5, not before.

**Validation:**
- `PING.COM`: sends PING frame, receives and prints reply frame bytes. Confirms solicited round-trip.
- `RESET.COM`, `STATUS.COM`: exercise other command classes. Each tool builds and decodes its own frames.
- Run `IOCTEST.COM` (from Phase 2) after a IOCALL to confirm unsolicited frames queued during IOCALL are still retrievable via `IOC_POLL`.

---

### Phase 4 — Port A bulk echo test

**Goal:** Z80 sends 128 bytes from MOVE_BUFFER to SIO1/A. MCU echoes 128 bytes back. Z80 receives. Compare.

**Start with byte-by-byte polling** (existing `sio1_ioc_put_byte`/`get_byte` loops) before adding `INIR`/`OTIR`. This confirms the RTS handshake causes the MCU to start clocking, without the deadlock exposure of WAIT mode.

Once byte-by-byte echo works, introduce WAIT-paced block I/O:

1. Assert RTS, wait `IOC_RTS_SETTLE_DELAY` T-states (fixed delay, TBD value).
2. Enable SIO1/A WAIT mode.
3. Execute `OTIR` (send) or `INIR` (receive) for the full 128-byte block.
4. Disable SIO1/A WAIT mode.
5. Release RTS.

**Files likely touched:**
- `src/sio_core.asm` or new `src/cbios_ioc_artery.asm`: Add `ioc_bulk_send_block` and `ioc_bulk_recv_block`. Change SIO1/A WR4 to SDLC mode.

**Symbols likely added:**
- `ioc_bulk_send_block`, `ioc_bulk_recv_block`, `ioc_bulk_wait_enable`, `ioc_bulk_wait_disable`

**Estimated resident bytes:** ~80–100 bytes (two block transfer helpers + WAIT control)

**Risk:** High. First INIR/OTIR use. WAIT deadlock is possible if WAIT mode is enabled while the MCU is not clocking, or left enabled after transfer. The MCU must commit to clocking for the full declared block before INIR/OTIR is issued. Must only be exercised with MCU active and RTS handshake confirmed working.

**Validation:**
1. Byte-by-byte: user-land tool fills `MOVE_BUFFER`, asserts RTS, sends byte-by-byte, receives byte-by-byte, compares. Confirms RTS → clock handshake.
2. Block: repeat with WAIT-paced INIR/OTIR. Sweep transfer counts from 1 to 128 bytes. Tune `IOC_RTS_SETTLE_DELAY` to the minimum value that is reliable.

---

### Phase 5 — New IOC storage and console drivers (hardware required)

**Prerequisite:** IOC transport (Phases 1–4) proven. Hardware complete: real video card, USB HID interface, and SD card reader all connected to and serving the IO Controller MCU.

**This phase is not started until the hardware exists.** Phases 1–4 use VDrip as the console and storage backend throughout.

#### Phase 5a — IOC storage driver

**Goal:** Write `cbios_storage_ioc.asm` as a new storage backend. ~80–90% new code. Sector READ/WRITE use Port B 32-byte command frames + Port A 128-byte INIR/OTIR payloads. The SD card is served by the MCU; the BIOS only issues IOC frames.

**Sequence:**

1. Add `cbios_storage_ioc.asm`. Build-time flag selects IOC vs VDrip backend in `cbios_storage.asm`.
2. Verify `DIR`, file read, file write, `MBASIC`, `BBC BASIC`, Turbo Pascal on the IOC backend.
3. Remove `cbios_storage_vdrip.asm` and all VDrip storage packet constants.

**Files touched:**
- New `src/cbios_storage_ioc.asm`
- `src/cbios_storage.asm` (backend selector)
- Remove `src/cbios_storage_vdrip.asm`

#### Phase 5b — IOC console driver

**Goal:** Write `cbios_console_ioc.asm` as a new console driver driving the real video card. The IOC event ring subscriber model (from Phase 2) delivers keyboard input as CONSOLE_INPUT frames. Output goes directly to the video card hardware, not through VDrip packets.

**VT-100 code handling:** The ANSI/VT-100 terminal handling logic (CSI parser, cursor movement, scroll, erase operations) from `cbios_console_vdrip.asm` is **copied as source** into `cbios_console_ioc.asm`. The VDrip-specific output path (packet framing, `vdrip_send_packet`, shadow-to-proxy blast, proxy cursor commands) is replaced with direct video card writes. No VDrip code remains resident.

**Sequence:**

1. Add `cbios_console_ioc.asm` with the CONSOLE_INPUT subscriber, the copied VT-100 parser, and the video card output path.
2. Verify interactive use, `MBASIC`, `BBC BASIC`, Turbo Pascal, SuperCalc all working.
3. Remove `cbios_console_vdrip.asm`, `src/vdrip_font.asm`, `src/virtual_drip_protocol.inc`, and all VDrip proxy infrastructure.

**At the end of Phase 5b:** VDrip is fully removed. All driver slots 0–5 (~6 KB) are occupied by the new IOC console and storage drivers. The system runs entirely on the real IO Controller hardware.

**Risk:** High for both sub-phases. Hardware bring-up issues are likely. Run 5a and 5b sequentially, not in parallel.

---

## 10. Size Impact Assessment

### New resident code (incremental per phase)

| Component | Phase | Estimated bytes |
|---|---|---:|
| IM2 table extension (`DD12h–DD13h`) | 1 | 2 |
| SIO1/B SDLC init (`sio1_cmd_init`) | 1 | 55–70 |
| Command ISR (`ioc_cmd_isr`, byte-by-byte + EoF → ring) | 2 | 80–100 |
| ISR staging buffer (32 bytes, in scratch) | 2 | 32 (data) |
| IOC event ring, depth=2 (64 bytes, in scratch) | 2 | 64 (data) |
| Event ring state variables (`head`, `tail`, `count`, `overflow`) | 2 | 4 (state) |
| Foreground dispatcher (`ioc_dispatch_pending`) | 2 | 35–50 |
| Console subscriber (`ioc_console_subscriber`) | 2 | 25–35 |
| Fixed-frame IOCALL (32-byte TX + RX frame pointers) | 3 | 60–80 |
| IOCALL reply wait (poll event ring for matching seq) | 3 | 20–30 |
| Port A SDLC init change to `sio1_ioc_init` | 4 | 15–20 |
| Port A WAIT-enable/disable helpers | 4 | 20–25 |
| Port A block-send (`ioc_bulk_send_block`) | 4 | 35–45 |
| Port A block-recv (`ioc_bulk_recv_block`) | 4 | 35–45 |
| Timeout/error recovery | 2–4 | 25–35 |
| **Total code estimate** | | **~390–470 bytes** |
| **Total data/state estimate** | | **~100 bytes in scratch/state** |

### Available unallocated resident code space

| Region | Bytes available |
|---|---:|
| `F52Ch–F67Fh` (after VDrip console tail, before slot 5) | ~340 |
| `F680h–F7EAh` (slot 5 before VDrip storage) | ~363 |
| **Total** | **~703 bytes** |

The estimated ~370–440 bytes of new code fits comfortably within the ~703 bytes of available space. No existing driver region need be relocated.

### Scratch and runtime state usage

**Unused scratch `FD00h–FDFFh` (256 bytes):**

| Buffer | Size |
|---|---:|
| ISR staging buffer (`ioc_cmd_staging_buf`) | 32 |
| IOC event ring, depth=2 (`ioc_event_ring`) | 64 |
| Reserved for depth=4 upgrade | 64 |
| **Total used** | **96–160** |
| **Remaining** | **96–160** |

No pressure. The scratch window is currently empty and is the correct home for ISR-written buffers. MOVE_BUFFER (`FA80h`) is not used here.

**Runtime state gaps (73 bytes available):**

Ring state variables (`ioc_ring_head`, `ioc_ring_tail`, `ioc_ring_count`, `ioc_ring_overflow`) = 4 bytes. Fits in `FE79h–FE7Fh` (7 bytes available) with 3 bytes to spare.

### VDrip code that will be removed — and what is copied forward

VDrip is a temporary development proxy. When the IO Controller hardware and BIOS are proven, **all VDrip resident code is removed**. No VDrip module is retained as a fallback.

**Storage driver (~80–90% rewritten):**
The IOC storage driver (`cbios_storage_ioc.asm`) is mostly new code — IOC command frame construction, Port B/Port A sector transport, and IOC-specific reply handling. The small amount of geometry-neutral CP/M glue (DPB constants, BDOS-facing sector/track/DMA state) may be adapted, but the transport layer is entirely different. `cbios_storage_vdrip.asm` is deleted.

**Console driver (new driver, VT-100 code copied):**
The IOC console driver (`cbios_console_ioc.asm`) is a new driver. It drives a **real hardware video card**, not the VDrip proxy renderer. The VT-100 terminal handling logic (ANSI/CSI parser, cursor movement, scroll, erase, SGR consumption) is substantial and already correct — it will be **copied** from `cbios_console_vdrip.asm` into the new driver as source code. It does not remain resident as part of VDrip. The VDrip-specific pieces — packet framing, `vdrip_send_packet`, `crc8_update`, shadow-to-VDP blast, proxy cursor commands, RTS/CTS flow control for the SIO0/B serial link — are all deleted. The new driver substitutes direct video card writes for the VDrip output path.

**Hardware prerequisite:**
The new console and storage drivers are written when the hardware is complete:
- Real video card connected and addressable.
- USB HID interface on IO Controller MCU (keyboard input translated to VT-100 bytes before reaching Z80).
- SD card reader connected to IO Controller MCU (sector read/write accessible via IOC command frames).

Neither the IOC console driver nor the IOC storage driver should be started before the corresponding hardware is present and the IOC transport (Phases 1–4) is proven.

**Resident space freed:**

| Region | Size | Notes |
|---|---:|---|
| VDrip console driver (slots 0–4 + overflow, ~E000h–F52Bh) | ~5.4 KB | Deleted entirely |
| VDrip storage backend (slot 5 partial, ~F7EBh–FA7Bh) | ~0.6 KB | Deleted entirely |
| **Total freed** | **~6 KB** | All driver slots 0–5 available for IOC drivers |

The reclaimed ~6 KB is the budget for the new IOC console and storage drivers, which start with a clean slate in the same slot regions.

---

## 11. Risk Assessment

| Risk | Severity | Mitigation |
|---|---|---|
| **BIOS space pressure** | Low | ~703 bytes available; estimated ~400 bytes needed. Comfortable margin. |
| **ISR latency** | Medium | Command ISR must be bounded. One byte per interrupt entry. No parsing in ISR beyond End-of-Frame check. |
| **MCU not clocking — polling hang** | Medium | Software timeout (`SIO_IOCTRL_TIMEOUT = 0xFFFF`) bounds the hang for polled paths. Never issue a polled send or receive without first asserting RTS and ensuring the MCU is active. |
| **MCU not clocking — WAIT deadlock** | **Critical** | If WAIT mode is enabled and the MCU stops or never starts clocking, the Z80 stalls with no escape. WAIT mode must be bracketed: enable immediately before `INIR`/`OTIR`, disable immediately after. Never enable persistently. Never issue INIR/OTIR unless the MCU has committed to clocking for the full block. |
| **MCU clock settle delay (TBD value)** | Low | Fixed delay after RTS assert before transfer start. Delay constant (`IOC_RTS_SETTLE_DELAY`) is TBD; determined during bring-up. Polled paths tolerate a wrong value via software timeout. WAIT-mode paths do not — WAIT-mode INIR/OTIR must only be used when MCU is confirmed active. |
| **INIR/OTIR mid-transfer clock withdrawal** | High | If the MCU withdraws its clock partway through a block transfer, the Z80 stalls in WAIT or produces garbage in polling mode. The MCU must guarantee clock for the declared transfer length. This is a MCU firmware contract, not a BIOS-only concern. |
| **SDLC init order** | Medium | Z80 SIO register write order matters. WR0 reset must be first. WR4 sets sync mode before WR3/WR5. Document the exact sequence. |
| **Frame receive in ISR vs foreground** | Medium | Phase 1–2: ISR writes frame buffer byte-by-byte. Foreground dispatches. This separates timing-critical collection from processing. |
| **textq overflow under bursty keyboard events** | Low | textq is 128 bytes. Keyboard frames are consumed in the foreground dispatcher, not the ISR. Overflow drops silently; acceptable for CP/M interactive use. |
| **IOC event ring overflow** | Low–medium | With ring depth=2 and frequent CONST polling, overflow is unlikely. If the foreground dispatcher is called rarely (e.g., a tight compute loop), keyboard frames can be dropped. The `ioc_ring_overflow` flag allows detection. |
| **Frame class demux error** | Low | `frame[0]` determines which subscriber handles the frame. If `frame[0]` is an unknown class, the dispatcher must discard cleanly (not crash). The initial subscriber table needs a default no-op fallback. |
| **IOCALL solicited/unsolicited collision** | Medium | If a solicited reply arrives while the event ring is full of unsolicited frames, the reply may be dropped. Sequence number matching in IOCALL's reply-wait loop must handle missed frames gracefully (retry or timeout, not hang). |
| **Port A INIR/OTIR timing** | High | First INIR/OTIR use. MCU clock rate, /WAIT pulse width, and RTS acknowledgement must all be confirmed on real hardware before relying on INIR for production storage. Start with byte-by-byte polling. |
| **CP/M sector correctness** | High | CP/M BDOS is unforgiving about sector errors. Phase 5 should run alongside VDrip storage initially. |
| **Cold boot / warm boot ordering** | Medium | `sio_core_init` (called from both boot and wboot) currently calls `sio1_ioc_init`. Adding `sio1_cmd_init` must be done in the same call chain and be idempotent. |
| **SIO1/A vs SIO1/B interrupt priority** | Low | In the SIO, channel A has higher priority than channel B. SIO1/A (Bulk) is polled and has no interrupt. This is fine: only SIO1/B (Command) uses interrupts. No priority conflict. |
| **VDrip coexistence during build-up** | None | The IO Controller path (SIO1) and VDrip path (SIO0) are on different SIO chips. They share no channels, ports, or state. All IOC phases coexist safely with VDrip. VDrip is removed when IOC is complete; the removal itself is a separate phase. |

---

## 12. Files and Symbols Likely Involved

### Files touched

| File | Phase | Change |
|---|---|---|
| `src/sio_core.asm` | 1, 2 | Add `sio1_cmd_init`, extend IM2 table, add `ioc_cmd_isr`, extend `sio_core_enable_interrupts` |
| `src/cbios_iocall.asm` | 3 | Add foreground IOCALL_REPLY polling path |
| `src/platform_zephyr80.inc` | 1 | Add `SIO1B_DATA_PORT`, `SIO1B_CTRL_PORT` aliases if missing |
| `src/cbios_defs.inc` | 1 | Add runtime state symbols for frame buffer and state |
| `src/cbios_boot.asm` | 1 | Ensure `sio1_cmd_init` is called from boot and wboot init sequences |

### Files not touched

| File | Reason |
|---|---|
| `src/cbios_console_vdrip.asm` | VDrip console is untouched |
| `src/cbios_storage_vdrip.asm` | VDrip storage remains as-is through Phase 4 |
| `src/cbios_console.asm` | Console facade unchanged |
| `src/cbios_storage.asm` | Storage facade unchanged |
| `src/cbios_bank.asm` | Banking unchanged |
| `src/zephyr.asm` | Jump table unchanged; `IOCALL` entry already present |

### New symbols (cumulative through all phases)

| Symbol | Phase | Kind | Notes |
|---|---|---|---|
| `SIO1B_DATA_PORT` | 1 | Constant | `32h` |
| `SIO1B_CTRL_PORT` | 1 | Constant | `33h` |
| `SIO1_CMD_VECTOR` | 1 | Constant | IM2 vector byte `12h` |
| `IOCB_FRAME_SIZE` | 1 | Constant | `32` |
| `IOC_RTS_SETTLE_DELAY` | 1 | Constant | T-states to wait after RTS assert before transfer; TBD, tuned at bring-up |
| `sio1_cmd_init` | 1 | Code | SIO1/B SDLC init |
| `ioc_cmd_isr` | 2 | Code | SIO1/B ISR: byte → staging → EoF → event ring |
| `ioc_cmd_staging_buf` | 2 | Data (scratch) | 32-byte in-progress receive buffer at `FD00h` |
| `ioc_cmd_staging_count` | 2 | State | Bytes received into staging buffer |
| `ioc_cmd_staging_error` | 2 | State | Error flag for in-progress frame |
| `ioc_event_ring` | 2 | Data (scratch) | 2 × 32-byte frame ring at `FD20h` |
| `ioc_ring_head` | 2 | State | Ring write index |
| `ioc_ring_tail` | 2 | State | Ring read index |
| `ioc_ring_count` | 2 | State | Pending frame count |
| `ioc_ring_overflow` | 2 | State | Dropped-frame flag |
| `ioc_dispatch_pending` | 2 | Code | Foreground: drain ring, call subscriber by frame class |
| `ioc_console_subscriber` | 2 | Code | CONSOLE_INPUT frame → `textq_put_ascii` loop |
| `IOCALL` (updated) | 3 | Code | Fixed-frame: HL=tx_frame, DE=rx_frame |
| `ioc_iocall_wait_reply` | 3 | Code | Poll event ring for reply with matching seq |
| `ioc_bulk_wait_enable` | 4 | Code | Enable SIO1/A WR1 WAIT mode |
| `ioc_bulk_wait_disable` | 4 | Code | Disable SIO1/A WR1 WAIT mode |
| `ioc_bulk_send_block` | 4 | Code | OTIR-based block send over SIO1/A |
| `ioc_bulk_recv_block` | 4 | Code | INIR-based block receive over SIO1/A |

---

## Recommended Next Implementation Prompt

The target architecture is documented in Section 7b. The complete frame delivery model is:

```
ISR → staging buffer → EoF → event ring → dispatcher → subscriber
```

IOCALL is a dumb synchronous transport (Section 7b, "Solicited frames"). It sends a fixed 32-byte TX frame and polls the event ring for a reply. It does not decode frame content.

The console subscriber is one of potentially several subscribers. It is the only path that writes to textq.

When ready to begin implementation, the following prompt describes Phase 1 precisely:

> **Task:** Add `sio1_cmd_init` to `src/sio_core.asm`.
>
> This routine must:
> - Program SIO1/B (ports `32h/33h`) in SDLC mode (WR4 bits 5:4 = 10), x1 clock, no parity, WR7 = `7Eh` flag.
> - Enable WR3 Rx CRC, 8-bit, Enter Hunt, Rx enable.
> - Enable WR5 Tx CRC, 8-bit, RTS inactive.
> - Leave WR1 interrupts disabled (ISR added in Phase 2).
> - Leave SIO1 WR9 MIE disabled.
> - Extend the IM2 table at `DD12h–DD13h` with a placeholder `.dw sio1_cmd_isr_stub` (a two-instruction RETI stub) so Phase 2 can fill in a real ISR.
>
> Add `sio1_cmd_init` to the `sio_core_init` call chain.
> Add `SIO1B_DATA_PORT` and `SIO1B_CTRL_PORT` to `platform_zephyr80.inc` if not already present.
> No behavior change to VDrip, IOCALL, textq, console, or storage.
> Build. Inspect the listing to confirm: IM2 table is 4 bytes (`DD10h–DD13h`), `sio1_cmd_init` does not overlap any existing code.
> Do not enable SIO1 interrupts. Do not change WR9.

---

## Appendix: Current Address Reference

| Symbol | Address | Notes |
|---|---:|---|
| `IOCALL` (jump table) | `DA3Fh` | Extended BIOS table entry |
| `IOCALL` (code) | `DF7Bh` | `IOCTRL_CODE_START` |
| `IOCTRL_CODE_END` | `DFFCh` | 4 bytes before core BIOS limit |
| `SIO_CORE_CODE_START` / IM2 table | `DD10h` | Start of SIO core and IM2 entry |
| `sio_core_isr` | `DEAFh` | Active SIO ISR (SIO0/B only) |
| `sio1_ioc_init` | `DD4Dh` | SIO1/A init (external-sync, not SDLC) |
| `sio1_ioc_put_byte` | `DE6Ah` | SIO1/A polled TX byte |
| `sio1_ioc_get_byte` | `DE6Fh` | SIO1/A polled RX byte |
| `SIO1_RX_SINK` | `FE72h` | Null sink slot for SIO_CH_IOCTRL |
| `textq_put_ascii` | ~`E1D5h` | ISR-safe CONIN FIFO enqueue |
| `MOVE_BUFFER` | `FA80h` | 192-byte staging buffer |
| Unused scratch | `FD00h–FDFFh` | 256 bytes, available for frame buffer |
| Available code gap | `F52Ch–F7EAh` | ~703 bytes for new IOC code |
