# FAT-Backed BDOS Bring-Up — Lessons Learned

> **Status:** Initial version capturing the lessons visible from one bring-up/debugging session.  
> This document is intentionally expected to grow as other development sessions add their own observations.

## 1. Purpose

This document records the lessons learned while adding a FAT-backed logical
drive personality to Zephyr-80 while preserving compatibility with ZSDOS and
ordinary CP/M applications.

The important result of the work was not merely that FAT files became visible
to CP/M. The bring-up exposed a number of implicit contracts in CP/M, ZSDOS,
the Zephyr banking model, and the IOC transport that are easy to violate when
customizing the operating system.

The goal of this document is to preserve those lessons for future OS work.

---

## 2. The most important architectural rule

### Bank 7 is implementation space; common memory is ABI space

One of the most useful architectural rules to emerge was:

> Bank 7 is where OS implementation belongs.  
> Common bank-0 memory exists only where code or data must cross between the
> application and OS mapping.

New functionality should default to bank 7.

Common memory should contain only things that genuinely need to remain visible
during a crossing, such as:

- CALL 5 / BDOS facade
- minimal bank transition code
- interrupt entry machinery
- caller-visible returned objects
- staging buffers
- cross-mode stack/state

Free common memory is not a reason to put implementation code there.

This rule prevents the common area from slowly becoming a second operating
system image and keeps future banking changes manageable.

---

## 3. Do not replace ZSDOS state unless necessary

The first instinct when adding an alternate filesystem may be to maintain
parallel state for:

- current drive
- current USER
- write-protect state
- current disk structures

That turned out to be the wrong abstraction.

ZSDOS already owns these concepts and applications expect its behavior.

The FAT personality therefore participates in the existing model rather than
creating a parallel one.

Examples:

- Function 14 still changes the current drive through ZSDOS.
- Function 32 remains authoritative for USER.
- ZSDOS remains authoritative for software write protection.
- FAT-specific state is a mirror or implementation cache, never the authority.

A cache is allowed to become stale. An independent OS state machine is not.

---

## 4. Synthetic BIOS support is extremely valuable

The FAT-backed drive does not use CP/M disk allocation internally, but allowing
ZSDOS to select it through the normal BIOS interface simplified the entire
design.

A small synthetic disk personality provides:

- SELDSK
- synthetic DPH
- synthetic DPB
- synthetic ALV
- harmless empty READ behavior
- WRITE failure in the read-only phase

This lets ZSDOS perform normal login and current-drive bookkeeping.

It also creates a useful safety property:

> If a FAT-specific operation accidentally falls through to ordinary ZSDOS
> disk processing, ZSDOS sees an empty synthetic disk rather than operating on
> the previously selected conventional drive.

That failure mode is much safer.

---

## 5. CP/M compatibility is defined by observable behavior, not documentation

A major lesson was that the documented BDOS function interface is not the
complete compatibility contract.

Programs depend on details such as:

- returned A values
- which 32-byte slot of the DMA directory buffer contains a match
- exact FCB mutations
- EX/S1/S2/RC encoding
- search continuation state
- drive restoration
- wildcard USER behavior
- EOF behavior

The correct approach was to characterize a real ZSDOS system with
`BDOSCHAR.COM` and reproduce what applications can observe.

This was much more productive than attempting to infer behavior from CP/M
documentation alone.

---

## 6. SEARCH FIRST / SEARCH NEXT contain more semantics than expected

Directory search became one of the richest compatibility surfaces.

A SEARCH result is not simply "here is a filename".

Traditional programs expect:

- A = 0..3 indicating the matching slot
- the corresponding directory entry at `DMA + A * 32`
- a full 128-byte synthetic directory sector
- correct extent fields
- persistent SEARCH NEXT state

This mattered because applications such as CRC interpret the returned DMA
buffer exactly as if it came from a real CP/M directory.

A search implementation that returns the right filename but the wrong slot,
extent fields, or user information is still incompatible.

---

## 7. FCB drive byte '?' is a real compatibility feature

CRC 2.0 uncovered one of the most obscure assumptions in the entire bring-up.

For SEARCH operations:

```text
FCB byte 0 = 3Fh ('?')
```

does not mean "drive 63".

ZSDOS interprets it as a special wildcard-drive/user search form on the current
drive.

CRC uses this to enumerate files across USER areas.

The original FAT dispatcher did not reproduce this behavior, causing CRC to
silently see an empty directory.

This is an important general lesson:

> Never assume that an apparently invalid FCB field is unused.
> Characterize how ZSDOS treats it before rejecting it.

CRC was valuable not because CRC itself mattered, but because it exposed an
otherwise invisible compatibility convention.

---

## 8. Explicit-drive FCB operations may temporarily change the selected drive

ZSDOS explicit-drive processing is not simply:

```text
read B:
```

The operation may behave more like:

```text
remember current drive D
select B
perform operation
restore D
```

This matters for debugging.

An error reported during BDOS function 20 against B: does not necessarily mean
that the B: data read failed.

The failing lower-level operation may be the later restoration of D:.

This distinction became important while debugging the transport race.

When diagnosing ZSDOS filesystem problems, trace actual SELDSK transitions
rather than inferring them from the BDOS call that eventually reports the
error.

---

## 9. ZCPR utilities may hide the behavior being tested

Another subtle lesson came from using TYPE as a compatibility test.

ZCPR2 TYPE does not necessarily preserve an explicit drive in its working FCB.

It may:

- temporarily log into the requested drive
- make that drive current
- set the working FCB drive to zero

