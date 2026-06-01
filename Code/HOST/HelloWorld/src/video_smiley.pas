program VideoSmiley;

const
  VDP_PATTERN_TABLE   = $0000;
  VDP_SPRITE_PATTERNS = $1800;
  VDP_COLOR_TABLE     = $2000;
  VDP_NAME_TABLE      = $3800;
  VDP_SPRITE_ATTRS    = $3B00;

  VDP_DBLUE  = 4;
  VDP_LGREEN = 3;
  VDP_WHITE  = 15;

  SPRITE_Y_START = $58;
  SPRITE_STEP    = 4;
  SPRITE_WRAP_X  = $F8;

  KEY_ESC = #27;

type
  TilePattern   = array[0..7] of Byte;
  SpritePattern = array[0..7] of Byte;
  SpriteAttr    = record
    Y, X, Pattern, Color : Byte;
  end;

var
  Spr  : SpriteAttr;
  Done : Boolean;

{ ------------------------------------------------------------------ }

procedure InitBackground;
var
  I           : Integer;
  Blank, Check : TilePattern;
  Row, Col    : Byte;
  Tile        : Byte;
begin
  for I := 0 to 7 do Blank[I] := $00;
  for I := 0 to 7 do
    if Odd(I) then Check[I] := $55 else Check[I] := $AA;

  VdpLoadTile(0, Blank);
  VdpLoadTile(1, Check);

  VdpFillColorTable(VDP_WHITE, VDP_DBLUE);

  { Checkerboard name table: flip tile phase each column and each row }
  VdpSetWriteAddress(VDP_NAME_TABLE);
  Tile := 0;
  for Row := 0 to 23 do
  begin
    for Col := 0 to 31 do
    begin
      VdpDataWrite(Tile);
      Tile := Tile xor 1;
    end;
    Tile := Tile xor 1;
  end;
end;

procedure InitSpritePatterns;
var
  Face : SpritePattern;
  Eyes : SpritePattern;
begin
  Face[0] := $3C;  Face[1] := $7E;  Face[2] := $FF;  Face[3] := $FF;
  Face[4] := $FF;  Face[5] := $FF;  Face[6] := $7E;  Face[7] := $3C;

  Eyes[0] := $00;  Eyes[1] := $00;  Eyes[2] := $24;  Eyes[3] := $24;
  Eyes[4] := $00;  Eyes[5] := $42;  Eyes[6] := $3C;  Eyes[7] := $00;

  VdpLoadSpritePattern(0, Face);
  VdpLoadSpritePattern(1, Eyes);
end;

procedure UpdateSprites;
var
  FaceAttr, EyesAttr : SpriteAttr;
begin
  FaceAttr.Y := Spr.Y;  FaceAttr.X := Spr.X;
  FaceAttr.Pattern := 0;  FaceAttr.Color := Spr.Color;

  EyesAttr.Y := Spr.Y;  EyesAttr.X := Spr.X;
  EyesAttr.Pattern := 1;  EyesAttr.Color := VDP_DBLUE;

  VdpSetSprite(0, FaceAttr);
  VdpSetSprite(1, EyesAttr);
  VdpHideSprites(2);
end;

{ ------------------------------------------------------------------ }

begin
  VdpReset;
  VdpPing;
  VdpInitGraphics1;
  InitBackground;
  InitSpritePatterns;

  Spr.X     := 0;
  Spr.Y     := SPRITE_Y_START;
  Spr.Color := VDP_LGREEN;

  UpdateSprites;
  VdpFrameMark;

  Done := False;
  repeat
    UpdateSprites;
    VdpFrameMark;
    FrameDelay;

    Spr.X := Spr.X + SPRITE_STEP;
    if Spr.X >= SPRITE_WRAP_X then Spr.X := 0;

    if KeyPressed then
      Done := (ReadKey = KEY_ESC);
  until Done;

  VdpReset;
end.