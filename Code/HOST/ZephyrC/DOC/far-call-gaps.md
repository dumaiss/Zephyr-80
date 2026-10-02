# ZephyrC far-call implementation gaps

Status: **design and work list; transparent C far calls are not implemented**.

This document records what is present, what the current toolchain actually
emits, and the work required before a ZephyrC program can place ordinary C
functions in SRAM banks 1-6 and call them with SDCC's `__banked` syntax.

The intended end state is:

```c
uint16_t draw_level(uint8_t level) __banked;

/* The caller does not explicitly copy code or select a bank. */
result = draw_level(3);
```

`draw_level` may live in bank 1-6, the call switches to its bank, and the
runtime restores the caller's bank on return. Nested far calls must work.

This is different from `zep_bank_call()`, which is a deliberately small,
low-level interface with one `HL` argument and one `HL` result.

## 1. What exists now

The operating-system and basic library mechanisms already exist:

- BIOS `SELMEM` selects application banks 0-6 and refuses bank 7.
- BIOS `XMOVE` plus `MOVE` copies data between application banks through
  common memory.
- The mapping-changing BIOS code executes in common memory and preserves the
  RAM mode in which it was called.
- The standard CP/M startup loads `SP` from `(0006h)`. On Zephyr-80 that is
  `EC06h`, so the C stack grows through common memory and remains visible
  across a bank switch.
- `zep_bank_prepare()` copies page zero into another bank.
- `zep_bank_call()` installs a trampoline in common memory, selects a bank,
  calls a numeric address with `HL` as its argument, and restores bank 0.
- `examples/farcall/` builds `FARCALL.COM`. It copies a five-byte,
  position-independent assembly routine to bank 1 and calls it through
  `zep_bank_call()`.

The example proves the shape of the low-level operation, but its hardware run
is still pending. It does not place compiler-generated C in another bank and
does not exercise SDCC's `__banked` call convention.

No BIOS jump-table change is expected for the full implementation. The
remaining work is principally in ZephyrC's CRT, linker layout, build rules,
image loader, and common-memory call runtime.

## 2. Confirmed toolchain behaviour

ZephyrC uses:

```sh
zcc +cpm -compiler=sdcc -O2
```

The distinction between raw SDCC output and the final zcc object matters.

For a call through a prototype declared `__banked`, raw SDCC assembly contains
a call to an SDCC bank-call helper and two words of metadata. The zcc SDCC
optimizer then converts this to z88dk's classic far-call representation. The
final z80asm object contains:

- an external reference to `banked_call`; and
- a 32-bit relocation for the target function.

Conceptually, the linked call site is:

```asm
    call banked_call
    defq far_function       ; low word = address, next byte = bank
```

The ZephyrC runtime must therefore provide z88dk's `banked_call` ABI. Merely
providing the generic SDCC `get_bank` and `set_bank` helpers is not sufficient
for the current zcc pipeline.

`__banked` changes the call convention and emits the far target metadata. It
does **not** place a function in a bank. Placement is a separate compiler and
linker responsibility.

A C translation unit can be assigned to a bank section with options such as:

```sh
zcc ... --codeseg CODE_1 --constseg RODATA_1 -c bank1.c
```

The option applies to the whole translation unit. Functions intended for
different banks therefore belong in different source files. The caller's
prototype and the function definition must both carry `__banked` so SDCC uses
the same calling convention on both sides.

## 3. Required memory and section layout

The initial layout remains the one proposed in `API.md`:

```text
                bank 0                    bank N (1-6)
0000h-00FFh     CP/M page zero            copied page zero
0100h-3FFFh     shared root               identical shared-root copy
4000h-DFFFh     bank-0 overlay            CODE_N / RODATA_N
E000h-E3FFh     far-call and interrupt runtime               common
E400h-E7FFh     initialized data and BSS                     common
E800h-EC05h     C stack, growing down from EC06h              common
EC06h-FFFFh     BDOS facade and BIOS                          common
```

The exact `4000h` root boundary remains a decision until real linked sizes are
available. The following invariants do not depend on that particular boundary:

- Code that may run with any application bank selected must exist at the same
  address in every used bank, or in common memory.
- The mapping-changing trampoline itself must be in common memory.
- Writable state shared by callers and callees must be in common memory.
- The active C stack must be in common memory.
- A bank overlay must end before `E000h`.
- Bank 7 must never appear in a program far-call relocation or image.
- Foreground far calls require application mode 10. `SELMEM` preserves the
  current RAM mode; in mode 11 only `0000h-1FFFh` changes application bank.

### 3.1 Shared root

The root must contain all code that a banked function may call directly:

- startup and exit paths;
- the required ZephyrC routines;
- pulled-in libc and compiler support routines;
- the far-call entry/return support that is not placed in common memory; and
- explicitly designated application helper functions.

