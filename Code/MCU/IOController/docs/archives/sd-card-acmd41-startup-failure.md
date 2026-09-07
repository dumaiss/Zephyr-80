# SD card ACMD41 startup failure

## Status and scope

This note records the diagnosis and proposed remediation for an intermittent
SD-card startup failure. Phases 1 and 2 are verified. Phase 2 proves that the
bounded protocol-recovery path runs, but that recovery does not clear the
observed card state. Connector rework, reported level measurements, and a
three-card comparison now show that the remaining failure follows one card
brand rather than the socket in general; later diagnostic phases remain
pending.

Earlier observed behaviour, before the three-card comparison:

- A card that is physically installed may be reported to CP/M as unavailable.
- Repeating the access without removing the card does not reliably recover it.
- Ejecting and reinserting the card makes it start working.
- The CP/M fallback to drive A works, but the displayed `No Disk` result hides
  the distinction between an SD failure and an IOC transport failure.

The drive mapping, disk geometry, cache layout, BIOS jump table and CP/M error
recovery are outside the scope of this issue.

## Card comparison after connector rework

The following results were reported on 2026-09-04 after deployment of the BIOS
containing the direct V9958 console:

| Card | Result with current BIOS |
|---|---|
| Generic INDMEM 16 GiB SDHC, card 1 | Cannot select CP/M drive B and cannot use `SDREAD.COM`. |
| Generic INDMEM 16 GiB SDHC, card 2 | Same failure as the first INDMEM card. |
| SanDisk 4 GiB SDHC microSD in an adapter | Works reliably, including when already installed at boot. |

Before this comparison, all SD-card connector joints were reflowed and the
observed signal levels were measured as correct. Those checks substantially
reduce the likelihood of a bad solder joint, gross DC-level error, or a socket
that is unusable with every card. The reliable SanDisk result also proves that
the current BIOS, IOC transport, card-detect path, SPI peripheral, and physical
socket can complete initialization and serve disk requests in at least one
real configuration.

The result does not prove that the direct-console BIOS change caused the SD
failure. The same BIOS works with the SanDisk card, and the console does not
change the SD command sequence. The new image may still have changed boot
timing or aggregate power activity enough to expose a marginal, card-specific
startup characteristic.

Brand, controller/batch, capacity, physical card construction, and the use of
an adapter are confounded in this small sample. Both failing cards should be
treated as one card-family result, not as two statistically independent card
designs. No current-image per-card SPI trace has yet established that both
INDMEM cards fail with the exact same R1 sequence as the earlier ACMD41
capture; that remains an important verification step.

## Captured evidence

Immediately after a failure, `PING.COM` reported:

```text
SD SPI trace: 01 01 01 05 AF 04 FF 02
```

The eight bytes were recorded by `sd_card_init()` as follows:

| Byte | Value | Meaning |
|---|---:|---|
| 0 | `01` | Final CMD0 R1: card entered SPI idle state |
| 1 | `01` | CMD8 R1: command accepted while idle |
| 2 | `01` | Final CMD55 R1: command accepted while idle |
| 3 | `05` | Final ACMD41 R1: idle-state and illegal-command bits set |
| 4-5 | `04AF` | Final retry index 1199, stored little-endian as `AF 04` |
| 6 | `FF` | SPI1 baud divisor 255, or 125 kHz from the 64 MHz clock |
| 7 | `02` | Card-present input active; no SPI1 transfer timeout |

CMD8's four-byte R7 trailer is also validated by the driver before it reaches
the ACMD41 loop. The trace therefore shows a present, communicating card that
accepted CMD0, returned a valid CMD8 result, accepted the final CMD55, and
rejected the final ACMD41. It does not record the preceding 1,199 ACMD41
responses, so the original conclusion that every attempt returned `05` was
stronger than the captured evidence supports.

This is not a card-detect failure and is not an all-`FF` no-response failure.
The stable, command-specific R1 replies also make gross SPI corruption less
likely, although they do not rule out power or contact trouble.

