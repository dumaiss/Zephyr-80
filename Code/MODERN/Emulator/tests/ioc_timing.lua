-- license:BSD-3-Clause
-- IO controller lane timing (tests/ioc_timing.py): real transfers through the
-- probe program's bulk operations (sio1_lanes.asm ops 6 and 7, the KonaOS
-- bulk read and write sequences), timed from the Z80's own port accesses.
-- The timing probes are taps on ports 30h-33h with emulated time, never
-- code in the guest or the device; collecting them changes nothing the
-- controller does.  HARNESS_IOC_SPEED names the mode the process runs
-- (paced or fast).  Runs under harness.lua.
local H = harness
local mem = H.program
local FAST = os.getenv("HARNESS_IOC_SPEED") == "fast"

-- The paced model (the delay table in zephyr80_ioc.cpp), in microseconds.
local M = {
    command_byte = 20, window = 36, reply_guard = 200,
    bulk_guard = 100, fixed = 18, payload = 9, from_z80 = 24,
    header = 7, trailer = 2, window_extra = 27, -- the window is length + 27 bytes
}

local LINK_SYNC, PING, XFER_STATUS = 0x0c, 0x01, 0x06
local FS_OPEN, FS_READ, FS_WRITE, FS_CLOSE = 0x22, 0x23, 0x24, 0x25
local RSP = { [PING] = 0x81, [LINK_SYNC] = 0x8c, [XFER_STATUS] = 0x86, [FS_OPEN] = 0xa2, [FS_READ] = 0xa3,
              [FS_WRITE] = 0xa4, [FS_CLOSE] = 0xa5 }
local BULK_NO_HOST = 0x21

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
                    return { class = bytes[i + 4], seq = bytes[i + 5], status = bytes[i + 6], data = data, at = i,
                             wire = last + 2 - i + 1 }
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

-- The file the card holds: byte i of R4K.BIN (and of what W4K.BIN must become).
local function pattern(i)
    return (3 + i * 7 + (i >> 8)) & 0xff
end

local function us(a, b) return (b - a) * 1e6 end

-- Probe program -----------------------------------------------------------------

local MB = {
    BZPTR = 0x7f50,
    BURST = 0x7f3c, PKT2LEN = 0x7f0a, PKT2 = 0x7e40, READY_POLLS = 0x7f14,
    CMD = 0x7f00, HUNT = 0x7f01, PKTLEN = 0x7f02, STALL_AT = 0x7f03, STALL_N = 0x7f04,
    EVENT_AT = 0x7f06, EVENT_N = 0x7f07, EVENT = 0x7f09, WR1VAL = 0x7f0b,
    RESULT = 0x7f10, READYLO = 0x7f14, DRAINED = 0x7f16, RAWLEN = 0x7f19,
    BLEN = 0x7f30, BHUNT = 0x7f32, BNORTS = 0x7f33, BSTOP = 0x7f34, BRES = 0x7f36, BCOUNT = 0x7f37,
    BHDR = 0x7f40, BHEAD = 0x3ffb, BBUF = 0x4000, PKT = 0x7e00, RAW = 0x7d00,
}

local function poke(address, bytes)
    for i, v in ipairs(bytes) do mem:write_u8(address + i - 1, v) end
end

-- Port taps: every access to SIO1 with its emulated time and, for control
-- writes, the register the pointer selected.
local EV, recording, ptr = {}, false, { [0] = 0, [1] = 0 }
local triggers = {}

