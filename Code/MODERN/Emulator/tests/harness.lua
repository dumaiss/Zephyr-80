-- license:BSD-3-Clause
-- Autoboot harness for tests/run.py. Runs one case body (from the script
-- HARNESS_SCRIPT names) as a coroutine resumed every emulated frame, bounds
-- it by an emulated-time deadline and ends the run with an explicit verdict:
--
--   PASS harness <case>: <detail>     or     FAIL harness <case>: <detail>
--
-- preceded on failure by DIAG lines (case, emulated time, PC, latch, what the
-- case was waiting for, VDP mode and the serial tail). The runner requires
-- the PASS line; MAME's exit status alone never passes a case.
--
-- Observations:
--   harness.serial  SIO0/B as the host sees it: the bytes the pty slot
--                   deserialized from the guest's TXD, and bytes written to
--                   that slot for the guest's RXD, both in emulated time.
--   harness.vdp     V9958 registers, VRAM, name-table text, the GRAPHIC6
--                   console's text (harness.vdp.console) and the rendered
--                   screen bitmap.
--
-- Input: harness.keyboard presses and releases the USB keyboard's fields
-- through MAME's input path and logs each change (inputs.tsv).
if _G.harness then return end -- autoboot runs again after a soft reset

local lio = io
local machine = manager.machine
local H = {
    case = assert(os.getenv("HARNESS_CASE"), "HARNESS_CASE"),
    dir = assert(os.getenv("HARNESS_DIR"), "HARNESS_DIR"),
    deadline = assert(tonumber(os.getenv("HARNESS_DEADLINE")), "HARNESS_DEADLINE"),
    prompt = os.getenv("HARNESS_PROMPT") or "/system> ",
    machine = machine,
    handles = {},
}
_G.harness = H
H.cpu = machine.devices[":maincpu"]
H.program = H.cpu.spaces["program"]
H.io = H.cpu.spaces["io"]

local done, waiting_for, body = false, nil, nil
local latch_item = emu.item(machine.devices[":"].items["0/m_latch"])

function H.now()
    return machine.time:as_double()
end

-- One printable line: control bytes, bytes above 7Eh and the backslash as \xNN.
function H.escape(text)
    return (text:gsub("[%c\\\128-\255]", function(c) return string.format("\\x%02x", c:byte()) end))
end

function H.trace(fmt, ...)
    print("TRACE " .. string.format(fmt, ...))
end

