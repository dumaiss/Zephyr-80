MODULE ZTRTest;

IMPORT ZTR;

VAR
  result : ZTR.LoadResult;
  title : ARRAY [0..63] OF CHAR;

BEGIN
  result := ZTR.Load('NIGHT.ZTR');
  IF result = ZTR.loadOK THEN
    ZTR.Title(title);
    WRITELN('Title: ', title);
    WRITELN('Bytes: ', ZTR.FileSize());
    WRITELN('Rate: ', ZTR.TickRate(), ' Hz');
    WRITELN('Speed: ', ZTR.Speed());
    WRITELN('Rows: ', ZTR.PatternLength());
    WRITELN('Orders: ', ZTR.OrderCount());
    WRITELN('Patterns: ', ZTR.PatternCount());
    WRITELN('Instruments: ', ZTR.InstrumentCount())
  ELSE
    WRITELN('ZTR load failed: ', ORD(result))
  END
END ZTRTest.
