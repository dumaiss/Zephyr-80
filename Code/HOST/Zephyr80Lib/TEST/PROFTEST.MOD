MODULE ProfTest;

(* Instruction-count probe for the per-tick path.

   Not a correctness test.  It loads a song and runs a fixed number of
   Player.Tick calls between two marker port writes, so tests/ftl_profile.cpp
   can count emulated instructions for the tick path alone and attribute a cost
   per tick.  Everything outside the markers -- load, parse, setup -- is
   excluded from the count. *)

FROM PortIO IMPORT Out;
IMPORT Player;

CONST
  MarkerPort = 254;
  LoadFailed = 255;
  Begin = 1;
  End = 2;
  Ticks = 3000;
  TickMark = 253;
  OrderMark = 252;

VAR
  result : Player.Result;
  i : CARDINAL;

BEGIN
  result := Player.Load('NIGHT.ZTR');
  IF result <> Player.ok THEN
    Out(MarkerPort, LoadFailed)
  ELSE
    Out(MarkerPort, Begin);
    i := 0;
    WHILE i < Ticks DO
      Player.Tick;
      IF Player.TakeOrderChange() THEN Out(OrderMark, 0) END;
      Out(TickMark, 0);     (* per-tick boundary for the profiler *)
      INC(i)
    END;
    Out(MarkerPort, End)
  END
END ProfTest.