## Why SDREAD reports transport error 11

`SDREAD.COM` subsequently reported:

```text
transport error 0x11
rx A5 A5 A5 ...
```

This `11` is the BIOS transport code
`IOC_XPORT_TIMEOUT_REPLY_MARKER`, not MCU SD status
`IOC_STATUS_SD_UNUSABLE`. `SDREAD.COM` fills its receive buffer with `A5`
before calling IOCALL, so an unchanged buffer means that no reply packet was
received before the host stopped waiting.

There is a timing-budget mismatch between the current host and MCU sources:

- SD initialization runs at 125 kHz, or 64 microseconds per SPI byte.
- One ACMD41 iteration sends CMD55 and CMD41. Even with an immediate R1, the
  two calls need at least 16 SPI bytes, or about 1.024 milliseconds.
- The 1,200 iterations therefore have a theoretical minimum of about 1.23
  seconds before call, loop and initialization overhead.
- The BIOS command-byte timeout was reduced to approximately 1.5 seconds by
  setting `SIO_COMMAND_TIMEOUT_OUTER` to `04`.
- The timing comments in `sd_card.c` still calculate the initialization loop
  using 400 kHz and the former approximately 10.7-second host timeout.

Consequently, a complete failed initialization can finish at or after the
host timeout. The MCU is expected to return `IOC_STATUS_SD_NOT_READY` (`12`),
but the host may stop listening just before that reply is transmitted and
instead report transport error `11` with its untouched `A5` buffer.

This transport timeout masks the SD failure; it does not cause the card to
reject ACMD41.

## Updated hypotheses

### 1. Shared INDMEM controller, firmware, or media-quality problem

This is now the leading hypothesis. Two cards carrying the same generic brand
fail while a reputable card of the same SDHC generation works reliably in the
same socket with the same firmware. The two INDMEM cards may share the same
internal controller, controller firmware, production lot, or non-conforming
implementation. They may also be relabelled, counterfeit, or defective media;
none of those possibilities is established merely by the printed brand and
capacity.

The earlier trace is particularly suspicious for a purported SD v2/SDHC card:
the card accepts CMD8 and CMD55 but reports ACMD41 as illegal. The current
driver sends HCS in ACMD41 for a v2 card, which is the expected SDHC sequence.
If both INDMEM cards reproduce that trace, the evidence would point strongly
to a shared card-controller compatibility or compliance defect rather than a
normal SDHC capacity difference.

### 2. Card-specific power-up, inrush, or brownout sensitivity

Reflow and correct measured logic levels do not by themselves exclude a 3.3 V
ramp problem or a short supply dip during a card's initialization-current
peak. The two 16 GiB cards may use the same controller and flash organization
and therefore present similar inrush or reset timing, while the SanDisk
controller tolerates the board's rail behavior. An internal brownout can leave
a card responsive enough to accept CMD0, CMD8, and CMD55 but with its
application-command state machine malfunctioning until power is fully removed.

This remains plausible because protocol restart cannot perform a true card
power cycle. It should be evaluated with an oscilloscope at the socket during
both an INDMEM failure and a SanDisk success; a steady-state reading is not
sufficient to rule it out.

### 3. Non-standard card timing or SPI transaction expectations

The driver now uses complete command transaction boundaries, trailing clocks,
a standards-compliant 125 kHz initialization clock, and one bounded protocol
restart. A conforming SDHC card should not require more. A marginal or
non-conforming controller may nevertheless depend on a longer post-power
delay, a different initialization frequency within the allowed 100-400 kHz
range, more CS-high clocks, or undocumented spacing between CMD55 and ACMD41.
The two INDMEM cards could behave identically if they use the same controller
firmware.

Any timing experiment should change one parameter at a time in a diagnostic
build. A workaround should not be promoted to the normal driver until traces
show which condition changes the card's response.

### 4. Card-dependent signal integrity or loading