Therefore:

```text
D> TYPE B:FILE
```

does not necessarily exercise the same path as a transient application holding
an FCB whose drive byte explicitly refers to B while D remains current.

This explains why TYPE could pass while VGMPLAYER exposed an explicit-drive
problem.

The broader lesson is:

> Know what the test program actually asks BDOS to do.

Shell utilities are not always transparent wrappers around the command line.

---

## 10. FCBs must remain authoritative

IOC handles must never become hidden state inside an FCB.

Applications are allowed to:

- copy FCBs
- reopen files
- modify sequential/random positions
- preserve FCBs independently

Therefore the FCB must remain sufficient to reconstruct the operation.

IOC file handles can be cached for performance, but they are disposable.

A cached handle may be keyed by:

- drive
- USER
- CWD generation
- 8.3 identity

If the handle disappears, the backend must be able to reopen the file and
continue from FCB state.

This principle prevented the FAT personality from becoming dependent on
implementation-private state that CP/M programs cannot preserve.

---

## 11. Small handle pools expose lifecycle bugs very effectively

The initial FS2 implementation deliberately used only a very small number of
open file contexts.

This exposed a bug where repeated 128-byte reads leaked file handles.

Symptoms included:

- reads stopping after only a few records
- increasing the slot count increasing the failure point proportionally
- directory operations still functioning because DIR used a different context

Changing the number of available slots became a diagnostic tool.

The general lesson:

> Small fixed resource pools are useful during bring-up because lifecycle bugs
> become deterministic instead of being hidden by excess capacity.

Do not fix exhaustion bugs by merely increasing pool size.

---

## 12. Read/write completion semantics differ fundamentally

Reads can often be retried safely.

Writes cannot.

If a transport failure occurs after a write payload has been delivered but
before the final completion reply is received, the host may not know whether
the write committed.

That state must be represented explicitly:

- definitely not committed
- definitely committed
- completion unknown

Never blindly replay a write whose commit status is unknown.

This becomes especially important when extending FS2 from the read-only
Milestone 4 implementation to writable Milestones 5 and 6.

---

## 13. Interrupt masking must begin when the reply begins, not after parsing it

One of the most obscure bring-up bugs was in the IOC receive critical section.

The transport already masked interrupts during:

- command-body reception
- bulk transfer

but interrupts remained enabled while scanning for the first reply marker.

The MCU is the clock master.

Once the first byte appears, the rest of the reply continues arriving whether
the Z80 is ready or not.

The SIO FIFO is small.

A CTC interrupt immediately after the first receive-ready indication could
therefore:

1. delay the receive loop
2. allow the SIO FIFO to overflow
3. corrupt the reply before the code reached its existing DI section

The important rule is:

> Waiting for a reply may remain interruptible.
> Once the first RX-ready indication appears, every incoming byte belongs to a
> timing-critical transaction and must be protected.

So the correct boundary is:

```text
wait for RX-ready      interrupts enabled
RX-ready appears
DI
recognize marker
receive reply
perform bulk phase
EI
```

This fixed failures that initially appeared to be filesystem or drive-selection
bugs.

---

## 14. Transport errors can masquerade as filesystem errors

The interrupt race produced errors such as:

```text
ZSDOS error on B: No Drive
```

At first sight this suggested a drive-state or SELDSK problem.

In reality a later IOC transaction involved in restoring the selected drive
could lose its reply.

The filesystem layer then observed only a failed selection.

This is a general debugging lesson:

> A high-level filesystem error is not proof that the filesystem logic is the
> source of the failure.

When several unrelated operations fail nondeterministically, inspect common
transport paths before rewriting filesystem logic.

---

## 15. FAT attributes and CP/M attributes are not equivalent

Mapping FAT:

- HIDDEN
- SYSTEM
- ARCHIVE

directly onto CP/M attribute bits seemed convenient but produced compatibility
problems.

In particular, FAT's ARCHIVE bit became visible as a high bit in a CP/M file
type character and confused existing software.

The semantic models are different.

The final decision was:

- do not project FAT HIDDEN/SYSTEM/ARCHIVE into synthetic CP/M directory
  attributes
- keep FAT metadata internal to the FAT filesystem
- treat ZSDOS software write protection separately

If CP/M-specific attributes are ever needed later, they should be represented
as CP/M metadata rather than pretending FAT metadata has identical meaning.

---

## 16. Large files require real CP/M extent semantics

A FAT file is naturally one byte stream.

A CP/M application sees:

- 128-byte records
- extents
- EX/S1/S2/RC
- multiple directory entries for large files

Synthetic SEARCH therefore has to model the observable CP/M extent structure,
even though there are no real CP/M allocation blocks underneath.

This was especially visible with large files such as VGM data.

It is not enough to emit one synthetic directory entry per FAT file.

The compatibility layer must emit the extent sequence a real CP/M filesystem
would expose.

---

## 17. USER areas can be projected cleanly onto directories

The mapping:

```text
USER 0 -> current FAT directory
USER N -> current FAT directory/@N
```

proved simple and useful.

For example:

```text
/CPM/D/GAMES/FOO.COM       USER 0
/CPM/D/GAMES/@1/FOO.COM    USER 1
```

This preserves normal PC-visible files for USER 0 while allowing CP/M USER
semantics without inventing FAT metadata.

Native filesystem operations should not implicitly apply this mapping.

It belongs specifically to the FCB compatibility personality.

---

## 18. Hierarchy belongs beneath the CP/M view, not inside FCB syntax

