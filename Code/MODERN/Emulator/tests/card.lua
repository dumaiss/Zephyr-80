-- license:BSD-3-Clause
-- Card socket guest sessions (tests/card_backends.py): a shell driven over
-- the serial console with `-card` or `-carddir` media, one step per line of
-- HARNESS_STEPS ("command<TAB>expected substrings separated by 1Fh").  Each
-- step types its command, waits for the prompt and checks the answer holds
-- every expected substring; a step with none must answer nothing at all
-- (the shells print nothing on success).  A program that ends through WBOOT
-- with "[any key]" gets a key.  Each step's emulated duration is traced.
local H = harness
local S = H.serial

local BANNER = "KonaOS 0.0\r\nplatform: Zephyr-80\r\n"
local ANY_KEY = "[any key]"

local function steps()
    local out = {}
    local file = assert(os.getenv("HARNESS_STEPS"), "HARNESS_STEPS")
    for line in io.lines(file) do
        local command, expect = line:match("^([^\t]*)\t(.*)$")
        local list = {}
        for part in expect:gmatch("[^\31]+") do list[#list + 1] = part end
        out[#out + 1] = { command = command, expect = list }
    end
    return out
end

-- The answer to one command: from after its echo to the next prompt.
local function run_step(step, timeout)
    local start = H.now()
    local from = S.type(step.command, 5)
    local entered = H.now()
    local stop
    H.wait(function()
        local key = S.data:find(ANY_KEY, from, true)
        local _, prompt = S.data:find(H.prompt, from, true)
        if key and (not prompt or key < prompt) and not step.keyed then
            step.keyed = true
            S.send(" ")
        end
        if prompt and (not key or prompt > key) then
            stop = prompt
            return true
        end
        return false
    end, timeout, string.format("the prompt after %q", step.command))
    -- Everything before the prompt's own line (which names the directory).
    local answer = S.data:sub(from, stop - #H.prompt):match("^(.*\n)") or ""
    for _, want in ipairs(step.expect) do
        H.check(answer:find(want, 1, true), "%q answered %s; %q missing", step.command, H.escape(answer), want)
    end
    if #step.expect == 0 then
        H.check(not answer:find("[%w]"), "%q answered %s; want nothing", step.command, H.escape(answer))
    end
    H.trace("step %q %.6f s, answered %.6f s after CR", step.command, H.now() - start, H.now() - entered)
    return answer
end

-- KonaOS console-serial image: host sync, the card's root prompt, the steps.
H.case_body("card-shell", function()
    S.attach(5)
    S.host_sync(10)
    S.wait(H.prompt, 90, 1, string.format("shell prompt %q", H.prompt))
    H.check(S.data:find(BANNER, 1, true), "the kernel banner is missing")
    H.trace("prompt %s at %.3f emulated s", H.escape(H.prompt), H.now())
    local list = steps()
    for _, step in ipairs(list) do run_step(step, 60) end
    return string.format("%d shell commands answered as expected", #list)
end)

-- ZSDOS: its console is the V9958; three ESC on SIO0/B hand input to the
-- serial port and arm the output tee (common/sercon.asm).
H.case_body("card-zsdos", function()
    S.attach(5)
    H.wait(function() return H.now() > 6 end, 8, "ZSDOS boot")
    for _ = 1, 3 do
        S.send("\27")
        local t = H.now()
        H.wait(function() return H.now() > t + 0.05 end, 1, "the gap between ESC bytes")
    end
    local mark = S.mark()
    S.send("\r")
    S.wait(H.prompt, 10, mark, "the ZephyrShell prompt on the serial tee")
    H.trace("serial takeover at %.3f emulated s", H.now())
    local list = steps()
    for _, step in ipairs(list) do run_step(step, 60) end
    return string.format("%d ZephyrShell commands answered as expected", #list)
end)
