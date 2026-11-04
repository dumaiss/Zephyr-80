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

-- Bitmap-mode observers (GRAPHIC6, GRAPHIC7), palette, sprites, status ----------------
--
-- The observers read the V9958's VRAM, saved registers and rendered bitmap
-- (harness.lua); the stimuli here are the machine's own port writes, so each
-- observation is compared with what was written and with what MAME drew.
local function palette_entry(index, r, g, b)
    reg(16, index)
    H.io:write_u8(0xa2, (r << 4) | b)
    H.io:write_u8(0xa2, g)
end

local function address(a, write)
    reg(14, (a >> 14) & 7)
    H.io:write_u8(0xa1, a & 0xff)
    H.io:write_u8(0xa1, (write and 0x40 or 0) | ((a >> 8) & 0x3f))
end

local function status_read(n)
    reg(15, n)
    local v = H.io:read_u8(0xa1)
    reg(15, 0)
    return v
end

local function wait_frames(n) frames(n) end

local function first_pixel_box(image, colour, x0, y0, x1, y1)
    local minx, miny, maxx, maxy = 1e9, 1e9, -1, -1
    for y = y0, y1 do
        for x = x0, x1 do
            if image.at(x, y) == colour then
                minx, miny, maxx, maxy = math.min(minx, x), math.min(miny, y), math.max(maxx, x), math.max(maxy, y)
            end
        end
    end
    if maxx < 0 then return nil end
    return { minx, miny, maxx, maxy }
end

local function format_box(b) return b and string.format("%d,%d..%d,%d", b[1], b[2], b[3], b[4]) or "none" end

