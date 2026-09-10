MODULE PlyTest;

IMPORT ZTR, Player, Sound;

PROCEDURE Run(name : ARRAY OF CHAR);
VAR result : ZTR.LoadResult; ticks : CARDINAL;
BEGIN
  result := ZTR.Load(name);
  IF result # ZTR.loadOK THEN
    WRITELN(name, ': load error ', ORD(result));
    RETURN
  END;
  Sound.Init;
  Player.Start;
  ticks := 0;
  WHILE Player.Playing() DO
    Player.Tick;
    INC(ticks)
  END;
  Sound.Shutdown;
  WRITELN(name, ': ', ticks, ' ticks, ',
          Player.Minutes(), ':', Player.Seconds(),
          ', ', Sound.WriteCount(), ' PSG writes')
END Run;

BEGIN
  Run('NIGHT.ZTR');
  Run('RUNAWAY.ZTR')
END PlyTest.
