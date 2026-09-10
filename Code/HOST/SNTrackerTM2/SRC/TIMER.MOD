IMPLEMENTATION MODULE Timer;

FROM SYSTEM IMPORT ADR, BYTE;
FROM CTCLow IMPORT
  SetTab, LStart, LStop, Pend, Take, Over, Ints;

CONST
  CTCBaseRate = 180;

VAR
  running : BOOLEAN;
  (* At most 255 bytes are discarded to reach a page boundary.  The
     remaining 257 bytes own the table and the boundary byte fetched by
     vector FFh.  Zephyr CTC and SIO devices supply even vectors. *)
  tableStorage : ARRAY [0..511] OF BYTE;

PROCEDURE Start(rate : Hertz) : Result;
BEGIN
  IF running THEN
    RETURN alreadyActive
  END;
  IF (rate = 0) OR (rate > CTCBaseRate) THEN
    RETURN invalidRate
  END;
  SetTab(ADR(tableStorage));
  LStart(rate);
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