The per-drive FAT current directory provides hierarchy while preserving the
flat namespace expected by CP/M applications.

For example:

```text
ZCD GAMES
```

changes D:'s FAT current directory.

Legacy:

```text
DIR
TYPE
OPEN
```

continue to see an ordinary flat CP/M directory.

This proved cleaner than attempting to add path syntax to FCB operations.

---

## 19. Separate native filesystem semantics from CP/M compatibility

The architecture became much easier to reason about once the two layers were
kept distinct:

```text
FatFs
   |
   v
FS2 byte-oriented filesystem service
   |
   +---- native Zephyr API
   |
   +---- CP/M FCB compatibility personality
```

The native API should not inherit:

- 128-byte records
- CP/M extents
- USER mapping
- synthetic DPB/ALV behavior

Those exist only in the compatibility layer.

Likewise, the CP/M personality should not expose IOC tokens or FatFs details.

---

## 20. Performance problems should be solved at the right abstraction level

The conventional CP/M volume eventually became dramatically faster after
deblocking/cache improvements.

A workload such as SC2 loading dropped from several seconds to effectively
instantaneous, and VGMPLAYER transitions became nearly seamless.

This demonstrated that the hardware and transport are capable of good
performance.

The FAT compatibility path is currently slower largely because it still pays
more work per 128-byte BDOS record.

The first optimization after writable correctness should therefore be a simple
512-byte deblocking cache:

```text
one 512-byte FS2 read
    -> four 128-byte BDOS records
```

Do not start by redesigning the transport.

Measure the simple deblocking improvement first.

---

## 21. Correctness before optimization was the right decision

The bring-up deliberately postponed FAT deblocking while compatibility bugs
were still being resolved.

That made debugging substantially easier.

Otherwise a failure could have originated in:

- FCB semantics
- SEARCH state
- IOC handles
- cache identity
- stale cache contents
- transport
- FatFs

Keeping the read path simple until compatibility stabilized reduced the number
of moving pieces.

The same discipline should be applied to writable support.

---

## 22. Milestones should isolate semantic layers

The staged implementation worked well:

```text
M0  characterize BDOS
M1  synthetic FAT BIOS personality
M2  minimal read-only FS2
M3  native read-only filesystem API
M4  complete read-only CP/M/FAT personality
M5  expose writable FAT functionality safely through FS2/native API
M6  map writable functionality into CP/M FCB semantics
M7  optimize resources/transport
```

The important boundary is:

> M5 provides a real native R/W FAT filesystem.  
> M6 makes ordinary CP/M programs able to write through it.

Keeping those separate means CP/M write compatibility can be debugged without
also debugging FatFs write transport.

---

## 23. Characterization utilities are worth keeping permanently

`BDOSCHAR.COM`, transport stress tools, filesystem tests, and application-level
regressions should remain in the tree.

They are not temporary bring-up tools.

Future changes to:

- ZSDOS
- memory banking
- the facade
- the IOC protocol
- caching
- filesystem backends

can silently violate the same assumptions.

The tools provide executable documentation of those contracts.

---

## 24. Applications are excellent compatibility probes

Several applications revealed different classes of problems:

- DIR exposed synthetic extent/search behavior
- TYPE exercised ordinary sequential reads
- CRC exposed raw directory-search semantics and the `FCB[0]='?'` convention
- VGMPLAYER exercised large sequential reads, explicit-drive FCBs, interrupts,
  and repeated buffering
- ZCD exercised per-drive hierarchy state

No single application was sufficient.

Compatibility testing should deliberately include software with different
access patterns.

---

## 25. Final takeaway

The hardest part of adding FAT-backed drives was not FAT.

FatFs itself was already capable and reliable.

The difficult part was preserving the implicit contracts between:

- CP/M applications
- ZSDOS
- the BIOS
- Zephyr's common/banked memory model
- FCB semantics
- directory search behavior
- the IOC transport

The most useful rule for future OS extensions is:

> Add new implementation beneath the existing compatibility contract whenever
> possible. Characterize the contract before replacing it.

When a strange old program fails, treat it as evidence that the emulation
boundary is incomplete rather than assuming the program is doing something
wrong.

---

## Future additions

Once writable Milestones 5 and 6 are complete, this document should be
augmented with at least:

- the final write-completion / unknown-commit contract
- how CP/M MAKE/CLOSE semantics map onto FAT
- sequential and random write edge cases
- random-write-with-zero-fill behavior
- software write-protect interactions
- media-full and media-removal behavior during mutation
- lessons from the 512-byte FAT deblocking/cache optimization

Milestones 5 and 6 and the deblocking work were completed and validated on
hardware on 2026-09-22. Most of the list above is now covered by sections 26
onward; sections 41-52 add what the writable and performance work taught.
Still not covered by direct experience, because it needs deliberate physical
setup rather than a test case:

- media removal and reinsertion *during* a mutation
- a genuinely full volume, as opposed to an injected no-space status

---

## 26. Writable checkpoint: isolate commit semantics before FCB semantics

The first writable tranche was intentionally stopped at the native API:

```text
FS2 create/open-for-update, write, truncate, sync/close
    -> function 218 native byte API
    -> hardware validation
    -> only then writable CP/M FCB calls
```

This boundary bought a great deal. It exercised the dangerous parts --
Z80-to-IOC bulk transfer, FatFs mutation, completion reporting, stale handles,
write protection and media errors -- without simultaneously debugging CP/M
extent and FCB mutation rules. A checkpoint is useful when it produces an
independently testable vertical slice, not merely when it reduces the diff.

