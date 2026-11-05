-- license:BSD-3-Clause
-- Sound card case bodies for harness.lua (tests/sound.py runs them).
--
-- The Afternoon Blend card is write-only, so every stimulus is a write to the
-- I/O space (E0h-FFh) and every observation is the audio the machine produces
-- (MAME -wavwrite, analysed by sound.py) plus the register events this file
-- logs: events.tsv holds each write and read of the block (emulated time,
-- port, value) and each phase (name, parameters, start and end time).
--
--   sound-bus     Lua drives the bus: per-chip tones, the port mirrors, unwired
--                 ports, simultaneous chips and per-chip silence, the noise
--                 generator, the DAC codes, loud mixes
--   sound-guest   the probe program (sound.asm) drives the bus with real Z80
--                 instructions: OTIR timing, reads of E0h-FFh, OUT (C),A, then
--                 a machine reset with a tone and the DAC loud
local lio = io
local H = harness
local mem = H.program

local EVENTS
local events_file

local function log_events()
    events_file = assert(lio.open(H.dir .. "/events.tsv", "w"))
    events_file:write("kind\ttime\ta\tb\tc\td\n")
    H.keep(H.io:install_write_tap(0xe0, 0xff, "sound-w", function(offset, data)
        events_file:write(string.format("W\t%.9f\t%02X\t%02X\t\n", H.now(), offset, data))
    end))
    H.keep(H.io:install_read_tap(0xe0, 0xff, "sound-r", function(offset, data)
        events_file:write(string.format("R\t%.9f\t%02X\t%02X\t\n", H.now(), offset, data))
    end))
end

local function frames(n)
    for _ = 1, n do coroutine.yield() end
end

local function io_w(port, value)
    H.io:write_u8(port, value)
end

-- One chip's port with a mirror (0-3): E0h + 8m + chip.
local function psg_port(chip, mirror)
    return 0xe0 + 8 * (mirror or 0) + chip
end

local function psg(chip, value, mirror)
    io_w(psg_port(chip, mirror), value)
end

local DAC = 0xe4
local function silence(chip)
    for _, b in ipairs({ 0x9f, 0xbf, 0xdf, 0xff }) do psg(chip, b) end
end
local function silence_all()
    for chip = 0, 3 do silence(chip) end
    io_w(DAC, 0x80)
end

local function tone(chip, channel, divisor, attenuation, mirror)
    psg(chip, 0x80 | (channel << 5) | (divisor & 15), mirror)
    psg(chip, divisor >> 4, mirror)
    psg(chip, 0x90 | (channel << 5) | (attenuation or 0), mirror)
end

local function quiet(chip, channel, mirror)
    psg(chip, 0x90 | (channel << 5) | 15, mirror)
end

local function phase(name, params, count, setup)
    local pre = H.now()
    if setup then setup() end
    local t0 = H.now()
    frames(count)
    local t1 = H.now()
    events_file:write(string.format("P\t%.9f\t%s\t%s\t%.9f\t%.9f\n", t0, name, params, t1, pre))
    events_file:flush()
end

-- Divisors by chip and channel (single-chip phases, no two alike).
local function divisor(chip, channel)
    return 180 + 23 * chip + 61 * channel
end