H.case_body("vdp-bitmap", function()
    local checks = {}

    -- GRAPHIC6: 512x212, sprites off, a cleared page, a palette and corner pixels.
    reg(0, 0x0a) reg(1, 0x40) reg(2, 0x1f) reg(7, 0x06) reg(8, 0x0a) reg(9, 0x80) reg(23, 0)
    palette_entry(0, 0, 0, 0)
    palette_entry(1, 7, 0, 0)
    palette_entry(2, 0, 7, 0)
    palette_entry(3, 0, 0, 7)
    palette_entry(4, 5, 5, 5)
    palette_entry(5, 7, 3, 1)
    palette_entry(6, 7, 7, 0)
    poke(0, string.rep("\68", 256 * 212)) -- colour 4 packed twice
    poke(0 * 256 + 0, "\17")              -- line 0, pixels 0,1 = colour 1
    poke(0 * 256 + 255, "\51")            -- line 0, pixels 510,511 = colour 3
    poke(211 * 256 + 0, "\34")            -- line 211, pixels 0,1 = colour 2
    poke(211 * 256 + 255, "\85")          -- line 211, pixels 510,511 = colour 5
    poke(100 * 256 + 100, "\16")          -- line 100, pixel 200 = 1, pixel 201 = 0
    frames(4)
    local d = V.display()
    H.check(d.mode == "GRAPHIC6" and d.width == 512 and d.lines == 212 and d.base == 0 and d.enabled,
        "display %s %d lines base %X", d.mode, d.lines, d.base)
    H.check(V.pixel(0, 0) == 1 and V.pixel(1, 0) == 1 and V.pixel(2, 0) == 4 and V.pixel(511, 0) == 3 and V.pixel(0, 211) == 2
        and V.pixel(511, 211) == 5 and V.pixel(200, 100) == 1 and V.pixel(201, 100) == 0 and V.pixel(300, 50) == 4,
        "G6 pixel reads")
    local pal = V.palette()
    H.check(pal[1][1] == 7 and pal[1][2] == 0 and pal[1][3] == 0 and pal[3][3] == 7 and pal[4][1] == 5 and pal[5][2] == 3,
        "palette reads: %s", table.concat(pal[5], ","))
    local image = V.image()
    local g = V.geometry()
    H.check(image.w == 544 and image.h == 466, "bitmap %dx%d, want 544x466", image.w, image.h)
    local box1 = first_pixel_box(image, V.palette_rgb(1), 0, 0, image.w - 1, image.h - 1)
    local box3 = first_pixel_box(image, V.palette_rgb(3), 0, 0, image.w - 1, image.h - 1)
    local box5 = first_pixel_box(image, V.palette_rgb(5), 0, 0, image.w - 1, image.h - 1)
    -- Colour 1 is on line 0 (pixels 0,1) and line 100 (pixel 200): the first at the active area's corner.
    H.check(box1 and box1[1] == 16 and box1[2] == 22, "G6 pixel (0,0) rendered at %s, want 16,22", format_box(box1))
    H.check(box3 and box3[3] == 527 and box3[2] == 22 and box3[4] == 23, "G6 pixel 511,0 rendered at %s, want ..527 rows 22..23", format_box(box3))
    H.check(box5 and box5[3] == 527 and box5[4] == 445, "G6 pixel 511,211 rendered at %s, want ..527,445", format_box(box5))
    local compared, bad, skipped, first = V.render_check(0, 212)
    H.check(compared == 512 * 212 and bad == 0, "G6 render check: %s compared, %s bad, first %s", tostring(compared), tostring(bad), tostring(first))
    checks[#checks + 1] = string.format("G6 %d px compared with 0 mismatches, corners at 16,22 and 527,445", compared)
    -- A 192-line screen moves the active area down by 20 bitmap rows.
    reg(9, 0x00)
    frames(3)
    g = V.geometry()
    image = V.image()
    local box_c1 = first_pixel_box(image, V.palette_rgb(1), 0, 0, image.w - 1, image.h - 1)
    H.check(g.y0 == 42 and box_c1 and box_c1[2] == 42, "192 lines: active area at row %s, geometry %d", box_c1 and box_c1[2], g.y0)
    compared, bad = V.render_check(0, 192)
    H.check(bad == 0 and compared == 512 * 192, "192-line render check %s/%s", tostring(bad), tostring(compared))
    reg(9, 0x80)
    -- Vertical scroll: R#23 = 3 shows line 3 at the top; the corner pixel moves off the screen top.
    reg(23, 3)
    frames(3)
    H.check(V.pixel(0, 0) == 4, "scroll 3: screen line 0 shows VRAM line 3 (colour %s)", tostring(V.pixel(0, 0)))
    compared, bad = V.render_check(0, 212)
    H.check(bad == 0, "scrolled render check: %d bad", bad)
    -- The line past the end wraps (the circular surface): the last line shown, y 208, is VRAM line 211.
    H.check(V.pixel(0, 208) == 2, "scroll 3: screen line 208 shows VRAM line 211 (colour %s)", tostring(V.pixel(0, 208)))
    checks[#checks + 1] = "192-line geometry (row 42), R#23 scroll mapped and rendered"
    reg(23, 0)

    -- Page 1 (R#2 bit 5): VRAM 10000h-1FFFFh logical, shown in place of page 0.
    poke(0x10000, string.rep("\34", 256 * 212)) -- colour 2
    reg(2, 0x3f)
    frames(3)
    d = V.display()
    H.check(d.page == 1 and d.base == 0x10000 and V.pixel(10, 10) == 2, "page 1: base %X pixel %s", d.base, tostring(V.pixel(10, 10)))
    compared, bad = V.render_check(0, 212)
    H.check(bad == 0, "page 1 render check: %d bad", bad)
    reg(2, 0x1f)
    frames(2)
    checks[#checks + 1] = "page 1 via R#2 bit 5 (logical 10000h, the A16 boundary) shown and rendered"

    -- Sprites in sprite mode 2: SAT at 1F200h (R#5 E4, R#11 03), patterns 1F800h (R#6 3F), colours 1F000h.
    reg(5, 0xe4) reg(11, 0x03) reg(6, 0x3f) reg(8, 0x08) reg(1, 0x40)
    poke(0x1f800, "\255\255\255\255\255\255\255\255")        -- pattern 0: a solid 8x8
    poke(0x1f000, string.rep("\11", 16))                      -- sprite 0 colour 11, all lines
    poke(0x1f200, string.char(60, 40, 0, 0) .. string.char(0xd8))
    frames(3)
    local sprites = V.sprites()
    H.check(#sprites == 1 and sprites[1].y == 60 and sprites[1].x == 40 and sprites[1].colour == 11 and sprites[1].pattern == 0,
        "SAT decode: %d sprites", #sprites)
    image = V.image()
    local yellow = V.palette_rgb(11)
    local box = first_pixel_box(image, yellow, 0, 0, image.w - 1, image.h - 1)
    -- Sprite x 40 = hi-res pixel 80 (each sprite dot is two hi-res pixels wide); Y 60 shows from line 61.
    H.check(box and box[1] == 16 + 80 and box[2] == 22 + 2 * 61 and box[3] == 16 + 80 + 15 and box[4] == 22 + 2 * (61 + 7) + 1,
        "sprite rendered at %s, want %d,%d..%d,%d", format_box(box), 96, 144, 111, 159)
    compared, bad, skipped = V.render_check(0, 212)
    H.check(bad == 0 and skipped == 16 * 8, "render check around the sprite: %d bad, %d skipped (want 128)", bad, skipped)
    local s0 = V.status(0)
    reg(8, 0x0a) -- sprites disabled: R#8 bit 1
    frames(3)
    image = V.image()
    H.check(first_pixel_box(image, yellow, 0, 0, image.w - 1, image.h - 1) == nil, "a disabled sprite is still drawn")
    reg(8, 0x08)
    frames(2)
    checks[#checks + 1] = "sprite mode 2 SAT decoded; the sprite rendered at 96,144 (2x hi-res width), gone with R#8 SPD"

    -- Status registers: the observer reads the saved registers only.  F (S#0 bit 7) is
    -- set every frame; any number of observer reads leave it for the guest's first read.
    frames(2)
    local flag = V.status(0) & 0x80
    for _ = 1, 50 do V.status(0) V.status(2) V.pixels() V.display() V.sprites() end
    H.check(flag ~= 0 and (V.status(0) & 0x80) ~= 0, "the frame flag was not set to observe")
    local first = status_read(0)
    H.check((first & 0x80) ~= 0, "the observer cleared F: the guest's first S#0 read is %02X", first)
    -- The guest's read cleared the saved F until the next frame flag.
    H.check((V.status(0) & 0x80) == 0, "the guest's S#0 read left F set in the chip")
    checks[#checks + 1] = string.format("observers left F set for the guest's first S#0 read (%02X)", first)

    -- Observing changes nothing: with a command byte, a palette byte and a read-ahead pending, every observer
    -- (and a snapshot) runs, and the chip's saved latch state is as it was.
    local state_items = { "m_cmd_write_first", "m_pal_write_first", "m_address_latch", "m_read_ahead", "m_pal_write", "m_cmd_write", "m_int_state" }
    local items = {}
    for _, name in ipairs(state_items) do items[name] = emu.item(H.machine.devices[":vdp"].items["0/" .. name]) end
    local function latch_state()
        local out = {}
        for _, name in ipairs(state_items) do out[#out + 1] = string.format("%s=%d", name, items[name]:read(0)) end
        for i = 0, 9 do out[#out + 1] = string.format("S%d=%02X", i, V.status(i)) end
        for i = 0, 46 do out[#out + 1] = string.format("R%d=%02X", i, V.reg(i)) end
        return table.concat(out, " ")
    end
    reg(0, 0x0a)
    address(0x00040, false)
    local first = H.io:read_u8(0xa0)           -- a read-ahead is loaded
    H.io:write_u8(0xa1, 0x12)                   -- the first byte of a control pair
    H.io:write_u8(0xa2, 0x34)                   -- the first byte of a palette pair
    local pending = latch_state()
    for _ = 1, 3 do
        V.display() V.palette() V.sprites() V.pixels() V.pixel(3, 3) V.histogram(0, 0, 16, 16) V.render_check(0, 4) V.bytes(0, 64)
        for i = 0, 9 do V.status(i) end
        V.snapshot("observed.png")
    end
    H.check(latch_state() == pending, "observers changed the chip's state:\n%s\n%s", pending, latch_state())
    H.io:write_u8(0xa1, 0x8c)                   -- completes R#12 = 12h
    H.io:write_u8(0xa2, 0x05)                   -- completes palette entry R#16 = 5's pair
    H.check(V.reg(12) == 0x12, "the control pair pending across the observers did not complete (R#12 %02X)", V.reg(12))
    -- Control: a status read on the port does change that state (the pending first byte is dropped, F cleared).
    reg(15, 0)
    H.io:write_u8(0xa1, 0x12)
    local with_pending = latch_state()
    H.io:read_u8(0xa1)
    H.check(latch_state() ~= with_pending, "a port status read left the latch state alone")
    checks[#checks + 1] = "observers and a snapshot left the command, palette and read-ahead latches and every status and control register as they were (a port status read does not)"

    -- GRAPHIC7: one byte per pixel, the fixed GRB palette.
    reg(0, 0x0e) reg(1, 0x40) reg(2, 0x1f) reg(8, 0x0a) reg(9, 0x80)
    poke(0, string.rep("\28", 256 * 212)) -- 1Ch: G 0, R 7, B 0
    poke(0, "\255")                       -- pixel 0,0 white
    poke(211 * 256 + 255, "\3")           -- the last pixel: blue 3 (B level 7)
    frames(4)
    d = V.display()
    H.check(d.mode == "GRAPHIC7" and d.width == 256 and V.pixel(0, 0) == 255 and V.pixel(255, 211) == 3 and V.pixel(5, 5) == 0x1c,
        "G7 pixel reads %s", tostring(V.pixel(5, 5)))
    compared, bad, _, first = V.render_check(0, 212)
    H.check(compared == 256 * 212 and bad == 0, "G7 render check %s compared %s bad %s", tostring(compared), tostring(bad), tostring(first))
    image = V.image()
    H.check(V.rendered(image, 5, 5) == 0xffff0000 or V.rendered(image, 5, 5) == V.g7_rgb(0x1c), "G7 colour 1Ch rendered")
    H.check(V.rendered(image, 255, 211) == 0xff0000ff, "G7 byte 3 rendered %08X", V.rendered(image, 255, 211))
    -- Negative control: a pixel written now is not yet drawn, so the check must see it.
    poke(100 * 256 + 100, "\200")
    local _, stale = V.render_check(100, 101)
    H.check(stale == 1, "the render check missed an undrawn pixel (%s mismatches)", tostring(stale))
    checks[#checks + 1] = string.format("G7 %d px compared, 0 mismatches (1Ch %08X), a stale pixel detected", compared, V.g7_rgb(0x1c))
    V.snapshot("g7.png")
    return table.concat(checks, "; ")
end)
