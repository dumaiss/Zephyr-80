MODULE CallTest;

(* Micro-benchmark: what does an FTL procedure call cost?

   Three loops of identical trip count, bracketed by marker writes:
     1  empty loop            -- loop overhead alone
     2  call, no parameters
     3  call, one VAR record parameter  (how PlyCore passes a channel)

   The differences give the per-call cost, which decides whether the replay
   core is slow because of its logic or because of how often it calls. *)

FROM PortIO IMPORT Out;

CONST
  Mark = 253;
  Trips = 2000;

TYPE
  Big = RECORD a, b, c, d, e, f, g, h : CARDINAL END;          (* 16 bytes *)
  Odd = RECORD pad : ARRAY [0..84] OF CHAR END;                (* 85 bytes *)
  Pow = RECORD pad : ARRAY [0..127] OF CHAR END;               (* 128 bytes *)

VAR
  i, sink : CARDINAL;
  block : ARRAY [0..15] OF Big;
  odd : ARRAY [0..15] OF Odd;
  pow : ARRAY [0..15] OF Pow;

PROCEDURE Nothing;
BEGIN
END Nothing;

PROCEDURE WithVar(VAR item : Big);
BEGIN
END WithVar;

PROCEDURE WithOdd(VAR item : Odd);
BEGIN
END WithOdd;

PROCEDURE WithPow(VAR item : Pow);
BEGIN
END WithPow;

BEGIN
  sink := 0;

  Out(Mark, 1);
  i := 0;
  WHILE i < Trips DO INC(i) END;

  Out(Mark, 2);
  i := 0;
  WHILE i < Trips DO Nothing; INC(i) END;

  Out(Mark, 3);
  i := 0;
  WHILE i < Trips DO WithVar(block[sink]); INC(i) END;

  Out(Mark, 4);
  i := 0;
  WHILE i < Trips DO WithOdd(odd[sink]); INC(i) END;

  Out(Mark, 5);
  i := 0;
  WHILE i < Trips DO WithPow(pow[sink]); INC(i) END;

  Out(Mark, 6);
  i := 0;
  WHILE i < Trips DO sink := i + i; INC(i) END;

  Out(Mark, 7);
  i := 0;
  WHILE i < Trips DO sink := i * 256; INC(i) END;

  Out(Mark, 8);
  i := 0;
  WHILE i < Trips DO sink := i * 3; INC(i) END;

  Out(Mark, 9);
  i := 0;
  WHILE i < Trips DO sink := i DIV 16; INC(i) END;

  Out(Mark, 10);
  i := 0;
  WHILE i < Trips DO sink := i MOD 16; INC(i) END;

  Out(Mark, 11);
  i := 0;
  WHILE i < Trips DO sink := CARDINAL(BITSET(i) * BITSET(15)); INC(i) END;

  Out(Mark, 12);
  i := 0;
  WHILE i < Trips DO sink := i DIV 2; INC(i) END;

  Out(Mark, 13);
  i := 0;
  WHILE i < Trips DO sink := i DIV 2 DIV 2 DIV 2 DIV 2; INC(i) END;

  Out(Mark, 0)
END CallTest.
