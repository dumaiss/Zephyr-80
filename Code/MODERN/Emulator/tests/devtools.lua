-- license:BSD-3-Clause
-- Developer-tool cases (tests/devtools.py) under harness.lua, with the konaos
-- plugin loaded (-plugin konaos): symbols and bank-aware breakpoints on the
-- bankbp fixture, the debugger's cost, and save states taken and restored
-- around the savework fixture.
local H = harness
local P = assert(emu.plugin.konaos, "the konaos plugin is not loaded")
local C = P.console
local env = os.getenv

local function catch(f, ...)
	local ok, err = pcall(f, ...)
	return (not ok) and tostring(err) or nil
end

local function frames(n)
	for _ = 1, n do coroutine.yield() end
end

local function wait_prompt(prompt, timeout)
	return H.wait(function()
		local rows = C.read()
		if not rows then return nil end
		for i = #rows, 1, -1 do
			if rows[i]:sub(1, #prompt) == prompt then
				return rows[i]:sub(#prompt + 1):find("^%s*$") and i or nil
			end
		end
	end, timeout or 30, string.format("the shell prompt %q", prompt))
end

local function wait_text(text, timeout)
	return H.wait(function() return C.find(text) end, timeout or 30, string.format("%q on the console", text))
end

local function type_line(text)
	P.keys.queue(text .. "\r")
	H.wait(P.keys.idle, 10, "the keys typed")
end

local function out(fmt, ...)
	print("OUT " .. string.format(fmt, ...))
end

local function hex(s)
	return (s:gsub(".", function(c) return string.format("%02X", c:byte()) end))
end

-- Symbols and bank-aware breakpoints -----------------------------------------------

local cpu = H.cpu
local latch = emu.item(H.machine.devices[":"].items["0/m_latch"])
local status = emu.item(H.machine.devices[":vdp"].items["0/m_stat_reg"])

-- Stops: the harness's periodic callback runs while the debugger is stopped
-- (debugcpu's wait loop); each stop is recorded and execution resumed.
local stops = {}
local on_stop
if cpu.debug then
	emu.register_periodic(function()
		if H.machine.debugger.execution_state ~= "stop" then return end
		local pc = cpu.state["PC"].value
		if pc ~= 0 then
			local stop = { pc = pc, latch = latch:read(0), phys = P.phys("pc"), t = H.now() }
			stops[#stops + 1] = stop
			if on_stop then on_stop(stop) end
		end
		cpu.debug:go(0xffffffff)
	end)
end

-- The debugger's own view of physical memory: `dump` of the sram share or a
-- VRAM range; returns the bytes it printed.
local function dump(address, length)
	local path = H.dir .. "/dump.txt"
	os.remove(path)
	H.machine.debugger:command(string.format("dump %s,%s,%x,1,0", path, address, length))
	local f = io.open(path, "r")
	H.check(f, "the debugger wrote no dump for %s", address)
	local text = f:read("a")
	f:close()
	local bytes = {}
	for line in text:gmatch("[^\n]+") do
		for b in (line:match("^%s*%x+:%s*(.-)%s*$") or ""):gmatch("(%x%x)") do bytes[#bytes + 1] = string.char(tonumber(b, 16)) end
	end
	return table.concat(bytes)
end

H.case_body("debug-banks", function()
	local osmap, mapfile, hellomap, badmap = env("DEV_OSMAP"), env("DEV_BANKBP_MAP"), env("DEV_HELLO_MAP"), env("DEV_BAD_MAP")
	-- Diagnostics: nothing loaded, missing inputs, a placement naming an
	-- area the map lacks.
	local e = catch(P.resolve, "main")
	H.check(e and e:find("no symbols loaded", 1, true), "resolve with nothing loaded: %s", tostring(e))
	e = catch(P.load_os, H.dir .. "/absent.map")
	H.check(e and e:find("is missing", 1, true), "a missing OS map: %s", tostring(e))
	e = catch(P.load_program, H.dir .. "/absent/absent.map")
	H.check(e and e:find("is missing", 1, true), "a missing program map: %s", tostring(e))
	e = catch(P.load_program, badmap, "badplace")
	H.check(e and e:find("home area _ZMISSING", 1, true), "a placement/map mismatch: %s", tostring(e))
	out("diagnostics: %s", e)
	P.load_os(osmap)
	local image = P.load_program(mapfile)
	P.load_program(hellomap)
	H.check(#P.order == 3, "loaded %d images, want konaos, bankbp and hello", #P.order)

	-- Names.
	e = catch(P.resolve, "kos_entry")
	H.check(e and e:find("ambiguous", 1, true) and e:find("bankbp:kos_entry", 1, true) and e:find("hello:kos_entry", 1, true),
		"kos_entry in two programs: %s", tostring(e))
	out("ambiguous: %s", e)
	e = catch(P.resolve, "main")
	H.check(e and e:find("bankbp:_main", 1, true) and e:find("hello:_main", 1, true), "main in two programs: %s", tostring(e))
	local entry = P.resolve("bankbp:kos_entry")
	H.check(entry.value == 0x15d and entry.zone == "resident", "bankbp:kos_entry %04X %s", entry.value, entry.zone)
	local home_sym, far_sym = P.resolve("bankbp:home_step"), P.resolve("bankbp:far_step")
	H.check(home_sym.name == "_home_step" and home_sym.zone == "home" and home_sym.value == 0x8000,
		"home_step: %s %s %04X", home_sym.name, home_sym.zone, home_sym.value)
	H.check(far_sym.name == "_far_step" and far_sym.zone == "far1" and far_sym.segment == 1 and far_sym.value == 0x8000,
		"far_step: %s %s %04X", far_sym.name, far_sym.zone, far_sym.value)
	e = catch(P.resolve, "nosuch")
	H.check(e and e:find("no symbol nosuch", 1, true), "an unknown name: %s", tostring(e))
	e = catch(P.resolve, "other:main")
	H.check(e and e:find("no image other", 1, true), "an unknown image: %s", tostring(e))
	e = catch(P.bp, "bankbp:l__CODE")
	H.check(e and e:find("absolute", 1, true), "a breakpoint on an absolute symbol: %s", tostring(e))
	e = catch(P.bp, "konaos:_reset")
	H.check(e and e:find("no one physical bank", 1, true), "a breakpoint in the OS caller window: %s", tostring(e))
	local launch = P.where("konaos:_kos_process_launch")
	H.check(#launch.phys == 1 and launch.phys[1] == launch.logical, "the launch entry in common memory: %s", launch.text)
	local nucleus = P.where("konaos:_romfs_read")
	H.check(nucleus.phys[1] == 0x70000 | nucleus.logical, "a nucleus symbol in bank 7: %s", nucleus.text)
	out("where: %s; %s", launch.text, nucleus.text)

	-- Bank-aware breakpoints: pending until the launch finds the banks.
	local home = P.bp("bankbp:home_step")
	local far = P.bp("bankbp:far_step")
	H.check(home.pending and far.pending, "breakpoints before the program is loaded: %s / %s", home.text, far.text)
	local hello_bp = P.bp("hello:main")

	C.load_font()
	wait_prompt("/> ", 40)
	local views = {}
	on_stop = function(stop)
		if stop.pc ~= 0x8000 or views.done or stop.phys ~= far.phys[1] then return end
		-- Stopped in far_step with the aperture open: read the home zone
		-- (another bank, outside the CPU's view), the far bank and VRAM, and
		-- check that none of it moved the latch or the VDP status.
		local l0, s0, s2 = latch:read(0), status:read(0), status:read(2)
		local home_bytes = image.exe.primary:sub(0x8000 - 0x100 + 1, 0x8000 - 0x100 + 7)
		local far_bytes = image.exe.segments[1].bytes:sub(1, 6)
		views.home_sram = P.sram(home.phys[1], 7) == home_bytes
		views.far_sram = P.sram(far.phys[1], 6) == far_bytes
		local cpu_view = {}
		for i = 0, 5 do cpu_view[#cpu_view + 1] = string.char(H.program:read_u8(0x8000 + i)) end
		views.cpu_far = table.concat(cpu_view) == far_bytes
		views.dump_home = dump(string.format("%X:sram.s", home.phys[1]), 7) == home_bytes
		views.dump_far = dump(string.format("%X:sram.s", far.phys[1]), 6) == far_bytes
		-- VRAM's upper 64 KiB (the odd bytes of the console's bitmap lines):
		-- the first 16 bytes there holding ink.
		local at = 0x10000
		while at < 0x20000 and not P.vram(at, 16):find("[^%z]") do at = at + 16 end
		local high = P.vram(at, 16)
		views.dump_vram = dump(string.format("%X:vdp", at), 16) == high and high:find("[^%z]") ~= nil
		views.latch_kept = latch:read(0) == l0
		views.status_kept = status:read(0) == s0 and status:read(2) == s2
		views.done = true
		out("views at far_step: latch %02X, home %05X %s, far %05X %s, VRAM %05X %s", l0, home.phys[1], hex(home_bytes),
			far.phys[1], hex(far_bytes), at, hex(high))
	end
	type_line("/fs/BANKBP.EXE")
	wait_text("BANKBP rounds=3 value=131", 20)
	wait_prompt("/> ", 10)
	H.check(not home.pending and not far.pending, "breakpoints never armed: %s / %s", home.text, far.text)
	H.check(home.phys[1] >> 16 ~= far.phys[1] >> 16, "home and far in one bank: %s / %s", home.text, far.text)
	out("armed: %s [%s]; %s [%s]", home.text, home.condition, far.text, far.condition)

	-- Stops at 8000h: home, far, home, far, home, far, each in its own bank.
	local seq, sites = {}, {}
	for _, s in ipairs(stops) do
		if s.pc == 0x8000 then
			local which = s.phys == home.phys[1] and "home" or (s.phys == far.phys[1] and "far" or string.format("?%05X", s.phys))
			seq[#seq + 1] = which
			local mode, page, q = s.latch & 0x18, s.latch >> 5, s.latch & 7
			if which == "home" then
				H.check(mode == 0x10 and page == 0 and q == home.phys[1] >> 16, "home stop with latch %02X", s.latch)
			elseif which == "far" then
				H.check(mode == 0x10 and page ~= 0 and q == home.phys[1] >> 16, "far stop with latch %02X (aperture closed?)", s.latch)
			end
			sites[#sites + 1] = string.format("%s %05X latch %02X", which, s.phys, s.latch)
		end
	end
	H.check(table.concat(seq, " ") == "home far home far home far", "stops at 8000h: %s", table.concat(seq, " "))
	local hello_stops = 0
	for _, s in ipairs(stops) do if s.pc == hello_bp.symbol.value then hello_stops = hello_stops + 1 end end
	H.check(hello_stops == 0, "hello:main stopped %d times without hello running", hello_stops)
	for _, v in ipairs({ "home_sram", "far_sram", "cpu_far", "dump_home", "dump_far", "dump_vram", "latch_kept", "status_kept" }) do
		H.check(views[v], "memory view check %s failed", v)
	end
	out("stops: %s", table.concat(sites, "; "))

	-- The same logical address without the bank condition stops in both.
	P.bpclear()
	local raw = cpu.debug:bpset(0x8000, "", "")
	local first = #stops
	type_line("/fs/BANKBP.EXE")
	wait_text("BANKBP rounds=3 value=131", 20)
	wait_prompt("/> ", 10)
	cpu.debug:bpclear(raw)
	-- Every stop at 8000h, in whichever bank: bankbp's six and any other
	-- code that runs there (the nucleus's window, for one).
	local banks, mine, others = {}, 0, {}
	for i = first + 1, #stops do
		local s = stops[i]
		if s.pc == 0x8000 then
			banks[#banks + 1] = string.format("%X", s.phys >> 16)
			if s.phys == home.phys[1] or s.phys == far.phys[1] then
				mine = mine + 1
			else
				others[#others + 1] = string.format("%05X", s.phys)
			end
		end
	end
	H.check(mine == 6, "the plain breakpoint stopped %d times in bankbp's banks, want 6 (banks %s)", mine, table.concat(banks, " "))
	out("plain bpset 8000: %d stops in banks %s (bankbp's 6; elsewhere: %s)", #banks, table.concat(banks, " "),
		#others > 0 and table.concat(others, " ") or "none")
	return string.format("home_step %05X and far_step %05X share 8000h; bank-aware stops home/far x3 (latch mode 10, aperture open at far); a plain breakpoint at 8000h stops %d times, in banks %s; views of other banks and VRAM leave the latch and VDP status alone",
		home.phys[1], far.phys[1], #banks, table.concat(banks, " "))
end)

-- The debugger's cost: boot, run bankbp, and report wall per emulated second.
H.case_body("debug-timing", function()
	local breaks = env("DEV_BREAKS") == "1"
	if breaks then
		P.load_os(env("DEV_OSMAP"))
		P.load_program(env("DEV_BANKBP_MAP"))
		P.bp("bankbp:home_step")
		P.bp("bankbp:far_step")
	end
	C.load_font()
	local wall0, t0 = emu.osd_ticks(), H.now()
	wait_prompt("/> ", 40)
	type_line("/fs/BANKBP.EXE")
	wait_text("BANKBP rounds=3 value=131", 20)
	wait_prompt("/> ", 10)
	local frames_left = 600
	while frames_left > 0 do frames_left = frames_left - 1 coroutine.yield() end
	local wall = (emu.osd_ticks() - wall0) / emu.osd_ticks_per_second()
	local emulated = H.now() - t0
	local count = 0
	for _, s in ipairs(stops) do if s.pc == 0x8000 then count = count + 1 end end
	out("TIMING debug=%s breaks=%s emulated=%.3f wall=%.3f stops=%d", cpu.debug and "1" or "0", breaks and "1" or "0", emulated, wall, count)
	return string.format("%.3f emulated s in %.3f wall s, %d stops", emulated, wall, count)
end)

-- Save states ----------------------------------------------------------------------

-- The observations both runs make after a save point: the IO controller and
-- SIO1 line state at the first frame after it, every PSG/DAC write with its
-- time, the console at the end, VRAM and the VDP registers at the end.
local ioc = H.machine.devices[":ioc"]
local sio1 = H.machine.devices[":sio1"]
local function item(device, name) return emu.item(device.items["0/" .. name]) end
local IOC_ITEMS = { "m_phase", "m_count", "m_bulk_count", "m_bulk_total", "m_command_synced", "m_bulk_synced" }
local SIO1_ITEMS = { "m_rts", "m_cts", "m_dcd", "m_sync", "m_hunt", "m_fifo_depth" }
local function line_state()
	local parts = { string.format("t=%.9f", H.now()) }
	for _, n in ipairs(IOC_ITEMS) do parts[#parts + 1] = n .. "=" .. item(ioc, n):read(0) end
	for _, n in ipairs(SIO1_ITEMS) do
		local it = item(sio1, n)
		local v = {}
		for i = 0, it.count - 1 do v[#v + 1] = tostring(it:read(i)) end
		parts[#parts + 1] = n .. "=" .. table.concat(v, ",")
	end
	return table.concat(parts, " ")
end

local sound = {}
H.keep(H.io:install_write_tap(0xe0, 0xff, "dev-sound", function(offset, data)
	sound[#sound + 1] = string.format("%.9f %02X %02X", H.now(), offset & 0xff, data)
end))

-- The end of a run: what both runs must agree on after the save point.
local function final(path, since)
	local rows = C.text() or "no console"
	local vram = {}
	local space = H.machine.devices[":vdp"].spaces["vram"]
	for page = 0, 1 do vram[#vram + 1] = space:read_range(page * 0x10000, page * 0x10000 + 0xffff, 8) end
	local regs = emu.item(H.machine.devices[":vdp"].items["0/m_cont_reg"])
	local r = {}
	for i = 0, 46 do r[#r + 1] = string.format("%02X", regs:read(i)) end
	local f = assert(io.open(path, "w"))
	f:write("regs ", table.concat(r), "\n")
	for _, s in ipairs(sound) do
		if tonumber(s:match("^(%S+)")) > since then f:write("sound ", s, "\n") end
	end
	f:write("screen\n", rows, "\n")
	f:close()
	local v = assert(io.open(path .. ".vram", "wb"))
	v:write(table.concat(vram))
	v:close()
end

-- Copy a media tree or file at the save instant (the pre-save notifier runs
-- inside the save, with no emulation in between).
local function copy_file(from, to)
	local i = assert(io.open(from, "rb"))
	local o = assert(io.open(to, "wb"))
	while true do
		local chunk = i:read(1 << 20)
		if not chunk then break end
		o:write(chunk)
	end
	i:close()
	o:close()
end

local lfs = require("lfs")
local function copy_tree(from, to)
	lfs.mkdir(to)
	for name in lfs.dir(from) do
		if name ~= "." and name ~= ".." then
			local src, dst = from .. "/" .. name, to .. "/" .. name
			if lfs.attributes(src, "mode") == "directory" then copy_tree(src, dst) else copy_file(src, dst) end
		end
	end
end

local PHASES = { [0] = "IDLE", "WINDOW", "RELEASE", "GUARD", "REPLY", "BULK_HOST", "BULK_GUARD", "BULK_SEND",
	"BULK_RECEIVE", "BULK_RELEASE", "RESETTING" }

-- The line state at the first frame after a save (save-run) or after the
-- restore (save-load): the frame both runs share.
local after, just_saved = {}, {}
H.keep(emu.add_machine_frame_notifier(function()
	if #just_saved > 0 then
		local state = line_state()
		for _, name in ipairs(just_saved) do after[name] = state end
		just_saved = {}
	end
end))

H.case_body("save-run", function()
	local media, kind, snaps = env("DEV_MEDIA"), env("DEV_MEDIA_KIND"), env("DEV_SNAPS")
	local pending, saved = nil, {}
	local log = assert(io.open(H.dir .. "/points.tsv", "w"))
	H.keep(emu.add_machine_pre_save_notifier(function()
		if not pending then return end
		local name = pending
		local phase = item(ioc, "m_phase"):read(0)
		local dir = snaps .. "/" .. name
		lfs.mkdir(dir)
		if kind == "image" then copy_file(media, dir .. "/card.img") else copy_tree(media, dir .. "/card") end
		saved[name] = { t = H.now(), phase = PHASES[phase] or tostring(phase), bulk = item(ioc, "m_bulk_count"):read(0) }
		log:write(string.format("%s\t%.9f\t%s\t%d\n", name, H.now(), saved[name].phase, saved[name].bulk))
		log:flush()
		pending = nil
		just_saved[#just_saved + 1] = name
	end))
	-- Request a save; wait for it, then for the first frame after it, where
	-- both runs record the line state.
	local function save(name)
		pending = name
		H.machine:save(name)
	end
	local function settle(name)
		H.wait(function() return saved[name] end, 2, "save " .. name)
	end

	C.load_font()
	wait_prompt("/> ", 40)
	frames(6)
	save("idle")
	settle("idle")
	type_line("/fs/SAVEWORK.EXE")
	frames(4)
	-- Mid-command, mid-bulk (the program's load), mid-write (a block of
	-- OUTPUT.BIN on its way to the open file) and active: triggered from the
	-- SIO1 traffic and the console while the program runs.
	local want = { command = true, bulk = true, write = true }
	local tap = H.io:install_read_tap(0x30, 0x3f, "dev-save-trigger", function(offset, data)
		if pending then return end
		local phase = item(ioc, "m_phase"):read(0)
		if want.command and (phase == 1 or phase == 4) then
			want.command = nil
			save("command")
		elseif want.bulk and phase == 7 and item(ioc, "m_bulk_count"):read(0) >= 64 then
			want.bulk = nil
			save("bulk")
		elseif want.write and not want.bulk and phase == 8 and item(ioc, "m_bulk_count"):read(0) >= 64 then
			want.write = nil
			save("write")
		end
	end)
	H.keep(tap)
	H.wait(function() return saved.command and saved.bulk and saved.write end, 10, "the command, bulk and write save points")
	tap:remove()
	wait_text("SAVEWORK tick 5", 20)
	save("active")
	settle("active")
	wait_text("SAVEWORK done", 20)
	wait_prompt("/> ", 10)
	local done = H.now()
	frames(30)
	local f = assert(io.open(H.dir .. "/after.tsv", "w"))
	for _, name in ipairs({ "idle", "command", "bulk", "write", "active" }) do
		f:write(name, "\t", after[name], "\n")
	end
	f:write("done\t", string.format("%.9f", done), "\n")
	f:close()
	log:close()
	for _, name in ipairs({ "idle", "command", "bulk", "write", "active" }) do
		final(H.dir .. "/final-" .. name .. ".txt", tonumber(after[name]:match("^t=(%S+)")))
	end
	return string.format("saved idle %.6f, command %.6f (%s), bulk %.6f (%s, %d bytes clocked), write %.6f (%s, %d), active %.6f; done %.6f",
		saved.idle.t, saved.command.t, saved.command.phase, saved.bulk.t, saved.bulk.phase, saved.bulk.bulk,
		saved.write.t, saved.write.phase, saved.write.bulk, saved.active.t, done)
end)

if H.case == "save-load" then just_saved = { env("DEV_RESTORE") } end

H.case_body("save-load", function()
	local point = env("DEV_RESTORE")
	C.load_font()
	if point == "idle" then
		type_line("/fs/SAVEWORK.EXE")
	end
	wait_text("SAVEWORK done", 25)
	wait_prompt("/> ", 10)
	local done = H.now()
	frames(30)
	local first = after[point]
	local since = tonumber(first:match("^t=(%S+)"))
	local f = assert(io.open(H.dir .. "/after.tsv", "w"))
	f:write(point, "\t", first, "\n")
	f:write("done\t", string.format("%.9f", done), "\n")
	f:close()
	final(H.dir .. "/final-" .. point .. ".txt", since)
	return string.format("restored %s, first frame %.6f; done %.6f", point, since, done)
end)
