-- license:BSD-3-Clause
-- V9958 case bodies for harness.lua (tests/video.py runs them): the consoles of
-- both guests, the real graphics programs and the VDP command engine.
--
--   console-konaos / console-zsdos   the production image's V9958 console driven
--                 by a card file of ANSI text and a long scrolling listing; glyphs,
--                 positions, reverse video, erase, wrap, the sprite cursor, the
--                 circular scroll, the colours the VDP draws and the status port
--                 traffic, read from VRAM, the saved registers and the rendered
--                 bitmap (harness.vdp, harness.vdp.console)
--
-- Every observation reads the chip's saved state or its address space; no
-- port is read by the observers, so nothing the guest can see changes.
local lio = io
local H = harness
local V = H.vdp
local C = V.console
local K = H.keyboard

if os.getenv("HARNESS_FONT") then C.load_font(os.getenv("HARNESS_FONT")) end

local function trimmed(line) return (line:gsub("%s+$", "")) end

local transcript
local shots = 0
local function shot(name)
    shots = shots + 1
    local base = string.format("%02d-%s", shots, name)
    local rows = C.read()
    transcript = transcript or assert(lio.open(H.dir .. "/transcript.txt", "w"))
    transcript:write(string.format("== %s at %.3f emulated s\n", base, H.now()))
    if rows then
        C.dump(base .. ".txt")
        for i, line in ipairs(rows) do
            local shown = trimmed(C.printable(line))
            if shown ~= "" then transcript:write(string.format("%2d %s\n", i, shown)) end
        end
    else
        transcript:write("(not the console: " .. tostring(select(2, C.read())) .. ")\n")
    end
    transcript:flush()
    V.snapshot(base .. ".png")
end

local function seconds(s)
    local until_ = H.now() + s
    H.wait(function() return H.now() >= until_ end, s + 5, "a pause")
end

