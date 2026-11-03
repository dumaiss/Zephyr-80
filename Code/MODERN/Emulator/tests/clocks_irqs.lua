-- license:BSD-3-Clause
-- Clock and interrupt probes. Observes the CPU's real IM2 acknowledges by
-- tapping vector-table reads; programs devices only through the machine's
-- own I/O handlers. No guest instruction or device patching.
if _G.clocks_irqs_started then return end
_G.clocks_irqs_started = true

local machine = manager.machine
local cpu = machine.devices[":maincpu"]
local mem = cpu.spaces["program"]
local io = cpu.spaces["io"]
local case = assert(os.getenv("CLKIRQ_CASE"))
local limit = tonumber(os.getenv("CLKIRQ_LIMIT") or "5")
local handles = {}
_G.clocks_irqs_handles = handles
local done = false

local TABLE, ENTRY, RXDATA, EXIT, MARK = 0x8000, 0x9000, 0x9001, 0x9002, 0x9003
local CASES = { channels = 1, timer = 2, baud = 3, overlap = 4, daisy = 5, pty = 6 }
local TRG = { [0] = 1843200, 3686400, 7372800, 7372800 }

local function now()
    return machine.time:as_double()
end

local function finish(ok, detail)
    if done then return end
    done = true
    print(string.format("TRACE emulated %.6f s", now()))
    print((ok and "PASS" or "FAIL") .. " clocks-irqs " .. case .. ": " .. detail)
    machine:exit()
end

local function guarded(fn)
    return function(...)
        if done then return end
        local ok, err = xpcall(fn, debug.traceback, ...)
        if not ok then finish(false, err) end
    end
end

local function us(seconds)
    return string.format("%.3f us", seconds * 1e6)
end

-- Port to physical channel, from the IO board nets: CS0 = A1, CS1 = A0.
local function channel(port)
    return ((port & 1) << 1) | ((port >> 1) & 1)
end

-- Event stream: acknowledges (vector-table reads) and handler mailboxes.
local acks, exits, marks = {}, {}, {}
local on_ack, on_exit, on_mark, on_rx = nil, nil, nil, nil

local function tap_probe()
    local low = nil
    handles[#handles + 1] = mem:install_read_tap(TABLE, TABLE + 0x101, "clkirq-vector", guarded(function(offset, data)
        if low == nil then
            low = offset
            local ack = { vector = offset - TABLE, t = now() }
            acks[#acks + 1] = ack
            if on_ack then on_ack(ack) end
        else
            assert(offset == low + 1, string.format("vector read pair %04x/%04x", low, offset))
            low = nil
        end
    end))
    handles[#handles + 1] = mem:install_write_tap(ENTRY, MARK, "clkirq-mailbox", guarded(function(offset, data)
        local event = { value = data & 0xff, t = now() }
        if offset == ENTRY then
            assert(event.value ~= 0x99, "unexpected IM2 vector")
        elseif offset == EXIT then
            exits[#exits + 1] = event
            if on_exit then on_exit(event) end
        elseif offset == MARK then
            marks[#marks + 1] = event
            if on_mark then on_mark(event) end
        elseif offset == RXDATA and on_rx then
            on_rx(event)
        end
    end))
    handles[#handles + 1] = emu.add_machine_frame_notifier(guarded(function()
        if now() > limit then finish(false, string.format("no verdict by %.1f emulated seconds", limit)) end
    end))
end