The startup copies `0100h` through the root boundary from bank 0 into every
bank used by the program. All copies use identical link addresses.

Code used only while bank 0 is mapped may instead live in `CODE_0`. A banked
function must not make a normal near call to such code. If banked code needs a
bank-0 overlay function, that function must itself be declared `__banked` and
called through the far-call runtime.

The build must fail if the shared root exceeds its assigned range.

### 3.2 Bank overlays

Each bank section needs a virtual z80asm origin whose low 16 bits are the
physical execution address and whose next byte is the Zephyr bank number. For
the proposed `4000h` boundary:

```text
CODE_0    virtual 004000h, executes at 4000h in bank 0
CODE_1    virtual 014000h, executes at 4000h in bank 1
CODE_2    virtual 024000h, executes at 4000h in bank 2
...
CODE_6    virtual 064000h, executes at 4000h in bank 6
```

The 32-bit relocation at a far call then encodes both the 16-bit entry address
and the bank byte consumed by `banked_call`.

Each overlay should place its code and read-only data together. For example,
`CODE_1` and `RODATA_1` share bank 1's `4000h-DFFFh` allocation. Constants used
by a banked function must not accidentally remain in a bank-0-only section.

The linker or a post-link checker must reject any overlay that exceeds
`DFFFh`, overlaps another section, or encodes bank 7.

### 3.3 Common data and stack

The custom memory map must collect all writable data sections into common
memory, including:

- application globals and static locals;
- libc and compiler runtime state;
- ZephyrC ownership and exit-handler state;
- current-bank and nested-call state; and
- initialized data and BSS boundaries used by the CRT.

Initialized data is loaded once and BSS is cleared once. It is not duplicated
per application bank.

The proposed split leaves roughly 1 KiB for data/BSS and 1 KiB for stack. Both
limits need link-time symbols and checks. Stack headroom should also receive a
runtime guard in the first implementation.

The existing common-memory ownership must be reconciled before assigning the
far-call runtime:

- `zep_common_alloc()` currently owns `E000h-E2FFh`.
- ZephyrC's tick and low-level bank-call stubs own `E300h-E3FFh`.
- A fixed far-call trampoline and its bank stack cannot silently overlap
  either allocation.

The banked CRT may need a smaller allocator range or a fixed subdivision of
`E000h-E3FFh`. This is a ZephyrC ABI decision and must be documented in
`zephyr.h` when implemented.

## 4. Custom CRT and linker map

A new bank-aware startup, provisionally `crt_zephyr_banked`, is required. It
must replace or extend the normal CP/M CRT without changing normal ZephyrC
programs.

Work items:

- Add a custom z80asm memory map defining the root, `CODE_0` through `CODE_6`,
  per-bank read-only data, fixed common code, common data/BSS, and stack limits.
- Keep the CP/M entry point at `0100h` and preserve page-zero conventions.
- Preserve the standard CP/M command-line, stdio, initialization, `atexit`,
  and warm-boot behaviour needed by ZephyrC.
- Install the fixed common-memory far-call runtime before the first bank
  switch.
- Initialize common data and BSS.
- Load and prepare every bank named by the linked image manifest.
- Enter `main()` with bank 0 selected in application mode 10.
- Ensure normal return and `exit()` restore bank 0 before running cleanup and
  returning to CP/M.
- Export section boundary symbols needed by the loader and layout checker.

The ordinary `+cpm` startup remains the default. Banked applications should
select the new CRT explicitly until the implementation and compatibility tests
are complete.

## 5. `banked_call` common-memory runtime

The runtime must implement the ABI emitted by zcc, not the present
`zep_bank_call()` convention.

Required behaviour:

1. Read the target address and bank from the four bytes following the call.
2. Advance the real return address past that metadata.
3. Save the caller's current bank in common memory.
4. Select the target bank through BIOS `SELMEM` from common code.
5. Enter the function without changing the layout of its stack arguments.
6. Preserve the function's return value while restoring the caller's bank.
7. Return to the instruction after the inline metadata.

The implementation must support nested calls. A single saved-bank byte is not
enough for sequences such as bank 0 to bank 1 to bank 2. Use a bounded bank-call
stack in common memory, or follow z88dk's temporary-stack design, and detect
overflow rather than corrupting common data.

The first version must support and test SDCC's normal banked calling convention:

- arguments are caller-cleaned and passed on the stack;
- `uint8_t` returns in `L`;
- `uint16_t` and pointers return in `HL`; and
- 32-bit values return in `DEHL`.

`__z88dk_fastcall`, structures, floating-point returns, varargs, indirect
banked function pointers, and optimized tail calls require explicit tests
before they are documented as supported.

