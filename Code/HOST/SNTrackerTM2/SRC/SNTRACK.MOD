MODULE SNTrack;

(* FTL Modula-2.  Three things differ from the Turbo Modula-2 original:

   - SYSTEM has no BDOS and no IORESULT.  FTL's BDOS lives in CPM and returns
     the A register as its result, so IORESULT folds into the call.
   - There is no ComLine.  Command publishes the CP/M command tail as absolute
     variables at 80h and 81h, which is what READ(commandLine, ...) reached.
     RedirectInput and RedirectOutput have no counterpart and are dropped; if
     redirection is wanted back, InOut exports SwitchInStream/SwitchOutStream.
   - WRITELN with mixed arguments is a TM2 extension.  FTL wants explicit
     InOut calls. *)

FROM CPM IMPORT BDOS;
FROM SYSTEM IMPORT WORD;
FROM Command IMPORT CommLength, CommText;
(* Console output goes straight to the BDOS.  InOut is convenient but it
   imports Streams, which imports Files and Storage, and with Terminal and
   Conversi behind it that chain measured 11,492 bytes in the link map -- more
   than twice the size of the whole assembly player this replaces.  A library
   and its harness have to leave the TPA to the application. *)
IMPORT Player, Timer;

CONST
  ConStatus = 11;
  ConInput = 1;
  ConOutput = 2;

VAR
  ignored : WORD;

PROCEDURE Write(ch : CHAR);
BEGIN
  ignored := BDOS(ConOutput, WORD(ORD(ch)))
END Write;

