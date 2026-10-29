-- blackhole:fx — пост-эффект blackhole в слоте blackhole:holes: каждый кадр до 8 ближайших дыр (и вспышек коллапса)
-- в мировых координатах в массивы шейдера shaders/effects/blackhole.glsl, который трассирует луч пикселя с изгибом.
--   u_holes[i] = (x, y, z, rh): центр в мире, радиус горизонта в блоках (вспышка: радиус кольца)
--   u_info[i]  = (nx, ny, nz, k): ось вращения диска (нормаль), сила
--   u_info2[i] = (spin ±1, flash, outer, merge): направление вращения, яркость вспышки (>0 — запись-вспышка),
--                внешний радиус диска в радиусах горизонта, 0..1 фаза втекания при слиянии
-- Камера (позиция, базис, fov) в шейдере — штатные униформы эффекта u_cameraPos / u_view / u_projection того же кадра
-- (PostProcessing::configureEffect), их не нужно дублировать параметрами: так нет отставания на кадр. Для журнала и
-- сверки кадров Lua всё равно считает экранную проекцию активной камерой игрока (core.fx_last).
local core = require "blackhole:core"

-- глубина для шейдера (u_depth): G-буфер с позициями есть только при graphics.advanced-render
local function depth_available()
    local ok, v = pcall(function() return vc.get_setting("graphics.advanced-render") end)
    return ok and v == true
end

local M = {}
local slot = -1
local pid = 0
local MAXN = 8
local FAR = 160

function M.open(playerid)
    pid = playerid or 0
    slot = gfx.posteffects.index("blackhole:holes")
    if slot >= 0 then
        gfx.posteffects.set_effect(slot, "blackhole")
        gfx.posteffects.set_intensity(slot, 0)
    end
    core.fx_slot = slot
    core.fx_depth = depth_available()
    core.log(("hud open: post-effect slot blackhole:holes = %d, depth (advanced-render) %s"):format(slot,
        tostring(core.fx_depth)))
end

function M.close()
    if slot >= 0 then gfx.posteffects.set_intensity(slot, 0) end
end

-- экранная проекция (только для журнала/проверок)
local function project(cam, p, rworld, aspect, f)
    local cp = cam:get_pos()
    local fr, ri, up = cam:get_front(), cam:get_right(), cam:get_up()
    local dx, dy, dz = p[1] - cp[1], p[2] - cp[2], p[3] - cp[3]
    local zc = dx * fr[1] + dy * fr[2] + dz * fr[3]
    if zc <= 0.05 then return nil end
    local xc = dx * ri[1] + dy * ri[2] + dz * ri[3]
    local yc = dx * up[1] + dy * up[2] + dz * up[3]
    return (xc / zc) * f / aspect * 0.5 + 0.5, (yc / zc) * f * 0.5 + 0.5, rworld * f / zc * 0.5
end

local list = {}
function M.render()
    local t0 = core.now()
    core.frame(time.delta())
    if slot < 0 then return end
    local ok, cam = pcall(function() return cameras.get(player.get_camera(pid)) end)
    if not ok or not cam then return end
    local cp = cam:get_pos()
    local fr = cam:get_front()
    local n = 0
    local function push(c, rh, nrm, k, spin, flash, outer, merge, infl)
        local dx, dy, dz = c[1] - cp[1], c[2] - cp[2], c[3] - cp[3]
        local dist = math.sqrt(dx * dx + dy * dy + dz * dz)
        if dist - infl > FAR then return end
        if dx * fr[1] + dy * fr[2] + dz * fr[3] < -infl then return end   -- вся зона влияния за камерой
        n = n + 1
        local e = list[n] or {}
        list[n] = e
        e[1], e[2], e[3], e[4] = c[1], c[2], c[3], rh
        e[5], e[6], e[7], e[8] = nrm[1], nrm[2], nrm[3], k
        e[9], e[10], e[11], e[12] = spin, flash, outer, merge
        e[13] = dist
    end
    for _, s in pairs(core.holes) do
        local rh = s.rh_vis or 0
        if s.phase ~= "dead" and rh > 0.02 then
            local k = s.strength or 0
            push(s.center, rh, s.N or { 0, 1, 0 }, k, s.spin or 1, 0, 5.5 + 1.5 * math.min(k, 2),
                s.phase == "merging" and (s.merge_u or 0) or 0, rh * 8)
        end
    end
    local tnow = time.uptime()
    for i = #core.flashes, 1, -1 do
        local fl = core.flashes[i]
        local u = (tnow - fl.t0) / fl.dur
        if u >= 1 then
            table.remove(core.flashes, i)
        else
            local R = 1.0 + 9 * u * fl.power
            push(fl.pos, R, { 0, 1, 0 }, 0, 1, fl.power * (1 - u) ^ 1.5, 0, 0, R * 2)
        end
    end
    for i = n + 1, #list do list[i] = nil end
    if n > 1 then table.sort(list, function(a, b) return a[13] < b[13] end) end
    local cnt = math.min(n, core.cfg.max_holes_shader, MAXN)
    core.stats.shader_n = cnt
    if cnt == 0 then
        core.fx_last = nil
        gfx.posteffects.set_intensity(slot, 0)
        core.stats.slot_active = gfx.posteffects.is_active(slot)
        core.stats.logic_s = core.stats.logic_s + (core.now() - t0)
        return
    end
    -- журнал: экранные координаты (низ-лево 0,0), радиус горизонта в долях высоты
    local vp = gui.get_viewport()
    local aspect = (vp[1] or 854) / math.max(1, vp[2] or 480)
    local f = 1 / math.tan(math.rad(cam:get_fov()) * 0.5)
    local parts = {}
    for i = 1, cnt do
        local e = list[i]
        local x, y, r = project(cam, e, e[4], aspect, f)
        if x then parts[#parts + 1] = ("(%.3f %.3f r%.3f k%.2f f%.2f)"):format(x, y, r, e[8], e[10]) end
    end
    core.fx_last = table.concat(parts, " ")
    local hb, ib, jb = Bytearray(0), Bytearray(0), Bytearray(0)
    for i = 1, MAXN do
        local e = list[i]
        if e and i <= cnt then
            Bytearray.append(hb, byteutil.pack("<ffff", e[1], e[2], e[3], e[4]))
            Bytearray.append(ib, byteutil.pack("<ffff", e[5], e[6], e[7], e[8]))
            Bytearray.append(jb, byteutil.pack("<ffff", e[9], e[10], e[11], e[12]))
        else
            Bytearray.append(hb, byteutil.pack("<ffff", 0, 0, 0, 0))
            Bytearray.append(ib, byteutil.pack("<ffff", 0, 1, 0, 0))
            Bytearray.append(jb, byteutil.pack("<ffff", 0, 0, 0, 0))
        end
    end
    gfx.posteffects.set_array(slot, "u_holes", Bytearray_as_string(hb))
    gfx.posteffects.set_array(slot, "u_info", Bytearray_as_string(ib))
    gfx.posteffects.set_array(slot, "u_info2", Bytearray_as_string(jb))
    if (core.stats.frames % 60) == 0 then core.fx_depth = depth_available() end
    gfx.posteffects.set_params(slot, { u_count = cnt, u_depth = core.fx_depth and 1 or 0 })
    gfx.posteffects.set_intensity(slot, 1)
    core.stats.slot_active = gfx.posteffects.is_active(slot)
    core.stats.logic_s = core.stats.logic_s + (core.now() - t0)
end

return M