H.case_body("sound-bus", function()
    log_events()
    silence_all()
    frames(6)
    -- Calibration pulse: the DAC step against the audio's own time base.
    phase("cal", "", 8, function() io_w(DAC, 0xff) end)
    io_w(DAC, 0x80)
    phase("quiet", "", 8)

    -- Every tone channel of every chip alone through its own port.
    for chip = 0, 3 do
        for channel = 0, 2 do
            phase("tone", string.format("chip=%d channel=%d divisor=%d port=%02X", chip, channel, divisor(chip, channel), psg_port(chip)), 9, function()
                tone(chip, channel, divisor(chip, channel), 0)
            end)
            quiet(chip, channel)
        end
    end
    phase("quiet", "after-tones", 4)

    -- The mirrors: A3 and A4 are not decoded.
    for chip = 0, 3 do
        for mirror = 1, 3 do
            local d = 200 + 7 * (chip * 3 + mirror)
            phase("tone", string.format("chip=%d channel=0 divisor=%d port=%02X", chip, d, psg_port(chip, mirror)), 6, function()
                tone(chip, 0, d, 0, mirror)
            end)
            quiet(chip, 0, mirror)
        end
    end
    -- Ports 5-7 (and their mirrors) select nothing: loud tone data is lost.
    phase("unwired", "", 10, function()
        for mirror = 0, 3 do
            for port = 5, 7 do
                local p = 0xe0 + 8 * mirror + port
                io_w(p, 0x80 | 0x0a)
                io_w(p, 0x10)
                io_w(p, 0x90)
                io_w(p, 0xb0)
                io_w(p, 0xd0)
                io_w(p, 0xf0)
            end
        end
    end)

    -- Four chips at once, then each silenced alone.
    local together = { 211, 257, 307, 359 }
    phase("together", "all", 14, function()
        for chip = 0, 3 do tone(chip, 0, together[chip + 1], 0) end
    end)
    for chip = 0, 3 do
        phase("drop", string.format("chip=%d", chip), 10, function() quiet(chip, 0) end)
    end

    -- Attenuation: the 2 dB steps of one tone.
    phase("quiet", "before-attenuation", 4)
    for att = 0, 15 do
        phase("attenuation", string.format("chip=0 level=%d", att), 4, function()
            tone(0, 0, 254, att)
        end)
    end
    quiet(0, 0)

    -- Noise: tone 2 is silent; its divisor sets the rate 3 shift.  The
    -- control write resets the shift register, so its time anchors the
    -- sequence.
    local function noise(name, params, control, count, chip, mirror)
        phase(name, params, count, function()
            psg(chip, 0x80 | (2 << 5) | 0, mirror)   -- tone 2 divisor 180h: low 4 bits 0
            psg(chip, 0x18, mirror)
            psg(chip, 0xdf, mirror)                  -- tone 2 off
            psg(chip, 0xf0, mirror)                  -- noise full volume
            psg(chip, control, mirror)
        end)
    end
    noise("noise", string.format("chip=0 control=%02X", 0xe7), 0xe7, 75, 0)
    phase("noise", "chip=0 control=E7 again", 20, function() psg(0, 0xe7) end)
    phase("noise", "chip=0 control=E3 periodic", 20, function() psg(0, 0xe3) end)
    for rate = 0, 2 do
        phase("noise", string.format("chip=0 control=%02X", 0xe4 + rate), 6, function() psg(0, 0xe4 + rate) end)
    end
    noise("noise", "chip=3 control=E7 port=FB", 0xe7, 20, 3, 2)
    silence_all()
    phase("quiet", "after-noise", 6)

    -- DAC: 80h is zero; codes through the port and its mirrors.
    local codes = { 0x00, 0x01, 0x20, 0x40, 0x7f, 0x80, 0x81, 0xc0, 0xe0, 0xff }
    for i, code in ipairs(codes) do
        local port = DAC + 8 * ((i - 1) % 4)
        phase("dac", string.format("code=%02X port=%02X", code, port), 4, function() io_w(port, code) end)
    end
    io_w(DAC, 0x80)
    phase("quiet", "after-dac", 4)

    -- Loud mixes: every voice of every chip at full level, the DAC at an
    -- extreme.  Informational peaks; sound.py checks no clipping.
    phase("loud", "psg", 24, function()
        for chip = 0, 3 do
            for channel = 0, 2 do tone(chip, channel, 40 + 17 * chip + 9 * channel, 0) end
            psg(chip, 0xe7)
            psg(chip, 0xf0)
        end
    end)
    phase("loud", "psg+dac-high", 24, function() io_w(DAC, 0xff) end)
    phase("loud", "psg+dac-low", 24, function() io_w(DAC, 0x00) end)
    silence_all()
    phase("quiet", "end", 10)
    events_file:close()
    return "bus phases done"
end)

-- sound-guest -----------------------------------------------------------------

local CMD, PORT, COUNT, SRC, SCAN = 0x7f00, 0x7f01, 0x7f02, 0x7f10, 0x7f80

