-- license:BSD-3-Clause
-- Serial-console cases for the KonaOS console-serial image
-- (ZephyrOS `make console-serial-selftest`), whose whole console is SIO0/B.
-- The IOC model answers its LINK_SYNC and PING and no filesystem or HID
-- command, so the shell reports no filesystem and starts in /system.
local H = harness
local S = H.serial

-- The kernel's early banner (ZephyrOS tools/serial_smoke.py BANNER).
local BANNER = "KonaOS 0.0\r\nplatform: Zephyr-80\r\nkernel entry: OK\r\nserial: OK\r\n"
local CONSOLE_OK = "console: driver OK\r\n"
local BOOT_LIMIT = 90 -- emulated seconds from the first byte to the prompt

-- Port to physical CTC channel: CS0 = A1, CS1 = A0 (IO board nets).
local function ctc_channel(port)
    return ((port & 1) << 1) | ((port >> 1) & 1)
end

-- Attach, sync and wait for the shell prompt; returns the offset after it.
local function boot()
    S.attach(5)
    S.host_sync(10)
    local _, stop = S.wait(H.prompt, BOOT_LIMIT, 1, string.format("shell prompt %q", H.prompt))
    H.check(S.data:find(BANNER, 1, true), "the kernel banner is missing")
    H.check(S.data:find(CONSOLE_OK, 1, true), "no %q line", CONSOLE_OK)
    H.check(not S.data:find("PANIC", 1, true), "the boot transcript reports PANIC")
    H.trace("prompt %s at %.3f emulated s", H.escape(H.prompt), H.now())
    return stop + 1
end

-- Run one shell command; returns the offset of the response.
local function command(line, row, timeout)
    local from = S.type(line)
    local _, stop = S.wait(row, timeout, from, string.format("%q after %q", row, line))
    S.wait(H.prompt, timeout, stop + 1, string.format("prompt after %q", line))
    return from
end

H.case_body("serial-boot", function()
    local prompt_at = boot()
    local prompt_time = H.now()
    -- `pwd` answers with the working directory; no card keeps the shell in /system.
    local from = command("pwd", "\r\n/system\r\n", 5)
    H.check(not S.data:find("command not found", from, true), "the shell did not accept pwd")
    return string.format("prompt at %.3f emulated s after %d host syncs; pwd answered /system and the prompt returned at %.3f s",
        prompt_time, S.syncs, H.now())
end)

-- The runner's host session owns the pty in real time (throttled); this
-- side bounds it in emulated time and reports its verdict file.
H.case_body("serial-pty", function()
    local file = assert(os.getenv("HARNESS_HOST_FILE"), "HARNESS_HOST_FILE")
    local verdict = H.wait(function()
        local f = io.open(file, "rb")
        if not f then return nil end
        local text = f:read("a")
        f:close()
        return text:find("\n", 1, true) and text
    end, H.deadline, "the host session's verdict")
    local status, detail = verdict:match("^(%u+) (.-)\n")
    H.check(status == "PASS", "host session: %s", detail or verdict)
    return "host session: " .. detail
end)