`ZFW.COM` made that slice concrete. It tested fresh and repeatable
create-always, open-for-update, writes at several sizes, readback, sync,
truncate, size reporting, oversized-write rejection, handle exhaustion and
ZSDOS software write protection. The separate `ZFWPROB.COM` narrowed failures
to individual mutating primitives without requiring every earlier step to
succeed.

---

## 27. READY is permission to transfer, not evidence of a write

The writable bulk lifecycle has three distinct events:

```text
WRITE command reply / READY
    -> the IOC has armed a receive buffer

IOCBULKW completes
    -> bytes crossed the link

XFER_STATUS / DONE with the matching transfer ID
    -> FatFs commit callback completed with a known status
```

Neither READY nor a successful `IOCBULKW` proves that FatFs stored the bytes.
The host must always collect DONE, verify that its transfer ID matches the ID
issued by READY, and then inspect the commit status.

If READY was accepted but DONE is lost, malformed, or names another transfer,
the only honest result is `UNKNOWN_WRITE`. The native layer must invalidate
that handle and must not replay the write. Explicit offsets make known retries
idempotent; they do not make an unknown commit safe to replay.

The same uncertainty applies to non-bulk mutations. If the reply to
create-always, truncate, sync or writable close is lost, the operation may
already have changed the filesystem. Transport failure after a mutation is not
automatically equivalent to "nothing happened."

---

## 28. Writable stale handles must not use the read retry policy

A stale read-only handle can be reopened from its saved path identity and the
read attempted once more at the explicit offset. That is safe because reads do
not mutate the file.

The same policy is unsafe for a writable handle. A media-generation change or
unknown completion can leave the file in a state the host cannot reconstruct.
Writable contexts therefore fail stale, are invalidated, and require the
application to reopen and decide how to recover.

Media generation remains useful for card removal and remount while the Z80 is
still running. It should advance when media/FatFs failures invalidate open
contexts. It is not an MCU-session protocol: an MCU reset resets the whole
machine, so inventing a recoverable MCU nonce would model a state that cannot
actually occur.

---

## 29. Software and physical write protection are separate authorities

FatFs reports physical or filesystem-level read-only conditions. ZSDOS owns
the CP/M software write-protect vector. Both must be honored.

The bank-7 FAT layer keeps only a mirror of the ZSDOS vector. The mirror is
refreshed after the ZSDOS calls that reset, set or query write protection, and
native mutation checks the configured FAT-drive bit before issuing an FS2
mutation. Protecting or resetting disks also closes/invalidate outstanding
writable contexts so an old handle cannot bypass a newly asserted policy.

Do not encode ZSDOS software protection as a FAT attribute and do not infer it
from FAT metadata. They are deliberately independent mechanisms.

---

## 30. Crossing code must validate lengths before `LDIR`

Native WRITE exposed the one part of the implementation that genuinely had to
grow in common memory. An application buffer in the banked window disappears
when bank 7 is selected, so outbound bytes must be copied into the existing
common 512-byte staging buffer before the crossing. The filesystem protocol,
policy and persistent state still belong in bank 7.

The common helper must validate the caller's length before copying. In
particular, this Z80 behavior is dangerous:

```text
BC = 0
LDIR
```

It does not copy zero bytes. BC wraps and the instruction copies 65536 bytes,
walking across the address space and corrupting the resident OS. Zero-length
and greater-than-512-byte requests must be rejected or skipped before `LDIR`.
The same guard is required when delivering a zero-byte READ result.

This is a broader rule for bank-crossing facades: validate pointer/count pairs
while the caller mapping is visible, keep the common code purely mechanical,
and perform all semantic validation again in the bank-7 implementation.

---

## 31. Reuse the proven bulk lane and advertise capability explicitly

The existing `/SHARED` writer had already established the correct shape:
receive into the shared 512-byte buffer, commit through a callback, and expose
the final result through DONE. Reusing that lane was safer than creating a
second write transport.

Writable FS2 support was added additively to the version-1 command range. The
capability reply, rather than a guessed firmware version, tells a client
whether WRITE and TRUNCATE exist. A hardware diagnostic should query that bit
before sending a command that older firmware will not admit; otherwise a
missing feature looks like a hung transport.

This combination -- additive commands, explicit capability bits and a small
end-to-end diagnostic -- made the first writable checkpoint independently
flashable and testable while ordinary FAT-backed BDOS mutation remained out of
scope.

---

## 32. Final SEARCH characterization was simpler than physical CP/M emulation

Sections 6 and 16 record useful intermediate reasoning, but hardware
characterization and application testing refined the final contract. The
accepted FAT SEARCH result does not need four meaningful directory slots or a
sequence of synthetic physical extents.

For each match, the final implementation uses:

```text
DMA[0..127] = E5h
DMA[0..31]  = one synthetic directory entry
A           = 00h
```

On exhaustion:

```text
A           = FFh
DMA         = unspecified
```

The entry needs correct observable metadata only:

- USER
- seven-bit-clean 8.3 name
- zeroed CP/M attribute bits, because FAT HIDDEN/SYSTEM/ARCHIVE are deliberately
  not projected
- EX, S1, S2 and RC
- zero allocation bytes

Emitting several entries for a large FAT file made ordinary `DIR` display the
same filename repeatedly. The accepted representation emits one entry per FAT
file and puts the terminal logical extent in EX/S2/RC. Function 35 remains the
authority for the complete rounded-up record count.

This is a useful restraint:

> Reproduce the observable directory contract, not a fictional physical CP/M
> allocation layout that has no meaning on FAT.

