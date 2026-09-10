MODULE TimTest;

FROM Timer IMPORT Result, Start, Stop, TakeTick,
  QueueOverflows, Interrupts;

VAR
  result : Result;
  ticks : CARDINAL;

BEGIN
  WRITELN('Timer: 600 ticks at 60 Hz');
  result := Start(60);
  IF result = ok THEN
    ticks := 0;
    WHILE ticks < 600 DO
      IF TakeTick() THEN
        INC(ticks)
      END
    END;
    result := Stop();
    WRITELN('Ticks: ', ticks);
    WRITELN('CTC interrupts: ', Interrupts());
    WRITELN('Queue overflows: ', QueueOverflows())
  ELSE
    WRITELN('Timer start failed: ', ORD(result))
  END
END TimTest.
