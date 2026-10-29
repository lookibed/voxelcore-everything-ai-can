-- Пробы 6/7: камера (set_fov, настройки камеры) в мире AlphaProbe; F2 нажимается снаружи (vc_keys "f2")
-- после маркера [alpha_p7] ready, скриншот ищется в VC_ROOT/screenshots.
local C = setfenv(load(file.read("user:tools/scenarios/alpha_probes/common.lua")), getfenv(1))()
local T = "alpha_p7"
local pid = C.open_probe_world(T)
player.set_spawnpoint(pid, 8, 100, 8)
app.sleep(1)
local cam = cameras.get("core:first-person")
C.log(T, ("camera %s fov before %.3f, setting camera.fov=%s"):format("core:first-person", cam:get_fov(),
    tostring(app.get_setting("camera.fov"))))
cam:set_fov(70)
C.log(T, ("fov right after set_fov(70): %.3f"):format(cam:get_fov()))
app.sleep(1)
C.log(T, ("fov after 1 s: %.3f"):format(cam:get_fov()))
local pcam = player.get_camera(pid)
C.log(T, ("player.get_camera = %s, cameras.index(core:first-person) = %s"):format(tostring(pcam),
    tostring(cameras.index("core:first-person"))))
for _, n in ipairs({"camera.fov", "camera.fov-effects", "camera.shaking", "camera.inertia", "camera.sensitivity"}) do
    local ok, info = pcall(app.get_setting_info, n)
    local parts = {}
    if ok and type(info) == "table" then for k, v in pairs(info) do parts[#parts + 1] = k .. "=" .. tostring(v) end end
    C.log(T, n .. " = " .. tostring(app.get_setting(n)) .. " info {" .. table.concat(parts, ", ") .. "}")
end
C.log(T, "hud.hand_controller exists: " .. tostring(hud ~= nil))
C.log(T, "ready")
app.sleep(6)
C.log(T, ("fov at end: %.3f"):format(cam:get_fov()))
C.log(T, "done")