This is less likely than the first three hypotheses but is not eliminated by
correct DC levels. SPI clock edges remain fast even at a 125 kHz repetition
rate, and different cards present different input capacitance, thresholds,
output drive, and supply-current transients. The microSD adapter also changes
the contact stack and electrical loading. A scope comparison at the SD-side
pins can distinguish clean command bytes from ringing, slow edges, or MISO
contention that affects only the INDMEM cards.

### 5. New-BIOS timing or system-load interaction

The onset was noticed after deployment of the BIOS with the direct V9958
console, so that correlation should remain in the record. It is not evidence of
a general SD software regression because the SanDisk card works reliably under
the same image. A plausible narrower interaction is that the new boot path
changes when the first SD operation occurs, or changes simultaneous system
power demand, exposing a startup weakness shared by the INDMEM cards.

### Explanations now considered unlikely

- A bad connector joint or gross static voltage error: the joints were
  reflowed, levels check correctly, and the SanDisk card works in the socket.
- SDHC capacity handling: initialization fails before CMD58 establishes CCS
  and before any block address is issued; both 4 GiB and 16 GiB cards use the
  same v2/HCS initialization path.
- Card presence: trace byte 7 proves the presence input was active in the
  earlier capture.
- A cached absent state: failed initialization is not negatively cached, and a
  subsequent explicit SD operation retries initialization.
- SPI peripheral timeout: trace byte 7 has the bus-failure bit clear.
- MMC compatibility: the validated CMD8 result identifies an SD v2-style
  response, so adding CMD1 as a fallback would hide rather than explain the
  fault.

## Proposed remediation plan

Apply and test each phase independently. Do not combine these changes with
drive mapping, geometry, cache, or other BIOS work.

### Phase 1: make the failure report reliable

1. Increase the BIOS command reply timeout from approximately 1.5 seconds to
   approximately 3 seconds. `SIO_COMMAND_TIMEOUT_OUTER = 08` matches the
   existing command-ready timeout scale and gives the 125 kHz failure path
   useful margin.
2. Update the stale timing comments in `sd_card.c` to use the actual 125 kHz
   initialization clock and current host timeout.
3. Reproduce the failure and confirm that `SDREAD.COM` now receives MCU status
   `12` and the eight-byte trace instead of transport error `11`.

This phase improves observability only. It is not expected to make ACMD41
succeed.

### Phase 2: make initialization and recovery more conservative

Make the smallest targeted change to `sd_card_init()`:

1. Preserve the required startup sequence: CS high, MOSI high, at least 74
   clocks, then CMD0 at 100-400 kHz.
2. Give each command a complete transaction boundary: select, send command,
   receive its complete response, deselect, and provide the trailing clocks.
3. Send CMD55 and ACMD41 as two complete command transactions while preserving
   their required adjacency.
4. Validate CMD55 before issuing ACMD41.
5. If ACMD41 repeatedly returns `05`, stop the identical polling loop early
   and run one complete protocol-recovery attempt:
   - deselect the card;
   - provide at least 80 clocks with CS and MOSI high;
   - wait for a short settling interval;
   - restart initialization from CMD0.
6. If the second complete initialization still returns illegal-command for
   ACMD41, fail promptly with a diagnostic status instead of consuming all
   1,200 iterations.

Do not add CMD1 as a fallback unless a separate capture demonstrates an MMC or
pre-v2 SD card. The current CMD8 evidence does not support that path.

Implementation note: the first implementation required eight consecutive
ACMD41 `05` responses. Bench testing of the verified Phase 2 image still ended
at retry 1199, exposing that the final-response trace could not justify that
condition. The revised implementation counts eight total `05` responses in
the first initialization, so intervening idle replies do not suppress the one
protocol-recovery attempt. The restarted initialization fails on its first
ACMD41 `05`.

Trace byte 7 now sets bit 2 during the recovery initialization; bits 0 and 1
retain their SPI-timeout and card-present meanings. A persistent failure should
therefore return status `12` with final trace `01 01 01 05 00 00 FF 06`. A
final byte of `02` means the recovery threshold was not reached, while `06`
proves the captured reply came from the recovery pass. A successful recovery
proceeds to the requested card operation normally.