The hardware-accepted result showed `SONG.ZVG` once, while CRC still recovered
and processed the whole large file.

---

## 33. Raw all-USER SEARCH is a mode, not a malformed drive

The final CRC fix required more than recognizing `FCB[0] = '?'` as the current
drive. That value selects a raw directory-search mode whose continuation spans
all supported USER namespaces.

The dispatcher must therefore capture, on function 17:

- effective drive = current drive
- USER filter = wildcard
- first USER = 0
- final USER = 15 on this ZSDOS build

Function 18 must retain that mode, finish the current directory, skip missing
`@N` directories, advance through USER 15, and put the source USER in each
synthetic entry.

If function 17 falls through to ZSDOS, ZSDOS searches the deliberately empty
synthetic disk and CRC quietly builds an empty list. That exact failure prints
only the CRC banner, which made the disassembly of CRC's catalogue-building
path especially valuable.

ZSDOS remains authoritative for USER. The facade mirrors successful function
32 changes and the FAT layer consumes that mirror; it does not call back into
ZSDOS merely to ask for USER on every file operation. This keeps authority
clear without adding avoidable coupling.

The supported range must come from the running OS rather than a generic CP/M
assumption. This system has USER 0 through 15, not USER 31.

---

## 34. USER must precede the relative FAT current directory

The accepted resolver order is:

```text
/CPM/D/@N/<relative-CWD>/<name>
```

with USER 0 omitting `@0`:

```text
/CPM/D/<relative-CWD>/<name>
```

Putting the current directory before `@N` makes a directory visible in D8:
impossible to select consistently from D8:. The USER namespace is the root of
that logical CP/M view; hierarchy lives beneath it.

The saved relative directory is tagged with the USER that selected it. A
directory selected for USER 8 must not silently become the current directory
for USER 14. When a utility targets `D8:` from another drive/USER, it
temporarily selects USER 8 for the native operation and restores the caller's
USER afterward.

FS2 itself remains a neutral component resolver. The bank-7 native/FCB layer
decides when to prepend the CP/M drive and USER projection.

---

## 35. Fixed-size path components need boundary tests at 9/10 and 15

USER components are packed into an exact 11-byte 8.3 field. The first version
formatted both one- and two-digit USER values with the same number of trailing
spaces. `@10` through `@15` therefore wrote twelve bytes and overwrote the next
persistent-state byte, which happened to be the current-directory count.

That single-byte overwrite produced failures far away from the formatter:
directory selection appeared unreliable and later path replay used a nonsense
component count.

The lesson applies beyond USER names:

> For packed protocol and filesystem fields, test the first value that changes
> width, the maximum accepted value, and the byte immediately after the field.

The all-USER CRC regression was useful here because it automatically exercised
USER 10 through 15 and could detect corruption of adjacent current-directory
state.

---

## 36. SELDSK tests drive availability, not the current subdirectory

After a successful `ZCD` in USER 8, selecting D: could still fail with:

```text
ZSDOS error on D: No Drive
Call: 14
```

The synthetic `SELDSK` probe was replaying the saved relative directory without
the USER component. It tested `/CPM/D/TESTDIR` even though the selected path was
`/CPM/D/@8/TESTDIR`, then returned a null DPH.

The corrected responsibility is narrower:

```text
SELDSK D: validates /CPM/D and returns the synthetic DPH
file/native operations resolve USER and CWD beneath that root
```

A missing, renamed or USER-specific subdirectory must not make the entire
logical drive disappear. Keeping availability, login geometry and path
resolution separate also makes ZSDOS error reports much easier to interpret.

---

## 37. A crossing gate must preserve the semantic return value

Function 218 completed CHDIR successfully in bank 7, wrote status zero into
the descriptor, and then appeared to fail in the application.

The common gate used A to distinguish READ from non-READ while deciding whether
to copy staged payload data. That mechanical dispatch overwrote the status
returned by bank 7 with the operation number. CHDIR therefore returned `09h`,
and ZCD printed `Cannot select directory` even though the directory had already
changed.

The gate now preserves AF across its copy dispatch and returns the original
bank-7 status. This also reinforced two rules:

- test both the returned register value and the copied descriptor status
- test the complete application-to-bank-7 path, not only the bank-7 worker

The fix had to fit the existing common crossing region. `PUSH AF`/`POP AF`
used its last two bytes without moving any boundary; the generated memory map
now reports the 62-byte native gate exactly full.

---

## 38. ZCPR transient return and DU parsing are part of utility correctness

ZCPR2 invokes a transient with `CALL 0100h`. ZCD replaced SP with a private
stack and originally ended with `RET` without restoring the entry SP. It popped
bytes from the code following its private stack, printed a stray `ZCD?`, and
eventually returned with an apparently arbitrary drive/USER.

Jumping to page zero avoided the bad return but forced an unnecessary warm
boot. The correct ZCPR behavior is:

```text
save entry SP
use private stack
restore entry SP
RET
```

ZCPR then performs its normal post-program cleanup and restores the command
processor context without a warm boot.

Argument parsing had two further traps:

- A bare command is identified reliably by the command-tail length at 0080h,
  not by assuming a particular sentinel in the default FCB.
- ZCPR puts the parsed drive and 8.3 name in the default FCB, but the USER from
  a `DU:` prefix remains in ZCPR-private temporary state.

ZCD therefore parses USER 0 through 15 from the untouched command tail,
temporarily applies it through BDOS function 32, performs function 218, and
restores the original USER. This makes command-location and operation-target
independent:

