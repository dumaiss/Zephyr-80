-- license:BSD-3-Clause
-- Acceptance bodies (tests/acceptance.py) that the device cases do not
-- already hold.  Runs under harness.lua.
--
--   hwtest  the production KonaOS image with a writable card: `hwtest` typed
--           on the USB keyboard at the shell; the exerciser's lines read off
--           the V9958 console and off the serial lane it mirrors them to
--           (/dev/serial/0, SIO0/B); the verdict must be exactly
--           `hwtest: 4/4 PASS` and the shell must come back.
local H = harness
local C = H.vdp.console
local K = H.keyboard
local S = H.serial

if os.getenv("HARNESS_FONT") then C.load_font(os.getenv("HARNESS_FONT")) end

local function trimmed(line)
    return (line:gsub("%s+$", ""))
end

local function rows_text(rows)
    local out = {}
    for _, r in ipairs(rows) do
        local shown = trimmed(C.printable(r))
        if shown ~= "" then out[#out + 1] = shown end
    end
    return out
end

local function dump(name)
    C.dump(name .. ".txt")
    H.vdp.snapshot(name .. ".png")
end

-- The lines the exerciser prints (tests/hwtest/hwtest.c's output contract;
-- tools/serial_smoke.py --mode hwtest reads the same on the board).
local STAGES = { "hwtest: begin", "hwtest: xmem+far PASS", "hwtest: files PASS", "hwtest: timer PASS",
                 "hwtest: namespace+handles PASS" }
local VERDICT = "hwtest: 4/4 PASS"

H.case_body("hwtest", function()
    local P = "/> "
    S.attach(5)
    local _, _, t = C.wait(trimmed(P), 40, "the KonaOS shell prompt at the card root")
    dump("01-prompt")
    local lane_from = S.mark()
    -- The console scrolls while the stages run: keep every line read off it.
    local seen, order = {}, {}
    local function collect(r)
        for _, line in ipairs(r) do
            local s = trimmed(C.printable(line))
            if s ~= "" and not seen[s] then
                seen[s] = true
                order[#order + 1] = s
            end
        end
    end
    K.type("hwtest")
    K.tap("Enter")
    local typed = H.now()
    C.wait_for(function(r)
        collect(r)
        return seen[VERDICT] or seen["hwtest: 4/4 FAIL"]
    end, 180, "the exerciser's verdict on the console", 1)
    local verdict_at = H.now()
    -- The shell's prompt after the verdict.
    local rows = C.wait_for(function(r)
        collect(r)
        local last
        for i, line in ipairs(r) do
            if trimmed(line):find("^hwtest: %d/4 ") then last = i end
        end
        for i = (last or #r) + 1, #r do
            if r[i]:sub(1, #P) == P then return r end
        end
    end, 20, "the shell prompt after the verdict")
    dump("02-verdict")
    local transcript = assert(io.open(H.dir .. "/transcript.txt", "w"))
    transcript:write(table.concat(order, "\n") .. "\n")
    transcript:close()
    local shown = H.escape(table.concat(rows_text(rows), " | "))
    for _, line in ipairs(STAGES) do
        H.check(seen[line], "console: %q never shown; screen %s", line, shown)
    end
    H.check(seen[VERDICT], "console: the verdict is not exactly %q; screen %s", VERDICT, shown)
    for _, line in ipairs(order) do
        if line:find("^hwtest:") then
            H.check(not line:find("FAIL", 1, true), "console: %q", line)
        end
        H.check(not line:find("PANIC", 1, true), "console: %q", line)
    end
    -- The serial lane holds the same lines (the board's smoke tool reads them there).
    H.wait(function() return S.data:find(VERDICT .. "\r\n", lane_from, true) end, 5, "the verdict on the serial lane")
    local lane = S.data:sub(lane_from)
    for _, line in ipairs(STAGES) do
        H.check(lane:find(line .. "\r\n", 1, true), "serial lane: %q missing; lane %s", line, H.escape(lane))
    end
    H.check(not lane:find(" FAIL", 1, true) and not lane:find("PANIC", 1, true), "serial lane: %s", H.escape(lane))
    H.trace("hwtest verdict %.3f s after Enter; prompt at %.3f s", verdict_at - typed, t)
    return string.format("%s on the console and the serial lane, %.3f emulated s after Enter, shell prompt again",
        VERDICT, verdict_at - typed)
end)
