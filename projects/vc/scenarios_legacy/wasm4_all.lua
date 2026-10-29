-- Все картриджи WASM-4 из export:wasm4carts (оттранслированы Spider, лицензия CC BY-NC-SA,
-- в паки не входят): каждый запускается без UI через wasmrt:w4 на FRAMES кадров без
-- нажатий. В лог: ошибка или время кадра и гистограмма цветов экрана. Маркер: [wasm4_all] done.
local FRAMES = 180
app.config_packs({ "wasmrt" })
app.load_content()
local w4 = require "wasmrt:w4"
local host = require "wasmrt:host"

local names = {}
for _, entry in ipairs(file.list("export:wasm4carts")) do
    local name = entry:match("([^/:]+)%.lua$")
    if name then names[#names + 1] = name end
end
table.sort(names)
-- export:wasm4_only.txt — имена картриджей через пробел/перевод строки (только они,
-- с полным стеком вызовов при ошибке).
local only = nil
if file.isfile("export:wasm4_only.txt") then
    only = {}
    for name in file.read("export:wasm4_only.txt"):gmatch("%S+") do only[name] = true end
end

local ok_count, fail_count, blank_count = 0, 0, 0
for _, name in ipairs(names) do
    if not only or only[name] then
        local path = "export:wasm4carts/" .. name .. ".lua"
        local t0 = os.clock()
        local cart
        local ok, err = xpcall(function()
            cart = w4.start({ platform = "wasm4", module = path }, nil)
            local t1 = os.clock()
            cart:run_frames(FRAMES)
            local per = (os.clock() - t1) / FRAMES * 1000
            local h = cart:color_histogram()
            local drawn = 25600 - h[0]
            if drawn == 0 then blank_count = blank_count + 1 end
            debug.log(("[wasm4_all] ok   %-22s load %.2fs, %.2f ms/frame, colors %d/%d/%d/%d%s"):format(
                name, t1 - t0, per, h[0], h[1], h[2], h[3], drawn == 0 and "  BLANK" or ""))
        end, function(e) return only and debug.traceback(tostring(e), 2) or tostring(e) end)
        if cart then pcall(cart.stop, cart) end
        if ok then ok_count = ok_count + 1 else
            fail_count = fail_count + 1
            debug.log(("[wasm4_all] FAIL %-22s %s"):format(name, only and tostring(err) or tostring(err):sub(1, 300)))
        end
        host.forget(path)
        collectgarbage()
        app.tick()
    end
end
debug.log(("[wasm4_all] summary: ok %d, fail %d, blank after %d frames %d"):format(ok_count, fail_count, FRAMES, blank_count))
debug.log("[wasm4_all] done")
