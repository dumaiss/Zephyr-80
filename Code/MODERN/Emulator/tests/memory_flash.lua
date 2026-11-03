-- license:BSD-3-Clause
-- Emulator-local memory/media probes. No guest instruction or device patching.
if _G.memory_flash_probe_started then return end
_G.memory_flash_probe_started = true

local machine = manager.machine
local cpu = machine.devices[":maincpu"]
local memory = cpu.spaces["program"]
local ports = cpu.spaces["io"]
local flash = machine.images[":flash"]
local case = assert(os.getenv("MEMFLASH_CASE"))
local output = assert(os.getenv("MEMFLASH_OUTPUT"))
local image = assert(os.getenv("MEMFLASH_IMAGE"))
local busy = false
local subscriptions = {}
local taps = {}
_G.memory_flash_probe_handles = {subscriptions, taps}

local function loadfile(path)
    local file = assert(io.open(path, "rb"))
    local bytes = file:read("a")
    file:close()
    return bytes
end

local function guarded(fn)
    local ok, err = xpcall(fn, debug.traceback)
    if not ok then
        print("FAIL memory-flash " .. case .. ": " .. err)
        machine:exit()
    end
end

local function passed(detail)
    print("PASS memory-flash " .. case .. ": " .. detail)
    machine:exit()
end

local function latch(value)
    ports:write_u8(0, value)
end

