# VDrip Turbo Pascal 3 API — Proposed Design

Proposed Pascal 3 API for the Zephyr-80 VDrip/TMS9928A display subsystem, derived from
the `video_smiley.asm` CP/M demo.  All VDP traffic is routed through the `VIDEO_SEND`
extended BIOS call; this API wraps that interface at three levels: packet primitives,
VDP register/address helpers, and higher-level tile/sprite operations.

---

## Constants

```pascal
const
  { VRAM table base addresses — Graphics I mode }
  VDP_PATTERN_TABLE   = $0000;
  VDP_SPRITE_PATTERNS = $1800;
  VDP_COLOR_TABLE     = $2000;
  VDP_NAME_TABLE      = $3800;
  VDP_SPRITE_ATTRS    = $3B00;

  { TMS9928A color indices }
  VDP_TRANSPARENT = 0;   VDP_BLACK   = 1;   VDP_MGREEN  = 2;
  VDP_LGREEN      = 3;   VDP_DBLUE   = 4;   VDP_LBLUE   = 5;
  VDP_DRED        = 6;   VDP_CYAN    = 7;   VDP_MRED    = 8;
  VDP_LRED        = 9;   VDP_DYELLOW = 10;  VDP_LYELLOW = 11;
  VDP_DGREEN      = 12;  VDP_MAGENTA = 13;  VDP_GREY    = 14;
  VDP_WHITE       = 15;
```

---

## Types

```pascal
type
  TilePattern   = array[0..7] of Byte;   { 8x8 tile, 1 bit/pixel }
  SpritePattern = array[0..7] of Byte;   { 8x8 sprite, 1 bit/pixel }
  SpriteAttr    = record
    Y, X, Pattern, Color : Byte;
  end;
```

---

## Low-level VIDEO_SEND wrappers

These map 1:1 onto the VDrip packet types used by `video_smiley.asm`.

```pascal
procedure VdpReset;
{ Sends VIDEO_SEND with A=00h -- resets to BIOS text console mode. }

procedure VdpPing;
{ Sends a PACKET_PING -- verifies the VDrip subsystem is alive. }

procedure VdpFrameMark;
{ Sends PACKET_FRAME_MARK -- commits a rendered frame to the display. }

procedure VdpCtrlWrite(Value : Byte);
{ Sends one VDP control/register-select byte (PACKET_VDP_CTRL_WRITE). }

procedure VdpDataWrite(Value : Byte);
{ Sends one VDP data byte (PACKET_VDP_DATA_WRITE). }

procedure VdpDataBlock(var Data : Byte; Count : Integer);
{ Sends Count bytes starting at Data as a bulk PACKET_VDP_DATA_BLOCK.
  Pass the first element of an array or the first field of a record. }
```

---

## VDP register / address helpers

```pascal
procedure VdpWriteRegister(Reg, Value : Byte);
{ Writes Value to TMS9928A register Reg.
  Sends Value then (Reg or $80) as two control bytes. }

procedure VdpSetWriteAddress(Addr : Integer);
{ Arms the VDP VRAM write pointer at address Addr.
  Sends Lo(Addr) then ((Hi(Addr) and $3F) or $40) as two control bytes. }
```

---

## Mode initialization

```pascal
procedure VdpInitGraphics1;
{ Sets all 8 VDP registers for 16 KB Graphics I mode, display on, 8x8 sprites. }

procedure VdpSetBackdrop(Color : Byte);
{ Changes register 7 to set the border/backdrop color (use VDP_* constants). }
```

---

## Tile / background management

```pascal
procedure VdpLoadTile(TileNum : Byte; var Pat : TilePattern);
{ Writes one 8-byte pattern into the Pattern Table at slot TileNum. }

procedure VdpSetTileColor(Group : Byte; Fg, Bg : Byte);
{ Writes one Color Table entry for the 8-tile group at index Group. }

procedure VdpFillColorTable(Fg, Bg : Byte);
{ Fills all 32 Color Table entries with the same Fg/Bg pair. }

procedure VdpFillNameTable(TileNum : Byte);
{ Fills all 768 Name Table bytes with TileNum -- fast solid background. }

procedure VdpWriteNameTable(var Data : Byte; Count : Integer);
{ Writes Count bytes of raw tile indices starting at Name Table base. }
```

---

## Sprite management

