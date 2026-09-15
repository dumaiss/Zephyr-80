MODULE LibTest;

IMPORT Player, Sound, Timer;

VAR active : BOOLEAN;
    result : Player.Result;

BEGIN
  result := Player.Load('NOFILE.ZTR');
  active := Player.Playing();
  IF result # Player.fileNotFound THEN
    WRITELN('Unexpected missing-file result: ', ORD(result))
  ELSIF active OR Timer.Active() THEN
    WRITELN('Unexpected active library state')
  ELSE
    WRITELN('ZEPHYR80.LIB API OK')
  END
END LibTest.
