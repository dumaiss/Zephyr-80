# ZephyrC API

Status: **implemented**, except the parts that wait on work outside this
library (section 11). The library, the `MANDEL` example and the two tests
build; `README.md` says what has been run and where. Nothing has run on the
real machine yet.

ZephyrC is the C library for Zephyr-80 programs cross-compiled on a PC. It gives
C programs the machine's serial ports, V9958, sound card, CTC, banked memory,
input devices and operating system services, under the same ownership rules the
BIOS and the existing assembly and Turbo Modula-2 programs already follow.

It is the C counterpart of `../Zephyr80Lib` (Turbo Modula-2). Where both cover
the same hardware, the two describe it the same way: a program's sound code
reads alike in either language.

---

## 1. Toolchain

**z88dk, CP/M target, classic C library, SDCC code generator**, using z88dk's
provided startup code:

```sh
zcc +cpm -compiler=sdcc -O2 -I$(ZEPHYRC)/include prog.c -L$(ZEPHYRC)/lib -lzephyr -o PROG.COM
```

- Verified: the probe builds (7,996 bytes) and runs under RunCPM, and `bdos()`
  answers.
- The classic library supplies `<stdio.h>` with CP/M file I/O, `malloc`, and
  `<cpm.h>`. The newlib variants (`-clib=sdcc_iy`) have no `<cpm.h>`, which is
  why they are not used.
- The provided startup code loads `SP` from `(0006h)`, which is `EC06h` on the
  current OS. The stack is therefore in common memory, which the bank services
  depend on.
- z88dk is a snap on the development host and cannot read `/tmp`: build inside
  the home tree.
- The convention is sdcccall(0): arguments on the stack, a `uint8_t` taking one
  byte, caller-cleaned; `uint8_t` returns in `L` and `uint16_t` in `HL`. The
  library's assembly helpers use it, or `__z88dk_fastcall` where one argument
  fits in `HL`. Port I/O is `__sfr __at`, and `__critical` blocks save and
  restore the interrupt state.

A second startup code, for programs that call functions in other banks, is
specified in section 10. The API is identical under both.

### Conventions

- Prefix `zep_`, headers under `include/zephyr/`, one library `zephyr.lib`.
- Results are `uint8_t`; `ZEP_OK` is 0. Functions that return data return it
  directly and document their failure value.
- The library is written in assembly where timing matters. Calling conventions
  are fixed per prototype in the headers, not left to compiler defaults.
- **No C code ever runs in interrupt context.** Interrupt work is done by the
  library's own assembly stubs in common memory, which publish counters and
  flags that C reads.
- **Ownership is explicit.** A module that takes hardware (`open`, `acquire`,
  `start`, `init`) registers an `atexit` handler that gives it back: PSGs muted,
  CTC channels stopped and unregistered, serial ports and the VDP returned to
  the BIOS. A program that exits early still leaves the machine usable.
- Everything is polled or event-based. Nothing blocks without a timeout except
  where a function says so.
- **A program pauses before it warm boots.** z88dk's startup code ends a program
  with a warm boot, and warm boot reinitialises the console and clears the
  screen, taking with it whatever was printed last. After the cleanup handlers
  run, ZephyrC prints `[any key]` and waits. `zep_exit_pause(0)` turns that off
  for a program that must not block on the way out; `zep_exit_pause(1)` turns it
  on for a program that registers nothing else. Polling console input is also
  what flushes the V9958 console's pending output, so the prompt appears
  without stdio.

---

## 2. Machine model a program can rely on

```text
0000h-00FFh   page zero of the program's bank (BDOS vector, FCBs, command tail)
0100h-DFFFh   the program: code, static data, heap          -- banked
E000h-E3FFh   program reservation, mapped in every mode     -- common
E400h-EBFFh   CCP; free while a program runs, restored at warm boot -- common
EC00h-EFFFh   BDOS facade                                    -- common
F000h-FFFFh   BIOS                                           -- common
```

- Interrupt callbacks, and everything they touch, must live in `E000h-E3FFh`.
  The library keeps `E300h-E3FFh` for its own tick callback and bank-call
  trampoline; `zep_common_alloc` (section 6) hands out `E000h-E2FFh`.
- Banks 1-6 are free for the program. Bank 7 is the operating system and every
  bank service refuses it.
