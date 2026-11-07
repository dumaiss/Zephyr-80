-- license:BSD-3-Clause
-- The emulator bundle's launch check (tests/bundle.py): the card's shell
-- prompt on the V9958 console, the bundle's plugin and settings in use, and
-- every library the bundle ships mapped from the bundle, not from the host.
local bundle = assert(os.getenv("BUNDLE_DIR"), "BUNDLE_DIR")
local shipped = {}
for name in (os.getenv("BUNDLE_LIBS") or ""):gmatch("[^:]+") do shipped[#shipped + 1] = name:match("^(.-)%.so") end

local function finish(ok, text)
	print((ok and "PASS" or "FAIL") .. " bundle: " .. text)
	manager.machine:exit()
end

local function libraries()
	local inside, seen, outside, wrong = 0, {}, {}, {}
	for line in io.lines("/proc/self/maps") do
		local path = line:match("%s(/%S.*%.so[%.%d]*)$")
		if path then
			if path:sub(1, #bundle) == bundle then
				if not seen[path] then
					seen[path] = true
					inside = inside + 1
				end
			elseif not outside[path] then
				outside[path] = true
				local base = path:match("[^/]+$")
				for _, stem in ipairs(shipped) do
					if base:sub(1, #stem + 3) == stem .. ".so" then wrong[#wrong + 1] = path end
				end
			end
		end
	end
	return inside, outside, wrong
end

local done = false
emu.register_frame_done(function()
	if done then return end
	local plugin = emu.plugin.konaos
	if not plugin then return finish(false, "the konaos plugin is not loaded") end
	local rows = plugin.console.read()
	if not rows then return end
	for i = #rows, 1, -1 do
		if rows[i]:sub(1, 3) == "/> " then
			done = true
			local inside, outside, wrong = libraries()
			local external = {}
			for path in pairs(outside) do external[#external + 1] = path end
			table.sort(external)
			print("LIBS bundle " .. inside .. " other " .. #external .. ": " .. table.concat(external, " "))
			if os.getenv("ZEPHYR80_BUNDLE") ~= bundle then
				return finish(false, "ZEPHYR80_BUNDLE is " .. tostring(os.getenv("ZEPHYR80_BUNDLE")))
			end
			if #wrong > 0 then
				return finish(false, "libraries the bundle ships were loaded from the host: " .. table.concat(wrong, " "))
			end
			if inside == 0 then return finish(false, "no library is mapped from the bundle") end
			return finish(true, string.format("prompt %q at %.3f emulated s, %d libraries from the bundle, %d from the host",
				rows[i], manager.machine.time:as_double(), inside, #external))
		end
	end
end)
