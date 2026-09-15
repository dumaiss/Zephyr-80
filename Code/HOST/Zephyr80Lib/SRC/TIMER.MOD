IMPLEMENTATION MODULE Timer;

FROM CTCLow IMPORT
  LStart, LStop, IsAct, Pend, Take, Over, Ints;

CONST
  CTCBaseRate = 180;

VAR
  running : BOOLEAN;
  activeValue : CARDINAL;

PROCEDURE Start(rate : Hertz) : Result;
BEGIN
  IF running THEN
    RETURN alreadyActive
  END;
  IF (rate = 0) OR (rate > CTCBaseRate) THEN
    RETURN invalidRate
  END;
  LStart(rate);
  IsAct(activeValue);
  IF activeValue = 0 THEN
    RETURN unavailable
  END;
  running := TRUE;
  RETURN ok
END Start;

PROCEDURE Stop() : Result;
BEGIN
  IF NOT running THEN
    RETURN notActive
  END;
  LStop;
  running := FALSE;
  RETURN ok
END Stop;

PROCEDURE Active() : BOOLEAN;
BEGIN
  RETURN running
END Active;

PROCEDURE Pending() : BOOLEAN;
VAR value : CARDINAL;
BEGIN
  Pend(value);
  RETURN value # 0
END Pending;

PROCEDURE TakeTick() : BOOLEAN;
VAR value : CARDINAL;
BEGIN
  Take(value);
  RETURN value # 0
END TakeTick;

PROCEDURE QueueOverflows() : CARDINAL;
VAR value : CARDINAL;
BEGIN
  Over(value);
  RETURN value
END QueueOverflows;

PROCEDURE Interrupts() : CARDINAL;
VAR value : CARDINAL;
BEGIN
  Ints(value);
  RETURN value
END Interrupts;

BEGIN
  running := FALSE
END Timer.
