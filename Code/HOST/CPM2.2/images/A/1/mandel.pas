program Mandelbrot;

const
  W       = 64;
  H       = 24;
  MaxIter = 24;

var
  PX, PY  : Integer;
  I, C    : Integer;
  X, Y    : Real;
  XX      : Real;
  CX, CY  : Real;
  Escaped : Boolean;

function Shade(C : Integer) : Char;
begin
  case C of
    1: Shade := ' ';
    2: Shade := '.';
    3: Shade := ':';
    4: Shade := '-';
    5: Shade := '=';
    6: Shade := '+';
    7: Shade := '*';
    8: Shade := '#';
    9: Shade := '%';
  else
    Shade := '@';
  end;
end;

begin
  Writeln;
  Writeln('TURBO PASCAL ASCII MANDELBROT TEST');
  Writeln;

  for PY := 0 to H - 1 do
  begin
    CY := -1.2 + PY * 2.4 / (H - 1);

    for PX := 0 to W - 1 do
    begin
      CX := -2.1 + PX * 3.2 / (W - 1);

      X := 0.0;
      Y := 0.0;
      I := 0;
      Escaped := False;

      repeat
        XX := X * X - Y * Y + CX;
         Y := 2.0 * X * Y + CY;
         X := XX;
         I := I + 1;

        if (X > 2.0) or (X < -2.0) or
           (Y > 2.0) or (Y < -2.0) or
           (X * X + Y * Y > 4.0) then
          Escaped := True;

      until Escaped or (I = MaxIter);

      if I = MaxIter then
        Write('@')
      else
      begin
        C := Trunc(I * 9.0 / MaxIter) + 1;
        if C < 1 then C := 1;
        if C > 10 then C := 10;
        Write(Shade(C));
      end;
    end;

    Writeln;
  end;

  Writeln;
  Writeln('DONE');
end.