- The BIOS owns IM2, the vector page, SIO0/B, SIO1 and the IO Controller link.
  Programs own SIO0/A, the CTC channels (not their vectors), the sound card, and
  the V9958 while they hold it.

---

## 3. `<zephyr/bdos.h>` -- operating system

### Standard CP/M and ZSDOS

Use z88dk's own interfaces unchanged:

- `<stdio.h>` for files: `fopen`, `fread`, `fwrite`, `fclose`, `remove`, `rename`.
- `<cpm.h>` for everything else: `bdos(func, de)`, `bdosh(func, de)`,
  `struct fcb`, `setfcb`, `parsefcb`, `getuid`/`setuid`.

Buffers can be anywhere in the program's memory: the BDOS facade copies them.
Functions 27 and 31 return pointers to copies in common memory.

ZSDOS adds clock and file time stamps, wrapped here:

```c
typedef struct { uint8_t year, month, day, hour, minute, second; } zep_datetime_t; /* BCD */

uint8_t zep_get_time(zep_datetime_t *t);                   /* ZSDOS 98 */
uint8_t zep_set_time(const zep_datetime_t *t);             /* ZSDOS 99 */
uint8_t zep_get_stamp(struct fcb *f, uint8_t stamp[15]);   /* ZSDOS 102 */
uint8_t zep_set_stamp(struct fcb *f, const uint8_t stamp[15]); /* ZSDOS 103 */
```

Checked against `../CPM2.2/zsdos/src/zsdos.z80`: 98 and 99 take `DE` -> the
six-byte buffer, and 102 and 103 take `DE` -> an FCB and move the 15 stamp
bytes through the DMA, which `zep_get_stamp` and `zep_set_stamp` set and
restore. None of them has been run against a real clock yet.

### Zephyr extensions

```c
typedef struct {
    uint8_t  version;          /* 1 */
    uint8_t  ioc_level;        /* IO Controller transport level */
    uint16_t ioc_diag;         /* address of the IOC link failure record */
    uint16_t sercon_flags;     /* address of the serial console flags byte */
    uint16_t bios_table;       /* CP/M BIOS jump table */
    uint16_t ext_table;        /* Zephyr extension table */
} zep_sysinfo_t;

const zep_sysinfo_t *zep_sysinfo(void);                    /* BDOS 203; NULL if not a Zephyr BIOS */

typedef struct { uint8_t a, c, b, e, d, l, h; } zep_regs_t; /* BDOS 210-217 register block */
uint8_t zep_bdos_ext(uint8_t fn, zep_regs_t *r);

uint8_t zep_ioc_call(const uint8_t tx[32], uint8_t rx[32]);  /* BDOS 214 IOCALL */
uint8_t zep_ioc_bulk_read(uint8_t *dst, uint16_t n);         /* BDOS 216 */
uint8_t zep_ioc_bulk_write(const uint8_t *src, uint16_t n);  /* BDOS 217 */
```

`zep_sysinfo` validates the block (version 1, sercon pointer in page `FEh`)
before returning it, so a program run under an emulator or another BIOS gets
`NULL` rather than garbage.

**Do not call BDOS functions that answer in `HL` through z88dk's `bdos()`.**
Both it and `bdosh()` end with `ld l,a`, replacing the low byte (and `bdos()`
sign-extends `A` into `H` as well), so a returned pointer or 16-bit value is
lost. Function 203 is the one that matters here, and `zep_sysinfo` uses an
assembly helper that leaves `HL` alone. The rest of the Zephyr range answers in
`A`, where `bdos()` is correct.

---

## 4. `<zephyr/serial.h>` -- serial ports

```c
typedef enum {
    ZEP_SERIAL_USER,           /* SIO0/A: RS-232 (MAX202), baud from CTC0 */
    ZEP_SERIAL_CONSOLE         /* SIO0/B: USB, shared with the BIOS console */
} zep_port_t;

#define ZEP_SERIAL_RTSCTS  0x01    /* hardware flow control */

uint8_t  zep_serial_open(zep_port_t p, uint32_t baud, uint8_t flags);
void     zep_serial_close(zep_port_t p);

int      zep_serial_getc(zep_port_t p);                          /* -1: nothing waiting */
int      zep_serial_getc_ms(zep_port_t p, uint16_t ms);          /* -1: timeout */
uint8_t  zep_serial_putc(zep_port_t p, uint8_t c);               /* ZEP_OK, or timeout */
uint16_t zep_serial_read(zep_port_t p, uint8_t *buf, uint16_t n, uint16_t ms);
uint16_t zep_serial_write(zep_port_t p, const uint8_t *buf, uint16_t n);

#define ZEP_SERIAL_RX_READY  0x01
#define ZEP_SERIAL_TX_EMPTY  0x04
#define ZEP_SERIAL_CTS       0x20
#define ZEP_SERIAL_OVERRUN   0x40
#define ZEP_SERIAL_FRAMING   0x80
uint8_t  zep_serial_status(zep_port_t p);
void     zep_serial_rts(zep_port_t p, uint8_t asserted);
```

