IMPLEMENTATION MODULE Player;

IMPORT ZTR, PlyCore, Sound;

VAR
  soundOwned, loopingValue, finishedValue, endedValue : BOOLEAN;
  tickRateValue : CARDINAL;

PROCEDURE Stop;
BEGIN
  IF PlyCore.Playing() THEN PlyCore.Stop END;
  (* PlyCore.Stop, including natural completion, has already muted every
     voice.  Dropping ownership here avoids a second 16-write mute burst. *)
  soundOwned := FALSE;
  finishedValue := FALSE;
  endedValue := FALSE
END Stop;

PROCEDURE LoadFailure(value : ZTR.LoadResult) : Result;
BEGIN
  IF value = ZTR.noFileName THEN RETURN noFileName END;
  IF value = ZTR.fileNotFound THEN RETURN fileNotFound END;
  IF value = ZTR.fileTooLarge THEN RETURN fileTooLarge END;
  IF value = ZTR.unsupported THEN RETURN unsupported END;
  RETURN malformed
END LoadFailure;

PROCEDURE Load(name : ARRAY OF CHAR) : Result;
VAR loadResult : ZTR.LoadResult;
BEGIN
  IF soundOwned OR PlyCore.Playing() THEN Stop END;
  tickRateValue := 0;
  finishedValue := FALSE;
  endedValue := FALSE;

  loadResult := ZTR.Load(name);
  IF loadResult # ZTR.loadOK THEN RETURN LoadFailure(loadResult) END;

  tickRateValue := ZTR.TickRate();
  Sound.Init;
  soundOwned := TRUE;
  PlyCore.Start;
  RETURN ok
END Load;

PROCEDURE Tick;
BEGIN
  (* A loop enabled after one-shot completion resumes from the retained ZTR
     on the next application-supplied tick, without another disk read. *)
  IF (NOT PlyCore.Playing()) AND loopingValue AND endedValue THEN
    Sound.Init;
    soundOwned := TRUE;
    PlyCore.Start;
    endedValue := FALSE
  END;
  IF PlyCore.Playing() THEN
    PlyCore.Tick;
    IF NOT PlyCore.Playing() THEN
      finishedValue := TRUE;
      IF loopingValue THEN
        (* Restart now; the first tick of the new pass is still processed by
           the next call, preserving one tracker tick per Tick invocation. *)
        PlyCore.Start;
        endedValue := FALSE
      ELSE
        soundOwned := FALSE;
        endedValue := TRUE
      END
    END
  END;
END Tick;

PROCEDURE Playing() : BOOLEAN;
BEGIN RETURN PlyCore.Playing() END Playing;
PROCEDURE SetLooping(enabled : BOOLEAN);
BEGIN loopingValue := enabled END SetLooping;
PROCEDURE Looping() : BOOLEAN;
BEGIN RETURN loopingValue END Looping;
PROCEDURE Finished() : BOOLEAN;
BEGIN RETURN finishedValue END Finished;
PROCEDURE TakeFinished() : BOOLEAN;
VAR value : BOOLEAN;
BEGIN
  value := finishedValue;
  finishedValue := FALSE;
  RETURN value
END TakeFinished;
PROCEDURE TickRate() : CARDINAL;
BEGIN RETURN tickRateValue END TickRate;
PROCEDURE Title(VAR text : ARRAY OF CHAR);
BEGIN ZTR.Title(text) END Title;
PROCEDURE CurrentOrder() : CARDINAL;
BEGIN RETURN PlyCore.CurrentOrder() END CurrentOrder;
PROCEDURE CurrentRow() : CARDINAL;
BEGIN RETURN PlyCore.CurrentRow() END CurrentRow;
PROCEDURE Minutes() : CARDINAL;
BEGIN RETURN PlyCore.Minutes() END Minutes;
PROCEDURE Seconds() : CARDINAL;
BEGIN RETURN PlyCore.Seconds() END Seconds;
PROCEDURE TakeOrderChange() : BOOLEAN;
BEGIN RETURN PlyCore.TakeOrderChange() END TakeOrderChange;

BEGIN
  soundOwned := FALSE;
  loopingValue := FALSE;
  finishedValue := FALSE;
  endedValue := FALSE;
  tickRateValue := 0
END Player.