`SELMEM` preserves BC, DE, HL, IX, and IY but clobbers AF. The trampoline still
needs an ABI-level preservation audit because the return value may occupy more
than one register and zcc may use IX or IY as a frame pointer.

Far calls are foreground operations. They must not be made by an interrupt
callback. The runtime and the current-bank update must nevertheless remain
consistent if an interrupt arrives around a transition.

### 5.1 Failure handling

An ordinary C call has no channel for reporting that `SELMEM` refused a bank.
The linker and loader must therefore prevent invalid bank numbers. If a valid
linked call still receives a refusal, the runtime should take a deterministic
fatal path rather than continuing with the wrong mapping.

## 6. Current-bank state and existing bank API

The current implementation has a static `home_bank = 0`. That is sufficient
for a normal program calling a one-level payload, but not for transparent or
nested far calls.

The banked runtime needs a current-bank value in common memory. Every successful
transition updates it, and every nested return restores it.

The following APIs then require review:

- `zep_bank_current()` must return the actual application bank.
- `zep_bank_read()` and `zep_bank_write()` must identify the bank containing a
  below-`E000h` caller buffer. Assuming bank 0 is wrong when invoked by code in
  another bank.
- `zep_bank_call()` must either remain explicitly documented as a bank-0-only,
  non-nestable primitive, or be reimplemented on the common bank stack.
- `zep_bank_prepare()` remains useful to the loader but should not be the only
  bank initialization step; the shared root and overlay also have to be loaded.

Code and data in `E000h-EC05h` are common, so the bank number is irrelevant for
those pointers. The implementation should exploit that fact without weakening
range validation for ordinary banked addresses.

## 7. Bank-image production and loading

CP/M loads one flat `.COM` image into the current application bank. It does not
populate banks 1-6. The ZephyrC build must therefore emit loadable overlay
images and the CRT must install them.

### 7.1 Packaging decision

Choose and document one initial format:

- `PROGRAM.COM` plus `PROGRAM.B1` through `PROGRAM.B6`; or
- one generated bank container with a small directory; or
- bank payloads appended to the `.COM` for small programs.

Separate companion files are easiest to inspect and do not consume the bank-0
TPA while loading, but the CRT needs the build-time program basename because
CP/M does not reliably give a running program its own filename. An appended
payload avoids filename discovery but reduces the useful `.COM` space and must
not cause CP/M to load beyond `EC05h`.

The initial format should include enough metadata to reject the wrong or a
damaged overlay: magic, format version, bank number, load address, byte count,
and preferably a checksum or CRC.

z80asm's split-section output can produce the raw pieces. A ZephyrC packaging
tool should rename or combine them, write the manifest, and enforce bounds.

### 7.2 Startup loading sequence

Before calling `main()`, the banked CRT must:

1. Determine which banks have non-empty overlays.
2. Install the common-memory runtime.
3. For each used bank, copy page zero from bank 0.
4. Copy the shared root from bank 0 to that bank.
5. Load the bank's overlay into its physical address range in bounded chunks.
6. Verify the complete payload and leave no pending `XMOVE` state.
7. Restore bank 0, the default DMA, and any temporary FCB state.

The loader itself must remain executable throughout this process. It therefore
belongs in the root or fixed common code and performs all loading before an
overlay can replace bank-0-only code.

Page-zero copies make `CALL 5`, warm boot, the default FCBs, and the command
tail visible in every application bank. Page-zero objects are still separate
physical copies: modifying a default FCB or DMA area in one bank does not update
the others. Normal libc and ZephyrC writable state should therefore use common
storage, and page-zero-dependent behaviour needs dedicated tests.

## 8. C programming rules for banked code

Until stronger tooling can diagnose violations, document and enforce these
rules in examples and review:

- Put different banks in different source files.
- Compile banked source with matching code and read-only-data sections.
- Put `__banked` on both the public prototype and definition.
- A normal call made by banked code may target only its own overlay or shared
  root code.
- Calls to another overlay, including bank 0, require an `__banked` prototype.
- Shared writable data must be common.
- A pointer below `E000h` belongs to the bank in which it was obtained. Do not
  pass such a pointer to another bank unless the pointed-to bytes are duplicated
  intentionally at the same address.
- Common-memory pointers remain valid in every bank.
- Do not call far functions from interrupt callbacks.
- Avoid fine-grained bank calls; each call performs a BIOS transition.

Bank-local writable data may be considered later, but it requires explicit
address-space and initialization semantics. It is out of scope for the first
implementation.

## 9. Build-time validation

The banked build must fail on an invalid layout. At minimum, verify:

- entry point remains `0100h`;
- shared root ends at or below its configured boundary;
- each overlay starts at the same physical boundary and ends at or below
  `E000h`;
