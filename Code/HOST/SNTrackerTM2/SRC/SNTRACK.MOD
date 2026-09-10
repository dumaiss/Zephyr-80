MODULE SNTrack;

FROM SYSTEM IMPORT BDOS, IORESULT;
FROM ComLine IMPORT commandLine, RedirectInput, RedirectOutput;
IMPORT ZTR, Player, Sound, Timer, TrkUI;

VAR
  fileName : ARRAY [0..20] OF CHAR;
  loadResult : ZTR.LoadResult;
  timerResult, stopResult : Timer.Result;
  keyTicks, key : CARDINAL;

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

BEGIN
  RedirectInput;
  RedirectOutput;
  fileName := '';
  READ(commandLine, fileName);
  IF fileName[0] = CHR(0) THEN
    WRITELN('Usage: SNTRACK file.ZTR')
  ELSE
    loadResult := ZTR.Load(fileName);
    IF loadResult # ZTR.loadOK THEN
      WRITELN('Cannot load ZTR file; error ', ORD(loadResult))
    ELSE
      Sound.Init;
      Player.Init;
      Player.Start;
      TrkUI.Init;
      timerResult := Timer.Start(ZTR.TickRate());
      IF timerResult # Timer.ok THEN
        Player.Stop;
        WRITELN('Timer start failed; error ', ORD(timerResult))
      ELSE
        keyTicks := ZTR.TickRate();
        WHILE Player.Playing() DO
          IF Timer.TakeTick() THEN
            Player.Tick;
            TrkUI.Service;
            IF keyTicks <= 1 THEN
              PollKey;
              keyTicks := ZTR.TickRate()
            ELSE
              DEC(keyTicks)
            END
          END
        END;
        stopResult := Timer.Stop()
      END;
      Sound.Shutdown;
      WRITELN;
      WRITELN('Playback stopped.')
    END
  END
END SNTrack.