-- Taps and notifiers stay installed only while referenced.
function H.keep(handle)
    H.handles[#H.handles + 1] = handle
    return handle
end

-- A case failure: carried as a table so it is reported without a traceback.
function H.fail(fmt, ...)
    error({ harness = string.format(fmt, ...) }, 0)
end

function H.check(condition, fmt, ...)
    if not condition then H.fail(fmt, ...) end
end

-- Wait in emulated time until predicate() returns a true value, which is
-- returned. Only a case body (the coroutine) may wait.
function H.wait(predicate, timeout, what)
    local limit = H.now() + timeout
    while true do
        local value = predicate()
        if value then
            waiting_for = nil
            return value
        end
        waiting_for = what
        if H.now() > limit then
            H.fail("no %s within %.1f emulated s", what, timeout)
        end
        coroutine.yield()
    end
end

-- Serial ---------------------------------------------------------------------

local S = { data = "", fh = nil, path = nil, last = nil, syncs = 0 }
H.serial = S

-- The runner configures the pty slave (raw, 115200 8N1, non-blocking reads)
-- and names it in HARNESS_TTY_FILE; this side opens the same slave.
function S.attach(timeout)
    local file = assert(os.getenv("HARNESS_TTY_FILE"), "HARNESS_TTY_FILE")
    S.path = H.wait(function()
        local f = lio.open(file, "rb")
        if not f then return nil end
        local path = f:read("l")
        f:close()
        return path
    end, timeout, "pty slave from the runner")
    S.fh = assert(lio.open(S.path, "r+b"))
    S.fh:setvbuf("no")
    S.log = assert(lio.open(H.dir .. "/serial.bin", "wb"))
    S.times = assert(lio.open(H.dir .. "/serial-times.tsv", "w"))
    S.times:write("emulated_s\tdirection\trx_offset\tbytes\n")
    H.trace("serial endpoint %s", S.path)
end

function S.poll()
    if not S.fh then return end
    local chunk = S.fh:read(4096)
    if chunk and #chunk > 0 then
        S.times:write(string.format("%.6f\trx\t%d\t%s\n", H.now(), #S.data, H.escape(chunk)))
        S.data = S.data .. chunk
        S.last = H.now()
        S.log:write(chunk)
        S.log:flush()
    end
end

function S.close()
    for _, f in ipairs({ S.fh, S.log, S.times }) do
        if f then f:close() end
    end
    S.fh = nil
end

-- The offset the next received byte will have.
function S.mark()
    return #S.data + 1
end

function S.send(bytes)
    H.check(S.fh ~= nil, "serial endpoint not attached")
    S.times:write(string.format("%.6f\ttx\t%d\t%s\n", H.now(), #S.data, H.escape(bytes)))
    S.fh:write(bytes)
    S.fh:flush()
end

-- Wait for text at or after offset `from`; returns its start and end offsets.
function S.wait(text, timeout, from, what)
    local found = H.wait(function()
        local a, b = S.data:find(text, from or 1, true)
        return a and { a, b }
    end, timeout, what or string.format("%q on the serial lane", text))
    return found[1], found[2]
end

-- The serial images hold their banner until the host sends AAh 55h. The
-- receiver is live only after early console initialisation, so the pair
-- repeats every 0.25 s until the first byte arrives, as the bench tool does.
function S.host_sync(timeout)
    local next_send = 0
    H.wait(function()
        if #S.data > 0 then return true end
        if H.now() >= next_send then
            S.send("\170\85")
            S.syncs = S.syncs + 1
            next_send = H.now() + 0.25
        end
        return false
    end, timeout, "first byte after the host sync")
    H.trace("host sync sent %d times; first byte at %.3f emulated s", S.syncs, S.last)
end

-- Type a line: each byte waits for the previous byte's echo (the console's
-- receiver is polled, one byte deep), then CR. Returns the offset the
-- response starts from.
function S.type(line, timeout)
    for i = 1, #line do
        local ch = line:sub(i, i)
        local from = S.mark()
        S.send(ch)
        S.wait(ch, timeout or 2, from, string.format("echo of byte %d of %q", i, line))
    end
    local from = S.mark()
    S.send("\r")
    return from
end

function S.tail(count)
    return S.data:sub(-(count or 240))
end

-- VDP --------------------------------------------------------------------------

local V = {}
H.vdp = V
local vdp_device = machine.devices[":vdp"]
local vram = vdp_device.spaces["vram"]
V.vram_space = vram -- for taps; reads through it have no side effects
local registers = emu.item(vdp_device.items["0/m_cont_reg"])

-- Mode number as the V9958 decodes it: M5:M3 from R#0 D3:D1, M1:M2 from R#1 D4:D3.
local MODES = {
    [0x00] = "GRAPHIC1", [0x01] = "MULTICOLOR", [0x02] = "TEXT1", [0x04] = "GRAPHIC2",
    [0x08] = "GRAPHIC3", [0x0a] = "TEXT2", [0x0c] = "GRAPHIC4", [0x10] = "GRAPHIC5",
    [0x14] = "GRAPHIC6", [0x1c] = "GRAPHIC7",
}
-- Name-table modes: columns and the table base from R#2.
local NAME_TABLES = {
    TEXT1 = { 40, 0x7f }, TEXT2 = { 80, 0x7c },
    GRAPHIC1 = { 32, 0x7f }, GRAPHIC2 = { 32, 0x7f }, GRAPHIC3 = { 32, 0x7f },
}

function V.reg(n)
    return registers:read(n)
end

function V.mode()
    local n = ((V.reg(0) & 0x0e) << 1) | ((V.reg(1) & 0x18) >> 3)
    return MODES[n] or string.format("unknown mode %02X", n)
end

function V.vram(address)
    return vram:read_u8(address)
end

-- The screen as name-table rows, read from VRAM: one string per row of the
-- character codes (as bytes). Bitmap modes hold no character codes, so they
-- return nil and the reason; the GRAPHIC6 consoles are read by V.console.
function V.text()
    local mode = V.mode()
    local layout = NAME_TABLES[mode]
    if not layout then
        return nil, mode .. " holds no name table; text decoding is unsupported"
    end
    local columns, mask = layout[1], layout[2]
    local base = (V.reg(2) & mask) << 10
    local rows = (V.reg(9) & 0x80) ~= 0 and 27 or 24
    local out = {}
    for row = 0, rows - 1 do
        local codes = {}
        for column = 0, columns - 1 do
            codes[#codes + 1] = string.char(vram:read_u8(base + row * columns + column))
        end
        out[#out + 1] = table.concat(codes)
    end
    return out
end

-- Wait until text appears in the name table; returns the 1-based row and column.
function V.wait_text(text, timeout)
    local found = H.wait(function()
        local rows = V.text()
        if not rows then return nil end
        for row, line in ipairs(rows) do
            local column = line:find(text, 1, true)
            if column then return { row, column } end
        end
    end, timeout, string.format("%q in VDP name-table text", text))
    return found[1], found[2]
end

-- The rendered bitmap of the visible area: (string of 32-bit pixels, width, height).
function V.pixels()
    return machine.screens[":screen"]:pixels()
end

-- Save the rendered screen as a PNG (absolute path, or relative to the case directory).
function V.snapshot(name)
    local path = name:sub(1, 1) == "/" and name or (H.dir .. "/" .. name)
    local err = machine.screens[":screen"]:snapshot(path)
    H.check(err == nil, "snapshot %s failed: %s", path, tostring(err))
    return path
end

-- GRAPHIC6 console text ----------------------------------------------------------
--
-- Both guests' consoles draw 6x8 glyphs into a GRAPHIC6 bitmap (KonaOS
-- drivers/v9958/v9958_driver.h, ZSDOS drivers/console/v9958.asm, default
-- 85x26 mode): page 0 is a circular 256-line surface, logical text row r
-- starts at scanline origin + 8r (mod 256), R#23 = origin - 4 (four margin
-- lines above row 0), column c covers pixels 6c..6c+5, i.e. the three bytes
-- 3c..3c+2 of a 256-byte line, left pixel in the high nibble.  Paper is
-- colour 4 and ink colour F; a reverse-video cell swaps them.
--
-- V.console reads that bitmap from VRAM through the vdp's own address space
-- (MAME stores GRAPHIC6/7 VRAM interleaved, as the V9958 does: logical byte
-- L lives at ((L & 1) << 16) | (L >> 1), v9938.cpp vram_write) and R#23 from
-- the saved register file.  It does no port I/O and reads no status
-- register, so it changes nothing the guest can see.  Each cell's eight
-- ink rows are matched exactly against the guest's own font (the 2048-byte
-- glyph-major file tests/guest_font.py extracts from the flash image), then
-- with ink and paper swapped for a reverse cell.  A cell that matches no
-- glyph either way (a graphic drawn over text, a half-drawn glyph) is
-- reported as unknown; the sprite cursor and pointer are not in the bitmap.
-- A cell inked all over reads as a reverse-video space: it is pixel for
-- pixel the full block (CP850 DBh), which libtui, KonaEdit and KonaCommander
-- never draw (their bars are reverse spaces).
-- Screens the console does not draw (other modes, other pages, graphics)
-- are compared by snapshot instead (V.snapshot).
local C = { columns = 85, rows = 26, cell_width = 6, cell_height = 8, offset = 4, paper = 0x4 }
V.console = C
C.UNKNOWN = "\1"
local FULL_CELL = string.rep("\252", C.cell_height) -- every row FCh

-- Load the font file (256 glyphs x 8 row bytes, pixels in bits 7..2).  When
-- several codes share a bitmap, printable ASCII wins, then the lowest code.
function C.load_font(path)
    local f = assert(lio.open(path, "rb"))
    local data = f:read("a")
    f:close()
    H.check(#data == 256 * C.cell_height, "font %s holds %d bytes", path, #data)
    local glyphs = {}
    local order = {}
    for code = 0x20, 0x7e do order[#order + 1] = code end
    for code = 0, 255 do
        if code < 0x20 or code > 0x7e then order[#order + 1] = code end
    end
    for _, code in ipairs(order) do
        local rows = {}
        for r = 1, C.cell_height do
            rows[r] = string.char(data:byte(code * C.cell_height + r) & 0xfc)
        end
        local key = table.concat(rows)
        if glyphs[key] == nil then glyphs[key] = code end
    end
    C.glyphs = glyphs
end

-- One logical 256-byte bitmap line of page 0 as an array of byte values.
local function g6_line(y)
    local even = vram:read_range(y * 128, y * 128 + 127, 8)
    local odd = vram:read_range(0x10000 + y * 128, 0x10000 + y * 128 + 127, 8)
    local bytes = {}
    for i = 1, 128 do
        bytes[2 * i - 1] = even:byte(i)
        bytes[2 * i] = odd:byte(i)
    end
    return bytes
end

-- The console as text: rows (strings of character codes; C.UNKNOWN for a
-- cell matching no glyph), reverse (strings of "r"/" " per cell) and the
-- number of unknown cells.  nil and the reason when the VDP is not showing
-- a page-0 GRAPHIC6 console.
function C.read()
    H.check(C.glyphs ~= nil, "console font not loaded")
    local mode = V.mode()
    if mode ~= "GRAPHIC6" then
        return nil, mode .. " is not the GRAPHIC6 console"
    end
    if (V.reg(2) & 0x20) ~= 0 then
        return nil, "R#2 shows page 1, not the console page"
    end
    local linemask = ((V.reg(2) & 0x1f) << 3) | 7
    local origin = (V.reg(23) + C.offset) & 0xff
    local pair = {}
    for b = 0, 255 do
        pair[b] = (((b >> 4) ~= C.paper) and 2 or 0) | (((b & 15) ~= C.paper) and 1 or 0)
    end
    local glyphs, ink_rows = C.glyphs, {}
    local rows, reverse, unknown = {}, {}, 0
    for row = 0, C.rows - 1 do
        local cells = {}
        for c = 1, C.columns do cells[c] = {} end
        for k = 0, C.cell_height - 1 do
            local line = g6_line((origin + row * C.cell_height + k) & linemask)
            for c = 0, C.columns - 1 do
                local i = 3 * c + 1
                cells[c + 1][k + 1] = (pair[line[i]] << 6) | (pair[line[i + 1]] << 4) | (pair[line[i + 2]] << 2)
            end
        end
        local codes, attrs = {}, {}
        for c = 1, C.columns do
            local m = cells[c]
            local key = string.char(m[1], m[2], m[3], m[4], m[5], m[6], m[7], m[8])
            local code, rev = glyphs[key], " "
            if key == FULL_CELL then
                code, rev = 0x20, "r"
            elseif code == nil then
                key = string.char(m[1] ~ 0xfc, m[2] ~ 0xfc, m[3] ~ 0xfc, m[4] ~ 0xfc,
                    m[5] ~ 0xfc, m[6] ~ 0xfc, m[7] ~ 0xfc, m[8] ~ 0xfc)
                code, rev = glyphs[key], "r"
            end
            if code == nil then
                code, rev, unknown = 1, "?", unknown + 1
            end
            codes[c] = string.char(code)
            attrs[c] = rev
        end
        rows[row + 1] = table.concat(codes)
        reverse[row + 1] = table.concat(attrs)
    end
    C.last = { rows = rows, reverse = reverse, unknown = unknown, time = H.now() }
    return rows, reverse, unknown
end

-- A row for a transcript: printable ASCII as is, other codes '.', unknown '?'.
function C.printable(line)
    return (line:gsub("[^\32-\126]", function(c) return c == C.UNKNOWN and "?" or "." end))
end

-- The first row (1-based) and column holding `text`, or nil; `rows` defaults
-- to a fresh read.
function C.find(text, rows)
    rows = rows or C.read()
    if not rows then return nil end
    for row, line in ipairs(rows) do
        local column = line:find(text, 1, true)
        if column then return row, column end
    end
    return nil
end

-- Wait until `text` is on the console; reads every `every` frames (default
-- 3).  Returns the row, the column and the emulated time it was first seen.
function C.wait(text, timeout, what, every)
    every = every or 3
    local frames = 0
    local found = H.wait(function()
        frames = frames + 1
        if frames % every ~= 1 and every > 1 then return nil end
        local row, column = C.find(text)
        return row and { row, column, H.now() }
    end, timeout, what or string.format("%q on the GRAPHIC6 console", text))
    return found[1], found[2], found[3]
end

-- Wait until `predicate(rows, reverse)` holds on the console.
function C.wait_for(predicate, timeout, what, every)
    every = every or 3
    local frames = 0
    return H.wait(function()
        frames = frames + 1
        if frames % every ~= 1 and every > 1 then return nil end
        local rows, reverse = C.read()
        return rows and predicate(rows, reverse)
    end, timeout, what)
end

-- Write the screen as text (and the reverse-video map) to the case
-- directory; returns the path.
function C.dump(name)
    local rows, reverse, unknown = C.read()
    local path = H.dir .. "/" .. name
    local f = assert(lio.open(path, "w"))
    if not rows then
        f:write(string.format("no console: %s\n", reverse))
    else
        f:write(string.format("# %.6f emulated s, R#23 %02X, %d unknown cells\n", H.now(), V.reg(23), unknown))
        for i, line in ipairs(rows) do
            f:write(string.format("%2d |%s|  %s\n", i, C.printable(line), reverse[i]:find("[r?]") and reverse[i] or ""))
        end
    end
    f:close()
    return path
end

-- USB keyboard -------------------------------------------------------------------
--
-- Input goes through MAME's input path: the keyboard device's fields (one per
-- HID usage, :ioc:keyboard), set and cleared with ioport_field:set_value,
-- which the next frame's input update applies like a host key.  Every change
-- is logged to the case's input manifest (inputs.tsv) with its emulated time.
local K = { by_usage = {}, down = {}, log = nil, hold = 2, gap = 2 }
H.keyboard = K

-- US legends of the firmware's table (TinyUSB HID_KEYCODE_TO_ASCII): the
-- usage and Shift for each printable character.
local US = {}
do
    local lower = "abcdefghijklmnopqrstuvwxyz1234567890"
    local upper = "ABCDEFGHIJKLMNOPQRSTUVWXYZ!@#$%^&*()"
    for i = 1, #lower do
        US[lower:sub(i, i)] = { 0x03 + i, false }
        US[upper:sub(i, i)] = { 0x03 + i, true }
    end
    local plain, shifted = " -=[]\\;'`,./", " _+{}|:\"~<>?"
    local usages = { 0x2c, 0x2d, 0x2e, 0x2f, 0x30, 0x31, 0x33, 0x34, 0x35, 0x36, 0x37, 0x38 }
    for i = 1, #plain do
        US[plain:sub(i, i)] = { usages[i], false }
        if i > 1 then US[shifted:sub(i, i)] = { usages[i], true } end
    end
    US["\r"] = { 0x28, false }
    US["\t"] = { 0x2b, false }
    US["\b"] = { 0x2a, false }
end
K.US = US

local function keyboard_fields()
    for tag, port in pairs(machine.ioport.ports) do
        local index = tag:match("^:ioc:keyboard:KEYS(%d)$")
        local base = index and tonumber(index) * 16 or (tag == ":ioc:keyboard:MODIFIERS" and 0xe0)
        if base then
            for name, field in pairs(port.fields) do
                local bit = 0
                while (field.mask >> bit) & 1 == 0 do bit = bit + 1 end
                K.by_usage[base + bit] = field
                K.by_usage[name] = base + bit
            end
        end
    end
end
keyboard_fields()

-- A usage number or a field name ("Left Shift", "Enter", "Up", ...).
function K.usage(key)
    local usage = type(key) == "number" and key or K.by_usage[key]
    H.check(usage and K.by_usage[usage], "no keyboard field %s", tostring(key))
    return usage
end

function K.set(key, down)
    local usage = K.usage(key)
    local field = K.by_usage[usage]
    field:set_value(down and 1 or 0)
    K.down[usage] = down or nil
    if not K.log then
        K.log = assert(lio.open(H.dir .. "/inputs.tsv", "w"))
        K.log:write("emulated_s\tusage\tfield\tstate\n")
    end
    K.log:write(string.format("%.6f\t%02X\t%s\t%s\n", H.now(), usage, field.name, down and "down" or "up"))
    K.log:flush()
end

-- Wait `n` emulated frames (inside a case body).
function K.frames(n)
    for _ = 1, n do coroutine.yield() end
end

-- Press the keys of a chord in order, hold them `hold` frames, release in
-- reverse order, then wait `gap` frames.
function K.chord(keys, hold, gap)
    for _, key in ipairs(keys) do K.set(key, true) end
    K.frames(hold or K.hold)
    for i = #keys, 1, -1 do K.set(keys[i], false) end
    K.frames(gap or K.gap)
end

function K.tap(key, hold, gap)
    K.chord({ key }, hold, gap)
end

-- Type printable text (and CR, TAB, BS) on the US layout, Shift as needed.
function K.type(text, hold, gap)
    for i = 1, #text do
        local ch = text:sub(i, i)
        local map = US[ch]
        H.check(map, "no key types %q", ch)
        if map[2] then
            K.chord({ "Left Shift", map[1] }, hold, gap)
        else
            K.tap(map[1], hold, gap)
        end
    end
end

-- Release every key (the harness ends with nothing held).
function K.release_all()
    local held = {}
    for usage in pairs(K.down) do held[#held + 1] = usage end
    for _, usage in ipairs(held) do K.set(usage, false) end
end

-- Verdict ----------------------------------------------------------------------

local function diagnostics()
    local state = H.cpu.state
    print(string.format("DIAG case %s", H.case))
    print(string.format("DIAG emulated %.6f s", H.now()))
    print(string.format("DIAG PC %04X SP %04X I %02X latch %02X", state["PC"].value, state["SP"].value,
        state["I"].value, latch_item:read(0)))
    print(string.format("DIAG waiting for %s", waiting_for or "nothing"))
    print(string.format("DIAG vdp %s", V.mode()))
    if C.glyphs then
        local rows, why = C.read()
        if not rows then
            print("DIAG console " .. why)
        else
            for i, line in ipairs(rows) do
                if line:find("[^ ]") then print(string.format("DIAG console %2d |%s|", i, C.printable(line))) end
            end
        end
    end
    print(string.format("DIAG serial %d bytes received, last at %s; tail %s", #S.data,
        S.last and string.format("%.3f s", S.last) or "never", H.escape(S.tail())))
end

function H.finish(ok, detail)
    if done then return end
    done = true
    if not ok then diagnostics() end
    print(string.format("TRACE emulated %.6f s", H.now()))
    print((ok and "PASS" or "FAIL") .. " harness " .. H.case .. ": " .. detail)
    S.close()
    if K.log then K.log:close() end
    machine:exit()
end

-- A case failure's message, or a Lua error with the traceback of `thread`.
local function report(err, thread)
    if type(err) == "table" and err.harness then return err.harness end
    if thread then return "Lua error: " .. debug.traceback(thread, tostring(err)) end
    return "Lua error: " .. debug.traceback(tostring(err))
end

local function step()
    S.poll()
    if coroutine.status(body) == "suspended" then
        local ok, err = coroutine.resume(body)
        if not ok then
            H.finish(false, report(err, body))
            return
        end
    end
    if coroutine.status(body) == "dead" then
        H.finish(false, "case body ended without a verdict")
    elseif H.now() > H.deadline then
        H.finish(false, string.format("emulated deadline %.1f s reached", H.deadline))
    end
end

local cases = {}
function H.case_body(name, fn)
    cases[name] = fn
end

local ok, err = xpcall(function() dofile(assert(os.getenv("HARNESS_SCRIPT"), "HARNESS_SCRIPT")) end, report)
if not ok then
    H.finish(false, err)
    return
end
local fn = cases[H.case]
if not fn then
    H.finish(false, "no case body named " .. H.case)
    return
end
body = coroutine.create(function()
    local detail = fn(H)
    H.finish(true, detail or "")
end)
H.keep(emu.add_machine_frame_notifier(function()
    if done then return end
    local ran, failure = xpcall(step, report)
    if not ran then H.finish(false, failure) end
end))