Both ports are **polled**: there is no background receive buffer, so a program
must read often. `zep_serial_rts` lets it hold the far end off around anything
slow, such as a disk write.

### `ZEP_SERIAL_USER` (SIO0/A)

- Baud rate = 115200 / n, where n is CTC0's time constant in counter mode on its
  1.8432 MHz input (n = 1 gives 115200, 12 gives 9600). `zep_serial_open`
  refuses rates that are not exact.
- Opening it claims **CTC0**, so the timer cannot use CTC0 at the same time.
- It cannot use interrupts: SIO0/A shares SIO0's vector with the BIOS console.

### `ZEP_SERIAL_CONSOLE` (SIO0/B) -- official

The USB console port, lent to the program while it is open. This is the
mechanism XFER proved:

- **Open:** save the sercon flags, clear the tee and input bits, turn off
  SIO0/B's receive interrupt (WR1 = 00h, nothing else), clear receive errors,
  drain the FIFO, assert RTS.
- **Close:** restore the flags, set WR1 back to 18h (receive interrupt on all
  characters), release RTS. The sercon sink is still registered, so the console
  is back at once, without a warm boot. Warm boot would also restore it.
- The rate is fixed at 115200: the port has its own oscillator. `baud` must be
  115200 or 0.
- While it is open, console output still reaches the V9958 but not the port,
  and console input comes from the USB keyboard only.
- **V9958 console builds only.** In a VDrip build SIO0/B carries VDrip frames,
  and a program cannot tell the builds apart. VDrip needs its own transport.

---

## 5. `<zephyr/vdp.h>` -- V9958

```c
uint8_t zep_vdp_acquire(void);         /* the program owns the VDP */
void    zep_vdp_release(void);         /* BIOS console reinitialised (VIDEO_SEND A=00h) */

/* Registers and status */
void    zep_vdp_reg(uint8_t r, uint8_t v);       /* write; a shadow copy is kept */
uint8_t zep_vdp_reg_get(uint8_t r);              /* from the shadow: the VDP cannot be read */
uint8_t zep_vdp_status(uint8_t s);               /* select S#s, read, reselect S#0 */
void    zep_vdp_palette(uint8_t index, uint8_t r, uint8_t g, uint8_t b); /* 0-7 each */

/* Screen */
typedef enum { ZEP_VDP_T1, ZEP_VDP_T2, ZEP_VDP_MC,
               ZEP_VDP_G1, ZEP_VDP_G2, ZEP_VDP_G3,
               ZEP_VDP_G4, ZEP_VDP_G5, ZEP_VDP_G6, ZEP_VDP_G7 } zep_vdp_mode_t;
#define ZEP_VDP_LINES_212   0x01
#define ZEP_VDP_INTERLACE   0x02
void    zep_vdp_mode(zep_vdp_mode_t m, uint8_t flags);
void    zep_vdp_display(uint8_t on);

/* VRAM: 17-bit addresses, R#14 handled internally */
void    zep_vdp_vram_seek(uint32_t addr, uint8_t for_write);
void    zep_vdp_vram_write(const uint8_t *src, uint16_t n);
void    zep_vdp_vram_read(uint8_t *dst, uint16_t n);
void    zep_vdp_vram_fill(uint32_t addr, uint8_t value, uint32_t n);

/* Command engine */
typedef struct {
    uint16_t sx, sy, dx, dy, nx, ny;
    uint8_t  color, arg, cmd;                    /* R#44, R#45, R#46 */
} zep_vdp_cmd_t;
void    zep_vdp_command(const zep_vdp_cmd_t *c); /* loads R#32-R#46 */
uint8_t zep_vdp_command_busy(void);              /* S#2 CE */

/* Sprites (mode 2) */
void    zep_vdp_sprite(uint8_t n, uint8_t x, uint8_t y, uint8_t pattern, uint8_t color);

/* Frames */
uint8_t zep_vdp_vsync_start(void);    /* registers the VDP interrupt (section 5.1) */
void    zep_vdp_vsync_stop(void);
uint8_t zep_vdp_take_frame(void);     /* consumes one pending frame; saturates at 255 */
uint16_t zep_vdp_frames_missed(void);
uint8_t zep_vdp_vblank_poll(void);    /* S#0 F bit, when no interrupt is registered */
```

