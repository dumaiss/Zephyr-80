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