local function post(op, port, bytes)
    for i, b in ipairs(bytes) do mem:write_u8(SRC + i - 1, b) end
    mem:write_u8(PORT, port or 0)
    mem:write_u8(COUNT, op == 3 and #bytes // 2 or #bytes)
    mem:write_u8(CMD, op)
    H.wait(function() return mem:read_u8(CMD) == 0 end, 2, "the probe to finish operation " .. op)
end

H.case_body("sound-guest", function()
    log_events()
    -- The probe is ready once it has switched to flat mode and cleared CMD.
    frames(4)
    silence_all()
    frames(6)

    -- OTIR: the driver's silence sequence to every PSG, 4 bytes each, then 8 DAC
    -- bytes, back to back.
    phase("otir", "psg", 3, function()
        for chip = 0, 3 do post(1, 0xe0 + chip, { 0x9f, 0xbf, 0xdf, 0xff }) end
    end)
    phase("otir", "dac", 3, function()
        post(1, DAC, { 0x80, 0x90, 0xa0, 0xb0, 0xc0, 0xd0, 0xe0, 0x80 })
    end)

    -- Reads of the whole block while a tone sounds: all 7Fh (idle latches), the tone untouched.
    phase("reads", "tone chip=1 divisor=254", 10, function()
        tone(1, 0, 254, 0)
    end)
    mem:write_u8(SCAN, 0)
    post(2, 0, {})
    local scan = {}
    for i = 0, 31 do scan[#scan + 1] = string.format("%02X", mem:read_u8(SCAN + i)) end
    events_file:write(string.format("S\t%.9f\t%s\t\t\n", H.now(), table.concat(scan)))
    frames(6)
    quiet(1, 0)
    frames(4)

    -- OUT (C),A over mirrors: chip 3 tone through F3h, chip 2 through EAh, DAC through FCh.
    phase("guest-out", "chip=3 divisor=300 port=F3", 8, function()
        post(3, 0, { 0xf3, 0x80 | (300 & 15), 0xf3, 300 >> 4, 0xf3, 0x90 })
    end)
    post(3, 0, { 0xf3, 0x9f })
    phase("guest-out", "dac code=C0 port=FC", 5, function() post(3, 0, { 0xfc, 0xc0 }) end)
    post(3, 0, { 0xfc, 0x80 })

    -- Reset with a tone sounding and the DAC high: the DAC register clears, the
    -- PSG (no reset input) keeps playing.
    phase("pre-reset", "chip=0 divisor=300 dac=FF", 10, function()
        tone(0, 0, 300, 0)
        io_w(DAC, 0xff)
    end)
    local t_reset = H.now()
    H.machine:soft_reset()
    events_file:write(string.format("X\t%.9f\treset\t\t\n", t_reset))
    phase("post-reset", "chip=0 divisor=300", 12)
    silence_all()
    phase("quiet", "end", 10)
    events_file:close()
    return "guest phases done"
end)

-- Playback of the real clients ------------------------------------------------------
--
-- The production KonaOS image with a card image holding the clients, driven through
-- the USB keyboard and read off the GRAPHIC6 console (harness.vdp.console).
local C = H.vdp.console
local K = H.keyboard
if os.getenv("HARNESS_FONT") then C.load_font(os.getenv("HARNESS_FONT")) end

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
            local shown = C.printable(line):gsub("%s+$", "")
            if shown ~= "" then transcript:write(string.format("%2d %s\n", i, shown)) end
        end
    else
        transcript:write("(not the console: " .. tostring(select(2, C.read())) .. ")\n")
    end
    transcript:flush()
    H.vdp.snapshot(base .. ".png")
end

local function trimmed(line) return (line:gsub("%s+$", "")) end

local function screen_has(text)
    local rows = C.read()
    if not rows then return false end
    for _, line in ipairs(rows) do
        if line:find(text, 1, true) then return true end
    end
    return false
end

local function wait_text(text, timeout, what)
    return H.wait(function() return screen_has(text) end, timeout, what or string.format("%q on the console", text))
end

-- Wait for the shell prompt on a row of its own with nothing after it.
local function wait_prompt(timeout, what)
    H.wait(function()
        local rows = C.read()
        if not rows then return false end
        for i = #rows, 1, -1 do
            if trimmed(rows[i]) == "/>" then return true end
        end
        return false
    end, timeout, what or "the shell prompt")
end

local function run_command(line, timeout)
    K.type(line .. "\r")
    return H.now()
end

local function seconds(s)
    local until_ = H.now() + s
    H.wait(function() return H.now() >= until_ end, s + 5, "a pause")
end

local function boot()
    log_events()
    wait_text("/>", 30, "the KonaOS shell prompt at the card root")
    shot("prompt")
    events_file:write(string.format("X\t%.9f\tprompt\t\t\n", H.now()))
end

-- Program names and card paths the runner took from the build manifests.
local SNDTEST = os.getenv("HARNESS_SNDTEST") or "sndtest"
local SNTVIEW = os.getenv("HARNESS_SNTVIEW") or "sntview"
local VGMPLAY = os.getenv("HARNESS_VGMPLAY") or "vgmplay"
local ZTR = os.getenv("HARNESS_ZTR") or "/fs/NIGHT.ZTR"
local ZVG = os.getenv("HARNESS_ZVG") or "/fs/NIGHT.ZVG"
local WRAPS = os.getenv("HARNESS_WRAPS") or "/fs/WRAPS.ZVG"

local function mark(name)
    events_file:write(string.format("X\t%.9f\t%s\t\t\n", H.now(), name))
    events_file:flush()
end

-- The text of the screen's rows as one string (for the exit reports).
local function screen_text()
    local rows = C.read()
    local out = {}
    for _, line in ipairs(rows or {}) do
        local t = trimmed(C.printable(line))
        if t ~= "" then out[#out + 1] = t end
    end
    return table.concat(out, "\n")
end

H.case_body("playback-sndtest", function()
    boot()
    local modes = {
        { "tones", "sndtest: tones PASS" }, { "adsr", "sndtest: adsr PASS" }, { "noise", "sndtest: noise PASS" },
        { "modes", "sndtest: modes PASS" }, { "catchup", "sndtest: catchup PASS" }, { "close", "sndtest: exit PASS" },
        { "zvg " .. WRAPS .. " 0", "sndtest: zvg PASS" },
    }
    for _, m in ipairs(modes) do
        mark("start " .. m[1])
        run_command(SNDTEST .. " " .. m[1])
        wait_text(m[2], 40, SNDTEST .. " " .. m[1] .. " result")
        wait_prompt(10, "the prompt after sndtest " .. m[1])
        mark("end " .. m[1])
        shot("sndtest-" .. m[1]:match("^%S+"))
        K.chord({ "Left Ctrl", "L" })
        seconds(0.7)
    end
    seconds(0.5)
    mark("done")
    events_file:close()
    return "sndtest modes passed"
end)

H.case_body("playback-sntview", function()
    boot()
    run_command(SNTVIEW .. " " .. ZTR)
    H.wait(function() return H.vdp.mode() ~= "GRAPHIC6" or not screen_has("sntview") end, 30, "sntview's screen")
    seconds(6)
    mark("view")
    mark("play")
    K.tap("P")
    seconds(10)
    mark("pause")
    K.tap("P")
    seconds(2)
    mark("resume")
    K.tap("P")
    seconds(4)
    mark("quit")
    K.tap("Q")
    wait_prompt(40, "the prompt after sntview")
    mark("prompt")
    shot("sntview-exit")
    seconds(1.5)
    mark("done")
    events_file:close()
    return "sntview played"
end)

H.case_body("playback-vgmplay", function()
    boot()
    run_command(VGMPLAY .. " " .. ZVG)
    mark("launch")
    seconds(12)
    mark("stop")
    K.tap("Q")
    wait_prompt(40, "the prompt after vgmplay")
    mark("prompt")
    shot("vgmplay-exit")
    seconds(1.5)
    mark("done")
    events_file:close()
    return "vgmplay played"
end)
