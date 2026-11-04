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
--   harness.vdp     V9958 registers, VRAM, name-table text and the rendered
--                   screen bitmap.
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
-- return nil and the reason.
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

-- Verdict ----------------------------------------------------------------------

local function diagnostics()
    local state = H.cpu.state
    print(string.format("DIAG case %s", H.case))
    print(string.format("DIAG emulated %.6f s", H.now()))
    print(string.format("DIAG PC %04X SP %04X I %02X latch %02X", state["PC"].value, state["SP"].value,
        state["I"].value, latch_item:read(0)))
    print(string.format("DIAG waiting for %s", waiting_for or "nothing"))
    print(string.format("DIAG vdp %s", V.mode()))
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