-- The console text cell the sprite cursor sits on: column and row, 0-based
-- (sprite dots are two hi-res pixels wide, a cell is six hi-res pixels, so
-- x / 3; the row from the display line the SAT Y puts it on).
local function cursor_cell()
    local sprites = V.sprites()
    local s = sprites and sprites[1]
    if not s then return nil end
    local line = ((s.y - V.reg(23)) & 255) + 1
    return (s.x // 3), ((line - C.offset) // 8), s
end

-- Count status-port traffic from the start: every read of the chip's
-- status register (A1 and its mirrors) with the register R#15 selected.
local status_reads, status_by_reg, status_total = nil, {}, 0
local data_reads = 0
local function watch_ports()
    H.keep(H.io:install_read_tap(0xa0, 0xbf, "vdp-status-reads", function(offset, data)
        local port = offset & 3
        if port == 1 then
            local selected = V.reg(15) & 15
            status_by_reg[selected] = (status_by_reg[selected] or 0) + 1
            status_total = status_total + 1
        elseif port == 0 then
            data_reads = data_reads + 1
        end
    end))
end

local vdp_int_item = emu.item(H.machine.devices[":"].items["0/m_vdp_int"])
local function status_report()
    local parts = {}
    for reg = 0, 9 do
        if status_by_reg[reg] then parts[#parts + 1] = string.format("S#%d x%d", reg, status_by_reg[reg]) end
    end
    return table.concat(parts, ", ")
end

-- The text of a console cell run and its reverse map.
local function cells(rows, reverse, row, col, n)
    return rows[row]:sub(col, col + n - 1), reverse[row]:sub(col, col + n - 1)
end

-- Wait for `text` on the screen while a pager (ZephyrShell's `cat`, --More-- on the last row
-- after 24 lines) asks for a key: any key continues it.
local function wait_listing(text, timeout, what)
    local deadline = H.now() + timeout
    while H.now() < deadline do
        local rows = C.read()
        if rows and C.find(text, rows) then return end
        if rows and trimmed(rows[26]) == "--More--" then K.tap("Space") end
        K.frames(2)
    end
    H.fail("no %s within %.0f emulated s", what, timeout)
end

-- The console proof for one guest: the screen the driver draws, read from VRAM
-- (glyphs matched against the guest's own font), checked against the rendered
-- bitmap (what the VDP shows) and the sprite and colour state.
local function console_proof(guest, prompt, show)
    local P = prompt
    local notes = {}
    watch_ports()
    local _, _, t = C.wait(trimmed(P), 40, "the " .. guest .. " prompt")
    seconds(0.5)
    shot("prompt")
    notes[#notes + 1] = string.format("prompt %.3f s", t)

    -- Display set-up as the driver programs it.
    local d = V.display()
    H.check(d.mode == "GRAPHIC6" and d.enabled and d.lines == 212 and d.base == 0 and not d.sprites_off,
        "console display: %s enabled %s lines %d base %X sprites off %s", d.mode, tostring(d.enabled), d.lines, d.base, tostring(d.sprites_off))
    H.check((V.reg(1) & 0x20) == 0, "the console left the VDP interrupt enabled (R#1 %02X)", V.reg(1))
    H.check((V.reg(25) & 0x04) ~= 0, "R#25 WTE clear (R#25 %02X)", V.reg(25))
    local paper, ink, cursor_colour = V.palette_rgb(4), V.palette_rgb(15), V.palette_rgb(11)
    notes[#notes + 1] = string.format("G6 212 lines, R#1 %02X R#8 %02X R#9 %02X R#23 %02X, paper %08X ink %08X cursor %08X",
        V.reg(1), V.reg(8), V.reg(9), V.reg(23), paper, ink, cursor_colour)
    local compared, bad, skipped, first = V.render_check(0, 212)
    H.check(compared and bad == 0, "prompt screen: %s mismatches of %s (%s)", tostring(bad), tostring(compared), tostring(first))
    notes[#notes + 1] = string.format("prompt screen %d px rendered as VRAM says (%d under sprites)", compared, skipped)

    -- The cursor: sprite 0, pattern 0, colour 11, on the cell after the prompt.
    local col, row, s = cursor_cell()
    local rows = C.read()
    local line_row
    for i = #rows, 1, -1 do
        if trimmed(rows[i]):find(trimmed(P), 1, true) == 1 then line_row = i break end
    end
    H.check(line_row and row == line_row - 1 and col == #P, "cursor at col %s row %s, want col %d row %s", tostring(col), tostring(row), #P, tostring(line_row and line_row - 1))
    H.check(s.pattern == 0 and s.colour == 11, "cursor sprite pattern %d colour %d", s.pattern, s.colour)
    local hist = V.histogram(6 * col, C.offset + 8 * row, 6, 8)
    H.check((hist[cursor_colour] or 0) > 0 or (hist[cursor_colour & 0xffffff] or 0) > 0, "no cursor-coloured pixel on the cursor cell")
    notes[#notes + 1] = string.format("cursor sprite 0 at col %d row %d", col, row)

    -- ANSI text through the production console path.
    K.type(show("ANSI.TXT") .. "\r")
    wait_listing("END-OF-ANSI", 30, "the ANSI listing")
    seconds(0.3)
    shot("ansi")
    rows = select(1, C.read())
    local reverse = select(2, C.read())
    local function line_is(r, text) H.check(trimmed(rows[r]) == text, "row %d is %q, want %q", r, trimmed(C.printable(rows[r])), text) end
    -- Glyph rows: every code of the font, ASCII then CP850.  A cell is read back as the first
    -- code sharing its bitmap (printable ASCII first), so the expectation is the font's own.
    local function glyph_row(r, first, last)
        local want, want_rev = {}, {}
        for code = first, last do
            local read, rev = C.as_read(code)
            want[#want + 1] = string.char(read)
            want_rev[#want_rev + 1] = rev
        end
        local n = last - first + 1
        H.check(rows[r]:sub(1, n) == table.concat(want) and reverse[r]:sub(1, n) == table.concat(want_rev),
            "row %d glyphs %02Xh-%02Xh: %q", r, first, last, C.printable(rows[r]))
    end
    glyph_row(1, 0x20, 0x4f)
    glyph_row(2, 0x50, 0x7e)
    glyph_row(3, 0x80, 0xbf)
    glyph_row(4, 0xc0, 0xfc)
    H.check(select(3, C.read()) == 0, "unknown cells on the ANSI screen")
    notes[#notes + 1] = "glyph rows: 20h-7Eh and 80h-FCh (CP850) each matched to its own glyph"
    -- Cursor positioning and text placement.
    H.check(rows[10]:sub(20, 27) == "AT 10,20", "ESC[10;20H text: %q", C.printable(rows[10]))
    -- Reverse video: cells 1-7 of row 12 are reversed, the rest normal.
    local text, rev = cells(rows, reverse, 12, 1, 12)
    H.check(text == "REVERSE norm" and rev == "rrrrrrr     ", "reverse row 12: %q %q", C.printable(text), rev)
    local h_rev = V.histogram(0, C.offset + 8 * 11, 7 * 6, 8)
    local h_norm = V.histogram(7 * 6, C.offset + 8 * 11, 5 * 6, 8)
    local function colours(h) local n = 0 for _ in pairs(h) do n = n + 1 end return n end
    H.check(colours(h_rev) == 2 and h_rev[ink] and h_rev[paper], "reverse cells use %d colours", colours(h_rev))
    H.check(h_rev[ink] > h_rev[paper] and h_norm[paper] > h_norm[ink], "reverse cells: ink %d paper %d; normal cells: ink %d paper %d",
        h_rev[ink], h_rev[paper], h_norm[ink], h_norm[paper])
    notes[#notes + 1] = string.format("reverse run drawn ink-on-paper swapped (%d/%d px against %d/%d)", h_rev[ink], h_rev[paper], h_norm[ink], h_norm[paper])
    -- Erase to end of line, erase to start of line.
    H.check(trimmed(rows[14]) == "XXXX", "ESC[K row 14: %q", C.printable(rows[14]))
    H.check(rows[15]:sub(1, 8) == "    EFGH", "ESC[1K row 15: %q", C.printable(rows[15]))
    -- Autowrap at column 85.
    H.check(rows[16]:sub(82, 85) == "ABCD" and rows[17]:sub(1, 2) == "EF", "wrap at col 85: %q / %q", rows[16]:sub(78), rows[17]:sub(1, 6))
    -- With DECAWM off the last column is overwritten, no wrap.
    H.check(rows[18]:sub(83, 85) == "WXZ" and trimmed(rows[19]) == "", "no-wrap row 18: %q row 19: %q", rows[18]:sub(78), C.printable(rows[19]))
    -- Tab and backspace.
    H.check(rows[20]:sub(1, 11) == "a       bce", "tab/backspace row 20: %q", rows[20]:sub(1, 12))
    -- Insert line: the row marked INS moved down by the ESC[L.
    H.check(trimmed(rows[22]) == "" and trimmed(rows[23]) == "INSERTED-ONE", "insert line rows 22/23: %q %q", C.printable(rows[22]), C.printable(rows[23]))
    notes[#notes + 1] = "CUP, erase to end/start of line, wrap at col 85, DECAWM off (the last column overwritten), tab, backspace, insert line, the shell prompt where the cursor was left"
    -- The cursor after the listing.
    col, row = cursor_cell()
    -- The listing's last CUP left the cursor at 25;18 and the shell wrote its prompt there.
    H.check(rows[25]:sub(18, 17 + #trimmed(P)) == trimmed(P) and col == 17 + #P and row == 24,
        "cursor after the listing's ESC[25;18H and the prompt: col %s row %s, row 25 %q", tostring(col), tostring(row), C.printable(rows[25]))
    compared, bad, skipped, first = V.render_check(0, 212)
    H.check(bad == 0, "ANSI screen: %d mismatches (%s)", bad, tostring(first))
    notes[#notes + 1] = string.format("ANSI screen %d px rendered as VRAM says, cursor at col %d row %d", compared, col, row)

    -- A long listing: the circular scroll runs the 256-line surface past its end.
    K.chord({ "Left Ctrl", "L" })
    seconds(0.5)
    local r23_before = V.reg(23)
    local r23_seen = { [r23_before] = true }
    K.type(show("SCROLL.TXT") .. "\r")
    wait_listing("S100", 120, "end of the scrolling listing")
    C.wait(trimmed(P), 20, "the prompt after the listing")
    seconds(0.5)
    rows = C.read()
    local last
    for i = 1, #rows do if rows[i]:find("S100", 1, true) then last = i end end
    H.check(last ~= nil, "no S100 on the screen")
    -- The screen holds the last rows in order, ending at S100 then the prompt.
    for k = 0, 8 do
        local label = string.format("S%03d", 100 - k)
        H.check(rows[last - k]:sub(1, 4) == label, "row %d reads %q, want %s", last - k, C.printable(rows[last - k]):sub(1, 12), label)
    end
    H.check(trimmed(rows[last + 1]):find(trimmed(P), 1, true) == 1, "no prompt after the listing: %q", C.printable(rows[last + 1] or ""))
    H.check(select(3, C.read()) == 0, "unknown cells after the scroll")
    local r23_after = V.reg(23)
    H.check(r23_after ~= r23_before, "R#23 did not move (%02X)", r23_after)
    compared, bad, skipped, first = V.render_check(0, 212)
    H.check(bad == 0, "scrolled screen: %d mismatches (%s)", bad, tostring(first))
    col, row = cursor_cell()
    H.check(col == #P and row == last, "cursor after the listing at col %s row %s, want col %d row %d", tostring(col), tostring(row), #P, last)
    notes[#notes + 1] = string.format("100-line listing: R#23 %02X -> %02X, S092-S100 in order, prompt and cursor on row %d, %d px rendered as VRAM says",
        r23_before, r23_after, last, compared)
    shot("scrolled")

    -- Status port: only the command-complete poll (S#2), and no interrupt.
    local only_two = true
    for reg, n in pairs(status_by_reg) do if reg ~= 2 and reg ~= 0 then only_two = false end end
    H.check(status_total > 0, "no status reads seen")
    H.check(vdp_int_item:read(0) == 0, "the VDP /INT line was asserted")
    notes[#notes + 1] = string.format("status-port reads %d (%s), VDP /INT low, data-port reads %d", status_total, status_report(), data_reads)
    return table.concat(notes, "; ")
end

H.case_body("console-konaos", function()
    return console_proof("konaos", "/> ", function(file) return "cat /fs/" .. file end)
end)

H.case_body("console-zsdos", function()
    return console_proof("zsdos", "B0:/$ ", function(file) return "cat /" .. file end)
end)

-- The ports: address range, banks, mirrors, palette, register and status selection ----------
--
-- The flash image is DI/HALT, so only this script drives the chip, through the
-- machine's own I/O handlers (A0h-BFh).  Observation goes through the vdp's
-- address space and saved registers, and through the CPU-visible reads
-- (data and status ports) where the question is what a guest would see.
local DATA, CTRL, PAL, IND = 0xa0, 0xa1, 0xa2, 0xa3

local function reg(n, value)
    H.io:write_u8(CTRL, value)
    H.io:write_u8(CTRL, 0x80 | n)
end

-- Set the VRAM address (17 bits) for writing or reading, through R#14 and the
-- two-byte control sequence.
local function address(a, write, port)
    port = port or CTRL
    reg(14, (a >> 14) & 7)
    H.io:write_u8(port, a & 0xff)
    H.io:write_u8(port, (write and 0x40 or 0) | ((a >> 8) & 0x3f))
end

local function status(n)
    reg(15, n)
    return H.io:read_u8(CTRL)
end

local function frame_wait(n)
    for _ = 1, n or 1 do coroutine.yield() end
end

-- A distinct byte for each address (so a misplaced write cannot match by chance).
local function marker(a) return (a * 37 + (a >> 8) * 11 + (a >> 16) * 5 + 1) & 0xff end

H.case_body("vdp-ports", function()
    local notes = {}

    -- Mode with a linear VRAM map (GRAPHIC1): CPU address = chip address.
    reg(0, 0x00) reg(1, 0x40) reg(9, 0x80) reg(8, 0x0a)
    local points = { 0x00000, 0x00001, 0x03fff, 0x04000, 0x07fff, 0x08000, 0x0bfff, 0x0c000, 0x0ffff,
                     0x10000, 0x13fff, 0x14000, 0x17fff, 0x18000, 0x1bfff, 0x1c000, 0x1ffff }
    for _, a in ipairs(points) do
        address(a, true)
        H.io:write_u8(DATA, marker(a))
    end
    for _, a in ipairs(points) do
        H.check(V.vram(a) == marker(a), "VRAM %05X holds %02X, wrote %02X", a, V.vram(a), marker(a))
    end
    -- Reading back through the data port (the read-ahead's first byte is the addressed one).
    for _, a in ipairs(points) do
        address(a, false)
        local got = H.io:read_u8(DATA)
        H.check(got == marker(a), "data-port read of %05X gives %02X, want %02X", a, got, marker(a))
    end
    notes[#notes + 1] = string.format("%d addresses across the 16 KiB banks and the A16 boundary written, in VRAM and read back", #points)

    -- A write run in a 16K-compatible mode (GRAPHIC1, TEXT, GRAPHIC2/3): the 14-bit counter
    -- wraps inside its bank and R#14 does not follow (v9938.cpp: R#14 carries only when
    -- R#0 has M4 or M5 set).
    address(0x3ffe, true)
    for i = 0, 3 do H.io:write_u8(DATA, 0xa0 + i) end
    H.check(V.vram(0x3ffe) == 0xa0 and V.vram(0x3fff) == 0xa1 and V.vram(0x0000) == 0xa2 and V.vram(0x0001) == 0xa3 and V.reg(14) == 0,
        "GRAPHIC1 run over 3FFFh: %02X %02X then %02X %02X at 0000h, R#14 %d", V.vram(0x3ffe), V.vram(0x3fff), V.vram(0), V.vram(1), V.reg(14))
    notes[#notes + 1] = "GRAPHIC1: the counter wraps inside the 16 KiB bank (R#14 unchanged)"

    -- The bitmap modes carry into R#14: a write or read run crosses 3FFFh/4000h, FFFFh/10000h and wraps at 128 KiB.
    reg(0, 0x0a) reg(1, 0x40) reg(9, 0x80)
    local function logical(a) return V.byte(a, "GRAPHIC6") end
    address(0x3ffe, true)
    for i = 0, 3 do H.io:write_u8(DATA, 0xa0 + i) end
    H.check(logical(0x3ffe) == 0xa0 and logical(0x3fff) == 0xa1 and logical(0x4000) == 0xa2 and logical(0x4001) == 0xa3,
        "a run over 3FFFh/4000h: %02X %02X %02X %02X", logical(0x3ffe), logical(0x3fff), logical(0x4000), logical(0x4001))
    H.check(V.reg(14) == 1, "R#14 after crossing into bank 1 is %d", V.reg(14))
    address(0xffff, true)
    H.io:write_u8(DATA, 0xb0) H.io:write_u8(DATA, 0xb1)
    H.check(logical(0xffff) == 0xb0 and logical(0x10000) == 0xb1 and V.reg(14) == 4, "a run over FFFFh/10000h: %02X %02X R#14 %d", logical(0xffff), logical(0x10000), V.reg(14))
    address(0x1ffff, true)
    H.io:write_u8(DATA, 0xc0) H.io:write_u8(DATA, 0xc1)
    H.check(logical(0x1ffff) == 0xc0 and logical(0x00000) == 0xc1 and V.reg(14) == 0, "a run over the last byte wraps to 0: %02X %02X R#14 %d", logical(0x1ffff), logical(0), V.reg(14))
    address(0x3ffe, false)
    local run = {}
    for i = 1, 4 do run[i] = H.io:read_u8(DATA) end
    H.check(run[1] == 0xa0 and run[2] == 0xa1 and run[3] == 0xa2 and run[4] == 0xa3, "a read run over 3FFFh: %02X %02X %02X %02X", run[1], run[2], run[3], run[4])
    notes[#notes + 1] = "GRAPHIC6: write and read runs cross 3FFFh/4000h (R#14 1), FFFFh/10000h (R#14 4) and wrap from 1FFFFh to 0"

    -- GRAPHIC6 hides the interleave behind the same CPU addresses.
    local g6 = { 0x00000, 0x00001, 0x00002, 0x0ffff, 0x10000, 0x10001, 0x1fffe, 0x1ffff }
    for _, a in ipairs(g6) do
        address(a, true)
        H.io:write_u8(DATA, marker(a))
    end
    for _, a in ipairs(g6) do
        local physical = ((a & 1) << 16) | (a >> 1)
        H.check(V.vram(physical) == marker(a), "G6 logical %05X: physical %05X holds %02X, want %02X", a, physical, V.vram(physical), marker(a))
        address(a, false)
        H.check(H.io:read_u8(DATA) == marker(a), "G6 data-port read of logical %05X", a)
        H.check(V.byte(a, "GRAPHIC6") == marker(a), "the observer's G6 mapping of %05X", a)
    end
    notes[#notes + 1] = "GRAPHIC6: logical address L is physical ((L&1)<<16)|(L>>1), through the port and the observer"

    -- Mirrors in A0h-BFh: data through B8h/A8h, control through B9h, reads through any A2-set address;
    -- a write with A2 set is the interrupt latch, not the VDP.
    reg(0, 0x00) reg(1, 0x40)
    address(0x00100, true, 0xb9)
    H.io:write_u8(0xb8, 0x5a)
    H.io:write_u8(0xa8, 0x5b)
    H.io:write_u8(0xb0, 0x5c)
    H.check(V.vram(0x100) == 0x5a and V.vram(0x101) == 0x5b and V.vram(0x102) == 0x5c, "data writes through B8h, A8h, B0h: %02X %02X %02X", V.vram(0x100), V.vram(0x101), V.vram(0x102))
    address(0x00100, false, 0xa9)
    H.check(H.io:read_u8(0xbc) == 0x5a and H.io:read_u8(0xa4) == 0x5b and H.io:read_u8(0xb8) == 0x5c, "data reads through BCh, A4h, B8h")
    local latch_before = V.reg(14)
    address(0x00200, true)
    H.io:write_u8(0xa4, 0xee) -- A2 set: the latch, not VRAM data
    H.io:write_u8(0xbc, 0xee)
    H.io:write_u8(DATA, 0x11)
    H.check(V.vram(0x200) == 0x11 and V.vram(0x201) ~= 0xee, "a write with A2 set reached the VDP data port: %02X %02X", V.vram(0x200), V.vram(0x201))
    H.io:write_u8(0xa4, 0) -- restore the latch (route 0)
    notes[#notes + 1] = "ports mirror every 4 across A0h-BFh; data and control through A8h/B0h/B8h/B9h, reads through A4h/BCh; writes with A2 set never reach the data port"

    -- Palette: the pair through A2h, R#16 auto-incrementing and wrapping; the high bits ignored.
    reg(16, 0)
    for i = 0, 15 do
        H.io:write_u8(PAL, ((i & 7) << 4) | ((15 - i) & 7) | 0x88)
        H.io:write_u8(PAL, ((i >> 1) & 7) | 0xf8)
    end
    local pal = V.palette()
    for i = 0, 15 do
        H.check(pal[i][1] == (i & 7) and pal[i][2] == ((i >> 1) & 7) and pal[i][3] == ((15 - i) & 7), "palette %d reads %d,%d,%d", i, pal[i][1], pal[i][2], pal[i][3])
    end
    H.check(V.reg(16) == 0, "R#16 after 16 entries is %d, want it wrapped to 0", V.reg(16))
    reg(16, 9)
    H.io:write_u8(PAL, 0x25) H.io:write_u8(PAL, 0x03)
    pal = V.palette()
    H.check(pal[9][1] == 2 and pal[9][2] == 3 and pal[9][3] == 5 and V.reg(16) == 10, "entry 9 %d,%d,%d R#16 %d", pal[9][1], pal[9][2], pal[9][3], V.reg(16))
    -- The 16 entries through the rendered screen: a G6 bitmap of 16 vertical stripes.
    reg(0, 0x0a) reg(1, 0x40) reg(2, 0x1f) reg(7, 0x00) reg(9, 0x80)
    address(0, true)
    local stripe = {}
    for i = 0, 15 do stripe[#stripe + 1] = string.rep(string.char((i << 4) | i), 16) end
    local line = table.concat(stripe)
    for _ = 0, 211 do
        for i = 1, #line do H.io:write_u8(DATA, line:byte(i)) end
    end
    frame_wait(3)
    local image = V.image()
    for i = 0, 15 do
        local x = i * 32 + 4
        local colour = V.rendered(image, x, 50)
        local want = V.palette_rgb(i)
        H.check((colour & 0xffffff) == (want & 0xffffff), "stripe %d renders %08X, palette %08X", i, colour, want)
    end
    notes[#notes + 1] = "16 palette entries through A2h (two bytes each, R#16 auto-increment wrapping, upper bits ignored); all 16 rendered as the 3-bit RGB the entries hold"

    -- Registers: the control pair, the indirect port with R#17's auto-increment, and write-only R#46 not stored as a status.
    reg(17, 0x20)
    for i = 0, 3 do H.io:write_u8(IND, 0x40 + i) end
    H.check(V.reg(32) == 0x40 and V.reg(33) == 0x41 and V.reg(34) == 0x42 and V.reg(35) == 0x43 and (V.reg(17) & 0x3f) == 0x24,
        "indirect writes R#32-35: %02X %02X %02X %02X R#17 %02X", V.reg(32), V.reg(33), V.reg(34), V.reg(35), V.reg(17))
    reg(17, 0xa0) -- bit 7: no auto-increment
    H.io:write_u8(IND, 0x77) H.io:write_u8(IND, 0x78)
    H.check(V.reg(32) == 0x78 and V.reg(33) == 0x41, "no-increment indirect: R#32 %02X R#33 %02X", V.reg(32), V.reg(33))
    reg(17, 0x00)
    notes[#notes + 1] = "R#17 indirect port increments R#32.. and, with bit 7, stays on one register"

    -- Status selection: S#1 is the V9958 ID (2), S#2 the command/raster flags, S#0 the frame flag cleared by a read.
    local s1 = status(1)
    H.check(s1 & 0x3e == 0x04, "S#1 = %02X, want the V9958 ID 02 in bits 5:1", s1)
    frame_wait(2)
    local first = status(0)
    local second = status(0)
    H.check((first & 0x80) ~= 0 and (second & 0x80) == 0, "S#0 frame flag: first read %02X, second %02X", first, second)
    frame_wait(1)
    H.check((status(0) & 0x80) ~= 0, "the frame flag did not return with the next frame")
    -- Raster flags over a frame: VR (S#2 bit 6) follows the vertical blanking.
    local vr = 0
    local polls = 0
    reg(15, 2)
    local start = H.now()
    -- Sample S#2 while the CPU waits across a few frames: this probe's frame notifier
    -- only samples at frame ends, so VR is read at that instant every frame.
    for _ = 1, 8 do
        frame_wait(1)
        polls = polls + 1
        if (H.io:read_u8(CTRL) & 0x40) ~= 0 then vr = vr + 1 end
    end
    reg(15, 0)
    notes[#notes + 1] = string.format("S#1 ID %02X (V9958), S#0 F set once per frame and cleared by the read, VR seen at %d of %d frame ends", s1, vr, polls)
    return table.concat(notes, "; ")
end)

-- The command engine: results, busy state and time ----------------------------------------
--
-- video.asm runs the KonaOS driver's sequence on the real Z80: the 15-byte block
-- through the indirect port (R#46 last, which starts the command), then S#2 polled
-- until CE clears.  Taps on the indirect and status ports log the emulated time of
-- the starting write and of the first poll that saw CE clear, so a command's busy
-- time is measured to the Z80's own poll loop (27 T-states, 2.7 us), not to a frame.
-- The results are checked pixel for pixel against a reference of each command.
local MAIL_CMD, MAIL_POLLS, MAIL_BLOCK = 0x7f00, 0x7f02, 0x7f10
local mem = H.program

local timing = { armed = false, writes = 0, t0 = nil, t1 = nil, reads = 0, busy_reads = 0 }
local function install_timing_taps()
    H.keep(H.io:install_write_tap(IND, IND, "vdp-cmd-start", function(offset, data)
        if timing.armed then
            timing.writes = timing.writes + 1
            if timing.writes == 15 then timing.t0 = H.now() end
        end
    end))
    H.keep(H.io:install_read_tap(CTRL, CTRL, "vdp-cmd-poll", function(offset, data)
        if timing.armed and timing.t0 and not timing.t1 then
            timing.reads = timing.reads + 1
            if (data & 1) == 0 then timing.t1 = H.now() else timing.busy_reads = timing.busy_reads + 1 end
        end
    end))
end

-- Pixel geometry of the mode under test.
local MODES = {
    GRAPHIC6 = { r0 = 0x0a, width = 512, pitch = 256, per_byte = 2 },
    GRAPHIC7 = { r0 = 0x0e, width = 256, pitch = 256, per_byte = 1 },
}

local function set_screen(name, sprites_on, display_on)
    local m = MODES[name]
    reg(0, m.r0)
    reg(1, display_on and 0x40 or 0x00)
    reg(2, 0x1f)
    reg(8, sprites_on and 0x08 or 0x0a)
    reg(9, 0x80)
    reg(23, 0)
    return m
end

-- The pixels of page 0, lines [0, lines), as a flat array (index y * width + x).
local function read_page(m, lines)
    local pixels = {}
    local mode = V.mode()
    for y = 0, lines - 1 do
        local base = y * m.pitch
        for b = 0, m.pitch - 1 do
            local byte = V.byte(base + b, mode)
            if m.per_byte == 1 then
                pixels[y * m.width + b] = byte
            else
                pixels[y * m.width + 2 * b] = byte >> 4
                pixels[y * m.width + 2 * b + 1] = byte & 15
            end
        end
    end
    return pixels
end

-- Fill page 0 (lines [0, lines)) with a pattern through the data port.
local function load_page(m, lines, pattern)
    address(0, true)
    local seed = 12345
    for y = 0, lines - 1 do
        for b = 0, m.pitch - 1 do
            local v
            if pattern == "clear" then v = 0 else
                seed = (seed * 1103515245 + 12345) & 0x7fffffff
                v = (seed >> 16) & 0xff
                if m.per_byte == 2 and pattern == "nonzero" then
                    if (v >> 4) == 0 then v = v | 0x10 end
                    if (v & 15) == 0 then v = v | 1 end
                end
            end
            H.io:write_u8(DATA, v)
        end
    end
end

local function logic(op, dst, src, mask)
    local t = (op & 8) ~= 0
    if t and src == 0 then return dst end
    local l = op & 3
    if l == 0 then return src end
    if l == 1 then return dst & src end
    if l == 2 then return dst | src end
    return dst ~ src
end

-- Reference models: each returns the expected page after the command.
local function ref_hmmv(m, page, c)
    local out = {}
    for i, v in pairs(page) do out[i] = v end
    for y = c.dy, c.dy + c.ny - 1 do
        for x = c.dx, c.dx + c.nx - 1 do
            local v = c.clr
            if m.per_byte == 2 then v = (x & 1) == 0 and (c.clr >> 4) or (c.clr & 15) end
            out[y * m.width + x] = v
        end
    end
    return out
end

local function ref_hmmm(m, page, c, op)
    local out = {}
    for i, v in pairs(page) do out[i] = v end
    for y = 0, c.ny - 1 do
        for x = 0, c.nx - 1 do
            local src = page[(c.sy + y) * m.width + c.sx + x]
            local at = (c.dy + y) * m.width + c.dx + x
            out[at] = op and logic(op, page[at], src) or src
        end
    end
    return out
end

local function ref_lmmv(m, page, c, op)
    local out = {}
    for i, v in pairs(page) do out[i] = v end
    for y = c.dy, c.dy + c.ny - 1 do
        for x = c.dx, c.dx + c.nx - 1 do
            local src = m.per_byte == 2 and (c.clr & 15) or c.clr
            local at = y * m.width + x
            out[at] = logic(op, page[at], src)
        end
    end
    return out
end

local function compare(m, want, lines)
    local got = read_page(m, lines)
    local bad, first = 0, nil
    for i = 0, lines * m.width - 1 do
        if got[i] ~= want[i] then
            bad = bad + 1
            first = first or string.format("(%d,%d) holds %X, want %X", i % m.width, i // m.width, got[i] or -1, want[i] or -1)
        end
    end
    return bad, first, got
end

local function post(c, code)
    local block = { c.sx & 255, c.sx >> 8, c.sy & 255, c.sy >> 8, c.dx & 255, c.dx >> 8, c.dy & 255, c.dy >> 8,
                    c.nx & 255, c.nx >> 8, c.ny & 255, c.ny >> 8, c.clr or 0, c.arg or 0, code }
    for i, v in ipairs(block) do mem:write_u8(MAIL_BLOCK + i - 1, v) end
    timing.armed, timing.writes, timing.t0, timing.t1, timing.reads, timing.busy_reads = true, 0, nil, nil, 0, 0
    mem:write_u8(MAIL_CMD, 1)
    H.wait(function() return mem:read_u8(MAIL_CMD) == 0 end, 5, "the command probe")
    timing.armed = false
    H.check(timing.t0 and timing.t1, "no start or completion observed (writes %d reads %d)", timing.writes, timing.reads)
    local polls = mem:read_u8(MAIL_POLLS) | (mem:read_u8(MAIL_POLLS + 1) << 8)
    return { seconds = timing.t1 - timing.t0, polls = polls, busy_polls = timing.busy_reads }
end

local results = {}

-- Run one command on a freshly loaded page and compare it with its reference.
local function run_case(name, mode, units, c, code, reference, opts)
    opts = opts or {}
    local m = set_screen(mode, opts.sprites, opts.display ~= false)
    local lines = opts.lines or 64
    reg(14, 0)
    load_page(m, lines, opts.pattern or "nonzero")
    local before = read_page(m, lines)
    local r = post(c, code)
    local want = reference and reference(m, before, c) or nil
    local bad, first
    if want then bad, first = compare(m, want, lines) end
    H.check(not want or bad == 0, "%s %s: %d pixels differ from the reference, first %s", mode, name, bad or 0, tostring(first))
    local per_unit = r.seconds * 1e6 / units
    results[#results + 1] = { name = name, mode = mode, units = units, seconds = r.seconds, polls = r.polls, busy = r.busy_polls,
        sprites = opts.sprites and "on" or "off", display = opts.display == false and "off" or "on", per_unit_us = per_unit }
    return r
end

H.case_body("vdp-commands", function()
    install_timing_taps()
    H.wait(function() return H.now() > 0.005 end, 1, "the command probe program")
    local notes = {}
    local file = assert(lio.open(H.dir .. "/commands.tsv", "w"))
    file:write("command\tmode\tdisplay\tsprites\tunits\tbusy_us\tus_per_unit\tpolls\tbusy_polls\n")
    local function row()
        local r = results[#results]
        file:write(string.format("%s\t%s\t%s\t%s\t%d\t%.2f\t%.4f\t%d\t%d\n", r.name, r.mode, r.display, r.sprites, r.units,
            r.seconds * 1e6, r.per_unit_us, r.polls, r.busy))
        file:flush()
    end

    for _, mode in ipairs({ "GRAPHIC7", "GRAPHIC6" }) do
        local px = mode == "GRAPHIC6" and 2 or 1 -- pixels per byte
        local bytes = function(w) return w // px end
        -- HMMV: a rectangle of bytes; units are bytes.
        local c = { sx = 0, sy = 0, dx = 16, dy = 5, nx = 64, ny = 20, clr = 0x5a }
        run_case("HMMV", mode, bytes(c.nx) * c.ny, c, 0xc0, ref_hmmv); row()
        c = { sx = 0, sy = 0, dx = 0, dy = 0, nx = mode == "GRAPHIC6" and 512 or 256, ny = 56, clr = 0x33 }
        run_case("HMMV wide", mode, bytes(c.nx) * c.ny, c, 0xc0, ref_hmmv, { lines = 64 }); row()
        -- HMMM: a copy between disjoint rectangles.
        c = { sx = 8, sy = 2, dx = 100, dy = 30, nx = 48, ny = 16 }
        run_case("HMMM", mode, bytes(c.nx) * c.ny, c, 0xd0, function(m, p, cc) return ref_hmmm(m, p, cc) end); row()
        -- A console glyph copy: 6x8 (3 bytes x 8 lines in GRAPHIC6), then 12x8.
        c = { sx = 12, sy = 40, dx = 60, dy = 12, nx = 6, ny = 8 }
        run_case("HMMM 6x8", mode, bytes(c.nx) * c.ny, c, 0xd0, function(m, p, cc) return ref_hmmm(m, p, cc) end, { sprites = true }); row()
        run_case("HMMM 6x8", mode, bytes(c.nx) * c.ny, c, 0xd0, function(m, p, cc) return ref_hmmm(m, p, cc) end, { sprites = false }); row()
        -- LMMV with IMP, AND, OR, XOR; units are pixels.
        for _, lo in ipairs({ 0, 1, 2, 3 }) do
            c = { sx = 0, sy = 0, dx = 20, dy = 6, nx = 40, ny = 12, clr = 0x06 }
            run_case("LMMV op" .. lo, mode, c.nx * c.ny, c, 0x80 | lo, function(m, p, cc) return ref_lmmv(m, p, cc, lo) end); row()
        end
        -- LMMM with TIMP (the atlas copy): colour 0 in the source is transparent.
        c = { sx = 2, sy = 3, dx = 80, dy = 20, nx = 32, ny = 16 }
        run_case("LMMM TIMP", mode, c.nx * c.ny, c, 0x98, function(m, p, cc) return ref_hmmm(m, p, cc, 8) end); row()
        c = { sx = 2, sy = 3, dx = 80, dy = 20, nx = 32, ny = 16 }
        run_case("LMMM IMP", mode, c.nx * c.ny, c, 0x90, function(m, p, cc) return ref_hmmm(m, p, cc, 0) end); row()
        -- PSET: one dot with IMP.
        c = { sx = 0, sy = 0, dx = 33, dy = 17, nx = 0, ny = 0, clr = 0x07, arg = 0 }
        run_case("PSET", mode, 1, c, 0x50, function(m, p, cc) local o = {} for i, v in pairs(p) do o[i] = v end o[cc.dy * m.width + cc.dx] = cc.clr & (m.per_byte == 2 and 15 or 255) return o end); row()
    end
    -- A command shorter than a scanline's budget finishes early (informational; no assertion): the engine
    -- is given 13,662 units a line and a command started on an idle engine uses the rest of the current line's.
    for _, r in ipairs(results) do
        if r.name == "HMMM 6x8" and r.mode == "GRAPHIC6" then
            local units = r.sprites == "on" and 1111 or 854
            notes[#notes + 1] = string.format("glyph HMMM 6x8 (24 bytes) sprites %s: busy %.1f us, %.1f us from the engine table (%d units a byte)",
                r.sprites, r.seconds * 1e6, 24 * units / 10 / 21.477272, units)
        end
    end
    notes[#notes + 1] = string.format("%d command runs (HMMV, HMMM, glyph HMMM, LMMV IMP/AND/OR/XOR, LMMM IMP/TIMP, PSET in GRAPHIC7 and GRAPHIC6) match their references pixel for pixel", #results)

    -- LINE: eight octants, drawn on a cleared page; properties of the dots.
    for _, mode in ipairs({ "GRAPHIC7" }) do
        local lines = 128
        for _, shape in ipairs({
            { "x-major right-down", 40, 17, 0, 0 }, { "x-major left-down", 40, 17, 0, 4 }, { "x-major right-up", 40, 17, 0, 8 }, { "x-major left-up", 40, 17, 0, 12 },
            { "y-major right-down", 38, 11, 1, 0 }, { "y-major left-down", 38, 11, 1, 4 }, { "y-major right-up", 38, 11, 1, 8 }, { "y-major left-up", 38, 11, 1, 12 },
            { "horizontal", 50, 0, 0, 0 }, { "diagonal", 30, 30, 0, 0 },
        }) do
            local name, major, minor, maj, dir = shape[1], shape[2], shape[3], shape[4], shape[5]
            local c = { sx = 0, sy = 0, dx = 100, dy = 64, nx = major, ny = minor, clr = 0x77, arg = maj | dir }
            local m = set_screen(mode, false, true)
            reg(14, 0)
            load_page(m, lines, "clear")
            local r = post(c, 0x70)
            local page = read_page(m, lines)
            local set, minx, maxx, miny, maxy = {}, 1e9, -1, 1e9, -1
            local count = 0
            for i, v in pairs(page) do
                if v ~= 0 then
                    local x, y = i % m.width, i // m.width
                    set[i] = true
                    count = count + 1
                    minx, maxx, miny, maxy = math.min(minx, x), math.max(maxx, x), math.min(miny, y), math.max(maxy, y)
                end
            end
            local dix, diy = (dir & 4) ~= 0 and -1 or 1, (dir & 8) ~= 0 and -1 or 1
            H.check(set[c.dy * m.width + c.dx], "%s: the start dot (100,64) is not set", name)
            -- Every dot has a neighbour among the others (one connected path).
            for i in pairs(set) do
                local x, y = i % m.width, i // m.width
                local near = false
                for dy = -1, 1 do for dx = -1, 1 do
                    if (dx ~= 0 or dy ~= 0) and set[(y + dy) * m.width + x + dx] then near = true end
                end end
                H.check(near or count == 1, "%s: an isolated dot at (%d,%d)", name, x, y)
            end
            local major_extent = (maj == 0 and (maxx - minx) or (maxy - miny)) + 1
            local minor_extent = (maj == 0 and (maxy - miny) or (maxx - minx)) + 1
            H.check(count == major_extent and (major_extent == major or major_extent == major + 1),
                "%s: %d dots over a major extent %d, NX %d", name, count, major_extent, major)
            H.check(minor_extent == minor + 1 or minor_extent == minor or (minor == 0 and minor_extent == 1), "%s: minor extent %d, NY %d", name, minor_extent, minor)
            -- The line ends on the side DIX/DIY name.
            local ex = dix > 0 and maxx or minx
            local ey = diy > 0 and maxy or miny
            H.check((maj == 0 and ex ~= c.dx) or (maj == 1 and ey ~= c.dy) or major == 0, "%s: the line does not run toward DIX/DIY", name)
            results[#results + 1] = { name = "LINE " .. name, mode = mode, units = count, seconds = r.seconds, polls = r.polls, busy = r.busy_polls,
                sprites = "off", display = "on", per_unit_us = r.seconds * 1e6 / count }
            row()
        end
    end
    notes[#notes + 1] = "LINE in the eight octants plus horizontal and diagonal: start dot set, one connected path, one dot per major step, ending toward DIX/DIY"

    -- Busy state: CE is seen set after the start for a long command and the status polls match its length.
    local m = set_screen("GRAPHIC7", false, true)
    reg(14, 0)
    load_page(m, 16, "clear")
    local c = { sx = 0, sy = 0, dx = 0, dy = 0, nx = 256, ny = 200, clr = 0x1c }
    local r = post(c, 0xc0)
    H.check(r.busy_polls > 1000 and r.polls == r.busy_polls + 1, "full-screen HMMV: %d busy polls of %d", r.busy_polls, r.polls)
    -- The engine runs while the display runs: the fill finished within the time the K model gives it plus a margin, never instantly.
    -- The stock engine's rate: 13,662 units a scanline (1368 clocks of the card's 21.477272 MHz) and
    -- 53.1 clocks (531 units) a byte with the display on and sprites off: 25 whole bytes a line.
    local table_ms = 51200 / 25 * 1368 / 21.477272e6 * 1000
    H.check(math.abs(r.seconds * 1000 / table_ms - 1) < 0.05, "full-screen HMMV took %.2f ms, the engine's table gives %.2f ms", r.seconds * 1000, table_ms)
    results[#results + 1] = { name = "HMMV 256x200", mode = "GRAPHIC7", units = 256 * 200, seconds = r.seconds, polls = r.polls, busy = r.busy_polls,
        sprites = "off", display = "on", per_unit_us = r.seconds * 1e6 / (256 * 200) }
    row()
    notes[#notes + 1] = string.format("full-screen HMMV busy %.2f ms against %.2f ms from the engine table at the card clock (%d S#2 polls, CE set until the last)", r.seconds * 1000, table_ms, r.polls)

    -- Display off and sprites on/off change the time (the chip's timing columns).
    local variants = {}
    for _, v in ipairs({ { true, true }, { true, false }, { false, true }, { false, false } }) do
        local sprites, display = v[1], v[2]
        local c2 = { sx = 0, sy = 0, dx = 0, dy = 0, nx = 128, ny = 40, clr = 0x1c }
        local rr = run_case("HMMV 128x40", "GRAPHIC7", 128 * 40, c2, 0xc0, ref_hmmv, { sprites = sprites, display = display, lines = 48 })
        row()
        variants[#variants + 1] = string.format("%s/%s %.2f ms", display and "display" or "blank", sprites and "sprites" or "no sprites", rr.seconds * 1000)
    end
    notes[#notes + 1] = "HMMV 128x40 by state: " .. table.concat(variants, ", ")
    file:close()
    return table.concat(notes, "; ")
end)