- While a program holds the VDP, **it must not use the console at all** -- not
  printing, and not `zep_kbd_getc`. The V9958 console driver writes to the VDP
  inside `CONST` as well as `CONOUT`: it flushes pending text, moves its cursor
  sprite and presents. A key poll through BDOS therefore draws into the screen
  the program is drawing, and can leave the VDP address latch half-set between
  the program's own two-byte writes. Use `zep_kbd_raw_getc` (section 9) while
  the VDP is held, and print after `zep_vdp_release`.
- The library always runs with the V9958's native WAIT and the LunchCrema porch
  on, exactly as the BIOS console leaves them. Block VRAM writes at full `OTIR`
  speed are therefore safe; the software-paced bootstrap path is never used.
- A register write is two `OUT`s and a status read is a select plus an `IN`.
  Every such pair runs with interrupts masked, because the VDP interrupt handler
  reads status and would otherwise land between the two bytes.

### 5.1 Frame interrupts (requires a BIOS change)

Games need to be called at vertical blank, not poll for it. The BIOS grows a
second registrable source:

| Source (`B` for BDOS 200) | Device |
|---:|---|
| 0-3 | CTC channels (existing) |
| **4** | **V9958 interrupt (frame, and line if enabled)** |

Proposed BIOS behaviour:

- The V9958 is routed to the maskable INT (config latch D0 = 0, as the console
  already leaves it). It supplies no IM2 vector, so the Z80 reads a floating
  `FFh`, and the existing `FDFFh/FE00h` arrangement sends that to
  `irq_ff_unexpected` in common memory.
- `irq_ff_unexpected` becomes the V9958 dispatcher: if source 4 is registered,
  switch to the interrupt stack, read S#0 (which acknowledges the frame
  interrupt), call the callback with the status in `A`, and end with `EI`/`RETI`.
  If S#1's line flag is enabled the dispatcher reads that too.
- The callback contract is the CTC one: entry and state in `E000h-E3FFh`,
  `AF`/`BC`/`DE`/`HL` only, `RET`, no BDOS, no BIOS.
- **BIOS console consequence:** every two-byte VDP register or status-select
  sequence in `cbios_console_v9958.asm` must be interrupt-atomic, for the same
  reason given above.
- Unregistering, warm boot and program exit restore R#1 IE0 to off.

**To verify on hardware first:** that the INT acknowledge really reads `FFh`
(data bus pull-ups), and that the V9958 `/INT` reaches the Z80 `/INT` with the
latch at D0 = 0. If the bus does not float high, the vector is random and this
design is unsafe.

`zep_vdp_vsync_start` registers the library's stub, which counts frames exactly
like the timer stub counts ticks.

---

## 6. `<zephyr/timer.h>` -- CTC

### Tick service

```c
uint8_t  zep_timer_start(uint8_t channel, uint8_t rate_hz);   /* channel 0-3, rate 1-180 */
uint8_t  zep_timer_stop(uint8_t channel);
uint8_t  zep_timer_take_tick(uint8_t channel);   /* 1 if a tick was consumed */
uint8_t  zep_timer_pending(uint8_t channel);     /* saturates at 255 */
uint16_t zep_timer_overflows(uint8_t channel);   /* ticks lost to saturation */
uint32_t zep_timer_count(uint8_t channel);       /* raw callbacks since start */
```

- A 180.0115 Hz base (`/256`, time constant 217) and a phase accumulator give 1
  to 180 logical ticks per second; 60 Hz is the exact divide-by-three case.
  This is the scheme VGMPlayer and Zephyr80Lib `Timer` already use.
- **Any channel.** CTC0 is the one verified on hardware; CTC1-3 are expected to
  work and get a per-channel acceptance test before release. The one hard
  conflict is CTC0 with `ZEP_SERIAL_USER`, and `zep_timer_start` refuses it
  while that port is open.