```text
B0:ZCD D8:TESTDIR
B0:ZCD D8:
```

The utility can eventually reside on ROM drive A: and still target any
supported FAT USER namespace without changing the shell's permanent drive or
USER.

---

## 39. A reported failure may follow a successful state change

The ZCD episode combined two independent defects:

1. CHDIR succeeded, but the gate returned the operation number as an error.
2. The now-changed CWD made the next flawed SELDSK probe return no DPH.

The visible sequence looked like one failed command followed by a damaged
drive. In fact, the command had mutated state successfully and only its status
report was wrong; the later login failure came from consuming that new state
incorrectly.

When a state-changing command reports failure, diagnostics should separately
check:

- whether the operation executed
- whether state changed
- whether completion status crossed the boundary intact
- whether the next consumer interprets the new state correctly

This distinction will be even more important for writable operations, where a
false failure can tempt an unsafe retry.

---

## 40. Acceptance needs asymmetric cross-drive and application-level cases

The read-only milestones were accepted on hardware on 2026-09-22 with a matrix
that deliberately exercised both directions of drive crossing:

- `DIR`, `TYPE` and CRC on a small FAT file
- CRC and uninterrupted VGMPlayer playback on a large FAT file
- VGMPlayer reading `D8:SONG.ZVG` while B: was current
- VGMPlayer reading `B8:SONG.ZVG` while D: was current
- `ZCD`, `DIR` and CRC inside a FAT subdirectory, followed by return to the
  expected parent/root view
- USER 1 `/CPM/D/@1` isolation followed by restoration of USER 0
- `DIR`, `TYPE` and CRC again on conventional B:

The two explicit-drive cases are not redundant. One validates FAT dispatch
while another backend is current; the other validates conventional ZSDOS I/O
and restoration while the synthetic FAT drive is current.

The one-level `ZCD ..` acceptance case proved restoration of the expected view
from the tested subdirectory. It should not be overinterpreted as exhaustive
proof of arbitrary-depth parent normalization or root-containment behavior.

The detailed accepted command suite is recorded in
`Code/HOST/CPM2.2/docs/fat-read-only-milestones2-4.md`.

---

## 41. `LDIR` with a computed count of zero moves 65536 bytes

The writable milestone recorded the path identity of each native handle so a
stale token could be reopened. The relative directory depth was multiplied by
the component size and used directly:

```text
BC = depth * 11
LDIR
```

At the drive root the depth is zero, and the Z80 decrements `BC` *before* it
tests it. A zero count is therefore not "copy nothing" but "copy 65536 bytes",
which walked the component array over the entire address space and took bank 7
— with the operating system resident in it — with it. The machine froze hard
on the first native `OPEN` issued from the drive root, which is the ordinary
case.

Section 30 covers validating a *caller's* length before a block move. This is
the other half: a length the OS computes for itself can also be zero, and the
zero case is the one that does not look like an error at the call site.

Two details make this worth remembering beyond the specific bug:

- The routine that *read* the same structure back already guarded correctly
  (`ld a,b / or a / jr z,...`). Only the routine that *wrote* it did not. When
  one side of a paired reader/writer has a guard and the other does not, that
  asymmetry is the defect, not a style difference.
- Every other block move in the file used a constant count. Auditing for
  "which `LDIR` has a computed count" found exactly one candidate in about a
  minute, and is a cheap sweep to repeat after any change that introduces one.

---

## 42. A comparison before a conditional return destroys the flags it tests

Native reads returned status 0 and zero bytes, for every file, on every drive,
in both read and write modes. The cause was three instructions:

```text
    call fat_fs2_read
    cp   #FS2_STATUS_STALE      ; sets the flags from the CP
    jr   nz,fat_native_read_result
    ...
fat_native_read_result:
    jp   nz,fat_native_return   ; tests the CP, not the result
```

On success `A` is 0, so the stale comparison sets NZ, and the success path
returned immediately — skipping the block that stored the transferred count
and advanced the file position. Errors happened to work, because they are also
NZ. The genuine stale case worked, because it is Z. Only the normal path was
broken.

The general rule is that a status register is not a variable: any comparison
between producing a result and branching on it discards the result. The
practical detection is cheaper than the rule, though — **the sibling routines
all re-tested with `or a` and this one did not.** `sync`, `truncate` and
`open` each did the same stale-or-transport check and each restored the flags
before branching. When four routines share a shape and one differs, look at
the one that differs before looking anywhere else.

---

## 43. Two personalities over the same files need two sets of tests

The read-only milestones were accepted with `DIR`, `TYPE`, CRC and VGMPlayer.
All four reach files through the CP/M FCB path. Nothing in that suite — and
nothing in the bank-7 test harness, which exercised `fat_native_entry` only
with `ZCHDIR` — ever called native `OPEN`, `READ`, `WRITE` or `SEEK`.

Three defects lived in that gap: the zero-count `LDIR` of section 41, the
clobbered flags of section 42, and a buffer aliasing bug covered below. All
three were present and undetected through an entire accepted milestone.

The architectural claim of this design is that CP/M FCB access and the native
byte API are two views of the same files. That claim cuts both ways: it means
**neither view's test coverage substitutes for the other's**, even though they
share a transport, a resolver and a handle pool underneath. The native API had
no consumer other than a directory-changing utility, so it had no coverage, so
it had bugs.

The concrete rule adopted afterwards: adding a native operation means adding a
case to the bank-7 harness in the same change. That harness drives bank-7
routines directly in an emulator and would have caught all three in seconds.

---

## 44. A test harness must model the address aliasing the real path has

