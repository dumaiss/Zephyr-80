MODULE SndTest;

FROM Sound IMPORT
  Channel, TonePeriod, Volume, Result,
  NoiseMode, NoiseRate,
  Init, Shutdown, SetTone, SetVolume, SetNoise, WriteCount;

VAR
  chip, base : CARDINAL;
  result : Result;
  key : CHAR;

BEGIN
  WRITELN('Afternoon Blend TM2 sound test');
  Init;
  FOR chip := 0 TO 3 DO
    base := chip * 4;
    result := SetTone(Channel(base), TonePeriod(448));
    IF result = ok THEN
      SetVolume(Channel(base), Volume(12))
    END;
    result := SetTone(Channel(base + 2), TonePeriod(224));
    IF result = ok THEN
      SetVolume(Channel(base + 2), Volume(8))
    END;
    result := SetNoise(Channel(base + 3), whiteNoise, highRate);
    IF result = ok THEN
      SetVolume(Channel(base + 3), Volume(6))
    END;
    WRITELN('PSG ', chip, ' active; press Return');
    READLN(key);
    SetVolume(Channel(base), Volume(0));
    SetVolume(Channel(base + 2), Volume(0));
    SetVolume(Channel(base + 3), Volume(0))
  END;
  Shutdown;
  WRITELN('PSG writes: ', WriteCount())
END SndTest.
