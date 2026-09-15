MODULE PlyTest;

IMPORT Player, Sound;

PROCEDURE Run(name : ARRAY OF CHAR);
VAR result : Player.Result; ticks : CARDINAL;
BEGIN
  result := Player.Load(name);
  IF result # Player.ok THEN
    WRITELN(name, ': load error ', ORD(result));
    RETURN
  END;
  ticks := 0;
  WHILE Player.Playing() DO
    Player.Tick;
    INC(ticks)
  END;
  WRITELN(name, ': ', ticks, ' ticks, ',
          Player.Minutes(), ':', Player.Seconds(),
          ', ', Sound.WriteCount(), ' PSG writes');
  IF NOT Player.Finished() THEN
    WRITELN(name, ': completion latch missing')
  ELSIF NOT Player.TakeFinished() THEN
    WRITELN(name, ': completion latch could not be consumed')
  ELSIF Player.Finished() THEN
    WRITELN(name, ': completion latch did not clear')
  END;

  (* Enabling looping after one-shot completion must reuse the retained ZTR.
     A further tick restarts playback without another Load. *)
  Player.SetLooping(TRUE);
  Player.Tick;
  IF NOT Player.Playing() THEN
    WRITELN(name, ': retained-song restart failed')
  END;
  Player.Stop;
  Player.SetLooping(FALSE)
END Run;

BEGIN
  Run('NIGHT.ZTR');
  Run('RUNAWAY.ZTR')
END PlyTest.
