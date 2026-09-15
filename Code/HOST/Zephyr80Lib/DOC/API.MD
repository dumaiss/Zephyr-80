# Zephyr80Lib API

Applications import one or more of the public `Sound`, `Timer`, and `Player`
definition modules. The library is singleton and designed for foreground game
loops under the current Zephyr CP/M execution and interrupt architecture.

## Player

`Player` is the normal API for embedded ZTR music. It loads the complete file,
claims the PSGs, and sequences all 16 ZTR channels. It does not configure,
start, read, or stop a timer. The application supplies music ticks.

```modula-2
TYPE
  Result = (ok, noFileName, fileNotFound, fileTooLarge,
            unsupported, malformed);

PROCEDURE Load(name : ARRAY OF CHAR) : Result;
PROCEDURE Tick;
PROCEDURE Stop;
PROCEDURE Playing() : BOOLEAN;
PROCEDURE SetLooping(enabled : BOOLEAN);
PROCEDURE Looping() : BOOLEAN;
PROCEDURE Finished() : BOOLEAN;
PROCEDURE TakeFinished() : BOOLEAN;
PROCEDURE TickRate() : CARDINAL;
PROCEDURE Title(VAR text : ARRAY OF CHAR);
PROCEDURE CurrentOrder() : CARDINAL;
PROCEDURE CurrentRow() : CARDINAL;
PROCEDURE Minutes() : CARDINAL;
PROCEDURE Seconds() : CARDINAL;
PROCEDURE TakeOrderChange() : BOOLEAN;
```

### Playback lifecycle

`Load` validates the named ZTR file before touching the sound hardware. On
success it mutes and initializes all PSGs and prepares playback at order 0 and
row 0. No music time passes until the application calls `Tick`.

Calling `Load` during playback first stops and mutes the old song. A successful
load claims `Sound`, but it has no effect on `Timer`, CTC0, VBlank handling, or
any other clock source.

`Tick` advances the sequencer by exactly one tracker tick. It does not check
whether real time has passed and does not consume a `Timer` event. Calling it
without an active or restartable song has no effect. Call it from foreground
code, not directly from a Zephyr ISR: sequencing and PSG rendering are
intentionally outside the BIOS callback contract.

### Completion and looping

Looping is disabled initially. `SetLooping(TRUE)` makes natural completion
restart the retained ZTR at order 0 without another disk read. The tick that
finishes one pass does not also process the first tick of the next pass, so the
one-call/one-tracker-tick contract remains intact. `Playing()` remains `TRUE`
across an automatic loop boundary.

With looping disabled, natural completion makes `Playing()` false. Further
ticks are harmless. The decoded ZTR remains available: enabling looping after
one-shot completion makes the next `Tick` restart it without calling `Load`.

`Finished()` is a completion latch. It becomes true whenever a pass reaches
its natural end, including every loop boundary. `TakeFinished()` returns and
clears that latch, following the same event-consumption model as
`TakeOrderChange()`. Multiple completions before the latch is consumed collapse
into one notification. An explicit `Stop` is cancellation, not natural
completion, and clears the latch and any restartable end state.

`Looping()` returns the selected policy. `Load` preserves that policy but
clears the completion latch, allowing the usual setup order of
`SetLooping(TRUE)` followed by `Load`.

### Frame-synchronous game

For a soundtrack authored at the game's VBlank rate, the game can advance
music from the same foreground event used for simulation:

```modula-2
Player.SetLooping(TRUE);
music := Player.Load('LEVEL1.ZTR');
IF (music = Player.ok) AND (Player.TickRate() = 60) THEN
  WHILE gameRunning DO
    IF VBlank.TakeTick() THEN
      Player.Tick;
      UpdateGame;
      Render
    END
  END
END;
Player.Stop
```

Here one foreground VBlank event equals one game tick and one tracker tick. If
the clock and song rates differ, the application must use a phase accumulator
or choose a song authored at the engine rate; `Player` deliberately performs no
implicit rate conversion.

### CTC-timed application

`Timer` remains available as an optional source. The application owns its
lifecycle and explicitly wires each queued timer event to `Player.Tick`:

```modula-2
music := Player.Load('SONG.ZTR');
IF music = Player.ok THEN
  timerResult := Timer.Start(Player.TickRate());
  IF timerResult = Timer.ok THEN
    WHILE Player.Playing() DO
      WHILE Timer.TakeTick() AND Player.Playing() DO
        Player.Tick
      END;
      (* Poll input and perform other foreground work here. *)
    END;
    timerResult := Timer.Stop()
  END;
  Player.Stop
END
```

The timer queue holds at most 255 pending ticks. The application must consume
it frequently enough that it does not saturate, especially during disk or
display work. This queue belongs to `Timer`, not `Player`.

`Stop` is safe when playback is inactive. During active playback it stops the
music engine and mutes all PSG voices. It also cancels a pending retained-song
restart. Natural end-of-song performs sound cleanup during the final `Tick`
call. `Stop` never stops or otherwise changes the application's clock.

The player owns `Sound` between a successful `Load` and cleanup. Do not call
`Sound` directly during that interval. The PSGs are write-only, so state that
existed before playback cannot be restored. `Timer` is independent and may be
used for music, game timing, or both at the application's discretion.

The loader reserves a fixed 20,480-byte ZTR buffer in the linked program; it
does not allocate memory dynamically. The file remains in that private buffer
throughout playback.

### Player results

| Result | Meaning |
|---|---|
| `ok` | Playback started. |
| `noFileName` | The supplied name is empty. |
| `fileNotFound` | CP/M could not open the file. |
| `fileTooLarge` | The file or its declared ZTR size exceeds 20,480 bytes. |
| `unsupported` | The file is a recognized but unsupported ZTR variant or uses unsupported limits. |
| `malformed` | The ZTR signature, layout, offsets, or event data are invalid. |