-- /system/timer.exe on the guest's own CTC tick. Taps observe the CTC
-- programming and each channel-2 interrupt acknowledge (the IM2 vector
-- fetch); the guest's transcript gives its own counts and seconds.
H.case_body("timer", function()
    local writes = {}
    H.keep(H.io:install_write_tap(0x40, 0x4f, "harness-ctc", function(offset, data)
        writes[#writes + 1] = { t = H.now(), port = offset, data = data & 0xff }
    end))
    boot()

    -- Decode the CTC writes: control words (D0 = 1, a constant follows when
    -- D2 = 1), time constants, and the vector word (D0 = 0 on channel 0).
    local expect, control, constant, vector = {}, {}, {}, nil
    for _, w in ipairs(writes) do
        local ch = ctc_channel(w.port)
        if expect[ch] then
            constant[ch], expect[ch] = w.data, false
        elseif (w.data & 1) == 1 then
            control[ch], constant[ch] = { data = w.data, t = w.t }, nil
            expect[ch] = (w.data & 4) ~= 0
        elseif ch == 0 then
            vector = w.data & 0xf8
        end
    end
    H.check(control[2] and vector, "the guest never programmed CTC channel 2 and the vector (%d writes)", #writes)
    local c2 = control[2].data
    H.check((c2 & 0xc0) == 0x80, "channel 2 control %02X is not interrupt-enabled timer mode", c2)
    H.check(constant[2] ~= nil, "channel 2 has no time constant")
    local prescale = (c2 & 0x20) ~= 0 and 256 or 16
    local tc = constant[2] == 0 and 256 or constant[2]
    local programmed = 10e6 / prescale / tc
    H.trace("CTC channel 2 control %02X at %.3f s, constant %d, prescaler %d: 10 MHz / %d = %.4f Hz; vector base %02X",
        c2, control[2].t, tc, prescale, prescale * tc, programmed, vector)

    -- Acknowledges of channel 2's vector: the first of each two-byte fetch.
    local i_reg = H.cpu.state["I"].value
    local entry = (i_reg << 8) | (vector + 4)
    local acks = {}
    H.keep(H.program:install_read_tap(entry, entry, "harness-ctc2-ack", function(offset, data)
        acks[#acks + 1] = H.now()
    end))
    H.trace("tapping the channel-2 vector entry %04X (I = %02X)", entry, i_reg)

    -- `timer stage`: INFO constants, monotonic readings and a one-second advance.
    local from = command("timer stage", "timer: stage ", 30)
    local _, stop = S.wait(H.prompt, 5, from)
    local stage = S.data:sub(from, stop)
    local per_10s, per_tick, info = stage:match("timer: info (%d+) (%d+) (%u+)\r\n")
    H.check(info == "OK" and per_10s == "390625" and per_tick == "250", "timer stage info %s %s %s", tostring(per_10s), tostring(per_tick), tostring(info))
    H.check(stage:find("timer: mono 10000 OK\r\n", 1, true), "timer stage monotonic readings failed")
    local advance = tonumber(stage:match("timer: advance (%d+)\r\n"))
    -- ZephyrOS tests/test_timer.py: 39062 counts a second, poll slack 250.
    H.check(advance and advance >= 39062 and advance <= 39062 + 250, "timer stage advance %s outside 39062..39312", tostring(advance))
    H.check(stage:find("timer: stage PASS\r\n", 1, true), "timer stage verdict is not PASS")
    H.trace("timer stage PASS: info 390625 250, mono 10000, advance %d counts in 1 s", advance)

    -- Bare `timer`: one line a second for 60 s on the guest's clock.
    local first_ack = #acks + 1
    from = S.type("timer")
    local seconds = {}
    for n = 1, 60 do
        local _, b = S.wait(string.format("timer: %d s\r\n", n), 3, from, string.format("timer line %d", n))
        seconds[n] = H.now()
        from = b + 1
    end
    S.wait(H.prompt, 5, from, "prompt after timer")
    local last_ack = #acks
    local count = last_ack - first_ack + 1
    H.check(count > 9000, "only %d channel-2 acknowledges during the run", count)
    local span = acks[last_ack] - acks[first_ack]
    local rate = (count - 1) / span
    local shortest, longest = math.huge, 0
    for k = first_ack + 1, last_ack do
        local gap = acks[k] - acks[k - 1]
        shortest, longest = math.min(shortest, gap), math.max(longest, gap)
    end
    local per_second = {}
    for n = 2, 60 do
        local ticks = 0
        for k = first_ack, last_ack do
            if acks[k] > seconds[n - 1] and acks[k] <= seconds[n] then ticks = ticks + 1 end
        end
        per_second[#per_second + 1] = ticks
    end
    local lo, hi = math.huge, 0
    for _, ticks in ipairs(per_second) do lo, hi = math.min(lo, ticks), math.max(hi, ticks) end
    local line_mean = (seconds[60] - seconds[1]) / 59
    H.trace("timer run: %d acknowledges over %.6f s = %.4f Hz; intervals %.1f..%.1f us", count, span, rate, shortest * 1e6, longest * 1e6)
    H.trace("timer lines 1..60: mean spacing %.4f s; acknowledges between lines %d..%d", line_mean, lo, hi)
    H.check(math.abs(rate / 156.25 - 1) < 1e-3, "tick rate %.4f Hz, want 156.25 Hz", rate)
    H.check(longest < 1.5 / 156.25, "a %.1f us gap between acknowledges: a tick was lost", longest * 1e6)
    H.check(line_mean >= 0.99 and line_mean <= 1.05, "timer lines %.4f s apart", line_mean)
    return string.format("CTC2 programmed for %.2f Hz; %d acknowledges at %.4f Hz while timer.exe printed 60 seconds %.4f s apart; stage advance %d counts",
        programmed, count, rate, line_mean, advance)
end)