Bench verification of the revised image returned status `12` with:

```text
01 01 01 05 01 00 FF 06
```

The `06` proves that the first initialization reached the illegal-response
threshold and that the complete clocks/settle/CMD0 restart ran. On that second
initialization, ACMD41 returned a non-ready, non-`05` response at retry 0 and
then `05` at retry 1, where the firmware failed promptly as designed. CMD0,
CMD8 and CMD55 were again accepted, the card remained present, and no SPI
transfer timed out. Phase 2 therefore behaves as intended but cannot replace
the power cycle that physical reinsertion provides on this hardware.

### Phase 3: measure the hardware startup condition

Completed Phase 3 observations so far:

- all SD connector joints were reflowed;
- the measured signal levels checked correctly;
- both INDMEM 16 GiB SDHC cards failed with the current BIOS;
- the SanDisk 4 GiB SDHC microSD and adapter worked reliably, including from
  boot.

The remaining comparison should capture these signals at the SD socket during
a failing INDMEM initialization and a successful SanDisk initialization under
otherwise identical boot conditions. If physical reinsertion still changes an
INDMEM result, capture that transition as a third case:

1. Card 3.3 V, including ramp time and minimum voltage during initialization.
2. SD-side chip select, particularly before and during the initial clocks.
3. CLK and MOSI during the CS-high power-up clocks and CMD0.
4. CMD55 and ACMD41 transaction boundaries and their MISO responses.

Also:

- verify continuity and contact resistance under light mechanical movement;
- capture the complete current-image `PING.COM`/`SDREAD.COM` status and trace
  independently for each INDMEM card;
- test both INDMEM cards in a trusted reader or computer and, after backing up
  any required contents, verify their real capacity and full-media integrity;
- record CID/CSD identification for all three cards when available, because
  matching controller/manufacturer fields would strengthen the shared-batch
  hypothesis;
- vary only one diagnostic parameter at a time: post-power delay, CS-high
  startup clocks, or initialization frequency.

The main IO board schematic includes a 10 kOhm pull-up on the MCU-side
`/IO_SD_CS` net, so a completely floating PIC pin is not the leading theory.
The level at the SD side of the mezzanine buffer should still be verified.

### Phase 4: add a controllable card power cycle if required

If protocol recovery fails but eject/reinsert remains reliable, add a load
switch or suitable MOSFET to the card's 3.3 V supply in a future hardware
revision. Give the MCU explicit control and define a recovery sequence with:

1. all SD signals placed in a non-back-powering state;
2. card power disabled long enough for the rail to discharge;
3. card power restored and allowed to settle;
4. the normal CS-high power-up clocks and initialization sequence.

This is the only deterministic firmware-controlled equivalent of physical
reinsertion.

## Verification matrix

After each applicable phase, record results for:

- 20 cold boots with the card already installed;
- 20 first insertions after the system has booted;
- repeated initialization attempts without removing the card;
- both INDMEM 16 GiB cards and the SanDisk 4 GiB card, identified separately;
- `PING.COM` SD trace after every failure;
- `SDREAD.COM` status and receive buffer;
- CP/M selection of drive B and automatic fallback to drive A;
- normal record reads, writes, flushes and cache operation after successful
  initialization.

Success for the software recovery phase means that a card returning ACMD41
`05` can be recovered without physical removal. If only switched power can
meet that condition, the firmware should continue to report the failure
accurately and CP/M should continue falling back safely to drive A.

## Relevant source locations

- `src/sd_card.c`: initialization, trace capture and retry bounds.
- `include/sd_card.h`: SD diagnostics and hardware assumptions.
- `src/handlers.c`: mapping from `SdStatus` to IOC status values.
- `Code/HOST/CPM2.2/src/cbios_defs.inc`: command-channel timeout constants.
- `Code/HOST/HelloWorld/src/ioc_sd_read.asm`: `SDREAD.COM` diagnostics.