`TickRate` reports the authored tracker-tick rate from the successfully loaded
ZTR. It returns zero before the first successful load and after a failed load;
`Stop` leaves the most recently loaded rate available as metadata.

`Title` copies the loaded ZTR title into the caller's array and terminates it
with `CHR(0)`. The text is truncated when necessary to fit the supplied array.

`CurrentOrder` and `CurrentRow` are zero-based. `Minutes` and `Seconds` report
music time derived from calls to `Tick`, not wall-clock time; seconds range from
0 through 59 and minutes wrap after 99. `TakeOrderChange` returns `TRUE` once
after loading and once after every order transition, clearing the notification
when read. `Player` does not expose seeking or pause in this version.

## Timer

`Timer` is the public general timing API. Its private `CTCLow` backend uses
CTC0; applications do not import or call `CTCLow`.

```modula-2
TYPE
  Hertz = CARDINAL;
  Result = (ok, invalidRate, alreadyActive, notActive, unavailable);

PROCEDURE Start(rate : Hertz) : Result;
PROCEDURE Stop() : Result;
PROCEDURE Active() : BOOLEAN;
PROCEDURE Pending() : BOOLEAN;
PROCEDURE TakeTick() : BOOLEAN;
PROCEDURE QueueOverflows() : CARDINAL;
PROCEDURE Interrupts() : CARDINAL;
```

`Start` accepts 1 through 180 logical ticks per second. It returns
`alreadyActive` if this module already owns the timer, `invalidRate` outside
that range, or `unavailable` if the Zephyr BIOS refuses CTC0 registration.
CTC0 is an exclusive application resource.

The hardware callback runs at approximately 180 Hz. A phase accumulator
publishes logical ticks at the requested rate. `Pending` reports whether at
least one tick is queued without consuming it; `TakeTick` consumes exactly one
tick and reports whether one was available. These operations preserve the
caller's enabled or disabled interrupt state.

The pending counter saturates at 255. `QueueOverflows` counts logical ticks
rejected while it was full. `Interrupts` counts raw CTC callbacks. Both are
16-bit diagnostic counters, reset by a successful start, and may eventually
wrap. Hardware expirations missed while interrupts were disabled cannot be
counted.

`Stop` resets CTC0 before unregistering it and returns `notActive` if this
module did not consider the timer active.

The private callback complies with the Zephyr BIOS contract:

- callback code is copied to `E3C0h-E3F6h`; its state is at `E3F8h-E3FEh`,
  wholly within the application-owned common reservation;
- registration and unregistration use Zephyr BDOS functions 200 and 201;
- the callback touches only common state, never calls TM2, BDOS, or BIOS, and
  returns with `RET` for the BIOS dispatcher;
- the BIOS owns IM2, the vector page, register preservation, interrupt stack,
  and final `EI`/`RETI`.

TM2's stock startup loads `SP` from `(0006h)`, which is `EC06h` on the current
Zephyr OS. The callback is deliberately near the top of the program reservation
so the linked application's data/heap tail can use its lower portion while the
normal TM2 stack grows down from `EC06h`. A consumer must keep its data and heap
below `E3C0h` and budget its maximum stack depth so it remains above `E3FEh`.

`Timer` is independent of `Player`. A caller may use it as the music clock by
passing each consumed tick to `Player.Tick`, or may reserve it for unrelated
game timing while music follows another clock.

## Sound

`Sound` exposes the four Afternoon Blend SN76489-compatible PSGs as 16 logical
channels.

```modula-2
CONST
  ChannelCount = 16;

TYPE
  Channel = [0..15];
  TonePeriod = [1..1023];
  Volume = [0..15];
  NoiseMode = (periodicNoise, whiteNoise);
  NoiseRate = (lowRate, mediumRate, highRate, tone2Rate);
  Result = (ok, wrongVoice);

PROCEDURE Init;
PROCEDURE Shutdown;
PROCEDURE MuteAll;
PROCEDURE SetTone(channel : Channel; period : TonePeriod) : Result;
PROCEDURE SetVolume(channel : Channel; volume : Volume);
PROCEDURE SetNoise(channel : Channel;
                   mode : NoiseMode;
                   rate : NoiseRate) : Result;
PROCEDURE RestartNoise(channel : Channel) : Result;
PROCEDURE WriteCount() : CARDINAL;
```

Channels map as follows:

| Logical channels | PSG port | Voices |
|---|---:|---|
| 0-3 | `E0h` | tone 0-2, noise 3 |
| 4-7 | `E1h` | tone 0-2, noise 3 |
| 8-11 | `E2h` | tone 0-2, noise 3 |
| 12-15 | `E3h` | tone 0-2, noise 3 |

`SetTone` accepts only the three tone voices on each chip and returns
`wrongVoice` for a noise voice. The period is the PSG's 10-bit hardware period,
not a frequency in hertz.

`SetNoise` and `RestartNoise` accept only each chip's noise voice and return
`wrongVoice` for tone voices. `tone2Rate` clocks the noise generator from that
chip's tone voice 2. `RestartNoise` rewrites the most recent noise control value
for the chip; before a successful `SetNoise`, it has no hardware effect.

`SetVolume` accepts every channel. Volume 0 is silent and 15 is full level.
`Init` resets the diagnostic write count, invalidates remembered noise modes,
and mutes all channels. `Shutdown` and `MuteAll` also mute every channel.

`WriteCount` returns the number of PSG port writes since the last `Init`
(including initialization's mute writes), modulo the 16-bit `CARDINAL` range.
It is intended for diagnostics.

`Sound` is exclusive because the PSGs are write-only and the module has no way
to save another user's state. Do not call it while `Player` is active.