Function 40 (write random with zero fill) writes zero records across the gap
it skips, then writes the caller's record. It passed every harness test and
failed on hardware, writing the caller's record as zeros.

The reason is one line in the memory map:

```text
FAC_DMA_BUF = FAC_BULK_BUF
```

When an application's DMA sits in the TPA it is hidden under bank 7, so the
facade stages the record into `FAC_DMA_BUF` — which *is* the common bulk
buffer that the gap fill then writes zeros through. The record was destroyed
before it was ever sent, and the subsequent copy to the bulk buffer became a
copy of that buffer onto itself.

The harness never saw it because it called the bank-7 routines directly with a
scratch DMA at a distinct address. That is a faithful model of the *interface*
and an unfaithful model of the *machine*: on real hardware the aliased case is
not an edge case, it is the normal path.

The fix in the code was to stage the caller's record into bank 7 before the
gap fill. The fix in the harness was to add a second case with the DMA
pointing at `FAC_BULK_BUF`, which is now the case that fails if the staging is
removed. Plain `WRITE` was never affected, because its copy to the bulk buffer
is a copy onto itself and changes nothing — which is exactly why only one of
the three write functions misbehaved.

---

## 45. Mutation-test the assertions, not just the code

The first version of the zero-fill test asserted that the skipped gap read
back as zeros. It passed. It also passed with the entire zero-fill
implementation deleted.

The mock extended a file with `resize(n, 0)`. FatFs extends a file by
allocating clusters that hold whatever was previously on the card. The model
was therefore zero-filling the gap itself, and the assertion could not
distinguish an implementation that zeroed it from one that did not.

Changing the fill value to `0xCC` made the test fail with the implementation
removed and pass with it present. The same technique — delete the behaviour,
confirm the test notices — was then applied to every new assertion in the
session and caught a second worthless test immediately.

For a guarantee expressed as "this region reads back as X", the model must
produce **not-X** by default. A model that defaults to the expected value
cannot test the guarantee, however carefully the assertion is written.

---

## 46. Run the compatibility suite on a conventional drive too

The FCB-level acceptance utility uses only standard BDOS calls, so it runs on
any drive. Running it on a conventional CP/M volume found three defects — all
three in the *test*, none in either drive:

- **A random write that was never closed.** CP/M records a file's new length
  in the directory at `CLOSE`, not at write. The FAT personality opens, writes
  and closes per record, so it commits immediately and masked the omission.
  The conventional drive reported the stale length and was right to.
- **An over-specified contract.** Function 40 zero-fills a *previously
  unallocated block*, not an arbitrary gap. A gap inside a block that was
  already allocated legitimately holds old data. The test demanded more than
  CP/M promises, and the FAT implementation happened to provide it.
- **A write-protect case that cannot pass.** On a conventional drive a
  protected write reaches ZSDOS, which raises its own `Bdos Err ... R/O`,
  takes the console and ends the program. It never returns a code to test.

The general value is that a cross-drive suite turns "does this work" into
"does this differ", and a difference is a far sharper signal than a failure.
When the FAT drive failed a check the conventional drive passed, the fault was
localised to the FAT path immediately; when both failed identically, the
expectation itself was wrong.

The third finding is also a real compatibility difference worth deciding
deliberately: the FAT personality intercepts above ZSDOS and returns a failure
code where a conventional drive raises a BDOS error. Friendlier, but not what
CP/M documents, and a program relying on the error will behave differently on
the two drive types.

---

## 47. ZSDOS software write protection can be configured to survive every reset

Section 29 establishes that software and physical write protection are
separate authorities. There is a further wrinkle: in this build the software
one cannot be cleared by the functions that are supposed to clear it.

`zsdos.lib` ships `FLGBITS EQU 01101101B`, and bit 2 is "Read-Only Enable".
`CMND37` in `zsdos.z80` — which serves **both** function 13 and function 37 —
tests that bit and skips the write-protect clear entirely when it is set:

```text
CMND37: CALL UNLOG
        LD   A,(FLAGS)
        BIT  2,A        ; Test hard R/O enabled
        JR   NZ,UNWPT1  ; If enabled -- skip the DSKWP clear
        LD   HL,DSKWP
        CALL ANDDEM
UNWPT1:
```

So once a drive is write-protected, neither reset function clears it, and
neither does a warm boot. Only a cold boot. This is ZSDOS working as
configured, not a fault, and not something the FAT backend's mirror is doing
wrong — the mirror reads function 29 faithfully and reports exactly what ZSDOS
reports.

Two consequences:

- A diagnostic that sets write protection will poison the machine until a
  power cycle unless it clears it deliberately. The documented route is BDOS
  100 (Get Flags), clear bit 2, BDOS 101 (Set Flags), function 37, then
  restore the original flags byte. `ENTRY` folds functions 98-103 into the
  command table via `SUB 98-MAXCMD`, which is why 100 and 101 are the flags
  calls.
- While debugging, a sticky protection bit looks exactly like a stale mirror
  in the FAT backend. Asking ZSDOS directly through function 29 is what
  separates the two, and is worth doing before suspecting the mirror.

---

## 48. `.ds` reserves space but does not zero it

The reclaimable pool allocator was given a thirteen-byte owner table declared
with `.ds 13`. In the assembled image those bytes were `FFh`, not zero, so
every line read as already owned, every lease was refused, and the read cache
was permanently disabled.

There was no symptom other than being slower than expected — the fallback
read-through path is correct, which is precisely why a refused lease produces
no visible failure. The cache had a complete implementation, complete tests
and no effect.