local function between(list, from, to)
    local out = {}
    for _, e in ipairs(list) do
        if e.t > from and e.t < to then out[#out + 1] = e end
    end
    return out
end

-- Every port 40h-4Fh: write/read conversion and counter-mode trigger clock.
local function channels()
    local base = { [0] = 0x40, 0x42, 0x41, 0x43 }
    local index, start = 0, 0
    local function start_port()
        index = index + 1
        if index > 16 then
            finish(true, "16 ports: A0*2+A1 channel select, A3:A2 mirrors, read/write agree; TRG0-3 1.8432/3.6864/7.3728/7.3728 MHz")
            return
        end
        local port = 0x3f + index
        start = #acks + 1
        io:write_u8(port, 0xc5) -- interrupt, counter, falling edge, constant follows
        io:write_u8(port, 0x00) -- 256
    end
    on_mark = function(m)
        assert(m.value == 1)
        local constants = { [0] = 0x11, 0x22, 0x33, 0x44 }
        for ch = 0, 3 do
            io:write_u8(base[ch], 0x47)
            io:write_u8(base[ch], constants[ch])
            io:write_u8(base[ch], 0x43) -- reset freezes the count for read-back
        end
        for port = 0x40, 0x4f do
            local value, want = io:read_u8(port), constants[channel(port)]
            assert(value == want or value == want + 1, string.format("read %02x = %02x, want channel %d (%02x)", port, value, channel(port), want))
        end
        for ch = 0, 3 do io:write_u8(base[ch], 0x03) end
        io:write_u8(0x40, 0x00) -- vector base, channel 0
        print("TRACE read-back: every port reads the channel its writes program")
        start_port()
    end
    on_ack = function(ack)
        local port = 0x3f + index
        local ch = channel(port)
        assert(ack.vector == ch * 2, string.format("port %02x acknowledged vector %02x, want %02x", port, ack.vector, ch * 2))
        if #acks - start + 1 == 34 then
            io:write_u8(port, 0x03)
            local period = (acks[#acks].t - acks[start + 2].t) / 31
            local want = 256 / TRG[ch]
            assert(math.abs(period / want - 1) < 1e-3, string.format("port %02x period %s, want %s", port, us(period), us(want)))
            print(string.format("TRACE port %02x -> ch%d vector %02x period %s (%.1f Hz trigger)", port, ch, ack.vector, us(period), 256 / period))
            start_port()
        end
    end
end

-- KonaOS tick programming from the CPU: 156.25 Hz over 625 periods.
local function timer()
    local first = nil
    on_ack = function(ack)
        assert(ack.vector == 0x04, string.format("vector %02x", ack.vector))
        if #acks == 10 then
            local count = io:read_u8(0x41)
            assert(count >= 245 and count <= 251, "ch2 read-back after reload " .. count)
            print("TRACE ch2 read-back after reload " .. count)
        end
        if #acks == 626 then
            local span = acks[626].t - acks[1].t
            local rate = 625 / span
            local low, high = math.huge, 0
            for i = 2, 626 do
                local d = acks[i].t - acks[i - 1].t
                low, high = math.min(low, d), math.max(high, d)
            end
            local windows = {}
            for w = 0, 3 do
                windows[#windows + 1] = #between(acks, acks[1].t + 0.0032 + w - 1e-9, acks[1].t + 0.0032 + w + 1)
            end
            local sum = windows[1] + windows[2] + windows[3] + windows[4]
            for _, n in ipairs(windows) do assert(n == 156 or n == 157, "ticks in one second " .. n) end
            assert(sum == 625, "ticks in four seconds " .. sum)
            assert(math.abs(rate - 156.25) < 1e-3, string.format("rate %.6f Hz", rate))
            assert(math.abs(low - 0.0064) < 2e-6 and math.abs(high - 0.0064) < 2e-6, "interval " .. us(low) .. " .. " .. us(high))
            finish(true, string.format("625 ticks in %.9f s = %.6f Hz; per-second %d/%d/%d/%d; interval %s .. %s", span, rate, windows[1], windows[2], windows[3], windows[4], us(low), us(high)))
        end
    end
end

-- CTC TO0 clocks SIO0/A: loopback character time at two constants.
local function baud()
    local pattern = { 0x55, 0xaa, 0x00, 0xff, 0x5a, 0xa5, 0x12, 0x80 }
    local segments, current = {}, nil
    on_mark = function(m)
        if m.value == 0xee then
            local detail = {}
            for _, s in ipairs(segments) do
                assert(#s.acks == 8 and #s.rx == 8, "segment " .. s.tc .. " received " .. #s.rx)
                local char = 160 * s.tc / 1843200
                for i = 1, 8 do assert(s.rx[i] == pattern[i], "byte " .. i) end
                for i = 2, 8 do
                    local d = s.acks[i] - s.acks[i - 1]
                    assert(math.abs(d - char) < 3e-6, string.format("TC %d character time %s, want %s", s.tc, us(d), us(char)))
                end
                local mean = (s.acks[8] - s.acks[1]) / 7
                assert(math.abs(mean / char - 1) < 5e-3, "mean " .. us(mean))
                detail[#detail + 1] = string.format("TC %d: %.1f baud (character %s)", s.tc, 10 / mean, us(mean))
            end
            assert(#segments == 2)
            finish(true, "SIO0/A loopback on CTC TO0, 8 bytes each; " .. table.concat(detail, "; "))
        else
            current = { tc = m.value, acks = {}, rx = {} }
            segments[#segments + 1] = current
        end
    end
    on_ack = function(ack)
        assert(ack.vector == 0x1c, string.format("vector %02x", ack.vector))
        current.acks[#current.acks + 1] = ack.t
    end
    on_rx = function(e)
        current.rx[#current.rx + 1] = e.value
    end
end

-- V9958 outside the chain and CTC ch2 inside it, requesting together.
local function overlap()
    local finish_at = nil
    on_mark = function(m)
        if m.value == 0xee then finish_at = m.t + 0.1 end
    end
    on_ack = function(ack)
        if not finish_at or ack.t < finish_at then return end
        local a, b, e = nil, {}, nil
        for _, m in ipairs(marks) do
            if m.value == 0xa1 then a = m.t elseif m.value == 0xb0 then b[#b + 1] = m.t elseif m.value == 0xee then e = m.t end
        end
        assert(a and e and #b == 10, "markers")
        local phase_a = between(acks, a, b[1])
        assert(#phase_a >= 1 and phase_a[1].vector == 0x04 and phase_a[1].t - a < 10e-6, "released V9958 request cleared the pending CTC request")
        for _, x in ipairs(phase_a) do assert(x.vector ~= 0xff, "V9958 acknowledged after its request was released") end
        local worst = 0
        for i, t in ipairs(b) do
            local window = between(acks, t, b[i + 1] or e)
            assert(#window >= 2, "repetition " .. i .. ": " .. #window .. " acknowledges")
            assert(window[1].vector == 0x04 and window[2].vector == 0xff, string.format("repetition %d order %02x,%02x", i, window[1].vector, window[2].vector))
            local exit = between(exits, window[1].t, window[2].t)
            assert(#exit == 1 and exit[1].value == 0x04, "repetition " .. i .. " CTC handler exit")
            local gap = window[2].t - exit[1].t
            assert(gap < 8e-6, string.format("repetition %d: V9958 acknowledged %s after the CTC RETI", i, us(gap)))
            worst = math.max(worst, gap)
        end
        local tail = between(acks, e, finish_at)
        local ctc, vdp, last = 0, 0, nil
        for _, x in ipairs(tail) do
            if x.vector == 0x04 then ctc = ctc + 1 elseif x.vector == 0xff then
                if last then assert(math.abs(x.t - last - 1 / 59.94) < 2e-4, "V9958 frame interval " .. us(x.t - last)) end
                vdp, last = vdp + 1, x.t
            else error(string.format("vector %02x", x.vector)) end
        end
        assert(ctc >= 15 and ctc <= 16 and vdp >= 5 and vdp <= 7, string.format("free-running counts CTC %d V9958 %d", ctc, vdp))
        finish(true, string.format("released V9958 keeps CTC pending; 10/10 CTC 04h then V9958 FFh, V9958 within %s of RETI; free-running 100 ms CTC %d V9958 %d", us(worst), ctc, vdp))
    end
end

-- CTC > SIO0 > SIO1 priority, nesting and RETI release.
local function daisy()
    local start = nil
    on_mark = function(m)
        if m.value == 0xe0 then start = m.t end
    end
    on_ack = function(ack)
        if not start or ack.t < start + 0.005 then return end
        local list = between(acks, start, ack.t)
        local function only(v)
            local found = nil
            for _, x in ipairs(list) do
                if x.vector == v then assert(not found, string.format("vector %02x twice", v)); found = x end
            end
            return assert(found, string.format("vector %02x missing", v))
        end
        local function exit_of(v, after)
            for _, x in ipairs(exits) do
                if x.value == v and x.t > after then return x end
            end
            error(string.format("no exit %02x", v))
        end
        assert(list[1].vector == 0x04, string.format("first %02x", list[1].vector))
        local sio0, sio1 = only(0x10), only(0x20)
        local first_exit = exit_of(0x04, list[1].t)
        local sio0_exit = exit_of(0x10, sio0.t)
        assert(sio0.t > first_exit.t, "SIO0 acknowledged while the CTC was in service")
        assert(sio1.t > sio0_exit.t, "SIO1 acknowledged before SIO0's RETI")
        local nested = between(list, sio0.t, sio0_exit.t)
        assert(#nested >= 1, "CTC did not nest inside SIO0's service")
        for _, x in ipairs(nested) do assert(x.vector == 0x04, string.format("nested %02x", x.vector)) end
        for _, x in ipairs(list) do assert(x.vector == 0x04 or x.vector == 0x10 or x.vector == 0x20, string.format("vector %02x", x.vector)) end
        finish(true, string.format("order CTC 04h, SIO0 10h (+%s), SIO1 20h %s after SIO0 RETI; %d CTC nested in SIO0 service",
            us(sio0.t - list[1].t), us(sio1.t - sio0_exit.t), #nested))
    end
end

-- Current guests: SIO1 interrupt enables stay clear (WR1 pointer decode).
local function guest()
    local ptr, wr1, writes, reads, violations = { [0] = 0, 0 }, { [0] = {}, {} }, 0, 0, {}
    local ctc, tick, tick_acks = {}, nil, {}
    handles[#handles + 1] = io:install_write_tap(0x30, 0x3f, "clkirq-sio1-w", guarded(function(offset, data)
        local o = offset & 3
        writes = writes + 1
        if o & 1 == 0 then return end
        local ch = (o >> 1) & 1
        data = data & 0xff
        if ptr[ch] == 0 then
            ptr[ch] = data & 7
        else
            if ptr[ch] == 1 then
                wr1[ch][#wr1[ch] + 1] = data
                if data & 0x1b ~= 0 then violations[#violations + 1] = string.format("%s WR1=%02x at %.6f", ch == 0 and "A" or "B", data, now()) end
            end
            ptr[ch] = 0
        end
    end))
    handles[#handles + 1] = io:install_read_tap(0x30, 0x3f, "clkirq-sio1-r", guarded(function(offset, data)
        reads = reads + 1
        if offset & 1 == 1 then ptr[((offset & 3) >> 1) & 1] = 0 end
    end))
    handles[#handles + 1] = io:install_write_tap(0x40, 0x4f, "clkirq-ctc-w", guarded(function(offset, data)
        local ch = channel(offset & 3)
        data = data & 0xff
        ctc[#ctc + 1] = string.format("%02x:ch%d=%02x", offset & 0xff, ch, data)
        if ch == 2 and data == 250 and #ctc >= 2 and ctc[#ctc - 1]:match("ch2=a5$") and not tick then
            tick = (cpu.state["I"].value << 8) | 0x04
            handles[#handles + 1] = mem:install_read_tap(tick, tick, "clkirq-guest-tick", guarded(function()
                tick_acks[#tick_acks + 1] = now()
            end))
        end
    end))
    handles[#handles + 1] = emu.add_machine_frame_notifier(guarded(function()
        if now() < limit - 0.05 then return end
        local rate = "no CTC ch2 tick programmed"
        if tick and #tick_acks >= 2 then
            rate = string.format("ch2 tick %d acknowledges at %04x, %.4f Hz", #tick_acks, tick, (#tick_acks - 1) / (tick_acks[#tick_acks] - tick_acks[1]))
        end
        local w = {}
        for ch = 0, 1 do
            local v = {}
            for _, x in ipairs(wr1[ch]) do v[#v + 1] = string.format("%02x", x) end
            w[#w + 1] = (ch == 0 and "A" or "B") .. " WR1 [" .. table.concat(v, " ") .. "]"
        end
        print("TRACE CTC writes " .. table.concat(ctc, " "))
        local detail = string.format("%d SIO1 writes, %d reads; %s; %s", writes, reads, table.concat(w, ", "), rate)
        if #violations > 0 then finish(false, "SIO1 interrupt enabled: " .. table.concat(violations, ", ") .. "; " .. detail)
        elseif writes == 0 then finish(false, "guest never programmed SIO1; " .. detail)
        else finish(true, "SIO1 interrupt enables stay clear; " .. detail) end
    end))
end

if case == "konaos" or case == "zsdos" then
    guest()
else
    local setup = { channels = channels, timer = timer, baud = baud, overlap = overlap, daisy = daisy }
    if case ~= "pty" then
        tap_probe()
        assert(setup[case], "unknown case " .. case)()
    end
    mem:write_u8(0x7f01, 12)
    mem:write_u8(0x7f02, 1)
    mem:write_u8(0x7f00, CASES[case])
end