- common code stays within its assigned part of `E000h-E3FFh`;
- common data/BSS stays below the stack allocation;
- stack allocation ends at `EC06h` and has a non-zero safety margin;
- no output section overlaps the BDOS facade or BIOS;
- only banks 0-6 are emitted;
- every `__banked` target has a valid bank byte in its 32-bit relocation;
- every emitted companion image agrees with the link map and manifest; and
- the normal, non-banked build remains unchanged.

Generate map, symbol, and per-bank size reports as normal build artifacts. Do
not rely on the linker alone: the SDCC documentation explicitly leaves bank
placement and overflow checking to the platform integration.

## 10. Verification plan

### Phase 0: validate the existing primitive

- Run `FARCALL.COM` on the Zephyr-80 hardware.
- Confirm the bank-1 code executes, returns `1334h` for input `1234h`, and bank
  0 is restored.
- Confirm a subsequent BDOS call and warm boot still work.

### Phase 1: compiler-generated C payload

Before implementing transparent `__banked` calls, replace or supplement the
assembly payload with a separately compiled, self-contained C function placed
at a known bank address.

The first function should perform only operations compiled inline, use no
globals or constants outside its own section, and call no helpers. Invoke it
through `zep_bank_call()`. This proves that compiler-generated C executes in
another bank independently of the new ABI and loader.

Inspect its generated assembly to ensure it has no unresolved dependency on
bank-0-only code. Add progressively more operations only after the minimal case
passes on hardware.

### Phase 2: banked linker and loader

- Link one `CODE_1` C overlay and emit its bank image.
- Copy page zero and the shared root to bank 1.
- Load the overlay through the custom CRT.
- Verify the map, section limits, and bank metadata.
- Keep calls explicit through `zep_bank_call()` during this phase.

### Phase 3: transparent `__banked` calls

- Add common `banked_call` and current-bank state.
- Test bank 0 to bank 1 and return.
- Test bank 1 to bank 2 and return to bank 1.
- Test a far call back to a `__banked` function in bank 0.
- Test zero, one, and several stack arguments.
- Test 8-, 16-, and 32-bit results.
- Test calls to a shared-root compiler helper, ZephyrC routine, and libc
  routine.
- Test common globals and reject or demonstrate invalid cross-bank pointers.
- Test BDOS console and file operations while a non-zero application bank is
  selected.
- Test timer interrupts during repeated far calls.
- Test maximum supported nesting and bank-stack overflow handling.

### Phase 4: exit and failure paths

- Normal return from `main()`.
- `exit()` called from bank 0 and from a banked function.
- An `atexit` handler after banked calls.
- Missing, truncated, wrong-bank, and corrupt overlay files.
- Link-time root, overlay, common-data, and stack overflow failures.
- Attempted bank-7 image or call.

RunCPM does not implement Zephyr BDOS functions 210-217, so execution tests
need the machine, a full Zephyr-80 emulator, or a deliberately extended test
model. Host-side tools can still test image parsing, manifest generation, and
all link-map bounds.

## 11. Completion criteria

Far-call implementation is complete when all of the following are true:

- A C function is linked into at least bank 1, not copied as handwritten bytes.
- The program invokes it through a normal `__banked` C declaration.
- The generated `banked_call` metadata selects the correct bank automatically.
- Nested far calls restore every caller bank correctly.
- Arguments and supported return types follow the documented SDCC ABI.
- Shared root, common data, and stack remain valid in every selected bank.
- Startup loads and validates all required overlays without manual code in
  `main()`.
- Normal CP/M calls, interrupts, cleanup handlers, and warm boot still work.
- Link and packaging checks reject every defined overflow or invalid-bank case.
- The complete example builds with the normal ZephyrC build and passes on the
  target machine or a faithful system emulator.
- `README.md`, `API.md`, and the example describe the final file format,
  compiler flags, supported call forms, pointer rules, limits, and failure
  behaviour.

## 12. Recommended implementation order

1. Run the existing assembly `FARCALL.COM` on hardware.
2. Add the self-contained compiler-generated C payload test.
3. Freeze the root boundary and common-memory subdivision from real map sizes.
4. Choose the bank-image packaging format.
5. Add the custom memory map, section rules, map checker, and image packager.
6. Add the bank-aware CRT and overlay loader, still using explicit calls.
7. Implement the common `banked_call` ABI and nested bank stack.
8. Make the existing bank API current-bank-aware.
9. Add the ABI, BDOS, interrupt, exit, and failure-path tests.
10. Promote the banked example from experimental to supported and update the
    public API documentation.

Stop and inspect the generated map and bank images after each phase. Do not
combine the first linker-layout change with unrelated ZephyrC or BIOS changes.
