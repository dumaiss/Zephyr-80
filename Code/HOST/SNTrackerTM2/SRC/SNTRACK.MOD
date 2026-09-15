MODULE SNTrack;

FROM SYSTEM IMPORT BDOS, IORESULT;
FROM ComLine IMPORT commandLine, RedirectInput, RedirectOutput;
IMPORT Player, Timer;

VAR
  fileName : ARRAY [0..20] OF CHAR;
  loadResult : Player.Result;
  timerResult, stopResult : Timer.Result;
  keyTicks, idleSpins, key : CARDINAL;

PROCEDURE PollKey;
BEGIN
  BDOS(11, 0);
  IF IORESULT = 0 THEN RETURN END;
  BDOS(1, 0);
  key := IORESULT;
  IF (key = ORD('q')) OR (key = ORD('Q')) OR (key = 27) THEN
    Player.Stop
  END
END PollKey;

PROCEDURE InitUI;
VAR title : ARRAY [0..63] OF CHAR;
BEGIN
  Player.Title(title);
  WRITELN('Playing: ', title);
  WRITELN('Q/Esc: stop; one update per pattern block')
END InitUI;

PROCEDURE ServiceUI;
BEGIN
  IF Player.TakeOrderChange() THEN
    WRITELN('Order ', Player.CurrentOrder(),
            '  time ', Player.Minutes(), ':', Player.Seconds(),
            '  queue overflows ', Timer.QueueOverflows())
  END
END ServiceUI;

BEGIN
  RedirectInput;
  RedirectOutput;
  fileName := '';
  READ(commandLine, fileName);
  IF fileName[0] = CHR(0) THEN
    WRITELN('Usage: SNTRACK file.ZTR')
  ELSE
    Player.SetLooping(FALSE);
    loadResult := Player.Load(fileName);
    IF loadResult # Player.ok THEN
      WRITELN('Cannot load ZTR file; error ', ORD(loadResult))
    ELSE
      timerResult := Timer.Start(Player.TickRate());
      IF timerResult # Timer.ok THEN
        Player.Stop;
        WRITELN('Timer start failed; error ', ORD(timerResult))
      ELSE
        InitUI;
        ServiceUI;
        keyTicks := Player.TickRate();
        idleSpins := 0;
        WHILE Player.Playing() DO
          IF Timer.TakeTick() THEN
            idleSpins := 0;
            Player.Tick;
            ServiceUI;
            IF keyTicks <= 1 THEN
              PollKey;
              keyTicks := Player.TickRate()
            ELSE
              DEC(keyTicks)
            END
          ELSE
            (* Keep abort input reachable if logical ticks stop.  The large
               foreground divider keeps CONST/CONIN well below 10 Hz. *)
            IF idleSpins = 65535 THEN
              idleSpins := 0;
              PollKey
            ELSE
              INC(idleSpins)
            END
          END
        END;
        stopResult := Timer.Stop();
        Player.Stop
      END;
      WRITELN;
      WRITELN('Playback stopped.')
    END
  END
END SNTrack.
