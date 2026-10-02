MODULE BitTest;

(* Does CARDINAL(BITSET(x) * BITSET(mask)) actually compute x AND mask?
   Emits, for each sample: x, x MOD 16, BITSET form, x MOD 4, BITSET form. *)

FROM PortIO IMPORT Out;

VAR x, i : CARDINAL;
    samples : ARRAY [0..5] OF CARDINAL;

BEGIN
  samples[0] := 0;   samples[1] := 1;   samples[2] := 15;
  samples[3] := 16;  samples[4] := 171; samples[5] := 255;
  i := 0;
  WHILE i <= 5 DO
    x := samples[i];
    Out(250, x);
    Out(250, x MOD 16);
    Out(250, CARDINAL(BITSET(x) * BITSET(15)));
    Out(250, x MOD 4);
    Out(250, CARDINAL(BITSET(x) * BITSET(3)));
    INC(i)
  END
END BitTest.
