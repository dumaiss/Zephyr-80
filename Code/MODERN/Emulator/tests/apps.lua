-- license:BSD-3-Clause
-- Graphics programs on the production KonaOS image (tests/video.py runs them from a card
-- image): gfxtest, GfxDemo, sntview, and the timing workloads iobench and sntview.  Each
-- program is typed at the shell, held at its key stops, observed (harness.vdp: VRAM,
-- saved registers, palette, sprites, the rendered bitmap; no port is read) and released;
-- the lines it prints are read off the restored console.
--
--   apps-gfxtest   every gfxtest mode: info, mode6, mode7, yjk, reopen, upload, palette,
--                  prims, shapes, text, atlas, timing, pages, pointer
--   apps-gfxdemo   the GFX v1 demo screen
--   apps-sntview   the tracker viewer: the static screen, a page flip, playing, quitting
--   timing-iobench the I/O bench rows (console and VDP rows against the card rows)
--   timing-sntview sntview playing the song: the exit report's timing line
local lio = io
local H = harness
local V = H.vdp
local C = V.console
local K = H.keyboard

if os.getenv("HARNESS_FONT") then C.load_font(os.getenv("HARNESS_FONT")) end

local function trimmed(line) return (line:gsub("%s+$", "")) end

-- Captures: every snapshot with the program, its arguments and the stop it shows.
local captures
local capture_count = 0
local program_now, args_now = "", ""
local function capture(stop)
    capture_count = capture_count + 1
    local name = string.format("%02d-%s-%s.png", capture_count, program_now, stop):gsub("[^%w%.%-]", "_")
    V.snapshot(name)
    captures = captures or assert(lio.open(H.dir .. "/captures.tsv", "w"))
    if capture_count == 1 then captures:write("file\tprogram\targs\tstop\temulated_s\tmode\tpage\n") end
    local d = V.display()
    captures:write(string.format("%s\t%s\t%s\t%s\t%.3f\t%s\t%s\n", name, program_now, args_now, stop, H.now(), d.mode, tostring(d.page)))
    captures:flush()
    return name
end

local function seconds(s)
    local until_ = H.now() + s
    H.wait(function() return H.now() >= until_ end, s + 5, "a pause")
end

local last_write = 0
local writes = 0
H.keep(H.io:install_write_tap(0xa0, 0xa3, "vdp-activity", function()
    last_write = H.now()
    writes = writes + 1
end))

