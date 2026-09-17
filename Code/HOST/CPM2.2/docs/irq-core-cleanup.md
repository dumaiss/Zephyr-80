# IRQ core cleanup

The IRQ core now owns I/IM2, vector entries, CPU enable policy, source slots,
full asynchronous context, the saved foreground SP and RETI. SIO is a kernel
client of the same dispatcher as the four user CTC sources. User callbacks
remain restricted to E000h-E3FFh; private kernel registration accepts resident
BIOS code and cannot be reached through BDOS 200/201. Kernel removal requires
the driver to mask its local interrupt sources first.

`irq_save_disable` returns the previous interrupt-enable state in A (0/1).
Each caller retains its token; `irq_restore` restores that state. Both preserve
BC/DE/HL/IX/IY and the alternate registers. The old SIO lock/unlock names now
use this token ABI. All callers in this BIOS were updated. Boot's stackless
entries jump through IRQ-core policy before touching a stack. The command and
bulk IOC lanes retain separate tokens across their existing transfer phases;
their pre-existing transfer blackouts and wire timing loops are unchanged.
The command wait restores the entry state, including an initially disabled
state; it no longer assumes that every caller entered with IRQs enabled.

SIO0/A is reset with WR1 interrupts, RX and TX disabled at cold boot, WBOOT
(before the existing screen hold) and PROGRAM_EXIT. Normal console enable and
disable do not program A's channel configuration. The existing highest-IUS
acknowledgment still uses A's WR0. Z80 SIO has WR0-WR7, unlike SCC; the old
09h/08h "WR9 master enable" sequence selected A's WR1 and has been removed.
See the [Zilog peripherals manual](https://www.zilog.com/docs/z80/um0081.pdf).

The authoritative CTC constants are in `platform_zephyr80.inc`:

| Logical / physical channel | CPU port | Vector |
|---|---|---|
| 0 | 40h | 00h |
| 1 | 42h | 02h |
| 2 | 41h | 04h |
| 3 | 43h | 06h |

Reset-all uses those constants; individual shutdown uses a table built from
them. Unregister, unowned interrupts and application exit all call that helper.

## Context and stack budget

Every CTC and SIO interrupt saves AF/BC/DE/HL, IX/IY and AF'/BC'/DE'/HL'.
The fixed context is 20 bytes; the callback return address adds 2. The existing
FE82h-FEBFh stack is 62 bytes, leaving **40 bytes for callback pushes and
callee return addresses**. The registered SIO service reaches 28 bytes in the
instruction-level regression (including a sink that clobbers every saved
register and calls the token helpers). The production serial sink is also
exercised. Arbitrarily deep user callbacks are not supported; the 40-byte
limit includes their complete call tree. There is no need to move or enlarge
the stack for these bounded paths.

Only the CPU return PC lands on the foreground stack. ISR callbacks stay
masked; the IRQ core executes EI immediately before RETI, using the Z80's
delayed enable. A test-side active check rejects enables inside callbacks and
checks that the saved SP survives the interrupt. There is no production
sentinel or extra ISR traffic. Polling SIO dispatch also preserves index and
alternate registers. CPU interrupt rules follow the
[Zilog CPU manual](https://www.zilog.com/docs/z80/um0080.pdf); the existing
LD A,I retry for the NMOS false-negative sampling window is retained centrally.

## Placement

No existing runtime region or driver slot moved. The new code uses free space:

| Range reserved | Prior use | New use |
|---|---|---|
| EFA0h-EFFFh | Unused facade tail (facade ends EF91h) | SIO0/A ownership return |
| FC98h-FCDFh | Unallocated | IRQ policy and polling context helper |
| FCE0h-FCFFh | Unallocated | CTC channel shutdown table/helper |
| FF60h-FFFFh | Unallocated above facade stack | IRQ registration |

The facade's allocation limit is now EFA0h; its entry and existing code stay
put. BIOS remains F000h, CCP E400h, BDOS facade EC06h, IM2 FD00h and the floating
FFh vector target F7F7h. TPA, program ISR reservation, stacks, staging buffers,
storage layout, drive mappings and geometry are unchanged. This checkout's
normal configuration is V9958 console / ROM drive A:, not RAM-disk drive A:.
No storage backend was removed or disabled by this change.

## Validation

Run from the CP/M directory:

```sh
make
python3 tools/test_irq_core.py
```

The normal image build passes assembly/linking, overlap checks, diagnostic
record checks, image construction and generated memory/jump-table validation.
The regression executes the built machine code with libqkz80 and mocked ports;
it checks enabled/disabled and nested tokens, IOC error restoration, user and
kernel registration, all CTC and SIO vectors, default/FFh vectors, complete
foreground context, polling dispatch and ownership cleanup. This local
libqkz80 omits OUT (C),A, so the harness supplies that port-only instruction.
It does not simulate electrical timing, the daisy chain or complete CP/M I/O.

The retained VDrip build fails assembly on missing GETCHAR/NBYTES symbols in
`cbios_console_vdrip.asm`. Assembling the pre-change HEAD sources reproduces
those same errors. That unrelated legacy build failure was left in place;
VDrip packet/parser/READY/flow-control behavior was not redesigned.

Physical-machine validation remains pending. TIMTEST sources and binaries
were not changed. Run the existing channel-0 reproducer first, then channels
1, 2 and 3, SNTracker, the VGM player, and keyboard activity while the timer
runs. Record in-place startup re-entry, held-key failures, channel consistency
and SIO console reliability. This cleanup does not establish that the TIMTEST0
restart is fixed. If it persists, the next separately scoped experiment is the
minimal single-interrupt-source ROM described in the request.
