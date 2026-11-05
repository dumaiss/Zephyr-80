-- license:BSD-3-Clause
-- Mouse and controller cases (tests/mouse_controllers.py): MAME mouse and
-- gamepad input through the USB mouse and gamepad devices, the IO
-- controller's HID module and the real SIO1/B command lane and E0h-FFh reads,
-- observed by the probe program (sio1_lanes.asm ops 10-12) and, for the
-- clients, by the guests' own screens and sprites.  Runs under harness.lua.
local H = harness
local C = H.vdp.console
local K = H.keyboard
local Mo = H.mouse
dofile(assert(os.getenv("HARNESS_SCRIPT")):match("^(.*/)") .. "sio1_lanes.lua") -- H.lanes
local L = H.lanes
local mem = H.program

if os.getenv("HARNESS_FONT") then C.load_font(os.getenv("HARNESS_FONT")) end

local seq = 1
local function next_seq()
    seq = seq % 255 + 1
    return seq
end

local function frames(n)
    for _ = 1, n do coroutine.yield() end
end

local function wait_until(t, what)
    H.wait(function() return H.now() >= t end, t - H.now() + 1, what)
end

-- Probe helpers --------------------------------------------------------------

-- HID_MOUSE (12h): the reply's nine DATA bytes as a record.  The controller
-- clears the motion and the presses it reports.
local function take()
    local s = next_seq()
    local d = L.expect_reply(L.exchange(0x12, s, {}), 0x92, s, "HID_MOUSE").data
    H.check(#d == 9, "HID_MOUSE: %d DATA bytes, want 9", #d)
    local function s16(i)
        local v = d[i] | (d[i + 1] << 8)
        return v >= 0x8000 and v - 0x10000 or v
    end
    return { flags = d[1], buttons = d[2], pressed = d[3], dx = s16(4), dy = s16(6), wheel = s16(8), raw = d }
end

local function show(m)
    return string.format("flags %d buttons %d pressed %d dx %d dy %d wheel %d", m.flags, m.buttons, m.pressed, m.dx, m.dy, m.wheel)
end

local function same(m, flags, buttons, pressed, dx, dy, wheel)
    return m.flags == flags and m.buttons == buttons and m.pressed == pressed and m.dx == dx and m.dy == dy and m.wheel == wheel
end

local function expect(what, m, flags, buttons, pressed, dx, dy, wheel)
    H.check(same(m, flags, buttons, pressed, dx, dy, wheel), "%s: %s, want flags %d buttons %d pressed %d dx %d dy %d wheel %d",
        what, show(m), flags, buttons, pressed, dx, dy, wheel)
end

-- HID_STATUS page 6 or 7: the DATA bytes.
local function status_page(page)
    local s = next_seq()
    return L.expect_reply(L.exchange(0x0d, s, { page }), 0x8d, s, "HID_STATUS page " .. page).data
end

local function u16(d, i)
    return d[i] | (d[i + 1] << 8)
end

-- /CTSB as the guests sample it.
local function doorbell()
    L.post(10)
    return (mem:read_u8(L.MB.DOORBELL) & 0x20) ~= 0
end

local function hid_input(wanted)
    local s = next_seq()
    local d = L.expect_reply(L.exchange(0x0e, s, { wanted }), 0x8e, s, "HID_INPUT").data
    local bytes = {}
    for i = 3, #d do bytes[#bytes + 1] = d[i] end
    return d[1], d[2], bytes
end

-- Controller reads by the Z80 (IN A,(C)): the 32 bytes of E0h-FFh.
local function scan()
    L.post(11)
    local out = {}
    for i = 0, 31 do out[#out + 1] = mem:read_u8(L.MB.SCAN + i) end
    return out
end

-- The host-side read of the same ports through the CPU's I/O handlers.
local function port(p)
    return H.io:read_u8(p)
end

local function hex(v)
    return string.format("%02X", v)
end

local function start()
    L.start_probe()
    L.init(0)
    L.link_sync(next_seq())
    frames(3)
end

-- The mouse on the lane -------------------------------------------------------

H.case_body("mouse-lane", function()
    local notes = {}
    start()

    -- A connected mouse that has not moved: a second interface is mounted,
    -- nothing decoded yet; page 7 shows it.
    expect("mounted and silent", take(), 1, 0, 0, 0, 0, 0)
    local p7 = status_page(7)
    H.check(#p7 == 21 and p7[1] == 7 and p7[2] == 1 and p7[3] == 1 and u16(p7, 4) == 0 and p7[15] == 0,
        "page 7 before any report: address %d instance %d reports %d", p7[2], p7[3], u16(p7, 4))

    -- Movement in both directions, each axis; the reply clears.
    Mo.move(30, 20)
    frames(2)
    expect("right/down", take(), 3, 0, 0, 30, 20, 0)
    expect("cleared by the read", take(), 3, 0, 0, 0, 0, 0)
    Mo.move(-45, -17)
    frames(2)
    expect("left/up", take(), 3, 0, 0, -45, -17, 0)
    Mo.move(0, 0, 3)
    frames(2)
    expect("wheel away", take(), 3, 0, 0, 0, 0, 3)
    Mo.move(0, 0, -2)
    frames(2)
    expect("wheel toward", take(), 3, 0, 0, 0, 0, -2)
    notes[#notes + 1] = "30,20 / -45,-17 / wheel +3 / -2, each read clearing"

    -- Several frames between reads add up.
    Mo.move(10, 0)
    frames(1)
    Mo.move(10, 0)
    frames(1)
    Mo.move(-4, 5, 1)
    frames(2)
    expect("accumulation over three frames", take(), 3, 0, 0, 16, 5, 1)

    -- One host frame larger than a 12-bit report field arrives whole, in reports of at most 2047.
    Mo.move(5000, -3000, 300)
    frames(2)
    expect("a 5000/-3000 throw in one frame", take(), 3, 0, 0, 5000, -3000, 300)
    notes[#notes + 1] = "a 5000,-3000,+300 frame arrives whole (reports of 2047/127)"

    -- Saturation at +/-32767 (the firmware's capped add), never a wrap.
    for _ = 1, 3 do
        Mo.move(20000, -20000, 12000)
        frames(1)
    end
    frames(1)
    expect("three +20000 frames", take(), 3, 0, 0, 32767, -32767, 32767)
    for _ = 1, 3 do
        Mo.move(-20000, 20000, -12000)
        frames(1)
    end
    frames(1)
    expect("three -20000 frames", take(), 3, 0, 0, -32767, 32767, -32767)
    -- A long throw then the opposite stays a sum.
    for _ = 1, 2 do
        Mo.move(20000, 0)
        frames(1)
    end
    Mo.move(-2000, 0)
    frames(2)
    expect("capped then -2000", take(), 3, 0, 0, 32767 - 2000, 0, 0)
    notes[#notes + 1] = "three +/-20000 frames read +/-32767 (never wrapped, never -32768)"

    -- A press and release between two reads are not lost; a held button persists.
    Mo.button("Left", true)
    frames(1)
    Mo.button("Left", false)
    frames(2)
    expect("click between reads", take(), 3, 0, 1, 0, 0, 0)
    expect("the click is consumed", take(), 3, 0, 0, 0, 0, 0)
    Mo.button("Right", true)
    Mo.button("Middle", true)
    frames(2)
    expect("two buttons down", take(), 3, 6, 6, 0, 0, 0)
    expect("held across reads, pressed consumed", take(), 3, 6, 0, 0, 0, 0)
    Mo.button("Right", false)
    frames(2)
    expect("right released", take(), 3, 4, 0, 0, 0, 0)
    Mo.button("Left", true)
    Mo.button("Middle", false)
    frames(1)
    Mo.button("Left", false)
    frames(2)
    expect("left clicked while the middle released", take(), 3, 0, 1, 0, 0, 0)
    notes[#notes + 1] = "click between reads: pressed 1, held 0; two held buttons persist across reads"

    -- Keyboard delivery is independent: a key is queued while the mouse moves;
    -- motion rings no doorbell.
    H.check(not doorbell(), "/CTSB asserted by mouse motion alone")
    Mo.move(7, 7)
    K.tap("A")
    K.frames(2)
    local q = hid_input(0)
    H.check(q == 1 and doorbell(), "the key queued one byte (%d) and rang the doorbell", q)
    local _, _, bytes = hid_input(24)
    H.check(#bytes == 1 and bytes[1] == 0x61, "the byte is 'a' (%s)", L.hx(bytes))
    expect("the mouse report was not disturbed by the key", take(), 3, 0, 0, 7, 7, 0)
    H.check(not doorbell(), "/CTSB released after the drain")
    notes[#notes + 1] = "a key queued 'a' beside mouse motion; neither disturbed the other"

    -- Page 7 shows the raw interface and the wrapping totals.
    p7 = status_page(7)
    H.check(p7[2] == 1 and p7[3] == 1 and u16(p7, 4) > 20 and p7[6] == 7 and p7[7] == 2,
        "page 7: address %d instance %d, %d reports, last length %d, ID %02X", p7[2], p7[3], u16(p7, 4), p7[6], p7[7])

    -- Removal with a button down and motion owed: nothing stays stuck.
    Mo.button("Middle", true)
    frames(2)
    Mo.move(50, 50)
    Mo.connect(false)
    frames(2)
    expect("removed", take(), 0, 0, 0, 0, 0, 0)
    p7 = status_page(7)
    H.check(p7[2] == 0 and p7[15] == 0, "page 7 after removal: address %d, buttons %d", p7[2], p7[15])
    Mo.move(9, 9)
    Mo.button("Left", true)
    frames(2)
    expect("a removed mouse's input is dropped", take(), 0, 0, 0, 0, 0, 0)
    Mo.button("Left", false)
    frames(1)
    -- Plugged in again: mounted, the button still held shows as one press.
    Mo.connect(true)
    frames(2)
    expect("plugged in with the middle button held", take(), 3, 4, 4, 0, 0, 0)
    Mo.button("Middle", false)
    frames(2)
    expect("released", take(), 3, 0, 0, 0, 0, 0)
    notes[#notes + 1] = "removed with the middle held and 50,50 owed: flags 0, nothing pending; replugged: the held button is one press"

    -- A machine reset: pending motion and the held button; the new
    -- enumeration reports the button held now once.
    Mo.button("Left", true)
    frames(2)
    Mo.move(100, 100)
    frames(0)
    H.machine:soft_reset()
    local t0 = H.now()
    H.wait(function() return H.now() > t0 + 0.02 end, 1, "the reset")
    start()
    expect("after a reset with the left button held", take(), 3, 1, 1, 0, 0, 0)
    Mo.button("Left", false)
    frames(2)
    expect("released after the reset", take(), 3, 0, 0, 0, 0, 0)
    notes[#notes + 1] = "reset: the owed 100,100 gone, the held left button reported once after the new mount, then released"

    -- Page 7's totals after a reset restarted.
    p7 = status_page(7)
    H.check(p7[2] == 1 and p7[15] == 0 and u16(p7, 16) == 0 and u16(p7, 18) == 0, "page 7 after the reset: totals %d, %d", u16(p7, 16), u16(p7, 18))
    return table.concat(notes, "; ")
end)

-- The controllers on E0h-FFh -----------------------------------------------------

-- The ColecoVision bytes (controller_latch.c): bits low when pressed.
local IDLE, UP, RIGHT, DOWN, LEFT, FIRE = 0x7f, 0x01, 0x02, 0x04, 0x08, 0x40
local function byte(...)
    local v = IDLE
    for _, bit in ipairs({ ... }) do v = v & ~bit end
    return v
end

-- The port a read of `p` reaches: the IO board decodes bus A0 alone (U6 74HC138).
local function pad_of(p)
    return p & 1
end

local function expect_ports(what, want0, want1)
    local s = scan()
    for i = 0, 31 do
        local want = pad_of(0xe0 + i) == 0 and want0 or want1
        H.check(s[i + 1] == want, "%s: IN %02Xh read %02X, want %02X (pad %d)", what, 0xe0 + i, s[i + 1], want, pad_of(0xe0 + i))
    end
    return s
end

-- Poll the CPU-side read of `p` for the first frame it equals `want`; returns the emulated time.
local function until_port(p, want, frames_max, what)
    for _ = 1, frames_max do
        if port(p) == want then return H.now() end
        frames(1)
    end
    H.check(port(p) == want, "%s: IN %02Xh read %02X, want %02X after %d frames", what, p, port(p), want, frames_max)
    return H.now()
end

local P1, P2 = H.pad(1), H.pad(2)

H.case_body("controllers-lane", function()
    local notes = {}
    start()

    -- Nothing connected: both latches idle, on every address of the block.
    expect_ports("no pad", IDLE, IDLE)
    notes[#notes + 1] = "no pad: all 32 reads of E0h-FFh are 7Fh"

    -- Pad 1 connected and idle still reads 7Fh; no presence bit.
    P1.connect(true)
    frames(4)
    expect_ports("a pad connected and idle", IDLE, IDLE)
    local p6 = status_page(6)
    H.check(p6[2] == 2 and p6[12] == 2 and p6[14] == 1, "page 6 with one pad: %d devices, pad address %d, first arm %d", p6[2], p6[12], p6[14])

    -- Directions: the D-pad (the hat), eight ways, then released.
    local hat = {
        { { "D-Pad Up" }, byte(UP) }, { { "D-Pad Up", "D-Pad Right" }, byte(UP, RIGHT) }, { { "D-Pad Right" }, byte(RIGHT) },
        { { "D-Pad Right", "D-Pad Down" }, byte(RIGHT, DOWN) }, { { "D-Pad Down" }, byte(DOWN) },
        { { "D-Pad Down", "D-Pad Left" }, byte(DOWN, LEFT) }, { { "D-Pad Left" }, byte(LEFT) },
        { { "D-Pad Left", "D-Pad Up" }, byte(LEFT, UP) },
        { { "D-Pad Up", "D-Pad Down" }, IDLE }, { { "D-Pad Left", "D-Pad Right" }, IDLE },
    }
    for _, row in ipairs(hat) do
        for _, name in ipairs(row[1]) do P1.set(name, true) end
        frames(4)
        local got = port(0xfc)
        H.check(got == row[2], "D-pad %s: FCh reads %02X, want %02X", table.concat(row[1], "+"), got, row[2])
        P1.release_all()
        frames(4)
        H.check(port(0xfc) == IDLE, "D-pad released: FCh %02X", port(0xfc))
    end
    notes[#notes + 1] = "D-pad: 8 directions and opposite pairs cancelling"

    -- The left stick as the Mode LED's d-pad (hat neutral), and the hat over the stick.
    local stick = {
        { { "Left Stick Left" }, byte(LEFT) }, { { "Left Stick Right" }, byte(RIGHT) }, { { "Left Stick Up" }, byte(UP) },
        { { "Left Stick Down" }, byte(DOWN) }, { { "Left Stick Up", "Left Stick Left" }, byte(UP, LEFT) },
        { { "Left Stick Down", "Left Stick Right" }, byte(DOWN, RIGHT) },
    }
    for _, row in ipairs(stick) do
        for _, name in ipairs(row[1]) do P1.set(name, true) end
        frames(4)
        H.check(port(0xfc) == row[2], "%s: FCh reads %02X, want %02X", table.concat(row[1], "+"), port(0xfc), row[2])
        P1.release_all()
        frames(4)
    end
    P1.set("D-Pad Down", true)
    P1.set("Left Stick Up", true)
    P1.set("Left Stick Left", true)
    frames(4)
    H.check(port(0xfc) == byte(DOWN), "hat down over the stick up-left: %02X", port(0xfc))
    P1.release_all()
    frames(4)

    -- Fire: A or B, and the other buttons that change nothing.
    P1.set("A", true)
    frames(4)
    H.check(port(0xfc) == byte(FIRE), "A: %02X", port(0xfc))
    P1.set("A", false)
    P1.set("B", true)
    frames(4)
    H.check(port(0xfc) == byte(FIRE), "B: %02X", port(0xfc))
    P1.set("D-Pad Up", true)
    frames(4)
    H.check(port(0xfc) == byte(FIRE, UP), "B with up: %02X", port(0xfc))
    P1.release_all()
    for _, name in ipairs({ "LB", "RB", "LT", "RT", "L3", "R3" }) do P1.set(name, true) end
    frames(4)
    H.check(port(0xfc) == IDLE, "LB RB LT RT L3 R3: %02X, want idle", port(0xfc))
    P1.release_all()
    frames(4)
    notes[#notes + 1] = "A/B fire on D6; bumpers, triggers and stick buttons change nothing"

    -- The keypad substitutes and their priority over the hat and the stick.
    local keypad = {
        { { "X" }, 0x7d, "keypad 1" }, { { "Y" }, 0x77, "keypad 2" }, { { "Back" }, 0x79, "star" }, { { "Start" }, 0x76, "pound" },
        { { "X", "Y" }, 0x7d, "X over Y" }, { { "Start", "X" }, 0x76, "Start over X" }, { { "Back", "Start", "X" }, 0x79, "Back over all" },
        { { "X", "D-Pad Up" }, 0x7d, "X over the hat" }, { { "Y", "Left Stick Left" }, 0x77, "Y over the stick" },
        { { "X", "A" }, 0x3d, "keypad 1 with fire" }, { { "Y", "B" }, 0x37, "keypad 2 with fire" },
    }
    for _, row in ipairs(keypad) do
        for _, name in ipairs(row[1]) do P1.set(name, true) end
        frames(4)
        H.check(port(0xfc) == row[2], "%s (%s): FCh reads %02X, want %02X", row[3], table.concat(row[1], "+"), port(0xfc), row[2])
        P1.release_all()
        frames(4)
    end
    notes[#notes + 1] = "X/Y/Back/Start give keypad 1, 2, star, pound over the hat and stick; Back > Start > X > Y; fire kept"

    -- Both pads: independent, in mount order (pad 1 first), through every mirror.
    P2.connect(true)
    frames(4)
    P1.set("D-Pad Right", true)
    P2.set("A", true)
    P2.set("D-Pad Left", true)
    frames(4)
    expect_ports("two pads", byte(RIGHT), byte(FIRE, LEFT))
    H.check(port(0xfc) == byte(RIGHT) and port(0xff) == byte(FIRE, LEFT), "FCh %02X FFh %02X", port(0xfc), port(0xff))
    P1.release_all()
    frames(4)
    expect_ports("pad 1 released", IDLE, byte(FIRE, LEFT))
    P2.release_all()
    frames(4)
    local p6 = status_page(6)
    H.check(p6[2] == 2 and p6[3] == 3 and p6[12] == 2 and p6[19] == 3 and u16(p6, 15) > 0 and u16(p6, 22) > 0,
        "page 6 with two pads: %d live of the stack's two addresses, %d mounts, addresses %d %d, reports %d %d",
        p6[2], p6[3], p6[12], p6[19], u16(p6, 15), u16(p6, 22))
    notes[#notes + 1] = "two pads independent (right | fire+left); even addresses read pad 0, odd pad 1, all 32"

    -- The keyboard's number keys on port 0, with and without a pad, and over a held pad.
    local function key_down(name)
        K.set(name, true)
        frames(4)
    end
    local function key_up(name)
        K.set(name, false)
        frames(4)
    end
    local nib = { [0] = 0x0a, 0x0d, 0x07, 0x0c, 0x02, 0x03, 0x0e, 0x05, 0x01, 0x0b }
    P1.connect(false)
    P2.connect(false)
    frames(4)
    for d = 0, 9 do
        local name = d == 0 and 0x27 or 0x1d + d -- usage 1Eh-27h
        key_down(name)
        H.check(port(0xfc) == (0x70 | nib[d]), "number key %d with no pad: FCh %02X, want %02X", d, port(0xfc), 0x70 | nib[d])
        H.check(port(0xff) == IDLE, "number key %d: FFh %02X, want idle", d, port(0xff))
        key_up(name)
        H.check(port(0xfc) == IDLE, "number key %d released: FCh %02X", d, port(0xfc))
    end
    key_down("Keypad 7 Home")
    H.check(port(0xfc) == 0x75, "keypad 7: FCh %02X", port(0xfc))
    key_up("Keypad 7 Home")
    key_down("Keypad *")
    H.check(port(0xfc) == 0x79, "keypad *: star %02X", port(0xfc))
    key_up("Keypad *")
    K.set("Left Shift", true)
    key_down(0x25)
    H.check(port(0xfc) == 0x79, "Shift+8: star %02X", port(0xfc))
    key_up(0x25)
    key_down(0x20)
    H.check(port(0xfc) == 0x76, "Shift+3: pound %02X", port(0xfc))
    key_up(0x20)
    key_down(0x1e)
    H.check(port(0xfc) == IDLE, "Shift+1: no key, FCh %02X", port(0xfc))
    key_up(0x1e)
    K.set("Left Shift", false)
    frames(4)
    local text = {}
    -- The digits still reached the console queue.
    local queued = hid_input(0)
    H.check(queued > 0, "the number keys also queued console bytes (%d)", queued)
    hid_input(24)
    -- Over a pad: the key's nibble, the pad's fire; released, the pad again within a poll.
    P1.connect(true)
    frames(4)
    P1.set("D-Pad Up", true)
    P1.set("A", true)
    frames(4)
    H.check(port(0xfc) == byte(UP, FIRE), "pad up+fire: %02X", port(0xfc))
    key_down(0x22)
    H.check(port(0xfc) == 0x33, "key 5 over the pad: nibble 3 with the pad's fire, %02X", port(0xfc))
    P1.set("D-Pad Up", false)
    P1.set("D-Pad Down", true)
    frames(4)
    H.check(port(0xfc) == 0x33, "the pad changes under the key: still %02X", port(0xfc))
    H.check(port(0xff) == IDLE, "port 1 never takes the keyboard (%02X)", port(0xff))
    key_up(0x22)
    H.check(port(0xfc) == byte(DOWN, FIRE), "key released: the pad's state again, %02X", port(0xfc))
    P1.release_all()
    frames(4)
    notes[#notes + 1] = "digits 0-9, keypad 7 and *, Shift+8 and Shift+3 on port 0 with no pad and over a pad (the key's nibble, the pad's fire); port 1 untouched; the digits also queued for the console"

    -- Removal: a held pad reads 7Fh at once; plugged in again it reads again.
    P1.set("D-Pad Left", true)
    frames(4)
    H.check(port(0xfc) == byte(LEFT), "pad left: %02X", port(0xfc))
    P1.connect(false)
    frames(2)
    H.check(port(0xfc) == IDLE, "pad removed: FCh %02X, want 7F", port(0xfc))
    P1.connect(true)
    frames(4)
    H.check(port(0xfc) == byte(LEFT), "pad plugged in again with left held: %02X", port(0xfc))
    P1.release_all()
    frames(4)
    -- Mount order: the first pad mounted is pad 0, whichever MAME pad it is.
    P1.connect(false)
    P2.connect(false)
    frames(4)
    P2.connect(true)
    frames(4)
    P2.set("D-Pad Up", true)
    frames(4)
    H.check(port(0xfc) == byte(UP) and port(0xff) == IDLE, "MAME pad 2 alone is pad 0: FCh %02X FFh %02X", port(0xfc), port(0xff))
    P1.connect(true)
    P1.set("A", true)
    frames(4)
    H.check(port(0xfc) == byte(UP) and port(0xff) == byte(FIRE), "then MAME pad 1 is pad 1: FCh %02X FFh %02X", port(0xfc), port(0xff))
    P2.connect(false)
    frames(4)
    H.check(port(0xfc) == IDLE and port(0xff) == byte(FIRE), "pad 0 removed: FCh %02X, pad 1 stays FFh %02X", port(0xfc), port(0xff))
    P1.release_all()
    P2.release_all()
    P1.connect(false)
    frames(4)
    notes[#notes + 1] = "removal parks 7Fh at once and replug restores; mount order sets the port (pad 2 first is pad 0)"

    -- Mirrors with guest IN: all 32 addresses, even to pad 0, odd to pad 1.
    P1.connect(true)
    P2.connect(true)
    frames(4)
    P1.set("D-Pad Right", true)
    P2.set("B", true)
    frames(4)
    local s = scan()
    for i = 0, 31 do
        local want = (0xe0 + i) % 2 == 0 and byte(RIGHT) or byte(FIRE)
        H.check(s[i + 1] == want, "mirror IN %02Xh: %02X, want %02X", 0xe0 + i, s[i + 1], want)
    end
    notes[#notes + 1] = "all 32 guest INs of E0h-FFh: A0 selects the pad (FCh/FFh and every mirror)"

    -- Sound writes beside the reads: the PSGs and the DAC take their writes, the
    -- reads keep the pads, and the reads write nothing.
    local function psg_regs(chip)
        local item = emu.item(H.machine.devices[":psg" .. chip].items["0/m_register"])
        local out = {}
        for i = 0, 7 do out[#out + 1] = item:read(i) end
        return out
    end
    local before = {}
    for chip = 0, 3 do before[chip] = table.concat(psg_regs(chip), ",") end
    local writes = 0
    local tap = H.keep(H.io:install_write_tap(0xe0, 0xff, "ctl-w", function() writes = writes + 1 end))
    scan()
    for chip = 0, 3 do
        H.check(table.concat(psg_regs(chip), ",") == before[chip], "a read changed PSG %d: %s", chip, table.concat(psg_regs(chip), ","))
    end
    H.check(writes == 0, "%d writes seen during the controller scan", writes)
    -- OUT then IN, pair by pair: tone 0 on PSG0 (latch+data, mirror F0), PSG3 attenuation (mirror FBh), the DAC (E4h), a dead port (E6h).
    local pairs_list = {
        { 0xe0, 0x8a }, { 0xf0, 0x0f }, { 0xe0, 0x90 }, { 0xfb, 0xdf }, { 0xe4, 0xc0 }, { 0xe6, 0x55 }, { 0xe1, 0xa5 }, { 0xe1, 0x07 }, { 0xe1, 0xb2 },
    }
    mem:write_u8(L.MB.PAIRN, #pairs_list)
    for i, pair in ipairs(pairs_list) do
        mem:write_u8(L.MB.PAIRS + 2 * (i - 1), pair[1])
        mem:write_u8(L.MB.PAIRS + 2 * (i - 1) + 1, pair[2])
    end
    writes = 0
    L.post(12)
    for i = 1, #pairs_list do
        H.check(mem:read_u8(L.MB.SCAN + i - 1) == byte(RIGHT) and mem:read_u8(L.MB.SCAN2 + i - 1) == byte(FIRE),
            "pair %d (OUT %02Xh,%02X): FCh %02X FFh %02X after it", i, pairs_list[i][1], pairs_list[i][2],
            mem:read_u8(L.MB.SCAN + i - 1), mem:read_u8(L.MB.SCAN2 + i - 1))
    end
    H.check(writes == #pairs_list, "%d sound writes seen, want %d", writes, #pairs_list)
    local psg0 = psg_regs(0)
    H.check(psg0[1] == 0xfa and psg0[2] == 0, "PSG0 tone 0 divisor %03X volume %X (want FA, loud)", psg0[1], psg0[2])
    local psg3 = psg_regs(3)
    H.check(psg3[6] == 0x0f, "PSG3 tone 2 attenuation %X, want F (OUT FBh,DFh: the mirror of port 3)", psg3[6])
    local psg1 = psg_regs(1)
    H.check(psg1[3] == 0x75 and psg1[4] == 2, "PSG1 tone 1 divisor %03X attenuation %X, want 075, 2 (OUT E1h A5 07 B2)", psg1[3], psg1[4])
    notes[#notes + 1] = "9 sound writes (PSG0 tone and its mirror F0h, PSG3 attenuation through the mirror FBh, the DAC, a dead port, PSG1 tone and volume) each followed by IN FCh and IN FFh: the pads unchanged, the PSG registers as written, no write from a read"

    -- The ColecoVision mode-select writes decode to nothing: the byte is unchanged.
    local sel = {}
    for _, p in ipairs({ 0x80, 0x81, 0x9f, 0xc0, 0xc1, 0xdf }) do
        for _, v in ipairs({ 0x00, 0xff }) do
            H.io:write_u8(p, v)
            sel[#sel + 1] = string.format("%02X<-%02X", p, v)
            H.check(port(0xfc) == byte(RIGHT) and port(0xff) == byte(FIRE), "after OUT %02Xh,%02X: FCh %02X FFh %02X", p, v, port(0xfc), port(0xff))
        end
    end
    mem:write_u8(L.MB.PAIRN, 4)
    local mode_pairs = { { 0x80, 0x00 }, { 0xc0, 0xff }, { 0x81, 0x55 }, { 0xdf, 0xaa } }
    for i, pair in ipairs(mode_pairs) do
        mem:write_u8(L.MB.PAIRS + 2 * (i - 1), pair[1])
        mem:write_u8(L.MB.PAIRS + 2 * (i - 1) + 1, pair[2])
    end
    L.post(12)
    for i = 1, 4 do
        H.check(mem:read_u8(L.MB.SCAN + i - 1) == byte(RIGHT) and mem:read_u8(L.MB.SCAN2 + i - 1) == byte(FIRE),
            "guest OUT %02Xh: FCh %02X FFh %02X", mode_pairs[i][1], mem:read_u8(L.MB.SCAN + i - 1), mem:read_u8(L.MB.SCAN2 + i - 1))
    end
    notes[#notes + 1] = "mode-select writes (80h-9Fh, C0h-DFh, host and guest) leave the bytes as they were: one merged byte, no mode"
    tap = nil

    -- A machine reset: the controller restarts, the pads enumerate again (the
    -- mount counters start over) and their held state is read again.
    local before_mounts = status_page(6)[3]
    H.machine:soft_reset()
    local t0 = H.now()
    H.wait(function() return H.now() > t0 + 0.02 end, 1, "the reset")
    start()
    local p6r = status_page(6)
    H.check(before_mounts > 3 and p6r[3] <= 3 and p6r[4] == 0, "mounts %d before the reset, %d unmounts %d after it (a fresh enumeration)", before_mounts, p6r[3], p6r[4])
    local when = until_port(0xfc, byte(RIGHT), 20, "the held pad after the reset")
    H.check(port(0xff) == byte(FIRE) or until_port(0xff, byte(FIRE), 10, "pad 1 after the reset"), "pad 1 after the reset")
    notes[#notes + 1] = string.format("reset: the controller enumerated again (mounts %d -> %d), both held pads read again %.0f ms after the reset", before_mounts, p6r[3], (when - t0) * 1000)

    P1.release_all()
    P2.release_all()
    K.release_all()
    frames(4)
    expect_ports("everything released", IDLE, IDLE)
    return table.concat(notes, "; ")
end)

-- Input latency ---------------------------------------------------------------------

-- From a change in MAME's input fields (set at a frame boundary) to the
-- controller holding it, read from the module's own items at each frame: the
-- mouse's motion in the HID module's pending total, a pad's fire in its
-- latch.  The guest sees it at its next HID_MOUSE or IN FCh.
H.case_body("input-latency", function()
    start()
    local ioc = H.machine.devices[":ioc"]
    local function item(name) return emu.item(ioc.items["0/" .. name]) end
    local pend_x, latch = item("hid.m_pend_x"), item("latch.m_value")
    Mo.move(1, 0) -- the first report decodes
    frames(3)
    take()
    local t0 = H.now()
    Mo.move(3, 0)
    local n_mouse = 0
    repeat
        frames(1)
        n_mouse = n_mouse + 1
    until pend_x:read(0) ~= 0 or n_mouse > 6
    H.check(pend_x:read(0) == 3, "latency probe: the module holds %d, want 3", pend_x:read(0))
    local t_mouse = H.now() - t0
    take()
    P1.connect(true)
    frames(4)
    t0 = H.now()
    P1.set("A", true)
    local n_pad = 0
    repeat
        frames(1)
        n_pad = n_pad + 1
    until latch:read(0) == byte(FIRE) or n_pad > 6
    H.check(latch:read(0) == byte(FIRE), "the pad's fire never reached the latch (%02X)", latch:read(0))
    local t_pad = H.now() - t0
    P1.release_all()
    frames(4)
    H.trace("latency mouse %.1f ms (%d frame), pad %.1f ms (%d frame)", t_mouse * 1000, n_mouse, t_pad * 1000, n_pad)
    return string.format("mouse motion in the controller after %.1f ms (%d frame), a pad's fire in its latch after %.1f ms (%d frames), at frame granularity", t_mouse * 1000, n_mouse, t_pad * 1000, n_pad)
end)

-- Save state: motion owed, a click unread, pads and a keypad key held ----------------

local STATE_FILE = os.getenv("HARNESS_STATE_FILE") or (H.dir .. "/mc-state.tsv")

-- The host input both processes hold while the state is taken and restored.
local function hold_input(positions)
    Mo.x, Mo.y, Mo.wheel = positions[1], positions[2], positions[3]
    Mo.move(0, 0, 0)
    Mo.button("Right", true)
    P1.connect(true)
    P2.connect(true)
    P1.set("D-Pad Right", true)
    P1.set("A", true)
    P2.set("Y", true)
    K.set(0x22, true) -- the number key 5
end

local function snapshot()
    local m = take()
    local p7 = status_page(7)
    return string.format("%d %d %d %d %d %d | %02X %02X | %d %d %d %d", m.flags, m.buttons, m.pressed, m.dx, m.dy, m.wheel,
        port(0xfc), port(0xff), u16(p7, 16), u16(p7, 18), u16(p7, 20), p7[15])
end

H.case_body("mouse-state-save", function()
    start()
    P1.connect(true)
    P2.connect(true)
    frames(4)
    -- A consumed event must not come back: motion read before the save.
    Mo.move(5, 5)
    frames(2)
    expect("consumed before the save", take(), 3, 0, 0, 5, 5, 0)
    -- Unread at the save: motion, a click (down and up), a held right button.
    Mo.move(11, -7, 2)
    frames(2)
    Mo.button("Left", true)
    frames(1)
    Mo.button("Left", false)
    frames(1)
    hold_input({ Mo.x, Mo.y, Mo.wheel })
    frames(6)
    H.check(port(0xfc) == 0x33 and port(0xff) == 0x77, "latches before the save: %02X %02X (want 33 77: key 5 over pad 0, Y on pad 1)", port(0xfc), port(0xff))
    -- Owed by the mouse device, not yet scanned: moved in this step, saved in this step.
    Mo.move(21, 0)
    H.machine:save("mc")
    local x, y, w = Mo.x, Mo.y, Mo.wheel
    local saved = H.now()
    frames(4)
    local line = snapshot()
    local f = assert(io.open(STATE_FILE, "w"))
    f:write(string.format("%.9f\t%d\t%d\t%d\t%s\n", saved, x, y, w, line))
    f:close()
    H.check(line:sub(1, 20) == "3 2 3 32 -7 2 | 33 7", "continuing run: %s", line)
    return string.format("saved at %.4f s with 11,-7,+2 read-pending, 21,0 not yet scanned, a click and the right button held, pads 3D/77: the continuing run reads %s", saved, line)
end)

H.case_body("mouse-state-load", function()
    local f = assert(io.open(STATE_FILE, "r"))
    local saved, x, y, w, want = f:read("l"):match("^(%S+)\t(%d+)\t(%d+)\t(%d+)\t(.*)$")
    f:close()
    saved = tonumber(saved)
    hold_input({ tonumber(x), tonumber(y), tonumber(w) })
    H.wait(function() return H.now() > saved end, saved + 2, "the restore")
    frames(4)
    local got = snapshot()
    H.check(got == want, "after the restore: %s, want the saving run's %s", got, want)
    -- Consumed once: the next read is empty.
    expect("the events are not repeated", take(), 3, 2, 0, 0, 0, 0)
    return string.format("restored at %.4f s onto the same host input: %s as in the saving run; the next read is empty", saved, got)
end)

-- The guests ----------------------------------------------------------------------
--
-- The real clients on the production image, read off the V9958's GRAPHIC6
-- screen (harness.vdp.console) and its sprite table (harness.vdp.sprites).
-- The text pointer is sprite slot 1; the console cursor is slot 0.

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
    local sprites = H.vdp.sprites() or {}
    for _, sp in ipairs(sprites) do
        transcript:write(string.format("sprite %d: x %d y %d pattern %d colour %d\n", sp.slot, sp.x, sp.y, sp.pattern, sp.colour))
    end
    transcript:flush()
end

local function trimmed(line)
    return (line:gsub("%s+$", ""))
end

local function find_line(line, rows)
    for i, r in ipairs(rows) do
        if trimmed(r) == line then return i end
    end
end

local function find_prefix(prefix, rows)
    for i, r in ipairs(rows) do
        if trimmed(r):sub(1, #prefix) == prefix then return i, trimmed(r) end
    end
end

local function wait_screen(predicate, timeout, what)
    return C.wait_for(predicate, timeout, what)
end

-- The pointer sprite (slot 1, pattern 1) as the attribute table holds it, or
-- nil when hidden (the driver's hidden slot is the blank pattern 2 at Y 0).
local function pointer_sprite()
    local sprites = H.vdp.sprites()
    for _, sp in ipairs(sprites or {}) do
        if sp.slot == 1 and sp.pattern == 1 then return sp end
    end
end

-- The last row holding the prompt and what follows it.
local function last_prompt(rows, prompt)
    prompt = prompt or "/system> "
    for i = #rows, 1, -1 do
        if rows[i]:sub(1, #prompt) == prompt then return i, trimmed(rows[i]:sub(#prompt + 1)) end
    end
end

-- Wait for the screen to show the line, then return the rows.
local function wait_line(line, timeout, what)
    return C.wait_for(function(rows) return find_line(line, rows) and rows end, timeout, what or string.format("the line %q", line))
end

H.case_body("clients-shell", function()
    local P = "/system> "
    local notes = {}
    C.wait(trimmed(P), 30, "the KonaOS shell prompt")

    -- `mouse` with no mouse attached: the program binds the mouse and shows
    -- the pointer at the centre (libkos mouse_init); present stays 0.
    Mo.connect(false)
    frames(4)
    K.type("mouse\r")
    wait_line("mouse: move and click; any key ends", 20, "the mouse program")
    frames(8)
    local sp = pointer_sprite()
    H.check(sp, "no pointer sprite (slot 1) with no mouse attached")
    local centre = { x = sp.x, y = sp.y }
    shot("mouse-no-mouse")
    notes[#notes + 1] = string.format("no mouse attached: HID_MOUSE flags 0, the pointer sprite sits at the centre (sprite x %d y %d), no \"present\" line", centre.x, centre.y)
    H.check(not find_prefix("mouse: present", C.read()), "the program reported a present mouse with none attached")

    -- Attach the mouse: nothing moves until the first report; then present 1.
    Mo.connect(true)
    frames(8)
    sp = pointer_sprite()
    H.check(sp.x == centre.x and sp.y == centre.y, "the pointer moved on connection alone (%d,%d)", sp.x, sp.y)
    Mo.move(60, 40)
    wait_screen(function(rows) return find_line("mouse: present 1", rows) end, 5, "mouse: present 1")
    frames(4)
    local moved = pointer_sprite()
    local dx, dy = moved.x - centre.x, moved.y - centre.y
    H.check(dy == 40 and (dx == 30 or dx == 60), "motion 60,40 moved the sprite by %d,%d", dx, dy)
    local xscale = dx == 30 and 2 or 1
    shot("mouse-moved")
    -- A click prints the text cell under the pointer: (255+60)/6, (104+40)/8.
    Mo.button("Left", true)
    frames(3)
    Mo.button("Left", false)
    local cell_x, cell_y = (255 + 60) // 6, (104 + 40) // 8
    wait_screen(function(rows) return find_line(string.format("mouse: cell %d,%d pressed 1", cell_x, cell_y), rows) end, 5, "the left click's cell")
    notes[#notes + 1] = string.format("moved 60,40: sprite %+d,%+d (x in sprite units 1/%d); left click printed cell %d,%d pressed 1", dx, dy, xscale, cell_x, cell_y)
    Mo.button("Right", true)
    frames(3)
    Mo.button("Right", false)
    Mo.button("Middle", true)
    frames(3)
    Mo.button("Middle", false)
    wait_screen(function(rows)
        return find_line(string.format("mouse: cell %d,%d pressed 2", cell_x, cell_y), rows)
            and find_line(string.format("mouse: cell %d,%d pressed 4", cell_x, cell_y), rows)
    end, 5, "the right and middle clicks")
    -- Both edges: the pointer stops at the corners of the 510 x 208 area.
    Mo.move(5000, 5000)
    frames(10)
    sp = pointer_sprite()
    Mo.button("Left", true)
    frames(3)
    Mo.button("Left", false)
    wait_screen(function(rows) return find_line("mouse: cell 84,25 pressed 1", rows) end, 5, "the bottom-right corner cell")
    local corner_br = { x = sp.x, y = sp.y }
    Mo.move(-5000, -5000)
    frames(10)
    sp = pointer_sprite()
    Mo.button("Left", true)
    frames(3)
    Mo.button("Left", false)
    wait_screen(function(rows) return find_line("mouse: cell 0,0 pressed 1", rows) end, 5, "the top-left corner cell")
    local corner_tl = { x = sp.x, y = sp.y }
    -- The sprite is one row above the hot spot and half its x (the V9958's 512-dot rows count sprite dots double).
    H.check(corner_br.x == 254 and corner_br.y == 206 and corner_tl.x == 0 and corner_tl.y == 255,
        "corner sprites: bottom-right %d,%d top-left %d,%d, want 254,206 and 0,255 (row -1)", corner_br.x, corner_br.y, corner_tl.x, corner_tl.y)
    shot("mouse-corners")
    notes[#notes + 1] = string.format("right and middle clicks pressed 2 and 4; 5000,5000 stopped at cell 84,25 (sprite %d,%d) and -5000,-5000 at cell 0,0 (sprite %d,%d)",
        corner_br.x, corner_br.y, corner_tl.x, corner_tl.y)
    -- Movement while a button is held, then a key ends the program and hides the pointer.
    K.tap("Q")
    wait_screen(function(rows) local i, rest = last_prompt(rows) return i and rest == "" end, 10, "the shell after mouse")
    frames(8)
    H.check(not pointer_sprite(), "the pointer sprite is still shown after the program ended")
    shot("mouse-done")
    notes[#notes + 1] = "a key ended the program, the pointer sprite hidden"
    Mo.release_all()

    -- `joy` with the pads: a line whenever a pad's byte changes.
    K.type("joy\r")
    wait_line("joy: press the pads; any key ends", 20, "the joy program")
    frames(6)
    P1.connect(true)
    P2.connect(true)
    frames(6)
    P1.set("D-Pad Up", true)
    P1.set("A", true)
    wait_screen(function(rows) return find_line("joy: 0 raw 3E bits 00111110 dirs U---F key 6", rows) end, 5, "pad 0 up+fire")
    P2.set("X", true)
    wait_screen(function(rows) return find_line("joy: 1 raw 7D bits 01111101 dirs -R--- key 1", rows) end, 5, "pad 1 keypad 1")
    P1.set("Start", true)
    wait_screen(function(rows) return find_line("joy: 0 raw 36 bits 00110110 dirs U--LF key #", rows) end, 5, "pad 0 Start: pound with fire")
    P1.release_all()
    P2.release_all()
    wait_screen(function(rows)
        local count = 0
        for _, r in ipairs(rows) do if trimmed(r) == "joy: 0 raw 7F bits 01111111 dirs ----- key -" then count = count + 1 end end
        return count >= 2
    end, 5, "pad 0 released")
    shot("joy")
    K.tap("Q")
    wait_screen(function(rows) local i, rest = last_prompt(rows) return i and rest == "" end, 10, "the shell after joy")
    notes[#notes + 1] = "joy: pad 0 up+A (3E; the nibble Eh also reads as keypad 6), pad 1 X (7D, key 1), pad 0 Start with A (36, key #), released (7F); the idle lines of both pads first"
    P1.connect(false)
    P2.connect(false)
    return table.concat(notes, "; ")
end)

-- Pointer placement: the sprite is the pointer's own pixel position (x halved,
-- one row above the hot spot), so a move to a text cell is the difference.
local function pointer_pixel()
    local sp = pointer_sprite()
    H.check(sp, "the pointer sprite is not shown")
    return sp.x * 2 + 1, (sp.y + 1) & 0xff
end

local function goto_pixel(x, y)
    local px, py = pointer_pixel()
    Mo.move(x - px, y - py)
    local waited = 0
    repeat
        frames(2)
        waited = waited + 2
        px, py = pointer_pixel()
    until (math.abs(px - x) <= 1 and math.abs(py - y) <= 1) or waited >= 120
    H.check(math.abs(px - x) <= 1 and math.abs(py - y) <= 1, "the pointer is at %d,%d, wanted %d,%d after %d frames", px, py, x, y, waited)
    frames(4)
end

local function goto_cell(col, row)
    goto_pixel(col * 6 + 3, row * 8 + 4)
end

local function click(button, hold)
    Mo.button(button or "Left", true)
    frames(hold or 3)
    Mo.button(button or "Left", false)
    frames(4)
end

local function wheel(notches)
    Mo.move(0, 0, notches)
    frames(8)
end

local function status_line(rows)
    return trimmed(rows[26])
end

-- KonaEdit and KonaCommander with the mouse, from a card image.
H.case_body("clients-apps", function()
    local P = "/> "
    local notes = {}
    C.wait(trimmed(P), 30, "the KonaOS shell prompt at the card root")
    shot("prompt")

    -- KonaEdit with no mouse attached: the editor enables the mouse, the
    -- pointer sits at the centre, and nothing a mouse would do happens.
    Mo.connect(false)
    frames(4)
    K.type("kedit /fs/LONG.TXT\r")
    wait_screen(function(r)
        return trimmed(r[1]) == "File Edit Search Help" and trimmed(r[2]) == "line 01" and status_line(r) == "/fs/LONG.TXT  Ln 1 Col 1  INS"
    end, 30, "KonaEdit open on LONG.TXT")
    frames(10)
    local sp = pointer_sprite()
    H.check(sp and sp.x == 127 and sp.y == 103, "KonaEdit with no mouse: the pointer sprite at the centre (%s)", sp and (sp.x .. "," .. sp.y) or "hidden")
    shot("kedit-no-mouse")
    notes[#notes + 1] = string.format("KonaEdit with no mouse attached: the pointer sprite is shown at the centre (x %d y %d) - the editor enables the mouse and draws its pointer whether or not one is mounted", sp.x, sp.y)

    -- Attach the mouse: a click places the cursor (row r is line r, column c+1).
    Mo.connect(true)
    frames(6)
    goto_cell(4, 6)
    click("Left")
    wait_screen(function(r) return status_line(r) == "/fs/LONG.TXT  Ln 6 Col 5  INS" end, 5, "a click placing the cursor at Ln 6 Col 5")
    goto_cell(30, 9)
    click("Left")
    wait_screen(function(r) return status_line(r) == "/fs/LONG.TXT  Ln 9 Col 8  INS" end, 5, "a click past the end of line 09 placing the cursor at its end")
    goto_cell(2, 3)
    click("Left")
    wait_screen(function(r) return status_line(r) == "/fs/LONG.TXT  Ln 3 Col 3  INS" end, 5, "a click placing the cursor at Ln 3 Col 3")
    shot("kedit-click")
    notes[#notes + 1] = "KonaEdit: clicks at cell (4,6), (30,9) and (2,3) put the cursor at Ln 6 Col 5, Ln 9 Col 8 (past the line end) and Ln 3 Col 3"

    -- The wheel scrolls three lines a notch.
    wheel(-1)
    wait_screen(function(r) return trimmed(r[2]) == "line 04" end, 5, "one notch down: line 04 on top")
    wheel(-2)
    wait_screen(function(r) return trimmed(r[2]) == "line 10" end, 5, "two more notches: line 10 on top")
    wheel(3)
    wait_screen(function(r) return trimmed(r[2]) == "line 01" end, 5, "three notches up: line 01 on top")
    shot("kedit-wheel")
    notes[#notes + 1] = "KonaEdit wheel: -1 -> line 04 on top, -2 -> line 10, +3 -> line 01"

    -- Dragging selects (MARK).
    goto_cell(2, 4)
    Mo.button("Left", true)
    frames(3)
    goto_cell(5, 6)
    wait_screen(function(r) return status_line(r):find("MARK", 1, true) end, 5, "a drag selecting (MARK)")
    shot("kedit-drag")
    Mo.button("Left", false)
    frames(4)
    K.tap("Escape")
    wait_screen(function(r) return not status_line(r):find("MARK", 1, true) end, 5, "Escape clearing the mark")
    notes[#notes + 1] = "KonaEdit: press at (2,4), drag to (5,6): MARK; Escape clears it"

    -- Menus: a click on File opens its pop-up, a click outside closes it.
    goto_cell(1, 0)
    click("Left")
    wait_screen(function(r) return trimmed(r[5]):find("Save        F2", 1, true) end, 5, "the File menu opened by a click")
    shot("kedit-menu")
    goto_cell(60, 15)
    click("Left")
    wait_screen(function(r) return trimmed(r[2]) == "line 01" and not trimmed(r[5]):find("Save        F2", 1, true) end, 5, "a click outside closing the menu")
    notes[#notes + 1] = "KonaEdit menu: a click on File opens the pop-up, a click outside closes it"
    K.tap("F10")
    wait_screen(function(r) local i, rest = last_prompt(r, P) return i and rest == "" end, 10, "the shell after F10")
    frames(8)
    H.check(not pointer_sprite(), "the pointer is still shown after KonaEdit ended")

    -- KonaCommander: a click selects an entry, a double click opens it, the wheel
    -- and the right click in the viewer.
    K.type("kc\r")
    wait_screen(function(r) return trimmed(r[2]):find("L:/fs", 1, true) == 1 and r[3]:sub(1, 5) == ">/BIN" end, 30, "KonaCommander's panes")
    wait_screen(function(r) return trimmed(r[24]):find("timeout", 1, true) or trimmed(r[24]) == "Ready" end, 60, "KonaCommander ready (PC link absent)")
    shot("kc-open")
    frames(6)
    local function selected(r)
        for i = 3, 22 do
            if r[i]:sub(1, 1) == ">" then return r[i]:sub(2, 34):match("^%s*(.-)%s*$") end
        end
    end
    local listing = {}
    for i = 3, 22 do
        local name = C.last.rows[i]:sub(2, 34):match("^%s*(.-)%s*$")
        if name == "" then break end
        listing[#listing + 1] = name
    end
    H.check(#listing >= 4, "KonaCommander lists %s", table.concat(listing, " "))
    -- Click the last entry, then the first.
    goto_cell(8, 1 + #listing)
    click("Left")
    wait_screen(function(r) return selected(r) == listing[#listing] end, 5, "a click selecting " .. listing[#listing])
    goto_cell(8, 2)
    click("Left")
    wait_screen(function(r) return selected(r) == listing[1] end, 5, "a click selecting " .. listing[1])
    local docs
    for i, name in ipairs(listing) do if name == "/DOCS" then docs = i end end
    H.check(docs, "no /DOCS in the pane %s", table.concat(listing, " "))
    goto_cell(8, 1 + docs)
    click("Left", 2)
    click("Left", 2)
    wait_screen(function(r) return trimmed(r[2]):find("L:/fs/DOCS", 1, true) == 1 and r[3]:find("A.TXT", 1, true) end, 10, "a double click opening DOCS")
    shot("kc-docs")
    notes[#notes + 1] = string.format("KonaCommander: clicks selected %s then %s; a double click on /DOCS opened it", listing[#listing], listing[1])
    K.tap("Backspace")
    wait_screen(function(r) return trimmed(r[2]):find("L:/fs ", 1, true) == 1 end, 10, "Backspace to the parent")
    local note
    for i, name in ipairs(listing) do if name == "NOTE.TXT" then note = i end end
    goto_cell(8, 1 + note)
    click("Left", 2)
    click("Left", 2)
    wait_screen(function(r) for i = 1, 26 do if trimmed(r[i]) == "line one" then return true end end end, 10, "the viewer showing NOTE.TXT")
    shot("kc-view")
    goto_cell(40, 12)
    click("Right")
    wait_screen(function(r) return trimmed(r[2]):find("L:/fs ", 1, true) == 1 and selected(r) == "NOTE.TXT" end, 10, "a right click returning from the viewer")
    notes[#notes + 1] = "KonaCommander: a double click on NOTE.TXT opened the viewer, a right click returned"
    K.tap("Q")
    wait_screen(function(r) local i, rest = last_prompt(r, P) return i and rest == "" end, 10, "the shell after q")
    shot("kc-quit")
    Mo.release_all()
    return table.concat(notes, "; ")
end)

-- The libgfx pointer example (gfx_mouse): the left button paints a 4 x 4 brush
-- of colour 0Ah under the tracked pointer in the 512 x 212 mode, the right
-- button switches to the 256 x 212 256-colour mode and back (the pointer is
-- the tracked x / 2 there), a key exits.
H.case_body("clients-gfx", function()
    local P = "/> "
    local notes = {}
    C.wait(trimmed(P), 30, "the KonaOS shell prompt at the card root")
    K.type("gfxmouse\r")
    local function wait_screen_display(pred, timeout, what)
        return H.wait(function() local d = H.vdp.display() return pred(d) and d end, timeout, what)
    end
    -- libgfx's pointer is sprite 0 of the SAT at 1F200h in white (the console's cursor is yellow).
    local function libgfx_pointer()
        for _, sp in ipairs(H.vdp.sprites() or {}) do
            if sp.slot == 0 and sp.colour == 15 then return sp end
        end
    end
    local sp = H.wait(libgfx_pointer, 40, "the libgfx pointer sprite")
    frames(6)
    sp = libgfx_pointer()
    local start = { x = sp.x, y = sp.y }
    shot("gfx-start")
    -- Moved 40,30: the sprite follows (x halved in the 512-dot mode).
    Mo.move(40, 30)
    frames(10)
    sp = libgfx_pointer()
    H.check(sp.x - start.x == 20 and sp.y - start.y == 30, "40,30 moved the pointer sprite by %d,%d, want 20,30", sp.x - start.x, sp.y - start.y)
    -- Paint: hold the left button and drag right 60 pixels in steps of 3 (the brush is 4 wide).
    local d = H.vdp.display()
    local px0 = 256 + 40
    local py0 = 106 + 30
    H.check(H.vdp.pixel(px0 + 20, py0 + 1) == 4, "the canvas is not blank at the start of the stroke (%s)", tostring(H.vdp.pixel(px0 + 20, py0 + 1)))
    Mo.button("Left", true)
    frames(4)
    for _ = 1, 20 do
        Mo.move(3, 0)
        frames(3)
    end
    Mo.button("Left", false)
    frames(6)
    local painted = 0
    for x = px0, px0 + 60 do
        if H.vdp.pixel(x, py0 + 1) == 10 then painted = painted + 1 end
    end
    H.check(painted >= 56, "%d of 61 pixels on the stroke are the brush colour (0Ah)", painted)
    H.check(H.vdp.pixel(px0 + 80, py0 + 1) == 4 and H.vdp.pixel(px0 + 30, py0 + 40) == 4, "pixels away from the stroke are untouched")
    shot("gfx-painted")
    notes[#notes + 1] = string.format("512x212: the sprite follows 40,30 as 20,30; a left drag of 60 px painted %d/61 pixels of colour 0Ah, the rest of the canvas untouched", painted)
    -- Right button: the 256 x 212 mode, the pointer's x is halved.
    click("Right")
    wait_screen_display(function(dd) return dd.mode == "GRAPHIC7" and dd.enabled end, 5, "the 256 x 212 mode after the right button")
    frames(10)
    sp = libgfx_pointer()
    H.check(sp, "no pointer in the 256-colour mode")
    local g7x, g7y = sp.x, sp.y
    Mo.button("Left", true)
    frames(4)
    for _ = 1, 10 do
        Mo.move(2, 0)
        frames(3)
    end
    Mo.button("Left", false)
    frames(6)
    local g7_count = 0
    for x = g7x, g7x + 16 do
        if H.vdp.pixel(x, g7y + 1) == 0xfc then g7_count = g7_count + 1 end
    end
    H.check(g7_count >= 13, "the 256-colour stroke has %d pixels of FCh on its row (want 14: 10 moved + the 4-wide brush)", g7_count)
    shot("gfx-g7")
    notes[#notes + 1] = string.format("right button -> 256x212 (GRAPHIC7), the pointer at sprite %d,%d; a left drag of 20 tracked px painted %d pixels of FCh on its row there", g7x, g7y, g7_count)
    click("Right")
    wait_screen_display(function(dd) return dd.mode == "GRAPHIC6" end, 5, "the 512 x 212 mode again")
    -- A key exits.
    K.tap("Q")
    wait_screen(function(r) for i = 1, 26 do if trimmed(r[i]) == "gfx_mouse: done" then return true end end end, 10, "gfx_mouse: done")
    shot("gfx-done")
    Mo.release_all()
    return table.concat(notes, "; ")
end)