PROCEDURE WriteString(text : ARRAY OF CHAR);
VAR i : CARDINAL;
BEGIN
  i := 0;
  WHILE (i <= HIGH(text)) AND (text[i] # CHR(0)) DO
    Write(text[i]);
    INC(i)
  END
END WriteString;

PROCEDURE WriteLn;
BEGIN
  Write(CHR(13));
  Write(CHR(10))
END WriteLn;

(* Decimal, right-aligned in `width` columns, no leading zeroes. *)
PROCEDURE WriteCard(value, width : CARDINAL);
VAR digits : ARRAY [0..5] OF CHAR;
    count, i : CARDINAL;
BEGIN
  count := 0;
  REPEAT
    digits[count] := CHR(ORD('0') + value MOD 10);
    value := value DIV 10;
    INC(count)
  UNTIL (value = 0) OR (count > 5);
  i := count;
  WHILE i < width DO
    Write(' ');
    INC(i)
  END;
  WHILE count > 0 DO
    DEC(count);
    Write(digits[count])
  END
END WriteCard;

VAR
  fileName : ARRAY [0..20] OF CHAR;
  loadResult : Player.Result;
  timerResult, stopResult : Timer.Result;
  keyTicks, idleSpins, key : CARDINAL;
  uiPending : BOOLEAN;
  uiWaited : CARDINAL;

(* First blank-delimited token of the command tail. *)
PROCEDURE TakeFileName;
VAR i, n, out : CARDINAL;
BEGIN
  fileName[0] := CHR(0);
  n := ORD(CommLength);
  IF n > 126 THEN n := 126 END;
  i := 0;
  WHILE (i < n) AND (CommText[i] = ' ') DO INC(i) END;
  out := 0;
  WHILE (i < n) AND (CommText[i] <> ' ') AND (out < HIGH(fileName)) DO
    fileName[out] := CommText[i];
    INC(out);
    INC(i)
  END;
  fileName[out] := CHR(0)
END TakeFileName;

PROCEDURE PollKey;
BEGIN
  IF BDOS(ConStatus, 0) = 0 THEN RETURN END;
  key := BDOS(ConInput, 0);
  IF (key = ORD('q')) OR (key = ORD('Q')) OR (key = 27) THEN
    Player.Stop
  END
END PollKey;

PROCEDURE InitUI;
VAR title : ARRAY [0..63] OF CHAR;
BEGIN
  Player.Title(title);
  WriteString('Playing: '); WriteString(title); WriteLn;
  WriteString('Q/Esc: stop; one update per pattern block'); WriteLn
END InitUI;

(* Console output is the most expensive thing this program does -- roughly
   forty characters through InOut/Streams/Files/BDOS into the VDP, plus a
   decimal conversion per number -- and it used to happen inside the tick
   branch, at exactly the moment a tick was due.  That is why playback stalled
   on every order change.

   ServiceUI now only records that a line is owed.  FlushUI emits it, and only
   when the tick queue is empty, so the write never competes with a tick. *)
PROCEDURE ServiceUI;
BEGIN
  IF Player.TakeOrderChange() THEN
    uiPending := TRUE;
    uiWaited := 0
  ELSIF uiPending THEN
    INC(uiWaited)
  END
END ServiceUI;

PROCEDURE FlushUI;
BEGIN
  (* Normally the line waits for an empty queue.  On a song dense enough that
     the queue never empties, that would mean it never appears at all, so a
     line owed for a second is written anyway -- the resync below pays for it. *)
  IF uiPending AND (NOT Timer.Pending() OR (uiWaited >= Player.TickRate())) THEN
    uiPending := FALSE;
    uiWaited := 0;
    (* Carriage return, NOT WriteLn.  A newline on the bottom line of a full
       screen makes the console scroll, which on the V9958 means moving the
       whole text grid through the VDP -- far longer than a tick period, and it
       happens on every order change once the screen has filled.  Returning to
       column zero and overwriting costs nothing and never scrolls.  The
       trailing blanks erase a wider number from a previous order. *)
    WriteString('Order ');
    WriteCard(Player.CurrentOrder(), 1);
    WriteString('    ');
    Write(CHR(13))
    (* No resync here.  An earlier version discarded whatever queued during the
       write, on the assumption that playback could never catch up.  That is
       audible: dropped ticks make the music jump, so it alternates fast and
       slow.  Now that a tick fits inside its period the backlog drains on its
       own, and every tick gets played. *)
  END
END FlushUI;

BEGIN
  TakeFileName;
  IF fileName[0] = CHR(0) THEN
    WriteString('Usage: SNTRACK file.ZTR'); WriteLn
  ELSE
    Player.SetLooping(FALSE);
    loadResult := Player.Load(fileName);
    IF loadResult <> Player.ok THEN
      WriteString('Cannot load ZTR file; error ');
      WriteCard(ORD(loadResult), 1); WriteLn
    ELSE
      timerResult := Timer.Start(Player.TickRate());
      IF timerResult <> Timer.ok THEN
        Player.Stop;
        WriteString('Timer start failed; error ');
        WriteCard(ORD(timerResult), 1); WriteLn
      ELSE
        InitUI;
        uiPending := FALSE;
        uiWaited := 0;
        (* The banner above is console output too; drop the ticks it cost. *)
        WHILE Timer.TakeTick() DO END;
        keyTicks := Player.TickRate();
        idleSpins := 0;
        WHILE Player.Playing() DO
          IF Timer.TakeTick() THEN
            idleSpins := 0;
            Player.Tick;
            ServiceUI;
            FlushUI;
            IF keyTicks <= 1 THEN
              PollKey;
              keyTicks := Player.TickRate()
            ELSE
              DEC(keyTicks)
            END
          ELSE
            FlushUI;
            (* Keep abort input reachable if logical ticks stop.  The large
               foreground divider keeps CONST/CONIN well below 10 Hz. *)
            IF idleSpins = 65535 THEN
              idleSpins := 0;
              PollKey
            ELSE
              INC(idleSpins)
            END
          END
        END;
        stopResult := Timer.Stop();
        Player.Stop
      END;
      WriteLn;
      WriteString('Playback stopped; queue overflows ');
      WriteCard(Timer.QueueOverflows(), 1);
      WriteLn
    END
  END
END SNTrack.
