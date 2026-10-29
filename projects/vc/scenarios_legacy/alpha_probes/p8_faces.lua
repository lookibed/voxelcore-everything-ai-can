-- Проба 8 (фаза 2): порядок граней texture-faces VoxelCore и направление взгляда камеры alphamine:view.
-- Печи альфы (id 61) с meta 2..5 = фронт на стороне альфы 2 (-Z), 3 (+Z), 4 (-X), 5 (+X) по диагонали
-- x = z = 0, 4, 8, 12; метки сверху: m2 — золото, m3 — алмаз, m4 — железо, m5 — ничего. Камера пака (как в
-- игре, alphamine:player) смотрит с -Z (yaw 0), с +Z (yaw 180), с -X (yaw 270), с +X (yaw 90).
-- Ожидание: фронт виден ровно у одной печи: с -Z у золотой, с +Z у алмазной, с -X у железной, с +X у пустой.
-- Маркеры [alpha_p8] shot <dir> — снимать vc_screenshot; done.
local C = setfenv(load(file.read("user:tools/scenarios/alpha_probes/common.lua")), getfenv(1))()
local T = "alpha_p8"
local pid = C.open_probe_world(T)
local blocks = require("alphamine:blocks")
local pl = require("alphamine:player")
blocks.init()
pl.view_init()
player.set_spawnpoint(pid, 6, 80, 6)
player.set_pos(pid, 6, 80, 6)
pcall(app.sleep_until, function() return block.get(-16, 0, -16) ~= -1 and block.get(28, 0, 28) ~= -1 end, 1e9, 20)
local STONE = blocks.to_vc[1]
local FURNACE = blocks.to_vc[61]
local marks = {[2] = blocks.to_vc[41], [3] = blocks.to_vc[57], [4] = blocks.to_vc[42]}
for x = -12, 24 do for z = -12, 24 do block.set(x, 63, z, STONE, 0) end end
for m = 2, 5 do
    local p = (m - 2) * 4
    block.set(p, 64, p, FURNACE, m * 256)
    if marks[m] then block.set(p, 65, p, marks[m], 0) end
    C.log(T, ("furnace meta %d at %d,64,%d: states %d variant %d"):format(m, p, p, block.get_states(p, 64, p),
        block.get_variant(p, 64, p)))
end
app.sleep(1)
local views = {
    {"from_minus_z", 6.5, 67, -14.5, 0},
    {"from_plus_z", 6.5, 67, 26.5, 180},
    {"from_minus_x", -14.5, 67, 6.5, 270},
    {"from_plus_x", 26.5, 67, 6.5, 90},
}
for _, v in ipairs(views) do
    pl.has_pos = true
    pl.set_position(v[2], v[3], v[4], v[5], 10)
    pl.update_view()
    app.sleep(1.5)
    local cam = pl.view_camera
    local f = cam and cam:get_front() or {0, 0, 0}
    C.log(T, ("shot %s yaw %d camera front %.3f %.3f %.3f pos %.2f %.2f %.2f"):format(v[1], v[5], f[1], f[2], f[3],
        v[2], v[3], v[4]))
    app.sleep(3)
end
C.log(T, "done")