```pascal
procedure VdpLoadSpritePattern(PatNum : Byte; var Pat : SpritePattern);
{ Writes 8 bytes into Sprite Pattern Table slot PatNum. }

procedure VdpSetSprite(SprNum : Byte; var Attr : SpriteAttr);
{ Writes the 4-byte attribute entry for sprite SprNum (Y, X, pattern, color). }

procedure VdpHideSprites(FromSprite : Byte);
{ Writes the $D0 Y-terminator at sprite slot FromSprite -- hides that slot and all after it. }
```

---

## Timing and input

```pascal
procedure FrameDelay;
{ Software delay approximating one frame period.
  Matches the 3 x $FFFF decrement loop in video_smiley.asm. }

function KeyPressed : Boolean;
{ Non-blocking poll via BDOS CONST (function $0B).
  Returns True if a key is waiting; does not consume it. }

function ReadKey : Char;
{ Blocking read via BDOS CONIN (function $01).
  Call only after KeyPressed returns True to avoid stalling the animation loop. }
```

---

## Layer summary

| Layer | Hides |
|---|---|
| `VdpCtrlWrite` / `VdpDataWrite` / `VdpDataBlock` | `VIDEO_SEND` packet types and calling convention |
| `VdpWriteRegister` / `VdpSetWriteAddress` | Two-byte VDP control protocol |
| Tile / sprite helpers | VRAM address arithmetic for each table |
| `VdpInitGraphics1` | Magic register-value sequence for Graphics I mode |
| `KeyPressed` / `ReadKey` | BDOS call numbers and $FF/$00 status convention |

---

## Usage example -- `video_smiley` in Pascal

The following sketch shows how the API composes into the complete smiley sprite demo.
See `video_smiley.asm` for the original Z80 assembly reference.

```pascal
program VideoSmiley;

{ ... constants, types, var Spr : SpriteAttr; Done : Boolean ... }

procedure InitBackground;
var I : Integer;  Blank, Check : TilePattern;  Row, Col, Tile : Byte;
begin
  for I := 0 to 7 do Blank[I] := $00;
  for I := 0 to 7 do
    if Odd(I) then Check[I] := $55 else Check[I] := $AA;
  VdpLoadTile(0, Blank);
  VdpLoadTile(1, Check);
  VdpFillColorTable(VDP_WHITE, VDP_DBLUE);
  VdpSetWriteAddress(VDP_NAME_TABLE);
  Tile := 0;
  for Row := 0 to 23 do
  begin
    for Col := 0 to 31 do begin VdpDataWrite(Tile); Tile := Tile xor 1; end;
    Tile := Tile xor 1;
  end;
end;

procedure InitSpritePatterns;
var Face, Eyes : SpritePattern;
begin
  Face[0]:=$3C; Face[1]:=$7E; Face[2]:=$FF; Face[3]:=$FF;
  Face[4]:=$FF; Face[5]:=$FF; Face[6]:=$7E; Face[7]:=$3C;
  Eyes[0]:=$00; Eyes[1]:=$00; Eyes[2]:=$24; Eyes[3]:=$24;
  Eyes[4]:=$00; Eyes[5]:=$42; Eyes[6]:=$3C; Eyes[7]:=$00;
  VdpLoadSpritePattern(0, Face);
  VdpLoadSpritePattern(1, Eyes);
end;

procedure UpdateSprites;
var FaceAttr, EyesAttr : SpriteAttr;
begin
  FaceAttr.Y:=Spr.Y; FaceAttr.X:=Spr.X; FaceAttr.Pattern:=0; FaceAttr.Color:=Spr.Color;
  EyesAttr.Y:=Spr.Y; EyesAttr.X:=Spr.X; EyesAttr.Pattern:=1; EyesAttr.Color:=VDP_DBLUE;
  VdpSetSprite(0, FaceAttr);
  VdpSetSprite(1, EyesAttr);
  VdpHideSprites(2);
end;

begin
  VdpReset;  VdpPing;  VdpInitGraphics1;
  InitBackground;  InitSpritePatterns;
  Spr.X := 0;  Spr.Y := $58;  Spr.Color := VDP_LGREEN;
  UpdateSprites;  VdpFrameMark;
  Done := False;
  repeat
    UpdateSprites;  VdpFrameMark;  FrameDelay;
    Spr.X := Spr.X + 4;
    if Spr.X >= $F8 then Spr.X := 0;
    if KeyPressed then Done := (ReadKey = #27);
  until Done;
  VdpReset;
end.
```
