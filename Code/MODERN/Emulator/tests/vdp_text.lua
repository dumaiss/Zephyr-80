-- license:BSD-3-Clause
-- VDP observation case. The flash image is DI/HALT, so only this script
-- touches the V9958, through the machine's own I/O handlers (A0h data, A1h
-- control). harness.vdp then reads the V9958's VRAM, registers and rendered
-- bitmap, never a copy of what was written.
local H = harness
local V = H.vdp

local function reg(n, value)
    H.io:write_u8(0xa1, value)
    H.io:write_u8(0xa1, 0x80 | n)
end

local function poke(address, bytes)
    reg(14, (address >> 14) & 7)
    H.io:write_u8(0xa1, address & 0xff)
    H.io:write_u8(0xa1, 0x40 | ((address >> 8) & 0x3f))
    for i = 1, #bytes do H.io:write_u8(0xa0, bytes:byte(i)) end
end

-- Program a name-table mode, clear its names and patterns, then write `text`
-- at (row, column), 0-based. `solid` gets an all-ones pattern.
local function screen(r0, r1, r2, r4, columns, text, row, column, solid)
    reg(0, r0)
    reg(1, r1)
    reg(2, r2)
    reg(4, r4)
    reg(7, 0xf1) -- white on black
    reg(9, 0x00) -- 192 lines
    local names = (r2 & (columns == 80 and 0x7c or 0x7f)) << 10
    poke(names, string.rep(" ", columns * 24))
    poke(r4 << 11, string.rep("\0", 2048))
    if solid then poke((r4 << 11) + solid:byte() * 8, string.rep("\255", 8)) end
    poke(names + row * columns + column, text)
end

-- Count rendered pixels that differ from the backdrop (pixel 0, 0).
local function lit()
    local pixels, width, height = V.pixels()
    local backdrop = pixels:sub(1, 4)
    local count = 0
    for i = 1, width * height * 4, 4 do
        if pixels:sub(i, i + 3) ~= backdrop then count = count + 1 end
    end
    return count
end

local function frames(n)
    local screen_device = H.machine.screens[":screen"]
    local target = screen_device:frame_number() + n
    H.wait(function() return screen_device:frame_number() >= target end, 1, "rendered frames")
end

H.case_body("vdp-text", function()
    local checks = {}

    -- TEXT1, 40 columns: name table 0000h, patterns 0800h.
    screen(0x00, 0x50, 0x00, 0x01, 40, "ZEPHYR-80", 2, 3, "Z")
    H.check(V.mode() == "TEXT1", "mode %s, want TEXT1", V.mode())
    local row, column = V.wait_text("ZEPHYR-80", 1)
    H.check(row == 3 and column == 4, "TEXT1 text at row %d column %d, want 3/4", row, column)
    frames(2)
    local one = lit()
    poke(10 * 40 + 20, "Z")
    frames(2)
    local two = lit()
    H.check(one > 0 and two == 2 * one, "rendered TEXT1 glyph pixels %d then %d, want n then 2n", one, two)
    checks[#checks + 1] = string.format("TEXT1 row 3 col 4, one solid glyph %d px, two %d px", one, two)
    V.snapshot("text1.png")

    -- TEXT2, 80 columns: text past column 40 proves the 80-column layout.
    screen(0x04, 0x50, 0x03, 0x02, 80, "80-COLUMN", 10, 70)
    H.check(V.mode() == "TEXT2", "mode %s, want TEXT2", V.mode())
    row, column = V.wait_text("80-COLUMN", 1)
    H.check(row == 11 and column == 71, "TEXT2 text at row %d column %d, want 11/71", row, column)
    checks[#checks + 1] = "TEXT2 row 11 col 71"

    -- GRAPHIC1, 32 columns, name table 1800h: the last cell of the screen.
    screen(0x00, 0x40, 0x06, 0x00, 32, "G1", 23, 30)
    H.check(V.mode() == "GRAPHIC1", "mode %s, want GRAPHIC1", V.mode())
    row, column = V.wait_text("G1", 1)
    H.check(row == 24 and column == 31, "GRAPHIC1 text at row %d column %d, want 24/31", row, column)
    checks[#checks + 1] = "GRAPHIC1 row 24 col 31"

    -- GRAPHIC6 (the guests' console mode) is a bitmap: no text, a reason.
    reg(0, 0x0a)
    reg(1, 0x40)
    H.check(V.mode() == "GRAPHIC6", "mode %s, want GRAPHIC6", V.mode())
    local rows, reason = V.text()
    H.check(rows == nil and reason and reason:find("unsupported", 1, true), "GRAPHIC6 text was not refused")
    checks[#checks + 1] = "GRAPHIC6 refused (" .. reason .. ")"

    local f = io.open(H.dir .. "/text1.png", "rb")
    H.check(f ~= nil, "no text1.png snapshot")
    local size = f:seek("end")
    f:close()
    H.check(size > 0, "empty text1.png snapshot")
    checks[#checks + 1] = string.format("snapshot text1.png %d bytes", size)
    return table.concat(checks, "; ")
end)
