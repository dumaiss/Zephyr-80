-- license:BSD-3-Clause
-- SIO1 lane cases (tests/sio1_lanes.py): lane probes against the probe
-- program sio1_lanes.asm, and the guests' own IOC paths with their
-- register/wire trace.  Runs under harness.lua.
local H = harness
local S = H.serial
local mem = H.program

-- Wire constants (Code/MCU/IOController include/ioc_frame.h).
local LINK_SYNC, PING = 0x0c, 0x01
local RSP_LINK_SYNC, RSP_PING, RSP_UNKNOWN = 0x8c, 0x81, 0xfe
local FW_LEVEL = 75
local POWER_SYNCED = 0x6f -- idle power handshake + IOC_PING_LINK_SYNCED

local function crc16(bytes, first, last)
    local crc = 0
    for i = first, last do
        crc = crc ~ (bytes[i] << 8)
        for _ = 1, 8 do
            crc = (crc & 0x8000) ~= 0 and (((crc << 1) ~ 0x1021) & 0xffff) or ((crc << 1) & 0xffff)
        end
    end
    return crc
end

local function packet(class, seq, data)
    local p = { 0xa5, 0x5a, 3 + #data, 0, class, seq, 0 }
    for _, v in ipairs(data) do p[#p + 1] = v end
    local crc = crc16(p, 3, #p)
    p[#p + 1] = crc >> 8
    p[#p + 1] = crc & 0xff
    return p
end

-- The first complete, CRC-valid packet in `bytes` (a Lua array), or nil and why.
local function parse(bytes)
    for i = 1, #bytes - 8 do
        if bytes[i] == 0xa5 and bytes[i + 1] == 0x5a then
            local length = bytes[i + 2] | (bytes[i + 3] << 8)
            local last = i + 3 + length
            if length >= 3 and length <= 29 and last + 2 <= #bytes then
                local crc = crc16(bytes, i + 2, last)
                if crc == ((bytes[last + 1] << 8) | bytes[last + 2]) then
                    local data = {}
                    for k = i + 7, last do data[#data + 1] = bytes[k] end
                    return { class = bytes[i + 4], seq = bytes[i + 5], status = bytes[i + 6], data = data, at = i }
                end
            end
        end
    end
    return nil
end

local function hx(bytes, first, last)
    local out = {}
    for i = first or 1, math.min(last or #bytes, #bytes) do out[#out + 1] = string.format("%02X", bytes[i]) end
    return table.concat(out, " ")
end

-- Probe program -------------------------------------------------------------

local MB = {
    CMD = 0x7f00, HUNT = 0x7f01, PKTLEN = 0x7f02, STALL_AT = 0x7f03, STALL_N = 0x7f04,
    EVENT_AT = 0x7f06, EVENT_N = 0x7f07, EVENT = 0x7f09, PKT2LEN = 0x7f0a, WR1VAL = 0x7f0b,
    RESULT = 0x7f10, RR0TX = 0x7f11, RR0END = 0x7f12, RR1END = 0x7f13, READYLO = 0x7f14,
    DRAINED = 0x7f16, RAWLEN = 0x7f19, RR0STALL = 0x7f1b,
    READYTX = 0x7f1c, IRQS = 0x7f20, PKT = 0x7e00, PKT2 = 0x7e40, RAW = 0x7d00,
}

local function poke(address, bytes)
    for i, v in ipairs(bytes) do mem:write_u8(address + i - 1, v) end
end

local function post(op, opts)
    opts = opts or {}
    mem:write_u8(MB.HUNT, opts.hunt and 1 or 0)
    mem:write_u8(MB.STALL_AT, opts.stall_at or 0)
    mem:write_u16(MB.STALL_N, opts.stall_n or 1)
    mem:write_u8(MB.EVENT_AT, opts.rxslow_at or opts.reset_at or 0)
    mem:write_u16(MB.EVENT_N, opts.rxslow_n or 1)
    mem:write_u8(MB.EVENT, opts.reset_at and 2 or 1)
    mem:write_u8(MB.WR1VAL, opts.wr1 or 0)
    mem:write_u8(MB.CMD, op)
    H.wait(function() return mem:read_u8(MB.CMD) == 0 end, 2, string.format("probe operation %d", op))
    -- Pairs: the byte, then the empty polls that preceded it.
    local raw, gaps = {}, {}
    for i = 0, mem:read_u8(MB.RAWLEN) - 1 do
        raw[#raw + 1] = mem:read_u8(MB.RAW + 2 * i)
        gaps[#gaps + 1] = mem:read_u8(MB.RAW + 2 * i + 1)
    end
    -- Fewest and most empty polls before a byte of the reply, after its first.
    local reply = parse(raw)
    local min_empty, max_empty, waited, spans = nil, 0, 0, 0
    for i = (reply and reply.at or #gaps) + 1, #gaps do
        min_empty = math.min(min_empty or 255, gaps[i])
        max_empty = math.max(max_empty, gaps[i])
        spans = spans + 1
        if gaps[i] > 0 then waited = waited + 1 end
    end
    return {
        result = mem:read_u8(MB.RESULT), rr0tx = mem:read_u8(MB.RR0TX), rr0 = mem:read_u8(MB.RR0END),
        rr1 = mem:read_u8(MB.RR1END), ready_low = mem:read_u16(MB.READYLO), drained = mem:read_u8(MB.DRAINED),
        min_empty = min_empty or 0, max_empty = max_empty, raw = raw, gaps = gaps, waited = waited, spans = spans,
        rr0stall = mem:read_u8(MB.RR0STALL), readytx = mem:read_u8(MB.READYTX),
    }
end

local function init(wr1)
    local r = post(1, { wr1 = wr1 })
    H.check(r.result == 0, "init failed")
end

-- One exchange; returns the record and the parsed reply (or nil).
local function exchange(class, seq, data, opts)
    local p = packet(class, seq, data or {})
    poke(MB.PKT, p)
    mem:write_u8(MB.PKTLEN, #p)
    local r = post(4, opts)
    r.reply = parse(r.raw)
    H.trace("x %02X seq %02X%s: result %d, RR0 after send %02X, end RR0 %02X RR1 %02X, drained %d, empty polls %d..%d, raw %d: %s",
        class, seq, (opts and opts.hunt) and " hunt" or "", r.result, r.rr0tx, r.rr0, r.rr1, r.drained,
        r.min_empty, r.max_empty, #r.raw, hx(r.raw, 1, 40))
    return r, r.reply
end

local function expect_reply(r, class, seq, what)
    H.check(r.result == 0 and r.reply, "%s: no valid reply (result %d, %d bytes %s)", what, r.result, #r.raw, hx(r.raw))
    H.check(r.reply.class == class and r.reply.seq == seq and r.reply.status == 0,
        "%s: reply class %02X seq %02X status %02X, want %02X seq %02X", what, r.reply.class, r.reply.seq, r.reply.status, class, seq)
    return r.reply
end

local PATTERN = { 0x10, 0x32, 0x54, 0x76, 0x98, 0xba, 0xdc, 0xfe, 0x01, 0x23, 0x45, 0x67, 0x89, 0xab, 0xcd, 0xef }

-- A PING carrying PATTERN, checked against handler_ping; returns its service counters.
local function ping(seq, opts, what)
    local r = exchange(PING, seq, PATTERN, opts)
    local reply = expect_reply(r, RSP_PING, seq, what or "PING")
    local d = reply.data
    H.check(#d == 26, "%s: %d DATA bytes, want 26", what or "PING", #d)
    for i = 1, 16 do H.check(d[i] == PATTERN[i], "%s: echo byte %d is %02X", what or "PING", i, d[i]) end
    H.check(d[17] == FW_LEVEL and d[18] == POWER_SYNCED, "%s: level %d power %02X", what or "PING", d[17], d[18])
    return d[19] | (d[20] << 8), d[21] | (d[22] << 8), r
end

local function link_sync(seq, what)
    local r = exchange(LINK_SYNC, seq, {}, { hunt = true })
    expect_reply(r, RSP_LINK_SYNC, seq, what or "LINK_SYNC")
    H.check(#r.reply.data == 0, "LINK_SYNC reply carries %d DATA bytes", #r.reply.data)
    return r
end

local function start_probe()
    H.wait(function() return H.now() > 0.005 end, 1, "probe program start")
end

H.case_body("exchange", function()
    start_probe()
    init(0)
    local r = link_sync(1)
    H.check((r.readytx & 0x08) == 0, "READY (/DCDB) asserted while the request was served")
    local calls, aborts, paced = {}, nil, {}
    for k = 1, 3 do
        local c, a, x = ping(1 + k, nil, "PING " .. k)
        calls[k], aborts = c, a
        -- The receiver is paced by the lane clock: the capture loop, faster
        -- than a byte time, finds the FIFO empty before most bytes.
        H.check(x.waited * 2 > x.spans, "PING %d: only %d of %d reply bytes followed an empty poll", k, x.waited, x.spans)
        paced[#paced + 1] = string.format("%d/%d", x.waited, x.spans)
        H.check((x.rr0 & 0x10) == 0, "PING %d: receiver hunting after the reply", k)
    end
    H.check(calls[2] == calls[1] + 1 and calls[3] == calls[2] + 1 and aborts == 0,
        "service counters %d %d %d, aborts %d", calls[1], calls[2], calls[3], aborts)
    return string.format("LINK_SYNC with Hunt, then 3 PINGs: echo, level 75, power %02X, calls %d/%d/%d, aborts 0; READY low during service; reply bytes found after an empty RR0 poll %s",
        POWER_SYNCED, calls[1], calls[2], calls[3], table.concat(paced, " "))
end)

H.case_body("hunt", function()
    start_probe()
    init(0)
    link_sync(1)
    local c1 = ping(2)
    init(0) -- channel reset: the boundary is gone, /SYNCB stays low
    local r = exchange(PING, 3, PATTERN, { hunt = true })
    H.check(r.result == 3 and #r.raw == 0, "a reply reached a hunting receiver without a /SYNC edge (%d bytes)", #r.raw)
    H.check((r.rr0 & 0x10) ~= 0, "receiver left Hunt with no edge (RR0 %02X)", r.rr0)
    link_sync(4, "LINK_SYNC after the reset")
    local c2, aborts = ping(5, nil, "PING after LINK_SYNC")
    H.check(c2 == c1 + 3 and aborts == 0, "calls %d -> %d (want +3: the unseen PING was served), aborts %d", c1, c2, aborts)
    return string.format("after a channel reset the served PING (calls %d -> %d) never reached the hunting receiver; LINK_SYNC's /SYNCB edge resynchronised it", c1, c2)
end)

H.case_body("underrun", function()
    start_probe()
    init(0)
    link_sync(1)
    -- PING without DATA, stalled 60 us after its fifth byte: the transmitter
    -- underruns inside the frame.
    local r = exchange(PING, 2, {}, { stall_at = 5, stall_n = 23 })
    H.check((r.rr0stall & 0x40) ~= 0, "no Tx underrun latched during the stall (RR0 %02X)", r.rr0stall)
    H.check(r.reply == nil, "the underrun request was answered: %s", hx(r.raw))
    local calls, aborts = ping(3, nil, "PING after the underrun")
    H.check(aborts == 1, "aborts %d, want 1", aborts)
    return string.format("stall after byte 5: RR0 %02X (Tx underrun), no reply; next PING answered with aborts %d, calls %d", r.rr0stall, aborts, calls)
end)

H.case_body("early", function()
    start_probe()
    init(0)
    link_sync(1)
    local first = packet(PING, 2, PATTERN)
    local second = packet(PING, 3, PATTERN)
    poke(MB.PKT, first)
    mem:write_u8(MB.PKTLEN, #first)
    poke(MB.PKT2, second)
    mem:write_u8(MB.PKT2LEN, #second)
    local r = post(5)
    r.reply = parse(r.raw)
    H.trace("early: result %d, READY low polls %d, drained %d, raw %d: %s", r.result, r.ready_low, r.drained, #r.raw, hx(r.raw, 1, 48))
    H.check(r.ready_low > 0, "the second request never waited on READY")
    H.check(r.drained == 4, "the bounded drain removed %d bytes, want 4 (FIFO full of the first reply)", r.drained)
    expect_reply(r, RSP_PING, 3, "second PING")
    return string.format("second request waited %d READY polls; its capture drained 4 stale bytes and found reply seq 03", r.ready_low)
end)

H.case_body("overrun", function()
    start_probe()
    init(0)
    link_sync(1)
    local r = exchange(PING, 2, PATTERN, { rxslow_at = 3, rxslow_n = 400 })
    H.check((r.rr1 & 0x20) ~= 0, "no Rx overrun reported (RR1 %02X)", r.rr1)
    H.check(r.reply == nil, "a complete reply survived the overrun")
    local calls = ping(3, nil, "PING after the overrun")
    return string.format("pause after 3 reply bytes: RR1 %02X, %d bytes captured; the next PING succeeds without Hunt (calls %d)", r.rr1, #r.raw, calls)
end)

H.case_body("reset", function()
    start_probe()
    init(0)
    link_sync(1)
    local r = exchange(PING, 2, PATTERN, { reset_at = 4 })
    local seen = 0
    for i = 1, #r.raw do if r.raw[i] ~= 0xff then seen = seen + 1 end end
    H.check(seen == 4 and r.raw[#r.raw] ~= 0xff, "%d reply bytes after a channel reset at the fourth: %s", seen, hx(r.raw))
    H.check((r.rr0 & 0x11) == 0x10, "after the channel reset RR0 %02X (want Hunt, nothing available)", r.rr0)
    init(0)
    local s = link_sync(3, "LINK_SYNC after the reset")
    local markers = 0
    for i = 1, #s.raw - 1 do if s.raw[i] == 0xa5 and s.raw[i + 1] == 0x5a then markers = markers + 1 end end
    H.check(markers == 1 and #s.raw <= 11, "the resynchronised capture holds %d markers in %d bytes: %s", markers, #s.raw, hx(s.raw))
    ping(4, nil, "PING after the reset")
    return string.format("channel reset at reply byte 4 ends reception; LINK_SYNC capture %s holds only its own reply", hx(s.raw))
end)

H.case_body("irq", function()
    start_probe()
    init(0x1f) -- every SIO1 interrupt enable set on both channels
    link_sync(1)
    for k = 1, 3 do ping(1 + k) end
    local irqs = mem:read_u8(MB.IRQS)
    H.check(irqs == 0, "%d interrupt acknowledges", irqs)
    return "WR1 1Fh on both channels, LINK_SYNC and 3 PINGs with interrupts enabled between operations: no acknowledge"
end)

-- Save state: a lane synchronised by LINK_SYNC is saved at idle, and a second
-- process restores it and exchanges without Hunt.
H.case_body("state-save", function()
    start_probe()
    init(0)
    link_sync(1)
    local calls = ping(2)
    H.machine:save("synced")
    local t = H.now()
    H.wait(function() return H.now() > t + 0.05 end, 1, "the save")
    return string.format("saved after LINK_SYNC and a PING (calls %d)", calls)
end)

H.case_body("state-load", function()
    local t = H.now()
    H.wait(function() return H.now() > t + 0.02 end, 1, "the restore")
    local calls, aborts = ping(3, nil, "PING after the restore")
    H.check(calls == 3 and aborts == 0, "calls %d aborts %d after the restore, want 3 and 0", calls, aborts)
    return string.format("restored: PING without Hunt answered, calls %d continue the saved count", calls)
end)

-- Guests --------------------------------------------------------------------

-- The SIO1 register trace from the CPU's side and the command-lane exchanges
-- decoded from it: request bytes are the data writes while the transmitter
-- is enabled for a request (WR5 D3, set before the preload and RTS), reply
-- bytes the data reads after its release.
local function trace_sio1()
    local T = { exchanges = {}, wr1 = {}, writes = 0, reads = 0 }
    local file = assert(io.open(H.dir .. "/sio1-trace.tsv", "w"))
    file:write("emulated_s\taccess\tport\tvalue\n")
    local pointer = { [0] = 0, [1] = 0 }
    local current
    local function close_exchange()
        if not current then return end
        if #current.request == 0 then current = nil; return end
        current.request_frame = parse(current.request)
        current.reply_frame = parse(current.reply)
        T.exchanges[#T.exchanges + 1] = current
        current = nil
    end
    T.open_exchange = function() return current end
    T.flush = close_exchange
    T.close = function()
        close_exchange()
        file:close()
    end
    H.keep(H.io:install_write_tap(0x30, 0x33, "sio1-trace-w", function(offset, data)
        T.writes = T.writes + 1
        file:write(string.format("%.6f\tW\t%02X\t%02X\n", H.now(), offset, data))
        local ch = (offset >> 1) & 1
        if (offset & 1) == 1 then
            local reg = pointer[ch]
            pointer[ch] = 0
            if reg == 0 then
                pointer[ch] = data & 7
            elseif reg == 1 then
                T.wr1[#T.wr1 + 1] = data
            elseif reg == 5 and ch == 1 then
                -- The transmitter enabled for a request (the preload comes
                -- before RTS), disabled to release it.
                if (data & 0x08) ~= 0 then
                    if not (current and current.sending) then
                        close_exchange()
                        current = { t = H.now(), request = {}, reply = {}, sending = true }
                    end
                elseif current then
                    current.sending = false
                end
            elseif reg == 3 and ch == 1 and current then
                current.wr3 = data
            end
        elseif ch == 1 and current and current.sending then
            current.request[#current.request + 1] = data
        end
    end))
    H.keep(H.io:install_read_tap(0x30, 0x33, "sio1-trace-r", function(offset, data)
        T.reads = T.reads + 1
        if (offset & 1) == 0 then
            file:write(string.format("%.6f\tR\t%02X\t%02X\n", H.now(), offset, data))
            if offset == 0x32 and current and not current.sending then current.reply[#current.reply + 1] = data end
        else
            local ch = (offset >> 1) & 1
            pointer[ch] = 0
        end
    end))
    return T
end

-- Write the decoded exchanges to exchanges.tsv.
local function report_exchanges(T)
    local f = assert(io.open(H.dir .. "/exchanges.tsv", "w"))
    f:write("emulated_s\trequest\tseq\tdata\thunt\treply\tseq\tstatus\tdata\treply_bytes\n")
    for _, x in ipairs(T.exchanges) do
        local q, a = x.request_frame, x.reply_frame
        f:write(string.format("%.6f\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%d\n", x.t,
            q and string.format("%02X", q.class) or "?", q and string.format("%02X", q.seq) or "?",
            q and #q.data or "?", x.wr3 == 0xd1 and "yes" or "no",
            a and string.format("%02X", a.class) or "none", a and string.format("%02X", a.seq) or "-",
            a and string.format("%02X", a.status) or "-", a and hx(a.data) or "-", #x.reply))
    end
    f:close()
end

-- Every request answered, with its sequence; returns the exchanges by class.
local function check_exchanges(T, from, to)
    local found = {}
    for i = from or 1, to or #T.exchanges do
        local x = T.exchanges[i]
        H.check(x.request_frame, "exchange %d: the guest's request %s does not parse", i, hx(x.request))
        H.check(x.reply_frame, "exchange %d (request %02X seq %02X): no valid reply in %d bytes read: %s", i,
            x.request_frame.class, x.request_frame.seq, #x.reply, hx(x.reply, 1, 48))
        H.check(x.reply_frame.seq == x.request_frame.seq, "exchange %d: reply seq %02X for request seq %02X", i,
            x.reply_frame.seq, x.request_frame.seq)
        local want = x.request_frame.class | 0x80
        H.check(x.reply_frame.class == want or x.reply_frame.class == RSP_UNKNOWN, "exchange %d: reply class %02X", i, x.reply_frame.class)
        local c = x.request_frame.class
        found[c] = found[c] or {}
        table.insert(found[c], x)
    end
    return found
end

local function check_wr1(T)
    for _, v in ipairs(T.wr1) do H.check(v == 0, "the guest wrote WR1 %02X to SIO1", v) end
end

local function summary(T, found)
    local classes = {}
    for c, list in pairs(found) do classes[#classes + 1] = string.format("%02Xx%d", c, #list) end
    table.sort(classes)
    return string.format("%d exchanges (%s), %d SIO1 writes, %d reads", #T.exchanges, table.concat(classes, " "), T.writes, T.reads)
end

-- KonaOS console-serial image: the banner holds for the host sync.
local BANNER_IOC = "IOC version 75"

local function host_sync_from(mark, timeout)
    local next_send = 0
    H.wait(function()
        if #S.data >= mark then return true end
        if H.now() >= next_send then
            S.send("\170\85")
            next_send = H.now() + 0.25
        end
        return false
    end, timeout, "guest output after the host sync")
end

-- `interrupted`: the exchange at `from` is the one a reset cut off; the
-- bring-up starts after it.
local function konaos_boot(T, from, mark, interrupted)
    host_sync_from(mark, 15)
    local _, stop = S.wait(H.prompt, 30, mark, "shell prompt")
    H.check(S.data:find(BANNER_IOC, mark, true), "the shell banner does not report %q", BANNER_IOC)
    T.flush()
    if interrupted then
        local cut = T.exchanges[from]
        H.check(cut and cut.request_frame and cut.request_frame.class == PING and not cut.reply_frame,
            "the reset did not cut a PING reply off")
        from = from + 1
    end
    local found = check_exchanges(T, from)
    local first = T.exchanges[from]
    H.check(first.request_frame.class == LINK_SYNC and first.wr3 == 0xd1,
        "first exchange is %02X (WR3 %s), want LINK_SYNC armed with Hunt", first.request_frame.class, tostring(first.wr3))
    H.check(#found[LINK_SYNC] == 1, "%d LINK_SYNC exchanges: the bring-up retried", #found[LINK_SYNC])
    H.check(found[PING], "the guest sent no PING")
    for _, x in ipairs(found[PING]) do
        local d = x.reply_frame.data
        H.check(x.reply_frame.class == RSP_PING and d[17] == FW_LEVEL and d[18] == POWER_SYNCED,
            "PING reply %02X level %s power %s", x.reply_frame.class, tostring(d[17]), tostring(d[18]))
    end
    return stop, found
end

-- Four boots: cold to the prompt and `pwd`; after a machine reset at the
-- prompt; one cut off by a reset while the guest reads the shell's PING
-- reply; and the boot after that reset.  Each bring-up must succeed at its
-- first LINK_SYNC and see only its own replies.
H.case_body("sio1-konaos", function()
    local T = trace_sio1()
    S.attach(5)
    local _, found = konaos_boot(T, 1, 1)
    local prompt_time = H.now()
    local from = S.type("pwd")
    S.wait("\r\n/system\r\n", 5, from, "pwd answer")
    S.wait(H.prompt, 5, from, "prompt after pwd")
    local cold = summary(T, found)
    H.trace("cold boot: prompt at %.3f emulated s; %s", prompt_time, cold)

    -- Reset at the idle prompt.
    local reset_idle = H.now()
    local mark, first = S.mark(), #T.exchanges + 1
    H.machine:soft_reset()
    local _, found2 = konaos_boot(T, first, mark)
    H.trace("reset at the prompt (%.3f s): %s", reset_idle, summary(T, found2))

    -- Reset on the eighth byte the guest reads after the PING request.
    local reset_at, cut
    H.keep(H.io:install_read_tap(0x32, 0x32, "sio1-reset", function(offset, data)
        if reset_at then return end
        local open = T.open_exchange()
        local frame = open and parse(open.request)
        if frame and frame.class == PING and not open.sending and #open.reply >= 8 then
            reset_at = H.now()
            cut = #T.exchanges + 1
            H.machine:soft_reset()
        end
    end))
    local before = #T.exchanges
    H.machine:soft_reset()
    host_sync_from(S.mark(), 15)
    H.wait(function() return reset_at end, 30, "the shell's PING reply")
    -- The interrupted PING closes when the next request starts.
    mark = S.mark()
    local _, found3 = konaos_boot(T, cut, mark, true)
    check_exchanges(T, before + 1, cut - 1)
    T.close()
    report_exchanges(T)
    check_wr1(T)
    H.trace("reset during the PING reply (%.6f s): %s", reset_at, summary(T, found3))
    return string.format("cold prompt at %.3f s, banner %q, %s; idle reset and mid-reply reset each re-synchronised at the first LINK_SYNC",
        prompt_time, BANNER_IOC, cold)
end)

-- ZSDOS: boot with its V9958 console; its bring-up is LINK_SYNC, its other
-- requests are answered too.  It sends no PING.
H.case_body("sio1-zsdos", function()
    local T = trace_sio1()
    H.wait(function() return H.now() > 6 end, 10, "ZSDOS boot")
    T.close()
    report_exchanges(T)
    check_wr1(T)
    H.check(#T.exchanges > 0, "ZSDOS sent no IOC request")
    local found = check_exchanges(T, 1)
    local first = T.exchanges[1]
    H.check(first.request_frame.class == LINK_SYNC and first.wr3 == 0xd1,
        "first exchange is %02X, want LINK_SYNC armed with Hunt", first.request_frame.class)
    H.check(#found[LINK_SYNC] == 1, "%d LINK_SYNC exchanges", #found[LINK_SYNC])
    return "LINK_SYNC first attempt; " .. summary(T, found)
end)

-- IOC core replies (the `ioc-core` case's guest probes) ---------------------

-- What the core answers each class with an empty card socket
-- (Code/MCU/IOController src/dispatch.c, handlers.c, fs2.c, fs_share.c):
-- a status, and a check of the DATA where it is fixed.
local NO_MEDIA, NO_HANDLE = 0x4b, 0x48
local EMPTY_SOCKET = {
    [0x01] = { 0x00 }, [0x0c] = { 0x00 }, [0x33] = { 0x00 }, [0x0a] = { 0x00 }, [0x11] = { 0x00 },
    [0x30] = { 0x00, function(d) return #d == 14 and d[1] == 1 and d[3] == 0xfe and d[4] == 0x1f end },
    [0x31] = { 0x00 }, [0x32] = { 0x00 },
    [0x34] = { NO_MEDIA }, [0x35] = { NO_MEDIA }, [0x38] = { NO_MEDIA }, [0x3b] = { NO_MEDIA }, [0x3c] = { NO_MEDIA },
    [0x3d] = { NO_MEDIA }, [0x41] = { NO_MEDIA }, [0x42] = { NO_MEDIA }, [0x43] = { NO_MEDIA }, [0x44] = { NO_MEDIA },
    [0x36] = { NO_HANDLE }, [0x37] = { NO_HANDLE }, [0x39] = { NO_HANDLE }, [0x3a] = { NO_HANDLE },
    [0x3e] = { NO_HANDLE }, [0x3f] = { NO_HANDLE }, [0x40] = { NO_HANDLE }, [0x45] = { NO_HANDLE },
    [0x08] = { 0x15 }, [0x0f] = { 0x15 }, [0x03] = { 0x15 }, [0x10] = { 0x15 },
    [0x20] = { 0x13 }, [0x22] = { 0x13 }, [0x26] = { 0x13 }, [0x27] = { 0x13 }, [0x28] = { 0x13 },
    [0x0d] = { 0x00, function(d) return (#d == 26 or #d == 21) end },
    [0x0e] = { 0x00, function(d) return #d == 2 and d[1] == 0 and d[2] == 0 end },
    [0x12] = { 0x00, function(d) for i = 1, 9 do if d[i] ~= 0 then return false end end return #d == 9 end },
}

-- Every exchange answered with the class's response and the empty-socket
-- status; FS2 generations advance by one per FS2_RESET from 1; nothing ever
-- touches the bulk lane's data port (no READY is issued without media).
local function check_core_replies(T, bulk)
    local generation, seen = 1, {}
    for i, x in ipairs(T.exchanges) do
        local q, a = x.request_frame, x.reply_frame
        local want = EMPTY_SOCKET[q.class]
        H.check(want, "exchange %d: class %02X is not in the empty-socket table", i, q.class)
        H.check(a.class == (q.class | 0x80) and a.status == want[1],
            "exchange %d: request %02X answered %02X status %02X, want %02X status %02X", i, q.class, a.class, a.status,
            q.class | 0x80, want[1])
        if want[2] then H.check(want[2](a.data), "exchange %d (%02X): reply DATA %s", i, q.class, hx(a.data)) end
        if q.class == 0x32 then
            generation = generation + 1
            local g = a.data[1] | (a.data[2] << 8) | (a.data[3] << 16) | (a.data[4] << 24)
            H.check(g == generation, "FS2_RESET generation %d, want %d", g, generation)
        end
        seen[#seen + 1] = string.format("%02X>%02X/%02X", q.class, a.class, a.status)
    end
    H.check(bulk.data == 0, "%d bulk-lane data accesses with no READY", bulk.data)
    return table.concat(seen, " ")
end

local function bulk_data_tap()
    local bulk = { data = 0 }
    H.keep(H.io:install_read_tap(0x30, 0x30, "ioc-bulk-r", function() bulk.data = bulk.data + 1 end))
    H.keep(H.io:install_write_tap(0x30, 0x30, "ioc-bulk-w", function() bulk.data = bulk.data + 1 end))
    return bulk
end

-- A guest boot for `seconds`: its requests and the core's replies.
local function guest_replies(seconds, what)
    local T = trace_sio1()
    local bulk = bulk_data_tap()
    H.wait(function() return H.now() > seconds end, seconds + 2, what)
    T.close()
    report_exchanges(T)
    H.check(#T.exchanges > 0, "%s sent no IOC request", what)
    check_exchanges(T, 1)
    return T, check_core_replies(T, bulk)
end

-- The production KonaOS image (V9958 console): its IOC, filesystem and HID
-- drivers' boot requests against the empty socket.
H.case_body("ioc-konaos", function()
    local T, seen = guest_replies(8, "KonaOS boot")
    local classes = {}
    for _, x in ipairs(T.exchanges) do classes[x.request_frame.class] = true end
    H.check(classes[0x32] and classes[0x30] and classes[0x38], "KonaOS sent no FS2_RESET/CAPS/OPENDIR")
    return string.format("%d exchanges: %s", #T.exchanges, seen)
end)

H.case_body("ioc-zsdos", function()
    local T, seen = guest_replies(6, "ZSDOS boot")
    return string.format("%d exchanges: %s", #T.exchanges, seen)
end)