- `zep_timer_start` first asks `zep_sysinfo()` whether this is a Zephyr BIOS.
  Interrupt registration is a Zephyr BDOS function, and another BDOS returns
  whatever happened to be in `HL`, which can look like success.
- `take_tick` and `pending` preserve the caller's interrupt state.

### Raw CTC

```c
void    zep_ctc_write(uint8_t channel, uint8_t control, uint8_t time_constant);
uint8_t zep_ctc_read(uint8_t channel);      /* down-counter value */
void    zep_ctc_reset(uint8_t channel);
```

The control word may not set the vector bit: the BIOS owns the vector byte.

### Custom interrupt callbacks

For programs that need more than a tick counter:

```c
void   *zep_common_alloc(uint16_t n);                     /* from E000h-E2FFh; NULL when full */
uint8_t zep_common_install(void *dst, const void *code, uint16_t n);
uint8_t zep_isr_register(uint8_t source, void *entry);    /* BDOS 200: CTC 0-3, VDP 4 */
uint8_t zep_isr_unregister(uint8_t source);               /* BDOS 201 */
```

Callback code is assembly, assembled for its common-memory address (a z88dk
section with its `org` in `E000h-E3FFh`) and copied there with
`zep_common_install`. The library's own timer and frame stubs use the same
allocator, so a program's callbacks and the library's never overlap.

---

## 7. `<zephyr/sound.h>` -- Afternoon Blend

```c
#define ZEP_SOUND_CHANNELS 16    /* chip = channel >> 2, voice = channel & 3; voice 3 is noise */

void     zep_sound_init(void);                       /* mute all four PSGs; atexit mutes again */
void     zep_sound_mute_all(void);
uint8_t  zep_sound_tone(uint8_t channel, uint16_t period);   /* 1-1023; ZEP_OK or wrong voice */
void     zep_sound_volume(uint8_t channel, uint8_t attenuation); /* 0 loudest .. 15 off */
uint8_t  zep_sound_noise(uint8_t channel, uint8_t white, uint8_t rate); /* rate 0-3; 3 = tone 2 */
uint8_t  zep_sound_restart_noise(uint8_t channel);
uint16_t zep_sound_period_for_hz(uint16_t hz);       /* 111861 / hz */

/* Raw access */
void     zep_psg_write(uint8_t chip, uint8_t byte);  /* conventional SN76489 byte */
void     zep_psg_write_block(uint8_t chip, const uint8_t *bytes, uint8_t n);
void     zep_pcm_write(uint8_t sample);              /* AD7801 at E4h */
void     zep_pcm_write_block(const uint8_t *samples, uint16_t n);
```

- Semantics match Zephyr80Lib `Sound`.
- Ports `E0h-E3h` (PSG0-3) and `E4h` (PCM) are **write-only**; reads in that
  range belong to the controller latches. The card inserts its own wait, so no
  software delays.
- The chips have no reset input: `zep_sound_init` and the exit handler mute
  them, because nothing else will.
- A C wrapper for the ZTR player is a later addition.

---

## 8. `<zephyr/bank.h>` -- banked memory

```c
#define ZEP_BANK_FIRST 1
#define ZEP_BANK_LAST  6

uint8_t  zep_bank_current(void);
uint8_t  zep_bank_copy(uint8_t dst_bank, uint16_t dst,
                       uint8_t src_bank, uint16_t src, uint16_t n);   /* XMOVE + MOVE */
uint8_t  zep_bank_read(uint8_t bank, uint16_t addr, void *buf, uint16_t n);
uint8_t  zep_bank_write(uint8_t bank, uint16_t addr, const void *buf, uint16_t n);
uint8_t  zep_bank_fill(uint8_t bank, uint16_t addr, uint8_t value, uint16_t n);
uint8_t  zep_bank_prepare(uint8_t bank);      /* copy page zero so BDOS works while it is mapped */
uint16_t zep_bank_call(uint8_t bank, uint16_t entry, uint16_t hl);  /* through a common trampoline */
```

- Under the standard startup code all C code and data are in bank 0, so other
  banks hold **data**, reached by copying. Addresses must lie in
  `0000h-DFFFh`; copies go through the BIOS's common scratch buffer.
- `zep_bank_call` runs code that was built for, and copied into, another bank.
  The trampoline lives in `E000h-E3FFh`; the stack is already common.
