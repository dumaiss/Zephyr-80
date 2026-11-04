-- license:BSD-3-Clause
-- Keyboard cases (tests/keyboard.py): MAME key input through the USB
-- keyboard's fields, the IO controller's HID module and the real SIO1/B
-- command lane, observed by the probe program and by the guests' own
-- screens (harness.vdp.console).  Runs under harness.lua.
local H = harness
local C = H.vdp.console
local K = H.keyboard
dofile(assert(os.getenv("HARNESS_SCRIPT")):match("^(.*/)") .. "sio1_lanes.lua") -- H.lanes
local L = H.lanes
local mem = H.program

if os.getenv("HARNESS_FONT") then C.load_font(os.getenv("HARNESS_FONT")) end

-- The state-load case holds its key from the start: the field is set before
-- the state is restored, so the first scan after the restore finds it held.
if H.case == "kbd-state-load" then K.set("R", true) end

-- Probe program helpers -------------------------------------------------------

local seq = 1
local function next_seq()
    seq = seq % 255 + 1
    return seq
end

-- /CTSB as the guests sample it (op 10: Reset External/Status, RR0 D5).
local function doorbell()
    L.post(10)
    return (mem:read_u8(L.MB.DOORBELL) & 0x20) ~= 0
end

-- HID_INPUT asking for `wanted`; returns queued, dropped and the bytes.
local function hid_input(wanted)
    local s = next_seq()
    local r = L.exchange(0x0e, s, { wanted })
    local d = L.expect_reply(r, 0x8e, s, "HID_INPUT").data
    H.check(#d >= 2 and #d - 2 <= math.min(wanted, 24), "HID_INPUT %d: %d DATA bytes", wanted, #d)
    local bytes = {}
    for i = 3, #d do bytes[#bytes + 1] = d[i] end
    return d[1], d[2], bytes
end

-- Every queued byte, 24 a reply.
local function drain()
    local all, queued, dropped = {}, nil, nil
    repeat
        local bytes
        queued, dropped, bytes = hid_input(24)
        for _, b in ipairs(bytes) do all[#all + 1] = b end
    until queued == 0
    return all, dropped
end

local function text(bytes)
    local out = {}
    for i, b in ipairs(bytes) do out[i] = string.char(b) end
    return table.concat(out)
end

-- Press a key; returns the emulated time of the frame whose input update
-- applied it (the keyboard's scan and report run at that instant).
local function press(key)
    K.set(key, true)
    K.frames(1)
    return H.now()
end

local function release(key)
    K.set(key, false)
    K.frames(1)
    return H.now()
end

local function wait_until(t, what)
    H.wait(function() return H.now() >= t end, t - H.now() + 1, what)
end

-- The firmware's repeat for a key pressed at `tp` and released at `tr`
-- (ioc_hid.c: due REPEAT_DELAY_MS after the 10 ms tick of the press, then
-- REPEAT_PERIOD_MS after each tick it fired at; the controller is idle, so
-- each repeat runs at its tick): the bytes it queues, with the press.
local function repeats(tp, tr)
    local due = math.floor(tp * 100 + 1e-9) / 100 + 0.5
    local n = 1
    while due < tr - 1e-9 do
        n = n + 1
        due = due + 0.06
    end
    return n
end

-- The lane: input path, queue, doorbell, repeat, overflow, reset -------------

H.case_body("kbd-lane", function()
    L.start_probe()
    L.init(0)
    L.link_sync(1)
    local notes = {}

    -- HID_STATUS page 0: the emulated keyboard, no USB probe claimed.
    local s = next_seq()
    local st = L.expect_reply(L.exchange(0x0d, s, { 0 }), 0x8d, s, "HID_STATUS").data
    H.check(#st == 26 and st[1] == 0 and st[2] == 0 and st[14] == 1 and st[15] == 1 and st[26] == 0,
        "HID_STATUS page 0: status %02X revision %02X devices %d address %d speed %02X", st[1], st[2], st[14], st[15], st[26])

    -- Idle: /CTSB released, the queue empty.
    H.check(not doorbell(), "/CTSB asserted with nothing typed")
    local q, d = hid_input(0)
    H.check(q == 0 and d == 0, "idle queue: %d queued, %d dropped", q, d)

    -- Lowercase, Shift, Ctrl, an arrow and a function key, queued unread.
    K.tap("A")
    K.chord({ "Left Shift", "B" })
    K.chord({ "Right Ctrl", "C" })
    K.tap("Up")
    K.tap("F5")
    K.frames(2)
    H.check(doorbell(), "/CTSB released with input queued")
    local want = { 0x61, 0x42, 0x03, 0x1b, 0x5b, 0x41, 0x1b, 0x5b, 0x31, 0x35, 0x7e }
    local bytes
    q, d, bytes = hid_input(2)
    H.check(q == 9 and d == 0 and #bytes == 2 and bytes[1] == 0x61 and bytes[2] == 0x42,
        "partial dequeue of 2: %d queued, %d dropped, %s", q, d, L.hx(bytes))
    H.check(doorbell(), "/CTSB lost after a partial dequeue")
    q, d, bytes = hid_input(24)
    H.check(q == 0 and #bytes == 9 and not doorbell(), "the rest: %d queued, %s; doorbell %s", q, L.hx(bytes), tostring(doorbell()))
    for i = 3, #want do
        H.check(bytes[i - 2] == want[i], "byte %d: %02X, want %02X (%s)", i, bytes[i - 2] or 0, want[i], L.hx(bytes))
    end
    notes[#notes + 1] = "a Shift+b Ctrl+c Up F5 -> 61 42 03 1B 5B 41 1B 5B 31 35 7E, partial dequeue 2 + 9 with /CTSB held until drained"

    -- Held key: the firmware's delay and period on the emulated clock, and
    -- nothing after the release.
    local tp = press("X")
    wait_until(tp + 1.0, "the held key")
    local tr = release("X")
    local expect = repeats(tp, tr)
    wait_until(tr + 0.5, "time after the release")
    local got = drain()
    H.check(#got == expect and text(got) == string.rep("x", expect),
        "held x %.4f s (%.4f..%.4f): %d bytes %s, want %d", tr - tp, tp, tr, #got, L.hx(got, 1, 24), expect)
    wait_until(H.now() + 0.5, "a quiet half second")
    q = hid_input(0)
    H.check(q == 0 and not doorbell(), "a released key still repeats: %d queued", q)
    notes[#notes + 1] = string.format("x held %.3f s: %d bytes (press + %d repeats), none after the release", tr - tp, expect, expect - 1)

    -- Held with nothing draining: the repeat stops at half the queue.
    tp = press("Z")
    wait_until(tp + 6, "a long hold")
    release("Z")
    q, d = hid_input(0)
    H.check(q == 64 and d == 0, "held z 6 s undrained: %d queued, %d dropped (want 64, 0)", q, d)
    got = drain()
    H.check(text(got) == string.rep("z", 64), "the 64 bytes: %s", L.hx(got, 1, 8))
    notes[#notes + 1] = "z held 6 s undrained: 64 queued, 0 dropped"

    -- Overflow: whole sequences or a drop.
    for _ = 1, 43 do K.tap("Down", 1, 1) end
    q, d = hid_input(0)
    H.check(q == 126 and d == 1, "43 arrows: %d queued, %d dropped (want 126, 1)", q, d)
    K.tap("A")
    K.tap("B")
    K.tap("C")
    q, d, bytes = hid_input(24)
    H.check(q == 104 and d == 2 and #bytes == 24 and bytes[1] == 0x1b and bytes[3] == 0x42,
        "full queue: %d left after 24, %d dropped (want 104, 2)", q, d)
    got = drain()
    H.check(#got == 104 and got[101] == 0x5b and got[102] == 0x42 and got[103] == 0x61 and got[104] == 0x62,
        "queue tail %s (want ... 1B 5B 42 61 62)", L.hx(got, 99, 104))
    notes[#notes + 1] = "43 Down + a b c: 126 then 128 queued, the 43rd arrow and c dropped whole (dropped 2), 24 per reply"

    -- Reset: the queue, drops and doorbell are the controller's and go with
    -- it; a key held across the reset is reported once by the new
    -- enumeration and stops when released.
    K.tap("Q")
    K.frames(2)
    H.check(doorbell(), "q not queued")
    K.set("W", true)
    K.frames(2)
    H.machine:soft_reset()
    local t0 = H.now()
    H.wait(function() return H.now() > t0 + 0.02 end, 1, "the reset")
    local tw = release("W")
    L.start_probe()
    L.init(0)
    L.link_sync(next_seq())
    got, d = drain()
    H.check(#got >= 1 and text(got) == string.rep("w", #got) and d == 0, "after the reset: %s, %d dropped (want w only, q gone)", L.hx(got), d)
    wait_until(H.now() + 0.6, "after the held key's release")
    q = hid_input(0)
    H.check(q == 0 and not doorbell(), "a key held across the reset sticks: %d queued", q)
    notes[#notes + 1] = string.format("reset: q and the drop count gone; W held across it reported (%d byte), released at %.3f s, no repeat after", #got, tw)

    -- Ctrl+Alt+Esc resets the machine; no Escape is queued.
    local calls = L.ping(next_seq())
    K.chord({ "Left Ctrl", "Left Alt", "Escape" }, 1, 1)
    t0 = H.now()
    H.wait(function() return H.now() > t0 + 0.05 end, 1, "the reset combination")
    L.start_probe()
    L.init(0)
    L.link_sync(next_seq())
    local after, aborts = L.ping(next_seq())
    H.check(after == 2 and aborts == 0 and calls > 2, "PING calls %d before, %d after Ctrl+Alt+Esc (want a restart at 2)", calls, after)
    q, d = hid_input(0)
    H.check(q == 0 and d == 0, "Ctrl+Alt+Esc queued %d bytes", q)
    notes[#notes + 1] = string.format("Ctrl+Alt+Esc: the controller restarted (PING calls %d -> %d), nothing queued", calls, after)
    return table.concat(notes, "; ")
end)

-- Save state: the queue, the held key and the repeat phase -------------------

-- Saved mid-period with "ab" and four r's queued (the press and three
-- repeats) and R held; process 1 keeps running and records what it queues
-- by the check time, five repeats later.
local STATE_FILE = os.getenv("HARNESS_STATE_FILE") or (H.dir .. "/kbd-state.tsv")

H.case_body("kbd-state-save", function()
    L.start_probe()
    L.init(0)
    L.link_sync(1)
    K.tap("A")
    K.tap("B")
    local tp = press("R")
    local tick = math.floor(tp * 100 + 1e-9) / 100
    local ts = tick + 0.5 + 0.12 + 0.03       -- between the third repeat and the fourth
    wait_until(ts, "the save point")
    H.machine:save("kbd")
    local saved = H.now()
    local check = tick + 0.5 + 0.06 * 7 + 0.03 -- mid-period, five repeats later
    wait_until(check, "the check time")
    local got = drain()
    local f = assert(io.open(STATE_FILE, "w"))
    f:write(string.format("%.9f\t%.9f\t%.9f\t%s\n", tp, saved, check, text(got)))
    f:close()
    local want = "ab" .. string.rep("r", repeats(tp, check))
    H.check(text(got) == want, "continuous run: %q, want %q", text(got), want)
    return string.format("saved at %.4f s (R pressed at %.4f); the continuous run queued %q by %.4f s", saved, tp, text(got), check)
end)

local function saved_run()
    local f = assert(io.open(STATE_FILE, "r"))
    local tp, saved, check, got = f:read("l"):match("^(%S+)\t(%S+)\t(%S+)\t(.*)$")
    f:close()
    return tonumber(tp), tonumber(saved), tonumber(check), got
end

-- R held (set before the restore): the same bytes as the continuous run.
H.case_body("kbd-state-load", function()
    local tp, saved, check, want = saved_run()
    H.wait(function() return H.now() > saved end, saved + 2, "the restore")
    wait_until(check, "the check time")
    local got = drain()
    K.set("R", false)
    H.check(text(got) == want, "after the restore: %q, want the continuous run's %q", text(got), want)
    return string.format("restored at %.4f s with R held: queue and repeat phase continue, %q by %.4f s as without the save", saved, text(got), check)
end)

-- R not held in the new session: the first scan releases it, the repeat
-- stops, the queued bytes stay.
H.case_body("kbd-state-release", function()
    local tp, saved = saved_run()
    H.wait(function() return H.now() > saved end, saved + 2, "the restore")
    wait_until(saved + 1.0, "a second after the restore")
    local got = drain()
    local want = "ab" .. string.rep("r", 4)
    H.check(text(got) == want, "after the restore with R up: %q, want %q (no repeat after the release)", text(got), want)
    return string.format("restored with R up: the saved queue %q, then no repeat (the first scan released the key)", text(got))
end)


-- Guests ---------------------------------------------------------------------
--
-- Each step types through the keyboard, then waits for the screen the guest
-- draws in answer (harness.vdp.console): the text of the VRAM bitmap,
-- matched against the guest's own font.  Every step's screen goes to the
-- transcript and a snapshot.

local transcript
local shots = 0
local function shot(name)
    shots = shots + 1
    local base = string.format("%02d-%s", shots, name)
    C.dump(base .. ".txt")
    H.vdp.snapshot(base .. ".png")
    transcript = transcript or assert(io.open(H.dir .. "/transcript.txt", "w"))
    transcript:write(string.format("== %s at %.3f emulated s\n", base, H.now()))
    for i, line in ipairs(C.last.rows) do
        local shown = C.printable(line):gsub("%s+$", "")
        if shown ~= "" then transcript:write(string.format("%2d %s\n", i, shown)) end
    end
    transcript:flush()
end

local function trimmed(line)
    return (line:gsub("%s+$", ""))
end

-- The first row (1-based) whose text, trailing spaces dropped, is `line`.
local function find_line(line, rows)
    for i, r in ipairs(rows) do
        if trimmed(r) == line then return i end
    end
end

local function wait_line(line, timeout, what)
    return C.wait_for(function(rows) return find_line(line, rows) end, timeout, what or string.format("the line %q", line))
end

-- Wait for `predicate(rows)` and return its value.
local function wait_screen(predicate, timeout, what)
    return C.wait_for(predicate, timeout, what)
end

-- The row holding the last prompt and what follows it on that row.
local function prompt_row(prompt, rows)
    rows = rows or C.read()
    for i = #rows, 1, -1 do
        if rows[i]:sub(1, #prompt) == prompt then return i, trimmed(rows[i]:sub(#prompt + 1)) end
    end
end

-- Input-to-visible time of `key`: from the report (the frame that applied
-- it) to the first VRAM write into the bitmap's page 0, and to the frame the
-- observer first reads `expect` (a predicate on the rows).
local LATENCY = {}
local function timed(name, key, expect, timeout)
    local first
    local tap = H.vdp.vram_space:install_write_tap(0x00000, 0x1ffff, "kbd-latency", function(offset)
        if not first and (offset & 0xffff) < 0x8000 then first = H.now() end
    end)
    K.set(key, true)
    K.frames(1)
    local tp = H.now()
    first = nil
    K.set(key, false)
    local seen = C.wait_for(function(rows) return expect(rows) and H.now() end, timeout or 5, name, 1)
    tap:remove()
    H.check(first ~= nil and first <= seen, "%s: no VRAM write between the key and the screen", name)
    LATENCY[#LATENCY + 1] = string.format("%s %.1f ms to VRAM, %.1f ms to the observed screen", name, (first - tp) * 1000, (seen - tp) * 1000)
    H.trace("latency %s: %.3f ms to the first VRAM write, %.3f ms to the observed screen", name, (first - tp) * 1000, (seen - tp) * 1000)
end

-- KonaOS: the production image, V9958/HID console, no card.
H.case_body("konaos-shell", function()
    local P = "/system> "
    local _, _, t = C.wait(P, 30, "the KonaOS shell prompt on the V9958 console")
    H.trace("prompt at %.3f emulated s", t)
    shot("prompt")
    local notes = { string.format("prompt %.3f s", t) }

    -- Lowercase and Shift, Enter: echo's answer on its own line.
    timed("shell echo", "E", function(rows) local _, rest = prompt_row(P, rows) return rest == "e" end)
    K.type("cho Hello World\r")
    wait_line("Hello World", 5, "echo's answer")
    local rows = C.read()
    H.check(find_line(P .. "echo Hello World", rows) == find_line("Hello World", rows) - 1, "the command line is not above its answer")
    shot("echo")

    -- CapsLock: letters only.
    K.type("echo ")
    K.tap("Caps Lock")
    K.type("up")
    K.tap("Caps Lock")
    K.type(" low 42\r")
    wait_line("UP low 42", 5, "the CapsLock line")
    -- Backspace edits the line.
    K.type("echo abx")
    K.tap("Backspace")
    K.type("c\r")
    wait_line("abc", 5, "the edited line")
    H.check(find_line(P .. "echo abc", C.read()), "the edited command line")
    shot("edit")
    notes[#notes + 1] = "echo Hello World, CapsLock UP low 42, Backspace abx->abc"

    -- An escape sequence the shell swallows (F5), then a command.
    K.tap("F5")
    K.type("pwd\r")
    wait_line("/system", 5, "pwd's answer")
    -- Ctrl-L clears the screen and redraws the prompt.
    K.chord({ "Left Ctrl", "L" })
    wait_screen(function(rows) return trimmed(rows[1]) == trimmed(P) and not find_line("Hello World", rows) end, 5, "the screen cleared by Ctrl-L")
    shot("ctrl-l")
    -- Up recalls the last line (ESC [ A); Down past the newest empties it.
    K.tap("Up")
    wait_screen(function(rows) return trimmed(rows[1]) == P .. "pwd" end, 5, "Up recalling pwd")
    K.tap("Up")
    wait_screen(function(rows) return trimmed(rows[1]) == P .. "echo abc" end, 5, "Up recalling echo abc")
    K.tap("Down")
    wait_screen(function(rows) return trimmed(rows[1]) == P .. "pwd" end, 5, "Down to pwd")
    K.tap("Up")
    wait_screen(function(rows) return trimmed(rows[1]) == P .. "echo abc" end, 5, "Up again")
    K.tap("Enter")
    wait_line("abc", 5, "the recalled command's answer")
    shot("history")
    notes[#notes + 1] = "F5 swallowed, pwd; Ctrl-L clear; Up/Up/Down/Up history"

    -- A held key: the firmware's repeat, then the release.
    K.type("echo ")
    local tp = press("Z")
    wait_until(tp + 1.0, "the held z")
    local tr = release("Z")
    local n, zheld = repeats(tp, tr), tr - tp
    local _, rest
    wait_screen(function(rows) local _, r = prompt_row(P, rows) return r == "echo " .. string.rep("z", n) end, 5,
        string.format("%d z's on the prompt line", n))
    wait_until(H.now() + 0.5, "a quiet half second")
    _, rest = prompt_row(P)
    H.check(rest == "echo " .. string.rep("z", n), "the line changed after the release: %q", rest)
    shot("repeat")
    -- A held Backspace erases the whole line and stops at the prompt.
    tp = press("Backspace")
    wait_until(tp + 1.5, "the held Backspace")
    tr = release("Backspace")
    wait_screen(function(rows) local _, r = prompt_row(P, rows) return r == "" end, 5, "the line erased by the held Backspace")
    K.tap("Enter")
    wait_screen(function(rows) local i = prompt_row(P, rows) return i and trimmed(rows[i]) == trimmed(P) and trimmed(rows[i - 1]) == trimmed(P) end,
        5, "an empty line and the prompt")
    shot("erased")
    notes[#notes + 1] = string.format("z held %.3f s: %d on screen (press + %d repeats), stable after release; Backspace held %.3f s erased %d characters",
        zheld, n, n - 1, tr - tp, 5 + n)
    notes[#notes + 1] = table.concat(LATENCY, "; ")
    return table.concat(notes, "; ")
end)

-- ZSDOS: its V9958/HID console, ZephyrShell's prompt and two commands.
H.case_body("zsdos-shell", function()
    local P = "B0:/$ "
    local _, _, t = C.wait(trimmed(P), 30, "the ZephyrShell prompt on the V9958 console")
    H.trace("prompt at %.3f emulated s", t)
    shot("prompt")
    timed("shell echo", "E", function(rows) local _, rest = prompt_row(P, rows) return rest == "e" end)
    K.type("cho Hello ZSDOS\r")
    wait_line("Hello ZSDOS", 5, "echo's answer")
    K.type("ls\r")
    wait_line("SYSTEM/", 5, "ls's answer")
    shot("commands")
    K.tap("Up")
    wait_screen(function(rows) local _, rest = prompt_row(P, rows) return rest == "ls" end, 5, "Up recalling ls")
    K.tap("Enter")
    wait_screen(function(rows)
        local count = 0
        for _, r in ipairs(rows) do if trimmed(r) == "SYSTEM/" then count = count + 1 end end
        return count == 2
    end, 5, "the recalled ls's answer")
    shot("history")
    return string.format("prompt %.3f s; echo Hello ZSDOS, ls (SYSTEM/), Up recall; %s", t, table.concat(LATENCY, "; "))
end)

-- KonaEdit and KonaCommander from the card.
local function status_line(rows)
    return trimmed(rows[26])
end

local function edit_status(want, what)
    return wait_screen(function(rows) return status_line(rows):find(want, 1, true) end, 5, what or ("KonaEdit status " .. want))
end

H.case_body("terminal-apps", function()
    local P = "/> "
    local _, _, t = C.wait(trimmed(P), 30, "the KonaOS shell prompt at the card root")
    shot("prompt")
    local notes = { string.format("prompt %.3f s", t) }

    -- KonaEdit: open, navigate, edit, Escape, save, exit.
    K.type("kedit /fs/NOTE.TXT")
    local launched = press("Enter")
    release("Enter")
    -- The whole screen, drawn: the menu bar, the file, the status line.
    wait_screen(function(r)
        return trimmed(r[1]) == "File Edit Search Help" and trimmed(r[2]) == "line one" and trimmed(r[3]) == "line two"
            and status_line(r) == "/fs/NOTE.TXT  Ln 1 Col 1  INS"
    end, 30, "KonaEdit open on NOTE.TXT")
    local loaded = H.now()
    local rows
    shot("kedit-open")
    K.tap("Down")
    edit_status("Ln 2 Col 1")
    K.tap("End")
    edit_status("Ln 2 Col 9")
    K.tap("Home")
    edit_status("Ln 2 Col 1")
    K.tap("Right")
    K.tap("Right")
    edit_status("Ln 2 Col 3")
    K.tap("Up")
    edit_status("Ln 1 Col 3")
    K.tap("Down")
    K.tap("End")
    edit_status("Ln 2 Col 9")
    notes[#notes + 1] = "KonaEdit Down End Home Right Right Up Down End"
    K.type("XY")
    wait_screen(function(r) return trimmed(r[3]) == "line twoXY" and status_line(r):find("NOTE.TXT *", 1, true) end, 5, "the typed XY and the modified mark")
    K.tap("Enter")
    edit_status("Ln 3 Col 1")
    K.type("nex")
    K.tap("Backspace")
    K.type("w")
    wait_screen(function(r) return trimmed(r[4]) == "new" and status_line(r):find("Ln 3 Col 4", 1, true) end, 5, "the new line")
    shot("kedit-edit")
    -- Escape: out of the menu's pop-up, out of the menu bar, out of mark mode.
    K.tap("F1")
    K.tap("Down")
    wait_screen(function(r) return trimmed(r[5]):find("Save        F2", 1, true) end, 5, "the File menu")
    shot("kedit-menu")
    K.tap("Escape")
    wait_screen(function(r) return trimmed(r[3]) == "line twoXY" end, 5, "the pop-up closed by Escape")
    K.tap("Escape")
    K.tap("F7")
    K.tap("Left")
    edit_status("MARK", "mark mode")
    K.tap("Escape")
    wait_screen(function(r) return not status_line(r):find("MARK", 1, true) end, 5, "Escape clearing the mark")
    notes[#notes + 1] = "typed XY, Enter, nex Backspace w; F1 Down menu, Escape twice; F7 MARK, Escape"
    K.tap("F2")
    wait_screen(function(r) return status_line(r):find("/fs/NOTE.TXT  Ln", 1, true) end, 10, "the save (modified mark gone)")
    shot("kedit-saved")
    K.tap("F10")
    wait_screen(function(r) local i, rest = prompt_row(P, r) return i and rest == "" end, 10, "the shell after F10")
    notes[#notes + 1] = string.format("F2 saved, F10 exited; KonaEdit loaded %.3f s after Enter", loaded - launched)

    -- KonaCommander: panes, arrows, Enter into a directory, Backspace out,
    -- a file in the viewer, Escape back, q out.
    K.type("kc")
    launched = press("Enter")
    release("Enter")
    wait_screen(function(r) return trimmed(r[2]):find("L:/fs", 1, true) == 1 and r[3]:sub(1, 5) == ">/BIN" end, 30, "KonaCommander's panes")
    loaded = H.now()
    -- It looks for the PC link first; keys wait until it gives up.
    wait_screen(function(r) return trimmed(r[24]):find("timeout", 1, true) or trimmed(r[24]) == "Ready" end, 60, "KonaCommander ready (PC link absent)")
    local ready = H.now()
    shot("kc-open")
    -- The left pane's entries in the order it lists them, and the moves to
    -- each: the arrows step the '>' marker one entry at a time.
    local function pane(r)
        local entries, selected = {}, nil
        for i = 3, 22 do
            local name = r[i]:sub(2, 34):match("^%s*(.-)%s*$")
            if name == "" then break end
            entries[#entries + 1] = name
            if r[i]:sub(1, 1) == ">" then selected = #entries end
        end
        return entries, selected
    end
    local moves = {}
    local function select(name)
        for _ = 1, 20 do
            local entries, at = pane(C.read())
            local want
            for i, e in ipairs(entries) do if e == name then want = i end end
            H.check(want and at, "KonaCommander's pane has no %q or no selection", name)
            if want == at then return end
            local key = want > at and "Down" or "Up"
            K.tap(key)
            moves[#moves + 1] = key
            wait_screen(function(r) local _, now = pane(r) return now and now ~= at end, 5, "the selection moving " .. key)
        end
        H.fail("could not select %q", name)
    end
    local listed = pane(C.read())
    select(listed[#listed])
    select(listed[1])
    select("/DOCS")
    H.check(#moves >= 3, "KonaCommander's selection moved %d times", #moves)
    K.tap("Enter")
    wait_screen(function(r) return trimmed(r[2]):find("L:/fs/DOCS", 1, true) == 1 and r[3]:find("A.TXT", 1, true) end, 10, "Enter into DOCS")
    shot("kc-docs")
    K.tap("Backspace")
    wait_screen(function(r) local e, at = pane(r) return trimmed(r[2]):find("L:/fs ", 1, true) == 1 and #e == 3 and at end, 10, "Backspace to the parent")
    select("NOTE.TXT")
    K.tap("Enter")
    wait_screen(function(r) for i = 1, 26 do if trimmed(r[i]) == "line twoXY" then return true end end end, 10, "the viewer showing the edited NOTE.TXT")
    shot("kc-view")
    K.tap("Escape")
    wait_screen(function(r) local e, at = pane(r) return trimmed(r[2]):find("L:/fs ", 1, true) == 1 and at and e[at] == "NOTE.TXT" end, 10, "Escape back to the panes")
    K.tap("Q")
    wait_screen(function(r) local i, rest = prompt_row(P, r) return i and rest == "" end, 10, "the shell after q")
    shot("kc-quit")
    notes[#notes + 1] = string.format("KonaCommander panes %.3f s after Enter, ready %.3f s (PC link timeout); listed %s; %s, Enter (DOCS), Backspace, to NOTE.TXT, Enter (viewer), Escape, q",
        loaded - launched, ready - launched, table.concat(listed, " "), table.concat(moves, " "))
    return table.concat(notes, "; ")
end)
