-- Native 0.32 UI test (no F2F): `VoxelCore.exe --test <this file>` in a window.
-- Opens the main menu, clicks "Settings" with test.click(test.find_by_text(...)), takes
-- gui.screenshot() before/after and saves them through Canvas:encode("png") + file.write_bytes.
-- Prints wall-clock (time.precise_time) and engine-clock (time.uptime) timings and frame counts.
local function P(...) print("[native-test] " .. string.format(...)) end
local t0, u0 = time.precise_time(), time.uptime()
local frames = 0
local function tick() app.tick(); frames = frames + 1 end

P("start uptime=%.4f precise=%.4f test=%s f2f=%s", u0, t0, tostring(test ~= nil), tostring(f2f and f2f.is_active()))

-- wait for the main page
local doc
for i = 1, 600 do
    local ok, d = pcall(Document.new, "core:pages/main")
    if ok and d and _MENU.page == "main" then doc = d break end
    tick()
end
assert(doc, "main page did not appear")
for i = 1, 5 do tick() end
P("menu ready after %d frames, %.3f s wall, %.3f s uptime", frames, time.precise_time() - t0, time.uptime() - u0)

local function save(name)
    local canvas = gui.screenshot()
    local w, h = canvas.width, canvas.height
    local bytes = canvas:encode("png")
    file.write_bytes("export:" .. name, bytes)  -- user: is read-only for scripts in 0.32
    P("shot %s %sx%s %d bytes crc32=%s", name, tostring(w), tostring(h), #bytes, tostring(crc32 and crc32(bytes)))
end
save("native_menu.png")

-- button texts are translated in the "menu" context (main.xml: context='menu', text '@Settings')
local texts = {}
local i = 1
while doc.root[i] do texts[#texts + 1] = tostring(doc.root[i].text); i = i + 1 end
P("main page buttons: %s", table.concat(texts, " | "))
local label = gui.str("Settings", "menu")
local btn = test.find_by_text(doc, label)
P("find_by_text(%q) -> %s", label, tostring(btn and btn.id or btn))
assert(btn, "no Settings button")
local f0, w0 = frames, time.precise_time()
test.click(btn)
for i = 1, 10 do tick() end
P("after click: page=%s, %d frames (+2 inside test.click), %.3f s wall", tostring(_MENU.page), frames - f0, time.precise_time() - w0)
save("native_settings.png")

test.press("escape")
for i = 1, 5 do tick() end
P("after escape: page=%s", tostring(_MENU.page))
P("cursor locked=%s", tostring(input.is_cursor_locked and input.is_cursor_locked()))
P("end frames=%d wall=%.3f s uptime=%.3f s", frames, time.precise_time() - t0, time.uptime() - u0)