- Direct `SELMEM` is not exposed: it unmaps the C code that would call it.
  Section 10 is the supported way to run C in other banks.

---

## 9. `<zephyr/input.h>` -- keyboard and gamepads

### Keyboard

```c
int     zep_kbd_getc(void);          /* -1 if nothing; terminal bytes, cursor keys as VT100 */
uint8_t zep_kbd_hit(void);

int     zep_kbd_raw_getc(void);      /* straight from the IO Controller */
uint8_t zep_kbd_raw_ok(void);        /* 0 once a raw read has failed */
```

`zep_kbd_getc` goes through BDOS 6 (direct console I/O), so it shares the BIOS
console's view of the USB keyboard and never races it for the IO Controller's
queue. It is the right call for an ordinary program.

`zep_kbd_raw_getc` reads `CMD_HID_INPUT` itself and bypasses the console. **A
program holding the VDP must use it**, for the reason in section 5: the console
draws into the VDP during `CONST`. Keys it takes do not reach `CONST`, which is
what a program owning the screen wants.

On a machine whose IO Controller cannot answer, the raw read fails and
`zep_kbd_raw_ok` returns 0 from then on. Fall back to `zep_kbd_getc`: without a
HID keyboard, console input is the only input, and nothing is drawing over the
program anyway.

The IO Controller only delivers a **translated byte stream** today: there are
no key-down or key-up events, and holding two keys at once cannot be seen.
Games want key state, so the firmware gets a new command:

| Proposed | Request | Reply |
|---|---|---|
| `CMD_HID_KEYSTATE` | none | modifier byte, then a bitmap of pressed HID usages (keys 04h-E7h) |

```c
uint8_t zep_kbd_state(uint8_t bitmap[32]);    /* requires CMD_HID_KEYSTATE */
uint8_t zep_kbd_down(uint8_t hid_usage);      /* from the last zep_kbd_state */
```

### Gamepads

Available now: the IO Controller decodes a Logitech F310 into two
Coleco-format latches that the Z80 reads with `IN`.

```c
#define ZEP_PAD_UP      0x01
#define ZEP_PAD_RIGHT   0x02
#define ZEP_PAD_DOWN    0x04
#define ZEP_PAD_LEFT    0x08
#define ZEP_PAD_FIRE    0x10

uint8_t  zep_pad_read(uint8_t pad);     /* pad 0-1; bits set while pressed */
uint8_t  zep_pad_raw(uint8_t pad);      /* the active-low latch byte as the Z80 sees it */
uint8_t  zep_pad_connected(uint8_t pad);/* from HID_STATUS page 6 (IOCALL) */
```

- Read addresses: the decoder sends every read in `E0h-FFh` to the latches.
  Pad 0 and pad 1 are expected at the Coleco addresses `FCh` and `FFh`; the
  card-local select is confirmed on hardware before `zep_pad_read` is written.
- `zep_pad_raw` exists so Coleco-derived code can use the byte unchanged.
- **The keypad substitutes cannot be decoded.** A real Coleco controller has a
  keypad/joystick mode select; the latch has none, so the firmware's keypad
  codes are the same bit patterns as d-pad combinations (keypad 1 is exactly
  RIGHT, and the star code is RIGHT plus DOWN). `zep_pad_read` therefore reports
  directions and fire only. `zep_pad_raw` gives the byte for code that knows
  which the program asked the player for.
- Other limits: one fire line, no analog axes, F310 only.

For full controllers the firmware gets a second command:

| Proposed | Request | Reply |
|---|---|---|
| `CMD_HID_PADSTATE` | pad number | connected flag, 16-bit button mask, hat, four 8-bit axes |

```c
typedef struct { uint8_t connected; uint16_t buttons; uint8_t hat; int8_t lx, ly, rx, ry; } zep_pad_t;
uint8_t zep_pad_state(uint8_t pad, zep_pad_t *out);   /* requires CMD_HID_PADSTATE */
```

Both new commands follow the three-edit rule in `../Utilities/README.md`
(`ioc_frame.h`, `dispatch.c`, and `is_command_class()` in `external_sync.c`).

---

## 10. Banked programs: far calls

A second startup code, `crt_zephyr_banked`, lets a program put functions in
banks 1-6 and call them like any other function. It is built on SDCC's banked
function support: a function declared `__banked` is called through
`___sdcc_bcall_ehl`, which needs only `get_bank` and `set_bank` routines.