local function compare_flash(bytes)
    local old = ports:read_u8(0)
    bytes = bytes .. string.rep(string.char(255), 524288 - #bytes)
    busy = true
    for page = 0, 7 do
        latch(page << 5)
        assert(memory:read_range(0, 65535, 8) == bytes:sub(page * 65536 + 1, (page + 1) * 65536), "flash page " .. page .. " differs")
    end
    latch(old)
    busy = false
end

local function media()
    assert(flash.must_be_loaded and flash.readonly and not flash.is_writeable)
    compare_flash(loadfile(image))
    passed("524288 addressed bytes match input plus FF padding; read-only required media")
end

local function decoder()
    local rom = loadfile(image)
    local function pattern(physical)
        return ((physical >> 16) * 29 + (physical & 255) * 3 + ((physical >> 8) & 255)) & 255
    end
    for bank = 0, 7 do
        latch(8 | bank)
        for address = 0, 65535 do
            memory:write_u8(address, pattern((bank << 16) | address))
        end
    end
    for value = 0, 255 do
        for port = 0, 15 do
            ports:write_u8(0xa500 | port, value)
            for mirror = 0, 15 do
                assert(ports:read_u8(0x5a00 | mirror) == value, "latch mirror")
            end
        end
    end
    local count = 0
    for line in io.lines(assert(os.getenv("MEMFLASH_FIXTURE"))) do
        if line:sub(1, 1) ~= "#" then
            local l, a, f, r, w = line:match("(%x+) (%x+) (%x+) (%x+) (%x+)")
            l, a, f, r, w = tonumber(l, 16), tonumber(a, 16), tonumber(f, 16), tonumber(r, 16), tonumber(w, 16)
            latch(l)
            local expected = f == 1 and rom:byte(r + 1) or pattern(r)
            assert(memory:read_u8(a) == expected, "read " .. line)
            local value = pattern(w) ~ 255
            memory:write_u8(a, value)
            if f == 1 then assert(memory:read_u8(a) == expected, "flash changed on write " .. line) end
            latch(8 | (w >> 16))
            assert(memory:read_u8(a) == value, "write " .. line)
            memory:write_u8(a, pattern(w))
            count = count + 1
        end
    end
    assert(count == 8192)
    compare_flash(rom)
    passed("8192 actual read/write mappings; 65536 mirror reads; flash unchanged")
end

local function reload()
    compare_flash(loadfile(image))
    latch(0x0b)
    memory:write_u8(0x4567, 0xa9)
    for _, name in ipairs({"one.bin", "partial.bin", "full.bin", "one.bin"}) do
        assert(not flash:load(output .. "/" .. name), "load " .. name)
        assert(ports:read_u8(0) == 0x0b and memory:read_u8(0x4567) == 0xa9, "reload changes SRAM/latch")
        compare_flash(loadfile(output .. "/" .. name))
        print("TRACE reload " .. name .. " exact bytes and FF tail; SRAM/latch retained")
    end
    for _, name in ipairs({"empty.bin", "oversized.bin", "absent.bin"}) do
        local err = flash:load(output .. "/" .. name)
        assert(err, "invalid image accepted: " .. name)
        print("TRACE reject " .. name .. ": " .. err)
        compare_flash("")
    end
    assert(not flash:load(output .. "/full.bin"))
    flash:unload()
    compare_flash("")
    assert(not flash:load(output .. "/one.bin"))
    latch(0xfb)
    subscriptions[#subscriptions + 1] = emu.add_machine_reset_notifier(function()
        guarded(function()
            assert(ports:read_u8(0) == 0, "reset latch")
            assert(memory:read_u8(0) == 0x76 and memory:read_u8(1) == 255, "reset replacement bytes")
            latch(0x0b)
            assert(memory:read_u8(0x4567) == 0xa9, "soft reset lost SRAM")
            latch(0)
            passed("full/short/reject/unload/reload padding; reset latch0, replacement bytes and retained SRAM")
        end)
    end)
    machine:soft_reset()
end

local function guest()
    local rom = loadfile(image)
    compare_flash(rom)
    local counts = { [0] = 0, [7] = 0 }
    local phase = nil
    local second_page = assert(tonumber(os.getenv("MEMFLASH_OS_PAGE")))
    local second_latch = (second_page << 5) | 7
    local copied = false
    local active = false
    subscriptions[#subscriptions + 1] = emu.add_machine_reset_notifier(function()
        guarded(function()
            assert(ports:read_u8(0) == 0 and cpu.state["PC"].value == 0)
            print("TRACE reset latch=00 PC=0000 flash[0]=" .. string.format("%02x", memory:read_u8(0)))
            active = true
        end)
    end)
    taps[#taps + 1] = memory:install_write_tap(0, 65535, "flash-copy", function(address, data)
        if not active or busy or phase == nil then return end
        guarded(function()
            local value = ports:read_u8(0)
            assert(value == (phase == 0 and 0 or second_latch), "copy latch")
            local page = phase == 0 and 0 or second_page
            assert(data == rom:byte(page * 65536 + address + 1), "copy byte " .. address)
            assert(address == counts[phase], "copy order/count")
            counts[phase] = counts[phase] + 1
        end)
    end)
    taps[#taps + 1] = ports:install_write_tap(0, 15, "flash-latch", function(_, data)
        if not active or busy then return end
        guarded(function()
            print(string.format("TRACE latch %02x -> %02x PC=%04x t=%.9f copies=%d/%d", ports:read_u8(0), data, cpu.state["PC"].value, emu.time(), counts[0], counts[7]))
            if data == 0 and phase == nil then phase = 0
            elseif data == second_latch and phase == 0 then
                assert(counts[0] == 65536)
                phase = 7
            elseif data == 0x10 and phase == 7 then
                assert(counts[7] == 65536)
                phase = nil
                busy = true
                local old = ports:read_u8(0)
                for _, bank in ipairs({0, 7}) do
                    latch(8 | bank)
                    local ram = memory:read_range(0, 65535, 8)
                    local page = bank == 0 and 0 or second_page
                    assert(ram == rom:sub(page * 65536 + 1, (page + 1) * 65536), "RAM bank " .. bank .. " copy mismatch")
                    local file = assert(io.open(output .. "/" .. case .. "-bank" .. bank .. ".bin", "wb"))
                    file:write(ram)
                    file:close()
                end
                latch(old)
                busy = false
                copied = true
                print("TRACE both full SRAM banks byte-identical before post-copy guest writes")
            elseif data == 0x18 and copied then
                active = false
                passed(string.format("524288 flash bytes unchanged; 131072 copy writes and SRAM bytes match; OS entry PC=%04x", cpu.state["PC"].value))
            else
                error("unexpected boot latch transition")
            end
        end)
    end)
    machine:soft_reset()
end

guarded(function()
    if case == "decoder" then decoder()
    elseif case == "reload" then reload()
    elseif case == "konaos" or case == "zsdos" then guest()
    else media() end
end)