State that a routine *reads before writing* must be initialised explicitly
(`.db 0,0,...`), not merely reserved. Reserved space carries whatever fill the
image build produces. The dangerous version of this bug is the one here: a
design that deliberately tolerates the resource being unavailable will
tolerate it being unavailable permanently and by accident.

---

## 49. A protocol addition must move the firmware level

The writable FS2 commands `3Dh`-`40h` were added to the frame header, the
dispatcher and the admission list, but `IOC_FW_LEVEL` was left at 73.

`ioc_levels.inc` exists specifically so a stale tool reports a mismatch
instead of misbehaving, and its own header records that five programs once
expected a level the firmware had moved past. Not bumping it made a controller
that predates the writable commands indistinguishable from one that has them —
and a controller that does not admit a command drops the frame rather than
refusing it, which presents to the host as a hang.

During the first hardware failure of the writable path, "is the controller
running the firmware I think it is" could not be answered from the machine.
It cost a round of investigation down a path that turned out to be unrelated.

The rule: a command range added to `ioc_frame.h`, `dispatch.c` and
`external_sync.c` is a fourth edit, not three — the level moves with it, in
both `ioc_frame.h` and `ioc_levels.inc`.

A related gap in the same area is worth recording: the host issues writable
commands without ever reading the FS2 capability word, so it cannot tell a
controller that lacks them from one that is not answering. The capability
query exists (`CMD_FS2_CAPS`) and the flags are already defined; nothing
consults them.

---

## 50. Round trips, not block size, were the cost

Section 20 says performance problems should be solved at the right abstraction
level and section 21 says correctness comes first. With correctness complete,
the measurement was unambiguous. Counting controller transactions for a 64 KiB
sequential read through the FCB path:

```text
before deblocking       per 512-byte line: 6 mailbox + 1 bulk
                        ROOT, PUSH, PUSH, OPEN, READ, CLOSE, transfer
after a 512-byte line   3 opens for 9 records instead of 9
after a cached handle   132 transactions for 64 KiB, from 768
                        per line: 1.03 mailbox + 1 bulk
```

Only one of the original seven transactions moved data. The other six
re-resolved the path and reopened the file for every 512 bytes, because the
compatibility layer opened and closed per record by design — a decision that
is right for correctness and very expensive for throughput.

Two conclusions that were not obvious before measuring:

- **A larger deblocking line was the wrong lever.** The controller's transfer
  ceiling is 512 bytes, so a 2 KiB line still costs four transfers; it only
  amortises the five setup transactions. Caching the open handle removes them
  entirely and reaches the same cost per byte as the tools that bypass the
  FCB interface altogether.
- **The remaining gap is CP/M's, not FAT's.** With the handle cached, the FAT
  drive and the conventional drive read the same 125 KB file in the same time.
  CP/M's 128-byte record means four BDOS crossings per 512 bytes, each staging
  an FCB in, the DMA out and the FCB back. That is a ceiling both drive types
  share, and it is why a byte-oriented native reader is faster on the same
  file than any FCB-based one can be.

A smaller finding from the same measurement: the record delivery path filled
the caller's buffer with `1Ah` and then overwrote all of it, two 128-byte
`LDIR`s where one would do. Copying first and padding only the short tail cut
the per-record host work by 28%.

---

## 51. Caching a handle is a lease against a pool someone else uses

The handle cache holds one of the controller's two file slots between reads.
That is sound — the design states that IOC handles are opportunistic and the
FCB is authoritative — but it changes an invariant that tests and other code
paths had quietly relied on.

Three interactions had to be handled explicitly:

- **The controller retires every file slot on a namespace mutation**, because
  FatFs will not police an unlink or rename of a file something still holds
  open. A cached token can therefore die underneath its owner. A read that
  fails with no-handle or stale reopens once and retries; a second failure is
  a real error, not a stale handle.
- **Holding a slot can starve another caller.** Every mutation point and every
  native open now hands the slot back first, rather than letting the other
  side fail for a reason it cannot diagnose.
- **A failed close still clears the tag first.** Believing you own a handle
  the controller has already discarded is worse than owning none.

The test invariant changed from "zero slots held after every record" to "at
most one, and a flush returns it", with an explicit case asserting the flush.
The first version of the change failed that old assertion, which is the
correct outcome: an invariant that a deliberate design change invalidates
should be restated, not relaxed.

---

## 52. Two CP/M parsing details that utilities must know

Both were found while building ordinary file tools over the FAT personality,
and both are invisible until a specific case is tried.

**The CCP hands a transient eleven spaces for `..`.** The CP/M name parser
stops the name field at the first `.`, so `CD ..` and a bare `CD` are
identical in FCB1. A directory-changing utility that reads only the FCB cannot
tell them apart, and since an empty name selects the root, `CD ..` silently
jumps home instead of stepping up. From one level deep the two are the same
place, so the behaviour looks correct and only diverges at depth two —
exactly the caution section 40 recorded about not overinterpreting a one-level
`ZCD ..` acceptance case. The untouched command tail is the only place the two
can still be distinguished; `..` cannot be smuggled through the name field.

**A copy utility must refuse to copy a file onto itself.** `MAKE` truncates
the destination, so `CP FILE FILE` empties the file and then reads back what
it just emptied, destroying it and reporting success. The check needs both
forms: identical drive and name, and the implied case where the destination
names only a drive that happens to be the source's. The related ordering rule
for a move is that the delete goes last, after a successful close, so any
failure earlier leaves the original where it was.
