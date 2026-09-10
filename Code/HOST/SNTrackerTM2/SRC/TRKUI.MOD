IMPLEMENTATION MODULE TrkUI;

FROM SYSTEM IMPORT BDOS;
IMPORT ZTR, Player, Timer;

PROCEDURE PutChar(ch : CHAR);
BEGIN
  BDOS(2, ORD(ch))
END PutChar;

PROCEDURE PutString(text : ARRAY OF CHAR);
VAR pos : CARDINAL;
BEGIN
  pos := 0;
  WHILE (pos <= HIGH(text)) AND (text[pos] # CHR(0)) DO
    PutChar(text[pos]);
    INC(pos)
  END
END PutString;

PROCEDURE PutHex4(value : CARDINAL);
BEGIN
  value := value MOD 16;
  IF value < 10 THEN PutChar(CHR(ORD('0') + value))
  ELSE PutChar(CHR(ORD('A') + value - 10))
  END
END PutHex4;

PROCEDURE PutHex8(value : CARDINAL);
BEGIN
  PutHex4(value DIV 16);
  PutHex4(value)
END PutHex8;

PROCEDURE PutHex16(value : CARDINAL);
BEGIN
  PutHex8(value DIV 256);
  PutHex8(value)
END PutHex16;

PROCEDURE PutDec2(value : CARDINAL);
BEGIN
  PutChar(CHR(ORD('0') + (value DIV 10) MOD 10));
  PutChar(CHR(ORD('0') + value MOD 10))
END PutDec2;

PROCEDURE Init;
VAR title : ARRAY [0..63] OF CHAR;
BEGIN
  ZTR.Title(title);
  PutString('Playing: ');
  PutString(title);
  PutChar(CHR(13));
  PutChar(CHR(10));
  PutString('Q/Esc: stop; one update per pattern block');
  PutChar(CHR(13));
  PutChar(CHR(10));
  Service
END Init;

PROCEDURE Service;
BEGIN
  IF NOT Player.TakeOrderChange() THEN RETURN END;
  PutChar(CHR(13));
  PutChar('O');
  PutHex8(Player.CurrentOrder());
  PutString(' T');
  PutDec2(Player.Minutes());
  PutChar(':');
  PutDec2(Player.Seconds());
  PutString(' Q');
  PutHex16(Timer.QueueOverflows());
  PutString('   ')
END Service;

END TrkUI.
