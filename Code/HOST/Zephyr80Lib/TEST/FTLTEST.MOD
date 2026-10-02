MODULE FTLTEST;
(* Hosted ABI regression. Hardware access is supplied by ftl_bridge.cpp. *)
FROM CTCLow IMPORT LStart, LStop, IsAct, Pend, Take, Over, Ints;
FROM InOut IMPORT WriteString, WriteLn;
IMPORT Sound;
VAR n, i : CARDINAL;
PROCEDURE Check(actual, expected : CARDINAL);
BEGIN
  IF actual <> expected THEN
    WriteString('FTL bridge FAIL'); WriteLn; HALT
  END
END Check;
PROCEDURE Exercise;
VAR local, guard : CARDINAL;
BEGIN
  guard := 12345;
  LStart(180);
  IsAct(local); Check(local, 1);
  Pend(local); Check(local, 0);
  Take(local); Check(local, 0);
  Over(local); Check(local, 0);
  Ints(local); Check(local, 0);
  Check(guard, 12345);
  LStop;
  IsAct(local); Check(local, 0);
  Check(guard, 12345)
END Exercise;
PROCEDURE CheckSound;
VAR chip, base, rate, count : CARDINAL;
BEGIN
  Sound.Init;
  Check(Sound.WriteCount(), 16);
  FOR chip := 0 TO 3 DO
    base := chip * 4;
    count := Sound.WriteCount();
    Check(ORD(Sound.SetTone(Sound.Channel(base), 1)), ORD(Sound.ok));
    Check(ORD(Sound.SetTone(Sound.Channel(base+1), 1023)), ORD(Sound.ok));
    Check(ORD(Sound.SetTone(Sound.Channel(base+2), 448)), ORD(Sound.ok));
    Sound.SetVolume(Sound.Channel(base), 0);
    Sound.SetVolume(Sound.Channel(base+2), 15);
    Check(ORD(Sound.SetTone(Sound.Channel(base+3), 1)),
          ORD(Sound.wrongVoice));
    Check(ORD(Sound.SetNoise(Sound.Channel(base), Sound.whiteNoise,
              Sound.highRate)), ORD(Sound.wrongVoice));
    Check(ORD(Sound.RestartNoise(Sound.Channel(base+3))), ORD(Sound.ok));
    FOR rate := 0 TO 3 DO
      Check(ORD(Sound.SetNoise(Sound.Channel(base+3), Sound.periodicNoise,
                Sound.NoiseRate(rate))), ORD(Sound.ok))
    END;
    FOR rate := 0 TO 3 DO
      Check(ORD(Sound.SetNoise(Sound.Channel(base+3), Sound.whiteNoise,
                Sound.NoiseRate(rate))), ORD(Sound.ok))
    END;
    Check(ORD(Sound.RestartNoise(Sound.Channel(base+3))), ORD(Sound.ok));
    Check(ORD(Sound.RestartNoise(Sound.Channel(base))),
          ORD(Sound.wrongVoice));
    Check(Sound.WriteCount(), count+17)
  END;
  Sound.MuteAll;
  Check(ORD(Sound.RestartNoise(15)), ORD(Sound.ok));
  Sound.Shutdown;
  Check(Sound.WriteCount(), 116)
END CheckSound;
BEGIN
  CheckSound;
  IsAct(n); Check(n, 0);
  LStop;
  FOR i := 1 TO 1000 DO Exercise END;
  WriteString('FTL bridge PASS'); WriteLn
END FTLTEST.