-- The console runs interlaced (R#9 bit 3); the graphics programs set R#9 to 80h.
local function app_active() return (V.reg(9) & 0x08) == 0 end

-- Type a command and return the emulated time it was typed.
local function run_command(line)
    K.type(line .. "\r")
    return H.now()
end

-- Wait until a program that took the display is holding it at a key: it has switched off the
-- console's interlace, and the VDP has seen no port write for `quiet` seconds.
local function wait_stop(since, quiet, what)
    quiet = quiet or 0.5
    return H.wait(function()
        return app_active() and last_write > since and H.now() - last_write > quiet
    end, 90, what or "the program waiting at a key")
end

local function wait_released(what)
    H.wait(function() return not app_active() end, 60, what or "the console restored")
end

local function lines_with(prefix)
    local rows = C.read()
    local out = {}
    for _, row in ipairs(rows or {}) do
        local t = trimmed(C.printable(row))
        if t:find(prefix, 1, true) == 1 then out[#out + 1] = t end
    end
    return out
end

-- The console cleared and ready: the shell prompt on row 1.
local PROMPT = "/> "
local function clear_console()
    K.chord({ "Left Ctrl", "L" })
    H.wait(function()
        local rows = C.read()
        return rows and trimmed(rows[1]) == trimmed(PROMPT)
    end, 10, "the cleared console")
end

-- The VRAM bytes of page 0, lines [0, lines), all equal to `value` (a G6 byte holds two pixels).
local function uniform(value, lines, pitch)
    pitch = pitch or 256
    local mode = V.mode()
    local bad, first = 0, nil
    for y = 0, lines - 1 do
        for b = 0, pitch - 1 do
            if V.byte(y * pitch + b, mode) ~= value then
                bad = bad + 1
                first = first or string.format("(%d,%d)", b, y)
            end
        end
    end
    return bad, first
end

local function check_render(label, notes)
    local compared, bad, skipped, first = V.render_check(0, V.display().lines)
    if compared == nil then
        if notes then notes[#notes + 1] = label .. ": " .. tostring(bad) end
        return nil
    end
    H.check(bad == 0, "%s: %d of %d rendered pixels differ from VRAM (first %s)", label, bad, compared, tostring(first))
    return compared
end

local function hist_summary(h)
    local keys = {}
    for c in pairs(h) do keys[#keys + 1] = c end
    table.sort(keys, function(a, b) return h[a] > h[b] end)
    local out = {}
    for i = 1, math.min(#keys, 4) do out[#out + 1] = string.format("%08X x%d", keys[i], h[keys[i]]) end
    return table.concat(out, ", ")
end

-- gfxtest ------------------------------------------------------------------------------------

local function ub(i) local n = (i * 7 + 5) & 15 return (n << 4) | n end -- gfxtest_upload_byte

-- The upload mode's rectangles (page-relative logical addresses and the stream index of each byte).
local function upload_bytes()
    local list = {}
    local function rect(first_logical, pitch_bytes, lines, bytes_per_line)
        local i = 0
        for line = 0, lines - 1 do
            for b = 0, bytes_per_line - 1 do
                list[#list + 1] = { logical = first_logical + line * pitch_bytes + b, value = ub(i) }
                i = i + 1
            end
        end
    end
    rect(256 * 256, 256, 4, 256)          -- (0,256) 512x4: page 1, line 0 of the page
    rect(264 * 256 + 32, 256, 6, 64)      -- (64,264) 128x6
    rect(300 * 256, 256, 8, 128)          -- (0,300) 256x8
    rect(0, 256, 16, 256)                 -- (0,0) 512x16: page 0
    return list
end

local MODE_NOTES = {}

local function run_gfxtest()
    local results, notes = {}, {}
    local function note(s) notes[#notes + 1] = s end

    -- Write log for the upload mode: every VRAM byte of its four rectangles, as the chip stored it.
    local watch = upload_bytes()
    local by_physical = {}
    for _, e in ipairs(watch) do
        e.physical = ((e.logical & 1) << 16) | (e.logical >> 1)
        by_physical[e.physical] = by_physical[e.physical] or {}
        by_physical[e.physical].seen = {}
        by_physical[e.physical].entry = e
    end
    local tap = V.vram_space:install_write_tap(0x00000, 0x1ffff, "upload-log", function(offset, data)
        local w = by_physical[offset & 0x1ffff]
        if w then w.seen[data & 0xff] = true end
    end)
    H.keep(tap)

    -- run: type `gfxtest MODE`, then step through the keys; `stops` is a list of observers.
    local function run(mode, stops, final, extra_wait)
        clear_console()
        program_now, args_now = "gfxtest", mode
        local since = run_command("gfxtest " .. mode)
        for i = 1, #stops do
            wait_stop(since, 0.5, string.format("gfxtest %s at key %d", mode, i))
            local out = stops[i]()
            since = H.now()
            K.tap("Space")
            if out then note(string.format("%s key %d: %s", mode, i, out)) end
        end
        wait_released("gfxtest " .. mode .. " restored the console")
        C.wait(final, 60, "gfxtest " .. mode .. " result")
        seconds(0.3)
        local printed = lines_with("gfxtest:")
        results[mode] = printed
        capture_count_before = capture_count
        return printed
    end

    -- info: the direct-info record.
    local printed = run("info", {}, "gfxtest: v1")
    H.check(printed[#printed] == "gfxtest: v1 b1 fF r128 pA0 A1 A2 A3 A4 c0", "info line %q", tostring(printed[#printed]))
    note("info: " .. printed[#printed])

    -- mode6 / mode7 / yjk: the clear to a colour and the display held.
    local function held(name, colour, width, yjk)
        return function()
            local d = V.display()
            local text = string.format("%s %dx%d enabled %s R#25 %02X", d.mode, d.width or 0, d.lines, tostring(d.enabled), V.reg(25))
            H.check(d.enabled and d.lines == 212 and d.width == width and d.yjk == yjk, "%s: %s", name, text)
            local bad, first = uniform(colour, 212)
            H.check(bad == 0, "%s: %d VRAM bytes differ from the clear colour %02X (first %s)", name, bad, colour, tostring(first))
            local h = V.histogram(0, 0, d.width, 212)
            local n = 0
            for _ in pairs(h) do n = n + 1 end
            H.check(n == 1, "%s: the held screen is not one colour: %s", name, hist_summary(h))
            if not yjk then check_render(name) end
            local shot = capture(name)
            return string.format("%s, one colour %s, %s", text, hist_summary(h), shot)
        end
    end
    printed = run("mode6", { held("mode6", 0x44, 512, false) }, "gfxtest: done")
    printed = run("mode7", { held("mode7", 0x1c, 256, false) }, "gfxtest: done")
    printed = run("yjk", { held("yjk", 0x1c, 256, true) }, "gfxtest: done")

    -- reopen and upload (no key): their own PASS lines, and the upload's bytes in VRAM.
    printed = run("reopen", {}, "gfxtest: reopen")
    seconds(0.5)
    printed = lines_with("gfxtest: reopen")
    H.check(printed[#printed] == "gfxtest: reopen PASS", "reopen: %s", table.concat(printed, " | "))
    note("reopen: " .. table.concat(printed, " | "))
    for _, w in pairs(by_physical) do w.seen = {} end -- the reopen's own upload is not the upload mode's
    printed = run("upload", {}, "gfxtest: upload")
    seconds(0.5)
    printed = lines_with("gfxtest: upload")
    H.check(printed[#printed] == "gfxtest: upload PASS", "upload: %s", table.concat(printed, " | "))
    local missing, final_bad, final_checked = 0, 0, 0
    for _, e in ipairs(watch) do
        local w = by_physical[e.physical]
        if not w.seen[e.value] then missing = missing + 1 end
        if e.logical >= 256 * 256 then -- page 1: the bytes are still there
            final_checked = final_checked + 1
            if V.byte(e.logical, "GRAPHIC6") ~= e.value then final_bad = final_bad + 1 end
        end
    end
    H.check(missing == 0, "upload: %d of %d bytes never written to their VRAM address", missing, #watch)
    H.check(final_bad == 0, "upload: %d of %d page-1 bytes differ in VRAM afterwards", final_bad, final_checked)
    note(string.format("upload: %s; %d bytes of four rectangles (chunks 1, 7, 256, 4096; page 0 and page 1, the A16 boundary at logical 10000h) written to their addresses, %d page-1 bytes verified in place",
        table.concat(printed, " | "), #watch, final_checked))

    -- palette: two keys.
    local pal_stop1 = function()
        local d = V.display()
        local pal = V.palette()
        H.check(d.mode == "GRAPHIC6" and d.enabled, "palette key 1: %s", d.mode)
        local function same(i, r, g, b) return pal[i][1] == r and pal[i][2] == g and pal[i][3] == b end
        H.check(same(1, 0, 0, 7) and same(2, 7, 0, 0) and same(3, 0, 4, 0),
            "palette 1-3 hold %d,%d,%d %d,%d,%d %d,%d,%d", pal[1][1], pal[1][2], pal[1][3], pal[2][1], pal[2][2], pal[2][3], pal[3][1], pal[3][2], pal[3][3])
        check_render("palette")
        capture("palette-g6")
        return "G6 entries 1-3 = blue 0,0,7, red 7,0,0, green 0,4,0 (the 8-bit values >> 5)"
    end
    local pal_stop2 = function()
        local d = V.display()
        H.check(d.mode == "GRAPHIC7" and d.enabled, "palette key 2: %s", d.mode)
        check_render("palette G7")
        capture("palette-g7")
        return "G7 shown after the refused palette write"
    end
    run("palette", { pal_stop1, pal_stop2 }, "gfxtest: palette PASS")

    -- prims: two keys, spot-checked against the commands' meaning (GRAPHIC7: one byte a pixel).
    local function px(x, y) return V.pixel(x, y) end
    local prims1 = function()
        local d = V.display()
        H.check(d.mode == "GRAPHIC7", "prims key 1: %s", d.mode)
        -- Ordering: fill B (16x4 at 8,2, colour 22h) over fill A (40x8 at 0,0, colour 11h).
        H.check(px(0, 0) == 0x11 and px(39, 7) == 0x11 and px(8, 2) == 0x22 and px(23, 5) == 0x22 and px(24, 5) == 0x11 and px(7, 3) == 0x11 and px(40, 0) == 0,
            "fill ordering: %02X %02X %02X %02X %02X", px(0, 0), px(8, 2), px(23, 5), px(24, 5), px(40, 0))
        -- The 33-fill batch: the 32nd command is on the chip, the 33rd still queued.
        for i = 0, 31 do
            H.check(px(i * 6, 100) == i + 1 and px(i * 6 + 3, 101) == i + 1, "batch fill %d: %02X", i, px(i * 6, 100))
        end
        H.check(px(32 * 6, 100) == 0, "the 33rd fill was drawn before gfx_end (%02X)", px(32 * 6, 100))
        check_render("prims key 1")
        capture("prims-batch")
        return "fill B over fill A; 32 of 33 queued fills drawn at the auto-flush, the 33rd held"
    end
    local prims2 = function()
        -- The upload 4x4 at (200,20) copied four ways (overlapping); the page copies.
        local screen = {}
        local function get(x, y) return screen[y * 256 + x] or 0 end
        for y = 0, 3 do for x = 0, 3 do screen[(20 + y) * 256 + 200 + x] = ub(y * 4 + x) end end
        local function copy(sx, sy, dx, dy)
            local tmp = {}
            for y = 0, 3 do for x = 0, 3 do tmp[y * 4 + x] = get(sx + x, sy + y) end end
            for y = 0, 3 do for x = 0, 3 do screen[(dy + y) * 256 + dx + x] = tmp[y * 4 + x] end end
        end
        copy(200, 20, 204, 22) copy(200, 20, 196, 22) copy(200, 20, 204, 18) copy(200, 20, 196, 18)
        local bad = 0
        for y = 12, 30 do
            for x = 190, 214 do
                if px(x, y) ~= get(x, y) then bad = bad + 1 end
            end
        end
        H.check(bad == 0, "the four overlapping copies differ from the memmove reference in %d pixels", bad)
        for y = 60, 62 do for x = 50, 55 do H.check(px(x, y) == 0x55, "page 1 to page 0 copy (%d,%d) = %02X", x, y, px(x, y)) end end
        for y = 40, 42 do for x = 150, 155 do
            H.check(px(x, y) == 0x66, "the 66h fill at (%d,%d) = %02X", x, y, px(x, y))
            H.check(V.pixel(x, y, 1) == 0x66, "page 0 to page 1 copy: page 1 (%d,%d) = %02X", x, y, V.pixel(x, y, 1))
        end end
        check_render("prims key 2")
        capture("prims-copies")
        return "four overlapping copies equal the memmove reference; page 1 to page 0 and back through the A16 boundary"
    end
    run("prims", { prims1, prims2 }, "gfxtest: prims PASS")

    -- shapes, atlas: the screens at their key stops (no pixel reference here: the programs' own results,
    -- the render against VRAM and the captures).
    local function stop(name, mode)
        return function()
            local d = V.display()
            H.check(d.mode == mode and d.enabled, "%s: %s enabled %s", name, d.mode, tostring(d.enabled))
            local n = check_render(name)
            local h = V.histogram(0, 0, d.width, d.lines)
            local count = 0
            for _ in pairs(h) do count = count + 1 end
            H.check(count > 2, "%s: %d colours on the screen", name, count)
            local shot = capture(name)
            return string.format("%s, %d px rendered as VRAM says, %d colours (%s)", d.mode, n or 0, count, shot)
        end
    end
    run("shapes", { stop("shapes-g7", "GRAPHIC7"), stop("shapes-g6", "GRAPHIC6"), stop("shapes-end", "GRAPHIC6") }, "gfxtest: shapes PASS")
    run("text", {}, "gfxtest: text")
    seconds(0.5)
    printed = lines_with("gfxtest: text")
    H.check(printed[#printed] == "gfxtest: text PASS", "text: %s", table.concat(printed, " | "))
    note("text: " .. table.concat(printed, " | "))
    run("atlas", { stop("atlas-g6", "GRAPHIC6"), stop("atlas-g7", "GRAPHIC7") }, "gfxtest: atlas PASS")

    -- timing: the R#16 = 15 markers on the control port (the program's own timing marks).
    local marks, prev = {}, nil
    local mark_tap = H.io:install_write_tap(0xa1, 0xa1, "gfx-marks", function(offset, data)
        if prev == 0x0f and data == 0x90 then marks[#marks + 1] = H.now() end
        prev = data
    end)
    H.keep(mark_tap)
    local timing_stop = stop("timing", "GRAPHIC6")
    run("timing", { timing_stop }, "gfxtest: timing PASS")
    -- The program writes 24 markers (twelve windows); the console's restore at the exit writes one more
    -- R#16 = 15 (palette entry 15), the last.
    local names = { "glyph", "fill", "line", "filled", "outline", "polyline", "row-new", "row-cached", "stripe", "page", "vblank", "present" }
    local windows = {}
    H.check(#marks >= 25, "timing: %d markers, want the program's 24 and the restore's", #marks)
    local first = #marks - 24
    local file = assert(lio.open(H.dir .. "/gfxtest-timing.tsv", "w"))
    file:write("window\tmicroseconds\tT_states_10MHz\n")
    for i, name in ipairs(names) do
        local t0, t1 = marks[first + 2 * (i - 1)], marks[first + 2 * (i - 1) + 1]
        windows[#windows + 1] = string.format("%s %.0f us", name, (t1 - t0) * 1e6)
        file:write(string.format("%s\t%.1f\t%.0f\n", name, (t1 - t0) * 1e6, (t1 - t0) * 1e7))
    end
    file:close()
    note("timing windows (emulated, window = the two marks around each workload): " .. table.concat(windows, ", "))
    mark_tap:remove()

    -- pages: the async order, the page switch, frame pacing, the flip, the partial present.
    local function color_of(i) return V.palette_rgb(i) & 0xffffff end
    local frame_marks = {}
    local pages_tap = H.io:install_write_tap(0xa1, 0xa1, "gfx-pmarks", function(offset, data)
        if prev == 0x0f and data == 0x90 then frame_marks[#frame_marks + 1] = H.now() end
        prev = data
    end)
    H.keep(pages_tap)
    local function rect_colour(x, y, w, h)
        local hist = V.histogram(x, y, w, h)
        local only, n = nil, 0
        for c in pairs(hist) do only = c n = n + 1 end
        return n == 1 and (only & 0xffffff) or nil, hist
    end
    local function pages1()
        -- The upload over the same rectangle wins: (8,10) 64x8 shows the pattern, not the 0Ah fill.
        local bad = 0
        for y = 0, 7 do
            for x = 0, 63 do
                local want = ((y * 32 + x // 2) * 7 + 5) & 15
                if V.pixel(8 + x, 10 + y) ~= want then bad = bad + 1 end
            end
        end
        H.check(bad == 0, "the upload did not win over the fill on %d of 512 pixels", bad)
        -- 31 two-pixel fills and the large fill after them.
        for i = 0, 30 do
            H.check(V.pixel(8 + i * 6, 40) == (i & 7) + 1 and V.pixel(8 + i * 6 + 1, 41) == (i & 7) + 1, "small fill %d: %d", i, V.pixel(8 + i * 6, 40))
        end
        H.check(V.pixel(194, 40) == 0x0b and V.pixel(225, 47) == 0x0b, "the large fill: %d %d", V.pixel(194, 40), V.pixel(225, 47))
        check_render("pages key 1")
        capture("pages-order")
        return "the upload over a fill in flight wins (512 px); 31 small fills and the large one landed in order"
    end
    local function pages2()
        local d = V.display()
        H.check(d.page == 1 and d.base == 0x10000, "pages key 2: page %d", d.page)
        H.check(V.pixel(10, 10) == 0x0e and V.pixel(10, 69) == 0x0e and V.pixel(10, 70) == 0x0d and V.pixel(10, 200) == 0x0d,
            "page 1: %d %d %d %d", V.pixel(10, 10), V.pixel(10, 69), V.pixel(10, 70), V.pixel(10, 200))
        local c, h = rect_colour(0, 0, 512, 70)
        H.check(c == color_of(14), "the band renders %s, want palette 14 %06X", tostring(c), color_of(14))
        c = rect_colour(0, 70, 512, 142)
        H.check(c == color_of(13), "page 1's body renders %s, want palette 13 %06X", tostring(c), color_of(13))
        check_render("pages key 2")
        capture("pages-page1")
        return "page 1 shown: band colour 14 over 70 lines, 13 below, rendered as the palette says"
    end
    local function pages3()
        -- Three retraces between the program's two marks.
        local n = #frame_marks
        local span = frame_marks[n] - frame_marks[n - 1]
        H.check(span > 2 * 0.0150 and span < 3.2 * 0.0170, "three gfx_wait_vblank took %.2f ms, want 2-3 frames", span * 1000)
        capture("pages-frames")
        return string.format("three retrace waits took %.2f ms (a frame is 16.7 ms)", span * 1000)
    end
    local flips = {}
    local function pages4()
        local d = V.display()
        H.check(d.page == 0, "pages key 4: page %d", d.page)
        c = rect_colour(0, 0, 512, 70)
        H.check(c == color_of(14), "page 0's band after the partial present renders %s", tostring(c))
        H.check(rect_colour(0, 70, 512, 142) == color_of(12), "page 0's body renders %s, want palette 12", tostring(rect_colour(0, 70, 512, 142)))
        check_render("pages key 4")
        capture("pages-band")
        return "page 0 back: the 70-line band copied across the vertical blank, the body unchanged"
    end
    local stops = { pages1, pages2, pages3, pages4 }
    -- The flip runs after key 4: sample the shown page every frame for the 3 s run, then end the sweep.
    clear_console()
    program_now, args_now = "gfxtest", "pages"
    local since = run_command("gfxtest pages")
    for i = 1, 4 do
        wait_stop(since, 0.5, "gfxtest pages at key " .. i)
        note("pages key " .. i .. ": " .. stops[i]())
        since = H.now()
        if i < 4 then K.tap("Space") end
    end
    do
        local page = V.display().page
        K.tap("Space")
        local t_start = H.now()
        local seen = { { H.now(), page } }
        local seen_colours = {}
        local deadline = t_start + 4.0
        while H.now() < deadline do
            local p = V.display().page
            if p ~= page then
                page = p
                seen[#seen + 1] = { H.now(), p }
                -- The switch lands in the vertical blank after the frame just drawn: the next frame shows the new page.
                K.frames(2)
                seen_colours[p] = rect_colour(0, 150, 512, 50)
            end
            K.frames(1)
        end
        local flips_n = #seen - 1
        H.check(flips_n >= 11 and flips_n <= 13, "pages flip: %d page changes in 4 s, want 12", flips_n)
        local total = seen[#seen][1] - seen[2][1]
        local interval = total / (#seen - 2)
        -- Each flip is 15 retrace waits and the switch's own wait for the vertical blank: 16 frames.
        H.check(16 / interval > 59.0 and 16 / interval < 60.5, "flip interval %.2f ms is %.2f Hz over 16 frames", interval * 1000, 16 / interval)
        H.check(seen_colours[1] == color_of(3) and seen_colours[0] == color_of(15), "flip colours: page 1 %s page 0 %s",
            tostring(seen_colours[1]), tostring(seen_colours[0]))
        note(string.format("pages flip: %d changes, one every %.1f ms (16 frames: 15 retrace waits and the switch's own, %.2f Hz), page 1 shows palette 3, page 0 palette 15",
            flips_n, interval * 1000, 16 / interval))
        MODE_NOTES.frame_rate = 16 / interval
        -- the tear sweep: end it with a key
        capture("pages-flip-end")
        K.tap("Space")
    end
    wait_released("gfxtest pages restored the console")
    C.wait("gfxtest: pages PASS", 60, "gfxtest pages result")
    seconds(0.3)
    results.pages = lines_with("gfxtest:")
    pages_tap:remove()

    -- pointer: the final held screen, in GRAPHIC7 with the pointer placed at (100, 50).
    local pointer_stop = function()
        local d = V.display()
        H.check(d.mode == "GRAPHIC7" and d.enabled, "pointer: %s", d.mode)
        local sprites = V.sprites()
        H.check(sprites and #sprites >= 1, "no sprite on the pointer screen")
        local s = sprites[1]
        -- The program's last shape call set the box pattern in colour 0Ah (the default arrow is white).
        H.check(s.size == 16 and s.x == 100 and s.y == 49 and s.colour == 10 and s.pattern == 0,
            "pointer sprite: y %d x %d pattern %d colour %d size %d", s.y, s.x, s.pattern, s.colour, s.size)
        check_render("pointer")
        local image = V.image()
        local hot = V.rendered(image, 100, 50)
        H.check((hot & 0xffffff) == (V.sprite_rgb(10) & 0xffffff), "the pointer's hot spot renders %08X, want sprite colour 10 %08X", hot, V.sprite_rgb(10))
        local box = { 0xff, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0xff,
                      0xff, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0xff }
        local patterns = V.reg(6) << 11
        for i = 1, 32 do
            H.check(V.byte(patterns + i - 1, "GRAPHIC7") == box[i], "pattern byte %d is %02X, the program's box has %02X", i - 1, V.byte(patterns + i - 1, "GRAPHIC7"), box[i])
        end
        local sat = V.byte(((V.reg(5) & 0xfc) << 7) + (V.reg(11) << 15) + 4, "GRAPHIC7")
        capture("pointer")
        return string.format("sprite 0 at x %d y %d (hot spot line 50), 16x16, pattern 0 = the program's box shape, colour code 10, drawn in the chip's fixed GRAPHIC7 sprite colour at the hot spot; the next SAT slot %02X", s.x, s.y, sat)
    end
    run("pointer", { pointer_stop }, "gfxtest: pointer PASS")

    -- Every mode's own result line.
    local order = { "info", "mode6", "mode7", "yjk", "reopen", "upload", "palette", "prims", "shapes", "text", "atlas", "timing", "pages", "pointer" }
    local out = {}
    for _, m in ipairs(order) do
        local lines = results[m] or {}
        out[#out + 1] = m .. " [" .. table.concat(lines, " | ") .. "]"
    end
    local f = assert(lio.open(H.dir .. "/gfxtest-results.txt", "w"))
    f:write(table.concat(out, "\n") .. "\n")
    f:close()
    tap:remove()
    return table.concat(notes, "; ")
end

H.case_body("apps-gfxtest", function()
    C.wait(trimmed(PROMPT), 40, "the shell prompt")
    seconds(0.5)
    return run_gfxtest()
end)

-- gfxdemo ------------------------------------------------------------------------------------

H.case_body("apps-gfxdemo", function()
    C.wait(trimmed(PROMPT), 40, "the shell prompt")
    seconds(0.5)
    clear_console()
    program_now, args_now = "gfxdemo", ""
    local since = run_command("gfxdemo")
    wait_stop(since, 0.5, "gfxdemo at its key")
    local notes = {}
    local d = V.display()
    H.check(d.mode == "GRAPHIC6" and d.enabled and d.lines == 212 and d.width == 512, "gfxdemo: %s enabled %s", d.mode, tostring(d.enabled))
    local function px(x, y) return V.pixel(x, y) end
    -- gfx_clear(4), two bars (colour 5), a 40x8 box (colour 9) and two copies of it.
    local function solid(x, y, w, h, colour)
        for j = y, y + h - 1 do for i = x, x + w - 1 do
            if px(i, j) ~= colour then return false, i, j end
        end end
        return true
    end
    local ok, bx, by = solid(0, 0, 512, 20, 5)
    H.check(ok, "the top bar is not colour 5 at (%s,%s)", tostring(bx), tostring(by))
    ok, bx, by = solid(0, 192, 512, 20, 5)
    H.check(ok, "the bottom bar is not colour 5 at (%s,%s)", tostring(bx), tostring(by))
    for _, at in ipairs({ { 20, 40 }, { 80, 60 }, { 140, 80 } }) do
        ok, bx, by = solid(at[1], at[2], 40, 8, 9)
        H.check(ok, "the box at %d,%d is not colour 9 at (%s,%s)", at[1], at[2], tostring(bx), tostring(by))
    end
    H.check(px(19, 40) == 4 and px(60, 40) == 4 and px(20, 39) == 4 and px(20, 48) == 4 and px(300, 150) == 4, "the clear colour 4 around the box")
    notes[#notes + 1] = "GRAPHIC6 cleared to colour 4, bars 512x20 at y 0 and 192 (colour 5), a 40x8 box (colour 9) and its two copies at (80,60) and (140,80)"
    -- Text in two colour pairs, read back with the guest's own 6x8 font.
    local t1 = C.text_at(20, 100, 13, 4)
    local t2 = C.text_at(20, 116, 12, 0)
    H.check(t1 == "KonaOS GFX v1", "the first text reads %q", C.printable(t1))
    H.check(t2 == "text colours", "the second text reads %q", C.printable(t2))
    local function count_rgb(h, rgb)
        local n = 0
        for c, k in pairs(h) do if (c & 0xffffff) == (rgb & 0xffffff) then n = n + k end end
        return n
    end
    local h1 = V.histogram(20, 100, 78, 8)
    H.check(count_rgb(h1, V.palette_rgb(15)) > 0 and count_rgb(h1, V.palette_rgb(4)) > 0 and count_rgb(h1, V.palette_rgb(15)) + count_rgb(h1, V.palette_rgb(4)) == 78 * 8,
        "the first text is not white on colour 4")
    local h2 = V.histogram(20, 116, 72, 8)
    H.check(count_rgb(h2, V.palette_rgb(10)) > 0 and count_rgb(h2, V.palette_rgb(0)) > 0 and count_rgb(h2, V.palette_rgb(10)) + count_rgb(h2, V.palette_rgb(0)) == 72 * 8,
        "the second text is not colour 10 on colour 0")
    notes[#notes + 1] = string.format("text \"%s\" (15 on 4) and \"%s\" (10 on 0) read back from the screen", t1, t2)
    -- The application-defined glyph and the restored default.
    local face = { 0x1E, 0x21, 0x21, 0x21, 0x21, 0x12, 0x0C, 0x00 }
    local bad = 0
    for r = 0, 7 do
        for p = 0, 5 do
            local want = ((face[r + 1] >> (5 - p)) & 1) == 1 and 15 or 4
            if px(20 + p, 140 + r) ~= want then bad = bad + 1 end
        end
    end
    H.check(bad == 0, "the redefined glyph differs from its rows in %d pixels", bad)
    local default = C.text_at(36, 140, 1, 4)
    H.check(default == string.char((C.as_read(0x80))), "the restored glyph reads %q, want code 80h's glyph", C.printable(default))
    notes[#notes + 1] = "glyph 80h drawn as the application's face, then restored to the default and drawn again"
    local compared = check_render("gfxdemo")
    notes[#notes + 1] = string.format("%d px rendered as VRAM says", compared)
    local shot = capture("gfxdemo")
    K.tap("Space")
    wait_released("gfxdemo restored the console")
    C.wait("gfxdemo: done", 30, "gfxdemo's exit line")
    notes[#notes + 1] = shot .. "; exit line: gfxdemo: done"
    return table.concat(notes, "; ")
end)

-- The frame rate and clocks the timing runs report.
local function clocks()
    local screen = H.machine.screens[":screen"]
    local frames0, t0 = screen:frame_number(), H.now()
    K.frames(120)
    local frames1, t1 = screen:frame_number(), H.now()
    local rate = (frames1 - frames0) / (t1 - t0)
    return rate
end

-- iobench and sntview timing -----------------------------------------------------------------

local function screen_lines()
    local out = {}
    for _, row in ipairs(C.read() or {}) do
        local t = trimmed(C.printable(row))
        if t ~= "" then out[#out + 1] = t end
    end
    return out
end

H.case_body("timing-iobench", function()
    C.wait(trimmed(PROMPT), 40, "the shell prompt")
    seconds(0.5)
    local frame_rate = clocks()
    program_now, args_now = "iobench", ""
    local t0 = run_command("iobench")
    C.wait("iobench: summary", 400, "the bench summary")
    seconds(0.5)
    local lines = screen_lines()
    local file = assert(lio.open(H.dir .. "/iobench.tsv", "w"))
    file:write("row\tmean\tper_byte\n")
    local rows = {}
    for _, l in ipairs(lines) do
        local name, mean, per = l:match("^sum: (%S+) mean (%d+) per%-byte (%d+)")
        if name then
            rows[name] = { tonumber(mean), tonumber(per) }
            file:write(string.format("%s\t%s\t%s\n", name, mean, per))
        end
    end
    file:close()
    for _, name in ipairs({ "ipc.null", "con.putchar", "con.printf", "con.write", "con.mixed", "con.space", "con.held", "vdp.hmmm6", "vdp.hmmm12",
                            "vdp.direct.on", "vdp.direct.off", "file.byte", "file.getc", "file.block" }) do
        H.check(rows[name], "the bench summary has no %s row", name)
    end
    C.wait("iobench: end", 30, "the bench end line")
    capture("iobench-end")
    return string.format("iobench rows (T-states per op / per byte at the 10 MHz CPU): putchar %d, printf %d, write %d, mixed %d, space %d, held %d, hmmm6 %d per copy (%d/byte), hmmm12 %d per copy, direct.on %d per glyph, file.byte %d, file.getc %d, file.block %d per op (%d/byte); frame rate %.2f Hz; emulated %.1f s",
        rows["con.putchar"][2], rows["con.printf"][2], rows["con.write"][2], rows["con.mixed"][2], rows["con.space"][2], rows["con.held"][2],
        rows["vdp.hmmm6"][1], rows["vdp.hmmm6"][2], rows["vdp.hmmm12"][1], rows["vdp.direct.on"][1], rows["file.byte"][1], rows["file.getc"][1],
        rows["file.block"][1], rows["file.block"][2], frame_rate, H.now() - t0)
end)

H.case_body("apps-sntview", function()
    C.wait(trimmed(PROMPT), 40, "the shell prompt")
    seconds(0.5)
    local notes = {}
    local frame_rate = clocks()
    local play_seconds = tonumber(os.getenv("HARNESS_PLAY_SECONDS") or "40")
    clear_console()
    program_now, args_now = "sntview", "/fs/NIGHT.ZTR"
    local since = run_command("sntview /fs/NIGHT.ZTR")
    wait_stop(since, 1.0, "sntview's first screen")
    local d = V.display()
    H.check(d.mode == "GRAPHIC6" and d.enabled and d.lines == 212 and d.page == 0, "sntview: %s enabled %s page %s", d.mode, tostring(d.enabled), tostring(d.page))
    local compared = check_render("sntview first screen")
    local h = V.histogram(0, 0, 512, 212)
    local colours = 0
    for _ in pairs(h) do colours = colours + 1 end
    H.check(colours >= 5, "the viewer shows %d colours", colours)
    local shot = capture("first-page")
    local hash0 = {}
    for i = 0, 1023 do hash0[#hash0 + 1] = V.byte(8 * 256 + i, "GRAPHIC6") end
    notes[#notes + 1] = string.format("first screen: GRAPHIC6 512x212, %d px rendered as VRAM says, %d colours (%s)", compared, colours, shot)

    -- Space: the next page, shown by a page flip.
    local page_before = d.page
    K.tap("Space")
    H.wait(function() return V.display().page ~= page_before end, 10, "the page flip")
    K.frames(5)
    d = V.display()
    check_render("sntview second page")
    notes[#notes + 1] = string.format("Space flipped to page %d (R#2 %02X), %s", d.page, V.reg(2), capture("second-page"))
    K.tap("Space")
    H.wait(function() return V.display().page ~= d.page end, 10, "the next page")
    K.frames(5)
    notes[#notes + 1] = string.format("the next Space shows page %d again", V.display().page)

    -- P: play; the screen changes while the engine plays and the VDP keeps up.
    K.tap("P")
    seconds(2)
    local before = {}
    for i = 0, 8191 do before[i] = V.byte(i, "GRAPHIC6") end
    seconds(play_seconds - 2)
    local changed = 0
    for i = 0, 8191 do if V.byte(i, "GRAPHIC6") ~= before[i] then changed = changed + 1 end end
    H.check(changed > 0, "the screen did not change during %d s of playing", play_seconds)
    -- While the engine plays the foreground redraws the cursor row: the frame the VDP has drawn can trail
    -- VRAM by a draw in flight, so the playing screen is held to a tolerance of 10 % of its pixels.
    local compared2, bad2 = V.render_check(0, 212)
    H.check(compared2 and bad2 * 10 <= compared2, "sntview playing: %s of %s pixels differ from VRAM", tostring(bad2), tostring(compared2))
    notes[#notes + 1] = string.format("playing %d s: %d bytes of the top 32 lines changed, %d of %d px (%.1f %%) differ from VRAM at one instant, %s",
        play_seconds, changed, bad2, compared2, 100 * bad2 / compared2, capture("playing"))
    K.tap("Q")
    wait_released("sntview restored the console")
    C.wait("ms mean/max", 60, "sntview's timing line")
    seconds(0.5)
    local lines = {}
    for _, l in ipairs(screen_lines()) do if l:find("^sntview:") then lines[#lines + 1] = l end end
    local f = assert(lio.open(H.dir .. "/sntview-exit.txt", "w"))
    f:write(table.concat(lines, "\n") .. "\n")
    f:close()
    H.check(#lines >= 3 and lines[1]:find("underruns 0, overruns 0, missed ticks 0", 1, true), "the exit report: %s", table.concat(lines, " | "))
    notes[#notes + 1] = "exit: " .. table.concat(lines, " | ")
    notes[#notes + 1] = string.format("frame rate %.2f Hz", frame_rate)
    return table.concat(notes, "; ")
end)
