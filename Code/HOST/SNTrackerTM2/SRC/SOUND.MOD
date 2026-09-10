IMPLEMENTATION MODULE Sound;

FROM SYSTEM IMPORT OUT;

CONST
  PSG0Port = 224;                 (* E0h *)

VAR
  writes : CARDINAL;
  lastNoise : ARRAY [0..3] OF CARDINAL;
  noiseValid : ARRAY [0..3] OF BOOLEAN;

PROCEDURE Put(port, value : CARDINAL);
VAR wait : CARDINAL;
BEGIN
  OUT(port, value);
  INC(writes);
  (* Retain the assembly player's conservative settling delay.  Afternoon
     Blend's hardware WAIT remains the actual bus contract. *)
  FOR wait := 1 TO 38 DO END
END Put;

PROCEDURE Init;
VAR chip : CARDINAL;
BEGIN
  writes := 0;
  FOR chip := 0 TO 3 DO
    noiseValid[chip] := FALSE
  END;
  MuteAll
END Init;

PROCEDURE Shutdown;
BEGIN
  MuteAll
END Shutdown;

PROCEDURE MuteAll;
VAR chip, voice : CARDINAL;
BEGIN
  FOR chip := 0 TO 3 DO
    FOR voice := 0 TO 3 DO
      Put(PSG0Port + chip, 144 + voice * 32 + 15)
    END;
    noiseValid[chip] := FALSE
  END
END MuteAll;

PROCEDURE SetTone(channel : Channel; period : TonePeriod) : Result;
VAR chip, voice : CARDINAL;
BEGIN
  chip := channel DIV 4;
  voice := channel MOD 4;
  IF voice = 3 THEN
    RETURN wrongVoice
  END;
  Put(PSG0Port + chip,
      128 + voice * 32 + (period MOD 16));
  Put(PSG0Port + chip, (period DIV 16) MOD 64);
  RETURN ok
END SetTone;

PROCEDURE SetVolume(channel : Channel; volume : Volume);
VAR chip, voice : CARDINAL;
BEGIN
  chip := channel DIV 4;
  voice := channel MOD 4;
  Put(PSG0Port + chip,
      144 + voice * 32 + (15 - volume))
END SetVolume;

PROCEDURE SetNoise(channel : Channel;
                   mode : NoiseMode;
                   rate : NoiseRate) : Result;
VAR chip, voice, control : CARDINAL;
BEGIN
  chip := channel DIV 4;
  voice := channel MOD 4;
  IF voice # 3 THEN
    RETURN wrongVoice
  END;
  control := ORD(rate);
  IF mode = whiteNoise THEN
    control := control + 4
  END;
  Put(PSG0Port + chip, 224 + control);
  lastNoise[chip] := control;
  noiseValid[chip] := TRUE;
  RETURN ok
END SetNoise;

PROCEDURE RestartNoise(channel : Channel) : Result;
VAR chip : CARDINAL;
BEGIN
  IF (channel MOD 4) # 3 THEN
    RETURN wrongVoice
  END;
  chip := channel DIV 4;
  IF noiseValid[chip] THEN
    Put(PSG0Port + chip, 224 + lastNoise[chip])
  END;
  RETURN ok
END RestartNoise;

PROCEDURE WriteCount() : CARDINAL;
BEGIN
  RETURN writes
END WriteCount;

BEGIN
  writes := 0
END Sound.