```c
void draw_level(uint8_t n) __banked;     /* lives in whichever bank it was linked into */
```

### Layout

```text
                bank 0            bank N (1-6)
0000h-00FFh     page zero         page zero (copied)
0100h-3FFFh     root: startup,    root (identical copy)
                ZephyrC, libc,
                shared code
4000h-DFFFh     bank-0 code       banked functions for bank N
E000h-E3FFh     trampolines, set_bank/get_bank, interrupt stubs  -- common
E400h-E7FFh     all static data and globals                      -- common
E800h-EC05h     stack, growing down from EC06h                   -- common
EC06h-          (OS)
```

- **Root is duplicated into every bank used**, so library code, `libc` and the
  trampolines' return path are present whichever bank is mapped. Only the code
  in `4000h-DFFFh` differs between banks.
- **Static data and the stack must be common.** A banked function that touched
  a global in bank 0 would read bank N's copy instead. The banked startup code
  therefore links all data sections at `E400h-E7FFh` and keeps the stack above
  them, both in the CCP area, which is free while a program runs and restored
  from ROM at warm boot. That leaves 1 KiB of globals and about 1 KiB of stack.
  Larger data belongs in banks, reached through `zep_bank_*`, or on the heap in
  bank 0 when only root and bank-0 code use it. The exact split between globals
  and stack is set by the startup code's link map and checked at link time.
- `set_bank` wraps `SELMEM` and lives in common memory, as `SELMEM` requires.
- The startup code copies page zero and the root into each bank the image uses,
  then loads each bank's `4000h-DFFFh` segment from the `.COM` file (or from
  companion `.B1`-`.B6` files; decided at implementation).
- Interrupt callbacks are unaffected: they are already in common memory.
- A `__banked` call costs a trampoline and a latch write, a few hundred
  T-states, so keep them for coarse-grained functions.

Open implementation questions, answered when this startup code is built rather
than now: whether the image is one file or one per bank; whether `4000h` is the
right root boundary; and how the heap is split between common memory and banks.

---

## 11. Dependencies outside this library

| Work | Where | Needed by |
|---|---|---|
| V9958 as registrable interrupt source 4; interrupt-atomic console VDP writes | BIOS (`cbios_irq.asm`, `cbios_console_v9958.asm`) | `zep_vdp_vsync_*` |
| Confirm INT acknowledge reads `FFh` and V9958 `/INT` reaches the Z80 | hardware | the BIOS change above |
| CTC1-3 interrupt acceptance test | hardware (a `TIMTEST` for each channel) | `zep_timer_start` on channels 1-3 |
| Controller latch select for `FCh`/`FFh` | hardware | `zep_pad_read` |
| `CMD_HID_KEYSTATE`, `CMD_HID_PADSTATE` | IO Controller firmware | `zep_kbd_state`, `zep_pad_state` |
| ZSDOS 98-103 numbers and stamp layout | `zsdos.z80` | `zep_get_time` and friends |

## 12. State of each part

| Part | Built | Exercised so far |
|---|---|---|
| `bdos.h` | yes | `zep_sysinfo` under RunCPM (correctly reports "not a Zephyr BIOS"); IOCALL, bulk and stamps need the machine |
| `sound.h` | yes | compiles and is called by `MANDEL`; nothing has been heard yet |
| `timer.h` | yes | `TICKTEST` proves the tick stub, phase accumulator, saturation and per-channel isolation without a CTC |
| `serial.h` | yes | `SERTEST` opens the console port, exchanges a line and times out on a quiet line, against a pty peer |
| `vdp.h` | yes, minus vsync | `MANDEL` renders a correct set through a V9958 model in the harness |
| `input.h` | keyboard and latch | keyboard through BDOS in `MANDEL`; the latches need hardware |
| `bank.h` | yes | untested: RunCPM has no BDOS 210-217 |
| Banked startup, far calls | no | section 10 |

Next, in this order:

1. Run `MANDEL` on the machine and compare it with
   `../HelloWorld/build/mandelbrot_v9958_real.com`.
2. Time the CTC channels 0-3 with a small program built on `timer.h`, which
   settles whether CTC1-3 interrupt reliably.
3. Confirm the gamepad latch addresses, then `zep_pad_read`.
4. The BIOS V9958 interrupt source, then `zep_vdp_vsync_*`.
5. `bank.h` on hardware, then the banked startup code.