local function note(e)
    if recording then EV[#EV + 1] = e end
    for i = #triggers, 1, -1 do
        if triggers[i](e) then table.remove(triggers, i) end
    end
end

H.keep(H.io:install_write_tap(0x30, 0x33, "timing-w", function(offset, data)
    local ch = (offset >> 1) & 1
    if (offset & 1) == 1 then
        local reg = ptr[ch]
        if reg == 0 then
            ptr[ch] = data & 7
            note({ t = H.now(), ch = ch, k = "c0", v = data })
        else
            ptr[ch] = 0
            note({ t = H.now(), ch = ch, k = "wr", reg = reg, v = data })
        end
    else
        note({ t = H.now(), ch = ch, k = "dw", v = data })
    end
end))
H.keep(H.io:install_read_tap(0x30, 0x33, "timing-r", function(offset, data)
    local ch = (offset >> 1) & 1
    if (offset & 1) == 1 then
        ptr[ch] = 0
        note({ t = H.now(), ch = ch, k = "rr", v = data })
    else
        note({ t = H.now(), ch = ch, k = "dr", v = data })
    end
end))

local function start_probe()
    H.wait(function() return H.now() > 0.005 end, 1, "probe program start")
end

local function post_async(op, o)
    o = o or {}
    mem:write_u8(MB.HUNT, o.hunt and 1 or 0)
    mem:write_u8(MB.STALL_AT, o.stall_at or 0)
    mem:write_u16(MB.STALL_N, o.stall_n or 1)
    mem:write_u8(MB.EVENT_AT, 0)
    mem:write_u8(MB.WR1VAL, 0)
    mem:write_u16(MB.BLEN, o.len or 0)
    mem:write_u8(MB.BURST, o.burst or 0)
    mem:write_u8(MB.BHUNT, o.bhunt and 1 or 0)
    mem:write_u8(MB.BNORTS, o.norts and 1 or 0)
    mem:write_u16(MB.BSTOP, o.stop or 0)
    mem:write_u8(MB.CMD, op)
end

local function wait_op(op)
    H.wait(function() return mem:read_u8(MB.CMD) == 0 end, 3, string.format("probe operation %d", op))
end

-- One probe operation; returns its events.
local function run_op(op, o)
    EV, recording = {}, true
    post_async(op, o)
    wait_op(op)
    recording = false
    return EV
end

-- Opt-in trace (HARNESS_TRACE): the port accesses of each transfer, relative
-- to the first, one file per transfer.
local function dump(label, events)
    if not os.getenv("HARNESS_TRACE") or #events == 0 then return end
    local f = assert(io.open(H.dir .. "/" .. label:gsub("[^%w]+", "-") .. ".tsv", "w"))
    f:write("us\tchannel\taccess\tvalue\n")
    for _, e in ipairs(events) do
        f:write(string.format("%.1f\t%d\t%s%s\t%02X\n", us(events[1].t, e.t), e.ch, e.k, e.reg and ("." .. e.reg) or "", e.v))
    end
    f:close()
end

local function raw_bytes()
    local raw = {}
    for i = 0, mem:read_u8(MB.RAWLEN) - 1 do raw[#raw + 1] = mem:read_u8(MB.RAW + 2 * i) end
    return raw
end

local function init()
    mem:write_u8(MB.WR1VAL, 0)
    run_op(1)
    H.check(mem:read_u8(MB.RESULT) == 0, "init failed")
end

-- Event analysis ----------------------------------------------------------------

local function find(events, from, test)
    for i = from or 1, #events do
        if test(events[i]) then return i, events[i] end
    end
end

-- The command exchange: the request's RTS, the reply's first and last byte.
local function command_times(events, upto)
    local _, rts = find(events, 1, function(e) return e.ch == 1 and e.k == "wr" and e.reg == 5 and (e.v & 0x02) ~= 0 end)
    H.check(rts, "no request RTS in the events")
    local last_req = rts
    for _, e in ipairs(events) do
        if e.ch == 1 and e.k == "dw" and e.t > rts.t then last_req = e end
    end
    local first, last
    local count = 0
    for i, e in ipairs(events) do
        if upto and i >= upto then break end
        if e.ch == 1 and e.k == "dr" and e.t > last_req.t then
            if not first and e.v == 0xa5 then first = e end
            if first then last = e; count = count + 1 end
        end
    end
    H.check(first and last, "no reply bytes in the events")
    return { rts = rts.t, request_last = last_req.t, first = first.t, last = last.t, reads = count }
end

-- Bulk read: RTS, /DCDA seen, first and last data byte, /CTSA closing.
local function read_times(events)
    local i, rts = find(events, 1, function(e) return e.ch == 0 and e.k == "wr" and e.reg == 5 and e.v == 0xeb end)
    H.check(rts, "no bulk RTS in the events")
    local _, dcd = find(events, i, function(e) return e.ch == 0 and e.k == "rr" and (e.v & 0x08) ~= 0 end)
    local first, last
    local times, stale = {}, 0
    for _, e in ipairs(events) do
        if e.ch == 0 and e.k == "dr" and e.t > rts.t then
            if first or e.v == 0xa5 then
                first = first or e
                last = e
                times[#times + 1] = e.t
            else
                stale = stale + 1 -- the previous transfer's trailing fill byte
            end
        end
    end
    H.check(dcd and first, "bulk read: no admission or no data")
    local _, drop = find(events, i, function(e) return e.ch == 0 and e.k == "rr" and e.t > last.t and (e.v & 0x20) == 0 end)
    H.check(drop, "bulk read: /CTSA never seen closing")
    return { rts = rts.t, admitted = dcd.t, first = first.t, last = last.t, drop = drop.t, reads = #times, times = times, stale = stale }
end

-- Bulk write: RTS, /CTSA seen, first and last data byte, /CTSA closing.
local function write_times(events)
    local i, rts = find(events, 1, function(e) return e.ch == 0 and e.k == "wr" and e.reg == 5 and e.v == 0xeb end)
    H.check(rts, "no bulk RTS in the events")
    local j, cts = find(events, i, function(e) return e.ch == 0 and e.k == "rr" and (e.v & 0x20) ~= 0 end)
    H.check(cts, "bulk write: /CTSA never seen")
    local first, last, writes
    writes = 0
    for _, e in ipairs(events) do
        if e.ch == 0 and e.k == "dw" and e.t >= cts.t then
            first = first or e
            last = e
            writes = writes + 1
        end
    end
    H.check(first, "bulk write: no data")
    local _, off = find(events, j, function(e) return e.ch == 0 and e.k == "wr" and e.reg == 5 and e.v == 0xe0 end)
    local _, drop = find(events, j, function(e) return e.ch == 0 and e.k == "rr" and off and e.t > off.t and (e.v & 0x20) == 0 end)
    H.check(off and drop, "bulk write: /CTSA never seen closing")
    return { rts = rts.t, admitted = cts.t, first = first.t, last = last.t, drop = drop.t, writes = writes }
end

local function ioc_item(name)
    return emu.item(H.machine.devices[":ioc"].items["0/" .. name])
end

-- Transactions --------------------------------------------------------------------

local seq = 0
EV_LAST = {}
local function next_seq()
    seq = (seq % 250) + 1
    return seq
end

local synced = false
local function cmd_packet(class, data)
    local s = next_seq()
    local p = packet(class, s, data)
    poke(MB.PKT, p)
    mem:write_u8(MB.PKTLEN, #p)
    return s
end

-- A command exchange on its own (op 4).
local function exchange(class, data, o)
    local s = cmd_packet(class, data or {})
    local events = run_op(4, o)
    local reply = parse(raw_bytes())
    H.check(mem:read_u8(MB.RESULT) == 0 and reply, "class %02X: no reply (result %d, raw %s)", class, mem:read_u8(MB.RESULT), hx(raw_bytes(), 1, 20))
    H.check(reply.class == RSP[class] and reply.seq == s, "class %02X: reply %02X seq %02X, want %02X seq %02X",
        class, reply.class, reply.seq, RSP[class], s)
    return reply, events
end

local totals = {}   -- label -> accumulated microseconds
local lines = {}
local function out(fmt, ...)
    lines[#lines + 1] = string.format(fmt, ...)
end

-- Compare a measured microsecond value with the model's, within `tol`.
local function near(what, got, want, tol)
    if FAST then return end
    H.check(math.abs(got - want) <= tol, "%s: %.1f us, model %.1f us (+-%.0f)", what, got, want, tol)
end

local function le(what, fast, paced)
    H.check(fast <= paced + 1, "%s: %.1f us exceeds the paced %.1f us", what, fast, paced)
end

local function u32(v) return { v & 255, (v >> 8) & 255, (v >> 16) & 255, (v >> 24) & 255 } end

local function read_transfer(handle, offset, n, label)
    local data = { handle }
    for _, b in ipairs(u32(offset)) do data[#data + 1] = b end
    data[#data + 1] = n & 255
    data[#data + 1] = n >> 8
    local s = cmd_packet(FS_READ, data)
    local first_bulk = not synced
    local events = run_op(6, { len = n, bhunt = first_bulk })
    EV_LAST = events
    local reply = parse(raw_bytes())
    H.check(mem:read_u8(MB.RESULT) == 0 and reply, "%s: no reply", label)
    H.check(reply.class == RSP[FS_READ] and reply.seq == s and reply.status == 0 and #reply.data == 8,
        "%s: reply %02X status %02X, %d data", label, reply.class, reply.status, #reply.data)
    H.check(reply.data[2] == 0 and (reply.data[3] | (reply.data[4] << 8)) == n, "%s: READY direction %d length %d", label,
        reply.data[2], reply.data[3] | (reply.data[4] << 8))
    if mem:read_u8(MB.BRES) ~= 0 then
        local reads, first_t, last_t = 0, nil, nil
        for _, e in ipairs(events) do
            if e.ch == 0 and e.k == "dr" then reads = reads + 1; first_t = first_t or e.t; last_t = e.t end
        end
        local tail = {}
        for i = math.max(1, #EV_LAST - 40), #EV_LAST do local e = EV_LAST[i]; tail[#tail + 1] = string.format("%d%s%02X@%.1f", e.ch, e.k, e.v or 0, us(EV_LAST[1].t, e.t)) end
        print("DEBUG " .. table.concat(tail, " "))
        local sio = H.machine.devices[":sio1"].items
        print(string.format("DEBUG overrunA %s fifo_depthA %s", tostring(emu.item(sio["0/m_overrun"]):read(0)), tostring(emu.item(sio["0/m_fifo_depth"]):read(0))))
        local dr = {}
        for _, e in ipairs(EV_LAST) do if e.ch == 0 and e.k == "dr" then dr[#dr + 1] = string.format("%02X", e.v) end end
        print("DEBUG dr " .. table.concat(dr, " ", 1, 12) .. " ... " .. table.concat(dr, " ", #dr - 8))
        H.fail("%s: bulk read result %d after %d data reads (%.1f us), count %d, RR1/overrun %s", label, mem:read_u8(MB.BRES), reads,
            first_t and us(first_t, last_t) or 0, mem:read_u16(MB.BCOUNT), tostring(ioc_item("m_phase"):read(0)))
    end
    -- The captured header and the payload.
    local h = {}
    for i = 0, 4 do h[#h + 1] = mem:read_u8(MB.BHEAD + i) end
    H.check(h[1] == ((n + 3) & 255) and h[2] == ((n + 3) >> 8) and h[3] == RSP[FS_READ] and h[4] == s and h[5] == 0,
        "%s: bulk header %s", label, hx(h))
    local sum = 0
    for i = 0, n - 1 do
        local v = mem:read_u8(MB.BBUF + i)
        H.check(v == pattern(offset + i), "%s: byte %d is %02X, want %02X", label, i, v, pattern(offset + i))
        sum = (sum * 31 + v) & 0xffffffff
    end
    dump(label, events)
    local c = command_times(events)
    local b = read_times(events)
    H.check(b.reads == n + 9, "%s: %d data reads, want %d", label, b.reads, n + 9)
    local wire = reply.wire
    -- Model: the reply starts after the window, the guard and, on an
    -- unsynchronised lane, the establishing byte.
    local reply_at = M.window * M.command_byte + M.reply_guard + M.command_byte
    near(label .. " reply start", us(c.rts, c.first), reply_at, 12)
    near(label .. " reply span", us(c.first, c.last), (wire - 1) * M.command_byte, 10)
    near(label .. " admission", us(b.rts, b.first), M.bulk_guard + M.fixed + (first_bulk and M.fixed or 0), 12)
    -- The guest keeps up with the wire (56 T-states a byte against 6 us), so
    -- an interior byte is read within one loop of its arrival; the last two
    -- are read after the guest's own trailer setup, so the spans are taken
    -- between payload bytes.  The first payload byte is the eighth read
    -- (A5, 5A and the five header bytes before it).
    near(label .. " header span", us(b.times[1], b.times[8]), (M.header - 1) * M.fixed + M.payload, 9)
    near(label .. " payload span", us(b.times[8], b.times[7 + n]), (n - 1) * M.payload, 9)
    synced = true
    local r = { exchange = us(c.rts, c.last), admission = us(b.rts, b.first), bytes = us(b.first, b.last),
                tail = us(b.last, b.drop), reply_start = us(c.rts, c.first) }
    r.total = r.exchange + r.admission + r.bytes
    out("OUT %s sum %08x", label, sum)
    out("TIME %s %s n=%d exchange=%.1f admission=%.1f bytes=%.1f tail=%.1f total=%.1f", FAST and "fast" or "paced", label, n,
        r.exchange, r.admission, r.bytes, r.tail, r.total)
    return r
end

local function write_transfer(handle, offset, n, label)
    local data = { handle }
    for _, b in ipairs(u32(offset)) do data[#data + 1] = b end
    data[#data + 1] = n & 255
    data[#data + 1] = n >> 8
    local s = cmd_packet(FS_WRITE, data)
    for i = 0, n - 1 do mem:write_u8(MB.BBUF + i, pattern(offset + i)) end
    poke(MB.BHDR, { (n + 3) & 255, (n + 3) >> 8, FS_WRITE, s, 0 })
    local events = run_op(7, { len = n })
    local reply = parse(raw_bytes())
    H.check(mem:read_u8(MB.RESULT) == 0 and reply, "%s: no reply", label)
    H.check(reply.class == RSP[FS_WRITE] and reply.seq == s and reply.status == 0 and #reply.data == 8 and reply.data[2] == 1
        and (reply.data[3] | (reply.data[4] << 8)) == n, "%s: reply %02X status %02X", label, reply.class, reply.status)
    H.check(mem:read_u8(MB.BRES) == 0, "%s: bulk write result %d", label, mem:read_u8(MB.BRES))
    local id = reply.data[1]
    dump(label, events)
    local c = command_times(events)
    local w = write_times(events)
    local window = n + M.window_extra
    H.check(w.writes == n + 7, "%s: %d data writes, want %d", label, w.writes, n + 7)
    local reply_at = M.window * M.command_byte + M.reply_guard + M.command_byte
    near(label .. " reply start", us(c.rts, c.first), reply_at, 12)
    near(label .. " admission", us(w.rts, w.first), M.bulk_guard, 15)
    near(label .. " byte span", us(w.first, w.last), M.from_z80 * (n + 6), 15)
    near(label .. " window", us(w.rts, w.drop), M.bulk_guard + M.from_z80 * window, 20)
    -- DONE after the commit.
    local done = exchange(XFER_STATUS, {})
    H.check(done.data[1] == id and done.data[2] == 0, "%s: DONE id %02X status %02X, want %02X status 0", label, done.data[1], done.data[2], id)
    local r = { exchange = us(c.rts, c.last), admission = us(w.rts, w.first), bytes = us(w.first, w.last),
                tail = us(w.last, w.drop), reply_start = us(c.rts, c.first) }
    r.total = r.exchange + us(w.rts, w.drop)
    out("OUT %s done %02X", label, done.data[2])
    out("TIME %s %s n=%d exchange=%.1f admission=%.1f bytes=%.1f tail=%.1f window=%.1f total=%.1f", FAST and "fast" or "paced", label, n,
        r.exchange, r.admission, r.bytes, r.tail, us(w.rts, w.drop), r.total)
    return r
end

local function name83(name, ext)
    local out = {}
    local padded = (name .. string.rep(" ", 8)):sub(1, 8) .. (ext .. string.rep(" ", 3)):sub(1, 3)
    for i = 1, 11 do out[i] = padded:byte(i) end
    return out
end

local function open_file(name, ext, mode)
    local data = { mode }
    for _, b in ipairs(name83(name, ext)) do data[#data + 1] = b end
    local reply = exchange(FS_OPEN, data)
    H.check(reply.status == 0 and #reply.data == 5, "FS_OPEN %s.%s: status %02X", name, ext, reply.status)
    return reply.data[1], reply.data[2] | (reply.data[3] << 8) | (reply.data[4] << 16) | (reply.data[5] << 24)
end

local function close_file(handle, size)
    local data = { handle }
    for _, b in ipairs(u32(size)) do data[#data + 1] = b end
    local reply = exchange(FS_CLOSE, data)
    H.check(reply.status == 0, "FS_CLOSE: status %02X", reply.status)
end

local function link_sync()
    local s = cmd_packet(LINK_SYNC, {})
    local events = run_op(4, { hunt = true })
    local reply = parse(raw_bytes())
    H.check(reply and reply.class == 0x8c and reply.seq == s, "LINK_SYNC: no reply")
    local c = command_times(events)
    near("LINK_SYNC reply start", us(c.rts, c.first), M.window * M.command_byte + M.reply_guard + 2 * M.command_byte, 12)
    synced = false -- the command lane; the bulk lane synchronises with its first transfer
    out("TIME %s LINK_SYNC exchange=%.1f reply_start=%.1f", FAST and "fast" or "paced", us(c.rts, c.last), us(c.rts, c.first))
    return reply
end

local function ping()
    local reply, events = exchange(PING, {})
    local c = command_times(events)
    local d = reply.data
    near("PING reply start", us(c.rts, c.first), M.window * M.command_byte + M.reply_guard + M.command_byte, 12)
    out("TIME %s PING exchange=%.1f reply_start=%.1f", FAST and "fast" or "paced", us(c.rts, c.last), us(c.rts, c.first))
    return d[19] | (d[20] << 8), d[21] | (d[22] << 8), c
end

local function flush_lines()
    for _, l in ipairs(lines) do print(l) end
    lines = {}
end

-- Cases ------------------------------------------------------------------------------

-- LINK_SYNC, PINGs, reads and writes of 128 B, 512 B and 4 KiB (eight 512-byte
-- transfers), each timed phase by phase; the outcome lines (OUT) are
-- identical in both modes.
H.case_body("transfers", function()
    start_probe()
    init()
    link_sync()
    local calls
    for _ = 1, 3 do calls = ping() end
    -- Reads.
    local handle, size = open_file("R4K", "BIN", 0)
    H.check(size == 4096, "R4K.BIN is %d bytes", size)
    local t128 = read_transfer(handle, 0, 128, "read 128")
    local t512 = read_transfer(handle, 0, 512, "read 512")
    local t4k = { exchange = 0, admission = 0, bytes = 0, tail = 0, total = 0 }
    for k = 0, 7 do
        local r = read_transfer(handle, k * 512, 512, "read 4096 part " .. k)
        for key in pairs(t4k) do t4k[key] = t4k[key] + r[key] end
    end
    close_file(handle, 4096)
    -- Writes.
    local wh = open_file("W4K", "BIN", 1)
    local w128 = write_transfer(wh, 0, 128, "write 128")
    local w512 = write_transfer(wh, 0, 512, "write 512")
    local w4k = { exchange = 0, admission = 0, bytes = 0, tail = 0, total = 0 }
    for k = 0, 7 do
        local r = write_transfer(wh, k * 512, 512, "write 4096 part " .. k)
        for key in pairs(w4k) do w4k[key] = w4k[key] + r[key] end
    end
    close_file(wh, 4096)
    local c2 = ping()
    out("OUT calls %d then %d", calls, c2)
    for _, pair in ipairs({ { "read 4096", t4k }, { "write 4096", w4k } }) do
        out("TIME %s %s n=4096 exchange=%.1f admission=%.1f bytes=%.1f tail=%.1f total=%.1f", FAST and "fast" or "paced", pair[1],
            pair[2].exchange, pair[2].admission, pair[2].bytes, pair[2].tail, pair[2].total)
    end
    flush_lines()
    return string.format("%s: LINK_SYNC, 4 PINGs, reads and writes of 128 B, 512 B and 8 x 512 B; read 512 %.0f us (exchange %.0f, admission %.0f, bytes %.0f), write 512 %.0f us",
        FAST and "fast" or "paced", t512.total, t512.exchange, t512.admission, t512.bytes, w512.total)
end)

-- Timing edges --------------------------------------------------------------------------

local function device_state()
    local function item(device, name) return emu.item(H.machine.devices[device].items[name]):read(0) end
    return { phase = item(":ioc", "0/m_phase"), count = item(":ioc", "0/m_count"), bulk_count = item(":ioc", "0/m_bulk_count"),
             waiting = item(":ioc", "0/m_waiting"), starved = item(":ioc", "0/m_starved"), calls = item(":ioc", "0/core.m_calls") }
end

local PHASE = { IDLE = 0, WINDOW = 1, RELEASE = 2, GUARD = 3, REPLY = 4, BULK_HOST = 5, BULK_GUARD = 6, BULK_SEND = 7,
                BULK_RECEIVE = 8, BULK_RELEASE = 9, RESETTING = 10 }

-- Admission: a transfer the host never admits holds READY low for the 500 ms
-- bound and ends with DONE 21h; two requests back to back are both answered;
-- a request cut short by a stalled transmitter is dropped and the next one
-- is served.
H.case_body("admission", function()
    start_probe()
    init()
    link_sync()
    local handle = open_file("R4K", "BIN", 0)
    -- No host: the READY is never admitted.
    local data = { handle, 0, 0, 0, 0, 0, 2 }
    local s = cmd_packet(FS_READ, data)
    local events = run_op(6, { len = 512, bhunt = true, norts = true })
    local ready = parse(raw_bytes())
    H.check(ready and ready.class == RSP[FS_READ] and mem:read_u8(MB.BRES) == 6, "no-host: READY reply missing or the op admitted it")
    local id = ready.data[1]
    local reply_end = command_times(events).last
    local d1, ev1 = nil, nil
    -- A request now waits for READY, which the controller holds for the bound.
    local s2 = cmd_packet(XFER_STATUS, {})
    local ev2 = run_op(4)
    local r2 = parse(raw_bytes())
    H.check(r2 and r2.class == RSP[XFER_STATUS] and r2.seq == s2, "no-host: the DONE query was not answered")
    local rts = command_times(ev2).rts
    local held = us(reply_end, rts) / 1000
    H.check(held > 499 and held < 501, "no-host: READY returned %.3f ms after the reply, want the 500 ms bound", held)
    H.check(r2.data[1] == id and r2.data[2] == BULK_NO_HOST, "no-host: DONE id %02X status %02X, want %02X status %02X", r2.data[1], r2.data[2], id, BULK_NO_HOST)
    close_file(handle, 4096)
    out("OUT admission no-host done %02X", r2.data[2])
    -- Back to back: the second request waits on READY while the first is served.
    local first = packet(PING, next_seq(), {})
    local second = packet(PING, next_seq(), {})
    poke(MB.PKT, first)
    mem:write_u8(MB.PKTLEN, #first)
    poke(MB.PKT2, second)
    mem:write_u8(MB.PKT2LEN, #second)
    local calls0 = ping()
    run_op(5)
    local reply = parse(raw_bytes())
    H.check(mem:read_u16(MB.READY_POLLS) > 0, "back to back: the second request never waited on READY")
    H.check(reply and reply.class == 0x81 and reply.seq == second[6], "back to back: no reply to the second request")
    local calls1 = ping()
    H.check(calls1 == calls0 + 3, "back to back: calls %d -> %d, want +3 (two requests and a PING)", calls0, calls1)
    out("OUT admission back-to-back calls +%d", calls1 - calls0)
    -- Guest timeout: the transmitter stalls inside the request; no reply, one abort.
    local _, aborts0 = ping()
    local s3 = cmd_packet(PING, {})
    local ev3 = run_op(4, { stall_at = 5, stall_n = 23 })
    H.check(parse(raw_bytes()) == nil, "stalled request: answered")
    local _, aborts = ping()
    H.check(aborts == aborts0 + 1, "stalled request: aborts %d -> %d, want one more", aborts0, aborts)
    out("OUT admission stalled-request aborts +%d", aborts - aborts0)
    flush_lines()
    return string.format("%s: no host held READY %.3f ms (DONE %02X), back-to-back requests answered, a stalled request dropped (aborts 1) and the next served",
        FAST and "fast" or "paced", held, BULK_NO_HOST)
end)

-- Partial transfers: a read abandoned after 100 bytes still lets the controller
-- finish and serve the next request; a write whose payload ends 212 bytes
-- short commits what the SIO sent (its CRC, then the WR7 fill), the same in
-- both modes.
H.case_body("partial", function()
    start_probe()
    init()
    link_sync()
    local handle = open_file("R4K", "BIN", 0)
    local data = { handle, 0, 0, 0, 0, 0, 2 }
    local s = cmd_packet(FS_READ, data)
    local events = run_op(6, { len = 512, bhunt = true, stop = 100 })
    local ready = parse(raw_bytes())
    H.check(ready and ready.class == RSP[FS_READ] and mem:read_u8(MB.BRES) == 5, "abandoned read: result %d", mem:read_u8(MB.BRES))
    local abandoned = events[#events].t
    local calls0 = ping()
    local c = nil
    local r = exchange(XFER_STATUS, {})
    H.check(r.data[2] == 0 and r.data[1] == ready.data[1], "abandoned read: DONE id %02X status %02X", r.data[1], r.data[2])
    out("OUT partial read DONE %02X", r.data[2])
    close_file(handle, 4096)
    -- Short write.
    local wh = open_file("P512", "BIN", 1)
    local ws = cmd_packet(FS_WRITE, { wh, 0, 0, 0, 0, 0, 2 })
    for i = 0, 299 do mem:write_u8(MB.BBUF + i, pattern(i)) end
    poke(MB.BHDR, { 515 & 255, 515 >> 8, FS_WRITE, ws, 0 })
    local wev = run_op(7, { len = 300 })
    local wr = parse(raw_bytes())
    H.check(wr and wr.class == RSP[FS_WRITE] and mem:read_u8(MB.BRES) == 0, "short write: result %d", mem:read_u8(MB.BRES))
    local done = exchange(XFER_STATUS, {})
    H.check(done.data[1] == wr.data[1] and done.data[2] == 0, "short write: DONE id %02X status %02X", done.data[1], done.data[2])
    out("OUT partial write DONE %02X", done.data[2])
    close_file(wh, 512)
    local calls1 = ping()
    H.check(calls1 > calls0, "the controller stopped answering after the partial transfers")
    flush_lines()
    return string.format("%s: a read abandoned after 100 bytes and a write short by 212 bytes both ended; the next requests were answered", FAST and "fast" or "paced")
end)

-- Resets with work pending: the machine resets inside the command window, the
-- reply, a bulk read, a bulk write and the wait for the host.  Each leaves the
-- controller idle with nothing scheduled and nothing counted, and the next
-- LINK_SYNC and PINGs, run over the 500 ms the cancelled wait would have
-- ended in, see only their own replies.
local function reset_scenario(name, op_setup, trigger, long)
    -- Bring up, start the operation, reset from the trigger.
    mem:write_u8(MB.CMD, 0)
    local before = { init = true }
    op_setup()
    local fired, last_reply
    triggers[#triggers + 1] = function(e)
        if e.ch == 1 and e.k == "dr" then last_reply = e.t end
        if fired or not trigger(e) then return fired ~= nil end
        fired = device_state()
        fired.t = H.now()
        fired.reply_end = last_reply
        H.machine:soft_reset()
        return true
    end
    return function() return fired end
end

local function after_reset(name, fired, long)
    local t = H.now()
    H.wait(function() return H.now() > t + 0.02 end, 1, "the reset")
    local state = device_state()
    H.check(state.phase == PHASE.IDLE and state.count == 0 and state.bulk_count == 0 and state.waiting == 0 and state.starved == 0,
        "%s: after the reset phase %d count %d bulk %d waiting %s starved %s", name, state.phase, state.count, state.bulk_count,
        tostring(state.waiting), tostring(state.starved))
    H.check(state.calls == 0, "%s: %d service calls after the reset", name, state.calls)
    init()
    link_sync()
    local calls = ping()
    H.check(calls == 2, "%s: calls %d after the reset, want 2", name, calls)
    -- A wait that was pending would end 500 ms after the READY reply: run
    -- requests back to back across that instant.
    local n = 0
    if long then
        local stale = fired.reply_end + 0.5
        H.wait(function()
            if H.now() >= stale - 0.045 then return true end
            local c, aborts = ping()
            n = n + 1
            H.check(c == 2 + n and aborts == 0, "%s: PING %d calls %d aborts %d", name, n, c, aborts)
        end, 2, "the instant the cancelled wait would have ended")
        cmd_packet(PING, {})
        run_op(8, { burst = 40 })
        H.check(mem:read_u8(MB.RESULT) == 0, "%s: a request in the burst across the cancelled wait went unanswered (result %d)", name, mem:read_u8(MB.RESULT))
        local c, aborts = ping()
        n = n + 41
        H.check(c == 2 + n and aborts == 0, "%s: after the burst calls %d aborts %d, want %d and 0", name, c, aborts, 2 + n)
        H.check(H.now() > stale + 0.005, "%s: the burst ended at %.4f s, before the cancelled wait's %.4f s", name, H.now(), stale)
    end
    out("OUT reset %s phase %d then calls %d", name, fired.phase, 2 + n)
    return string.format("%s (phase %d)", name, fired.phase)
end

local function count_events(match, nth)
    local seen = 0
    return function(e)
        if match(e) then
            seen = seen + 1
            return seen == nth
        end
        return false
    end
end

H.case_body("reset", function()
    start_probe()
    init()
    link_sync()
    local handle = open_file("R4K", "BIN", 0)
    local done = {}
    -- 1. Inside the request window (the third request byte).
    local fired = reset_scenario("window",
        function() cmd_packet(PING, {}); post_async(4) end,
        count_events(function(e) return e.ch == 1 and e.k == "dw" end, 3))
    H.wait(fired, 1, "the window reset")
    done[#done + 1] = after_reset("window", fired())
    -- 2. Inside the reply (the fifth reply byte read).
    init(); link_sync()
    fired = reset_scenario("reply",
        function() cmd_packet(PING, {}); post_async(4) end,
        count_events(function(e) return e.ch == 1 and e.k == "dr" and e.v == 0xa5 end, 1))
    H.wait(fired, 1, "the reply reset")
    done[#done + 1] = after_reset("reply", fired())
    -- 3. Inside a bulk read (the 200th data read of the packet).
    init(); link_sync()
    local handle2 = open_file("R4K", "BIN", 0)
    fired = reset_scenario("bulk read",
        function() cmd_packet(FS_READ, { handle2, 0, 0, 0, 0, 0, 2 }); post_async(6, { len = 512, bhunt = true }) end,
        count_events(function(e) return e.ch == 0 and e.k == "dr" end, 200))
    H.wait(fired, 1, "the bulk read reset")
    H.check(fired().phase == PHASE.BULK_SEND, "bulk read: reset in phase %d, want BULK_SEND", fired().phase)
    done[#done + 1] = after_reset("bulk read", fired())
    -- 4. Inside a bulk write (the 100th data write).
    init(); link_sync()
    local wh = open_file("W4K", "BIN", 1)
    for i = 0, 511 do mem:write_u8(MB.BBUF + i, pattern(i)) end
    fired = reset_scenario("bulk write",
        function()
            local s = cmd_packet(FS_WRITE, { wh, 0, 0, 0, 0, 0, 2 })
            poke(MB.BHDR, { 515 & 255, 515 >> 8, FS_WRITE, s, 0 })
            post_async(7, { len = 512 })
        end,
        count_events(function(e) return e.ch == 0 and e.k == "dw" end, 100))
    H.wait(fired, 1, "the bulk write reset")
    H.check(fired().phase == PHASE.BULK_RECEIVE, "bulk write: reset in phase %d, want BULK_RECEIVE", fired().phase)
    done[#done + 1] = after_reset("bulk write", fired())
    -- 5. While the controller waits for a host that never comes.
    init(); link_sync()
    local handle3 = open_file("R4K", "BIN", 0)
    fired = reset_scenario("host wait",
        function() cmd_packet(FS_READ, { handle3, 0, 0, 0, 0, 0, 2 }); post_async(6, { len = 512, bhunt = true, norts = true }) end,
        count_events(function(e) return e.ch == 0 and e.k == "wr" and e.reg == 3 end, 1))
    H.wait(fired, 1, "the host-wait reset")
    H.check(fired().phase == PHASE.BULK_HOST, "host wait: reset in phase %d, want BULK_HOST", fired().phase)
    done[#done + 1] = after_reset("host wait", fired(), true)
    flush_lines()
    return string.format("%s: resets with work pending (%s) each left the controller idle with nothing scheduled; the next exchanges, run past the cancelled 500 ms wait, saw only their own replies",
        FAST and "fast" or "paced", table.concat(done, ", "))
end)

-- Save state in flight: a bulk read is saved at its 300th data read and
-- finished from the restored state in a second process, whose first port
-- access finds the controller mid-packet.
local restored
if H.case == "state-load" then
    triggers[#triggers + 1] = function(e)
        if e.ch ~= 0 or e.k ~= "dr" then return false end
        restored = device_state()
        restored.t = H.now()
        return true
    end
end

H.case_body("state-save", function()
    start_probe()
    init()
    link_sync()
    local handle = open_file("R4K", "BIN", 0)
    local s = cmd_packet(FS_READ, { handle, 0, 0, 0, 0, 0, 2 })
    local saved
    triggers[#triggers + 1] = count_events(function(e) return e.ch == 0 and e.k == "dr" end, 300)
    local fire = triggers[#triggers]
    triggers[#triggers] = function(e)
        if not fire(e) then return false end
        saved = device_state()
        saved.t = H.now()
        H.machine:save("midbulk")
        return true
    end
    run_op(6, { len = 512, bhunt = true })
    H.check(saved, "the 300th data read never came")
    H.check(mem:read_u8(MB.BRES) == 0, "the saved process's own read failed (%d)", mem:read_u8(MB.BRES))
    local ready = parse(raw_bytes())
    local calls = ping()
    H.check(saved.phase == PHASE.BULK_SEND, "saved in phase %d, want BULK_SEND", saved.phase)
    local f = assert(io.open(H.dir .. "/state.txt", "w"))
    f:write(string.format("phase=%d bulk_count=%d calls=%d id=%d t=%.6f\n", saved.phase, saved.bulk_count, saved.calls, ready.data[1], saved.t))
    f:close()
    local t = H.now()
    H.wait(function() return H.now() > t + 0.05 end, 1, "the save")
    return string.format("saved in BULK_SEND with %d of 521 bytes clocked at %.6f s; the process finished the read itself", saved.bulk_count, saved.t)
end)

H.case_body("state-load", function()
    local prev = {}
    for line in io.lines(assert(os.getenv("HARNESS_PREV"), "HARNESS_PREV") .. "/state.txt") do
        for k, v in line:gmatch("([%w_]+)=([%d.]+)") do prev[k] = tonumber(v) end
    end
    H.check(restored, "the restored process saw no data read")
    H.check(restored.phase == PHASE.BULK_SEND, "restored in phase %d, want BULK_SEND", restored.phase)
    H.check(restored.bulk_count >= prev.bulk_count - 2 and restored.bulk_count <= prev.bulk_count + 80,
        "restored with %d bytes clocked, saved at about %d", restored.bulk_count, prev.bulk_count)
    wait_op(6)
    H.check(mem:read_u8(MB.RESULT) == 0 and mem:read_u8(MB.BRES) == 0, "the restored read failed (result %d, bulk %d)",
        mem:read_u8(MB.RESULT), mem:read_u8(MB.BRES))
    for i = 0, 511 do
        local v = mem:read_u8(MB.BBUF + i)
        H.check(v == pattern(i), "restored payload byte %d is %02X, want %02X", i, v, pattern(i))
    end
    local ready = parse(raw_bytes())
    local done = exchange(XFER_STATUS, {})
    H.check(done.data[1] == prev.id and done.data[2] == 0, "restored DONE id %02X status %02X, want %02X status 0", done.data[1], done.data[2], prev.id)
    local calls = ping()
    H.check(calls == prev.calls + 2, "calls %d after the restore, want %d", calls, prev.calls + 2)
    out("OUT state restored payload ok, DONE %02X, calls %d", done.data[2], calls)
    flush_lines()
    return string.format("restored in BULK_SEND with %d bytes clocked (saved at about %d); the read completed with all 512 bytes, DONE %02X, calls continued to %d",
        restored.bulk_count, prev.bulk_count, done.data[2], calls)
end)

-- The ZSDOS reader (sio1_lanes.asm op 9: IOCBULK's call-based marker scan, INI
-- header, setup and INI payload at the driver's own loop rates) reading
-- /SHARED records and blocks on a lane that has just hunted, just written and
-- just read.  Its cover against the wire's marker and header spacing is the
-- smallest of any guest path; one character lost anywhere fails the read.
local function zread(handle, offset, n, label, hunt)
    local s = cmd_packet(FS_READ, { handle, offset & 255, (offset >> 8) & 255, (offset >> 16) & 255, (offset >> 24) & 255, n & 255, n >> 8 })
    mem:write_u16(MB.BZPTR, MB.BBUF)
    local events = run_op(9, { len = n, bhunt = hunt })
    local reply = parse(raw_bytes())
    H.check(mem:read_u8(MB.RESULT) == 0 and reply and reply.class == RSP[FS_READ] and reply.seq == s and reply.status == 0,
        "%s: no READY reply", label)
    H.check(mem:read_u8(MB.BRES) == 0, "%s: the ZSDOS-shaped read failed (result %d): a character was lost behind the reader", label, mem:read_u8(MB.BRES))
    for i = 0, n - 1 do
        local v = mem:read_u8(MB.BBUF + i)
        H.check(v == pattern(offset + i), "%s: byte %d is %02X, want %02X (a character was lost behind the reader)", label, i, v, pattern(offset + i))
    end
    out("OUT zsdos %s ok", label)
end

H.case_body("zsdos", function()
    start_probe()
    init()
    link_sync()
    -- /SHARED holds one open file: each write goes to W4K.BIN and R4K.BIN is reopened for the read after it.
    local function write_then_open()
        local wh = open_file("W4K", "BIN", 1)
        local ws = cmd_packet(FS_WRITE, { wh, 0, 0, 0, 0, 128, 0 })
        for i = 0, 127 do mem:write_u8(MB.BBUF + i, pattern(i)) end
        poke(MB.BHDR, { 131, 0, FS_WRITE, ws, 0 })
        run_op(7, { len = 128 })
        H.check(mem:read_u8(MB.BRES) == 0, "the write failed")
        close_file(wh, 128)
        return (open_file("R4K", "BIN", 0))
    end
    local handle = open_file("R4K", "BIN", 0)
    zread(handle, 0, 128, "first read (hunt)", true)
    handle = write_then_open()
    zread(handle, 128, 128, "128 B after a write", false)
    zread(handle, 256, 128, "128 B after a read", false)
    zread(handle, 512, 512, "512 B after a read", false)
    handle = write_then_open()
    zread(handle, 1024, 512, "512 B after a write", false)
    flush_lines()
    return string.format("%s: the ZSDOS-shaped reader lost nothing on 5 reads (after hunt, a write and a read; 128 B and 512 B)", FAST and "fast" or "paced")
end)
