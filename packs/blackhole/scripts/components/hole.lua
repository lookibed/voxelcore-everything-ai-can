-- blackhole:hole — чёрная дыра. Тело static (позиция только из transform, гравитации нет — kinematic в 0.32 падает).
-- Дыра движется сама: импульс p = m v, съеденное покоится (v = p / m), затухание падает с массой, гравитации нет;
-- дыры тянут друг друга в радиусе 2 R(m) притягивающей и сливаются при касании горизонтов (плавно, ~1 с).
-- Фазы: birth (рост из точки ~1 с) -> feed -> collapse (2 с, выброс блоков, вспышка); merging — втекание в большую.
-- Стирание блоков: путь set (block.set по кольцам) или fragment (VoxelFragment-«стёрка» кольца одним place), авто-выбор
-- по измеренной стоимости block.set против бюджета (settings budget_ms, erase_path).
-- Публичное поле `state` читают сценарии: entities.get(uid):get_component("blackhole:hole").state
local core = require "blackhole:core"
local sfx = require "blackhole:sfx"
local cfg = core.cfg

local tsf, rig = entity.transform, entity.skeleton
local uid = entity:get_uid()
local args = ARGS or {}

local now = core.now
local sqrt, sin, cos, exp, min, max, floor, random, abs =
    math.sqrt, math.sin, math.cos, math.exp, math.min, math.max, math.floor, math.random, math.abs

local S = {
    uid = uid,
    mass = args.mass or 1,
    vel = args.vel and { args.vel[1], args.vel[2], args.vel[3] } or { 0, 0, 0 },
    age = 0,
    phase = "birth",
    eaten_blocks = 0,       -- блоков снято с мира
    absorbed_blocks = 0,    -- блоков проглочено (обломки горизонтом + сразу на пути fragment)
    eaten_entities = 0,     -- чужих сущностей проглочено
    stolen_debris = 0,      -- обломков других дыр
    merged = 0,             -- слито дыр
    vis = 0,                -- видимый масштаб 0..1 (рост/схлопывание)
    rh_vis = 0,             -- радиус горизонта для пост-эффекта (плавно догоняет core.horizon(mass))
    strength = 0,           -- сила эффекта для пост-эффекта
    spin = (random() < 0.5) and -1 or 1,
    hum = 0,                -- speaker id гула
    ctime = 0,              -- время в фазе коллапса
    ejected = 0,
    path = "set",           -- текущий путь стирания блоков
    rings = { set = { n = 0, ms = 0, blocks = 0 }, fragment = { n = 0, ms = 0, blocks = 0 } },
}
state = S
if SAVED_DATA.mass then
    S.mass = SAVED_DATA.mass
    S.age = SAVED_DATA.age or 0
    S.eaten_blocks = SAVED_DATA.eaten or 0
    S.vel = SAVED_DATA.vel or S.vel
    S.phase = "feed"
    S.vis = 1
end

function on_save()
    SAVED_DATA.mass = S.mass
    SAVED_DATA.age = S.age
    SAVED_DATA.eaten = S.eaten_blocks
    SAVED_DATA.vel = S.vel
end

S.center = tsf:get_pos()
core.holes[uid] = S

-- импульс сохраняется: присоединённая масса покоится (или несёт свой импульс pv)
local function add_mass(dm, pv)
    local m1 = S.mass + dm
    if m1 <= 0 then return end
    local v = S.vel
    local px, py, pz = v[1] * S.mass, v[2] * S.mass, v[3] * S.mass
    if pv then px, py, pz = px + pv[1], py + pv[2], pz + pv[3] end
    S.mass = m1
    v[1], v[2], v[3] = px / m1, py / m1, pz / m1
end
S.add_mass = add_mass

-- ---------------------------------------------------------------- вид: сфера-пустота скрыта (горизонт рисует пост-эффект;
-- видимая чёрная сфера в кадре линзировалась бы в тёмное кольцо), ось диска — для обломков и шейдера
local core_bone = rig:index("core") or 1
rig:set_texture("$0", "blocks:bh_void")
pcall(rig.set_visible, rig, core_bone, false)
local N
do
    local tilt = math.rad(6 + random() * 16)
    local az = random() * math.pi * 2
    N = { sin(tilt) * cos(az), cos(tilt), sin(tilt) * sin(az) }
    if args.axis then N = vec3.normalize(args.axis) end
end
local U = core.cross(N, { 0, 0, 1 })
if vec3.length(U) < 1e-3 then U = core.cross(N, { 1, 0, 0 }) end
U = vec3.normalize(U)
local V = core.cross(U, N)
S.N, S.U, S.V = N, U, V

-- ---------------------------------------------------------------- обломки: полярные координаты в плоскости диска
local debris = {}
S.debris = debris
local eaten_ids = {}     -- кольцевой буфер {id, states} проглоченных блоков (для выброса при коллапсе)
local eaten_head = 0
local function remember(id, st)
    eaten_head = eaten_head % 600 + 1
    eaten_ids[eaten_head] = { id, st }
end

local function adopt(e, duid, pos, id, st)
    local c = S.center
    local d = { pos[1] - c[1], pos[2] - c[2], pos[3] - c[3] }
    local h = vec3.dot(d, N)
    local qx, qz = vec3.dot(d, U), vec3.dot(d, V)
    local r = sqrt(qx * qx + qz * qz)
    local rh = core.horizon(S.mass)
    local ax = vec3.normalize({ random() - 0.5, random() - 0.5, random() - 0.5 })
    local rec = { e = e, uid = duid, r = max(r, rh * 0.7), r0 = max(r, rh + 0.3, abs(h) * 0.5), th = math.atan2(qz, qx),
        h = h, t = 0, size = 1, ax = ax, spin = 0, id = id, st = st or 0 }
    debris[#debris + 1] = rec
    core.add_debris(duid, uid)
    return rec
end
S.adopt = adopt

local function free_debris(i)
    local rec = debris[i]
    debris[i] = debris[#debris]
    debris[#debris] = nil
    core.drop_debris(rec.uid)
    return rec
end

local function swallow(i)
    local rec = free_debris(i)
    if entities.exists(rec.uid) then rec.e:despawn() end
    add_mass(1)
    S.absorbed_blocks = S.absorbed_blocks + 1
    if rec.id then remember(rec.id, rec.st) end
    if random() < 0.35 then sfx.gulp(S.center, S.mass) end
end

local function spawn_debris(x, y, z, id, st)
    local e = entities.spawn("blackhole:debris", { x + 0.5, y + 0.5, z + 0.5 })
    core.dress(e, id, st)
    adopt(e, e:get_uid(), { x + 0.5, y + 0.5, z + 0.5 }, id, st)
end

-- ---------------------------------------------------------------- частицы
local emitter_disk
local function particles_start()
    if not cfg.particles or not gfx or not gfx.particles then return end
    local ok, id = pcall(gfx.particles.emit, uid, -1, {
        texture = "particles:bh_spark", lighting = false, collision = false, max_distance = 96,
        spawn_interval = 0.03, lifetime = 0.6, lifetime_spread = 0.4, velocity = { 0, 0, 0 },
        acceleration = { 0, 0, 0 }, explosion = { 0.6, 0.6, 0.6 }, size = { 0.08, 0.08, 0.08 }, size_spread = 0.5,
        spawn_shape = "sphere", spawn_spread = { 1, 1, 1 },
    })
    if ok then emitter_disk = id end
end
local spiral_phase = 0
local function particles_spiral(dt)
    if not cfg.particles or not gfx or not gfx.particles then return end
    local c = S.center
    local R = core.suck_radius(S.mass)
    local rh = core.horizon(S.mass)
    spiral_phase = spiral_phase + dt * (2.5 + S.mass / 400) * S.spin
    for arm = 0, 1 do
        local u = random()
        local r = rh * 1.3 + u * (R * 0.9)
        local th = spiral_phase + arm * math.pi + 2.2 * math.log(r / rh) * S.spin
        local p = vec3.add(c, vec3.add(vec3.mul(U, r * cos(th)), vec3.mul(V, r * sin(th))))
        local tang = vec3.add(vec3.mul(U, -sin(th) * S.spin), vec3.mul(V, cos(th) * S.spin))
        local inw = vec3.normalize(vec3.sub(c, p))
        local w = (3 + 9 * rh / r)
        local vel = vec3.add(vec3.mul(tang, w), vec3.mul(inw, w * 0.6))
        pcall(gfx.particles.emit, p, 2, {
            texture = (random() < 0.3) and "particles:bh_spark_blue" or "particles:bh_spark", lighting = false,
            collision = false, max_distance = 96, spawn_interval = 0.0001, lifetime = min(0.6, r / w * 0.8),
            lifetime_spread = 0.3, velocity = vel, acceleration = vec3.mul(inw, w * 2), explosion = { 0.2, 0.2, 0.2 },
            size = { 0.07, 0.07, 0.07 }, size_spread = 0.4,
        })
    end
end
local function particles_burst(pos, n, speed, tex)
    if not cfg.particles or not gfx or not gfx.particles then return end
    pcall(gfx.particles.emit, pos, n, {
        texture = tex or "particles:bh_spark", lighting = false, collision = false, max_distance = 128,
        spawn_interval = 0.0001, lifetime = 1.2, lifetime_spread = 0.5, velocity = { 0, 0, 0 },
        acceleration = { 0, -2, 0 }, explosion = { speed, speed, speed }, size = { 0.15, 0.15, 0.15 }, size_spread = 0.6,
    })
end

-- ---------------------------------------------------------------- поедание блоков кольцами изнутри наружу
local cur_k, cur_i = 0, 1     -- курсор: оболочка, индекс в ней
local quota = 0
local origin_key              -- воксель центра, от которого идут кольца (сдвинулась дыра — кольца заново)
local set_cost = 0.03         -- EMA мс на один block.set (+ обломок), измеряется на пути set
local ring_acc = { ms = 0, blocks = 0 }   -- накопитель текущего кольца
local scan                    -- путь fragment: {k, i, edible, sample, restore, ms}

local function ring_done(path, k, ms, blocks)
    local r = S.rings[path]
    r.n, r.ms, r.blocks = r.n + 1, r.ms + ms, r.blocks + blocks
    if blocks > 0 and (k % 4 == 0 or path == "fragment") then
        core.log(("hole %d ring %d path %s: %d blocks, %.2f ms (%.4f ms/block), R %.2f"):format(uid, k, path, blocks, ms,
            ms / blocks, core.suck_radius(S.mass)))
    end
end

local function choose_path(dt)
    if cfg.erase_path == "set" or cfg.erase_path == "fragment" then
        S.path = cfg.erase_path
        return
    end
    if S.path == "set" then
        local per_tick = core.eat_rate(S.mass) * dt * set_cost
        local budget = cfg.budget_ms / max(1, core.count_holes())
        if per_tick > budget then
            S.path = "fragment"
            core.log(("hole %d erase path -> fragment: block.set %.4f ms/block x %.0f blocks/s = %.2f ms/tick > budget %.2f ms (R %.2f, mass %.0f)")
                :format(uid, set_cost, core.eat_rate(S.mass), per_tick, budget, core.suck_radius(S.mass), S.mass))
        end
    end
end

local function erase_set(dt, kmax, R, cx, cy, cz, budget, t0)
    local scanned = 0
    while quota >= 1 and scanned < 2000 do
        if cur_k > kmax then cur_k, cur_i = 0, 1 end
        local sh = core.shell(cur_k)
        if cur_i > sh.n then
            ring_done("set", cur_k, ring_acc.ms, ring_acc.blocks)
            ring_acc.ms, ring_acc.blocks = 0, 0
            cur_k, cur_i = cur_k + 1, 1
        else
            local i = cur_i
            cur_i = cur_i + 1
            scanned = scanned + 1
            if sh.D[i] <= R then
                local x, y, z = cx + sh.X[i], cy + sh.Y[i], cz + sh.Z[i]
                local id = block.get(x, y, z)
                if id > 0 and core.edible(id) then
                    if core.debris_free() <= 0 then
                        cur_i = i   -- вернуться к этому блоку, когда освободится место
                        break
                    end
                    local tb = now()
                    local st = block.get_states(x, y, z)
                    block.set(x, y, z, 0, 0)
                    spawn_debris(x, y, z, id, st)
                    local cost = (now() - tb) * 1000
                    set_cost = set_cost * 0.9 + cost * 0.1
                    ring_acc.ms, ring_acc.blocks = ring_acc.ms + cost, ring_acc.blocks + 1
                    S.eaten_blocks = S.eaten_blocks + 1
                    core.stats.blocks = core.stats.blocks + 1
                    quota = quota - 1
                end
            end
            if (scanned % 16) == 0 and now() - t0 > budget then break end
        end
    end
end

local function erase_fragment(dt, kmax, cx, cy, cz, budget, t0)
    if cur_k > kmax then cur_k = 0 end
    if not scan or scan.k ~= cur_k then
        scan = { k = cur_k, i = 1, edible = 0, sample = {}, restore = {}, ms = 0, seen = 0 }
    end
    local sh = core.shell(cur_k)
    local ts = now()
    local nsamp = cfg.fast_debris + 32
    while scan.i <= sh.n do
        local i = scan.i
        scan.i = i + 1
        local x, y, z = cx + sh.X[i], cy + sh.Y[i], cz + sh.Z[i]
        local id = block.get(x, y, z)
        if id > 0 then
            if core.edible(id) then
                scan.edible = scan.edible + 1
                -- равномерная выборка (reservoir) для обломков-визуала и выброса при коллапсе
                if #scan.sample < nsamp then
                    scan.sample[#scan.sample + 1] = { x, y, z, id }
                else
                    local j = random(1, scan.edible)
                    if j <= nsamp then scan.sample[j] = { x, y, z, id } end
                end
            elseif id ~= core.void_id then
                scan.restore[#scan.restore + 1] = { x, y, z, id, block.get_states(x, y, z) }
            end
        end
        if (i % 64) == 0 and now() - t0 > budget then break end
    end
    scan.ms = scan.ms + (now() - ts) * 1000
    if scan.i <= sh.n then return end   -- кольцо ещё сканируется
    if scan.edible > 0 then
        if quota < scan.edible then
            quota = min(quota + 0, scan.edible)   -- копим квоту до размера кольца
            return
        end
        local tp = now()
        -- состояния обломков-выборки до стирания
        for _, sm in ipairs(scan.sample) do sm[5] = block.get_states(sm[1], sm[2], sm[3]) end
        local fr = core.shell_fragment(cur_k)
        fr.frag:place({ cx - cur_k - 1, cy - cur_k - 1, cz - cur_k - 1 }, 0)
        for _, r in ipairs(scan.restore) do block.set(r[1], r[2], r[3], r[4], r[5]) end
        local nd = min(cfg.fast_debris, core.debris_free(), #scan.sample)
        for j = 1, nd do
            local sm = scan.sample[j]
            spawn_debris(sm[1], sm[2], sm[3], sm[4], sm[5])
        end
        for j = 1, #scan.sample do remember(scan.sample[j][4], scan.sample[j][5]) end
        -- не ставшие обломками блоки проглочены сразу
        local direct = scan.edible - nd
        add_mass(direct)
        S.absorbed_blocks = S.absorbed_blocks + direct
        S.eaten_blocks = S.eaten_blocks + scan.edible
        core.stats.blocks = core.stats.blocks + scan.edible
        quota = quota - scan.edible
        local place_ms = (now() - tp) * 1000
        ring_done("fragment", cur_k, scan.ms + place_ms, scan.edible)
        if direct > 0 then sfx.gulp(S.center, S.mass) end
    end
    scan = nil
    cur_k = cur_k + 1
end

local function eat_blocks(dt, rate_k)
    local R = core.suck_radius(S.mass) * min(1, S.vis + 0.05)
    local kmax = floor(R)
    local c = S.center
    local cx, cy, cz = floor(c[1]), floor(c[2]), floor(c[3])
    local key = cx .. "," .. cy .. "," .. cz
    if key ~= origin_key then
        origin_key = key
        cur_k, cur_i, scan = 0, 1, nil
        ring_acc.ms, ring_acc.blocks = 0, 0
    end
    choose_path(dt)
    local cap = (S.path == "fragment") and max(40, (scan and scan.edible or 0) + 1) or 40
    quota = min(quota + core.eat_rate(S.mass) * rate_k * dt, cap)
    local budget = cfg.budget_ms / 1000 / max(1, core.count_holes())
    local t0 = now()
    if S.path == "fragment" then
        erase_fragment(dt, kmax, cx, cy, cz, budget, t0)
    elseif quota >= 1 then
        erase_set(dt, kmax, R, cx, cy, cz, budget, t0)
    end
    S.erase_ms = (now() - t0) * 1000
end

-- ---------------------------------------------------------------- движение обломков: сходящаяся спираль
local function update_debris(dt, hurry)
    local c = S.center
    local rh = core.horizon(S.mass)
    local swallow_r = rh * 0.55
    local mk = 1 + S.mass / 800
    local i = 1
    while i <= #debris do
        local d = debris[i]
        if core.debris[d.uid] ~= uid or not entities.exists(d.uid) then
            free_debris(i)
        else
            d.t = d.t + dt
            local ramp = min(1, d.t / 0.7) * hurry
            local closeness = 1 - min(1, d.r / d.r0)
            local vr = (1.2 + 7 * closeness * closeness) * min(mk, 6) * ramp
            d.r = d.r - vr * dt
            local w = min(16, 1.4 * (d.r0 / max(d.r, rh * 0.4)) ^ 1.5) * ramp
            d.th = d.th + w * dt * S.spin
            d.h = d.h * exp(-dt * (0.8 + 5 * closeness) * ramp)
            if d.r <= swallow_r then
                swallow(i)
            else
                local r = d.r
                local ct, st = cos(d.th), sin(d.th)
                d.e.transform:set_pos({
                    c[1] + U[1] * r * ct + V[1] * r * st + N[1] * d.h,
                    c[2] + U[2] * r * ct + V[2] * r * st + N[2] * d.h,
                    c[3] + U[3] * r * ct + V[3] * r * st + N[3] * d.h,
                })
                local size = max(0.08, min(1, (r - swallow_r) / (rh * 2.2))) * 0.92
                d.e.transform:set_size({ size, size, size })
                d.spin = d.spin + dt * (90 + 600 * closeness) * ramp
                d.e.transform:set_rot(mat4.rotate(d.ax, d.spin))
                i = i + 1
            end
        end
    end
end

-- ---------------------------------------------------------------- коллапс (объявлен раньше: его зовёт схлопыватель)
local function start_collapse(reason)
    if S.phase == "collapse" or S.phase == "dead" then return end
    if S.phase == "merging" then S.phase = "feed" end
    S.phase = "collapse"
    S.ctime = 0
    S.collapse_reason = reason
    core.log(("hole %d collapse start (%s): mass %.0f, age %.1f s (lifetime %.1f s), eaten %d blocks, absorbed %d, entities %d, merged %d")
        :format(uid, reason, S.mass, S.age, core.lifetime(S.mass), S.eaten_blocks, S.absorbed_blocks, S.eaten_entities,
            S.merged))
end
S.start_collapse = start_collapse

-- ---------------------------------------------------------------- притяжение сущностей и игроков
local sand_id = block.index("base:sand")
local function player_eids()
    local t = {}
    for _, pid in pairs(player.get_all and player.get_all() or { 0 }) do
        local ok, eid = pcall(player.get_entity, pid)
        if ok and eid then t[eid] = pid end
    end
    return t
end

local function pull(dt, k_force)
    local c = S.center
    local m = S.mass
    local rh = core.horizon(m)
    local Rp = core.pull_radius(m)
    local peids = player_eids()
    local ok, ids = pcall(entities.get_all_in_radius, c, Rp)
    if ok and ids then
        for _, oid in pairs(ids) do
            if oid ~= uid and not peids[oid] then
                local e = entities.get(oid)
                if e then
                    local name = e:def_name()
                    if name == "blackhole:hole" then
                        -- дыра <-> дыра — в holes_gravity
                    elseif name == "base:falling_block" then
                        -- осыпающийся песок в зоне тяги сразу становится обломком дыры (летит по спирали) или
                        -- проглатывается: приземлившись, base ставит его block.place со звуком, и сотни таких звуков
                        -- за секунды исчерпывают 255 источников OpenAL
                        local p = e.transform:get_pos()
                        e:despawn()
                        S.sand = (S.sand or 0) + 1
                        if core.debris_free() > 0 then
                            spawn_debris(floor(p[1]), floor(p[2]), floor(p[3]), sand_id)
                        else
                            add_mass(1)
                            S.absorbed_blocks = S.absorbed_blocks + 1
                            remember(sand_id, 0)
                        end
                    elseif name == "blackhole:debris" then
                        local owner = core.debris[oid]
                        if owner ~= uid then
                            local p = e.transform:get_pos()
                            local dd = vec3.length(vec3.sub(c, p))
                            if owner == nil or dd < rh * 1.6 or not core.holes[owner] then
                                core.drop_debris(oid)
                                e:despawn()
                                add_mass(1)
                                S.stolen_debris = S.stolen_debris + 1
                            end
                        end
                    else
                        local body = e.rigidbody
                        local p = e.transform:get_pos()
                        local dv = vec3.sub(c, p)
                        local dd = vec3.length(dv)
                        if name == "blackhole:collapser_thrown" and dd < (S.rh_vis > 0 and S.rh_vis or rh) + 0.6 then
                            -- схлопыватель попал в горизонт: коллапс сразу
                            e:despawn()
                            core.log(("hole %d hit by collapser #%d at distance %.2f (horizon %.2f)"):format(uid, oid, dd, rh))
                            start_collapse("collapser")
                            return
                        end
                        if body and body:get_body_type() == "dynamic" then
                            if dd < max(0.6, rh * 0.8) then
                                e:despawn()
                                add_mass(4)
                                S.eaten_entities = S.eaten_entities + 1
                                core.stats.absorbed = core.stats.absorbed + 1
                                core.log(("hole %d absorbed entity %s #%d (mass %.0f)"):format(uid, name, oid, S.mass))
                                sfx.gulp(c, S.mass)
                                particles_burst(p, 24, 3, "particles:bh_spark_blue")
                            else
                                local dir = vec3.mul(dv, 1 / max(dd, 1e-4))
                                local a = core.accel(m, dd, 160, 45) * k_force
                                local tang = core.cross(N, dir)
                                local tl = vec3.length(tang)
                                tang = tl > 1e-4 and vec3.mul(tang, 1 / tl) or { 0, 0, 0 }
                                local v = body:get_vel()
                                v = vec3.add(v, vec3.add(vec3.mul(dir, a * dt), vec3.mul(tang, a * dt * 0.35 * S.spin)))
                                if body:is_grounded() and v[2] < 2.5 then v[2] = 2.5 end
                                body:set_vel(v)
                            end
                        end
                    end
                end
            end
        end
    end
    -- игроки: player.get_all + своя проверка расстояния. player.get_all_in_radius в 0.32.1 сравнивает квадрат
    -- расстояния с радиусом (src/objects/Players.cpp getAllInRadius: length2 <= radius) — действующий радиус = sqrt(R).
    if cfg.pull_players then
        for _, pid in pairs(player.get_all and player.get_all() or { 0 }) do
            local x, y, z = player.get_pos(pid)
            local pc = { x, y + 0.9, z }
            local dv = vec3.sub(c, pc)
            local dd = vec3.length(dv)
            if dd <= Rp and not (player.is_suspended and player.is_suspended(pid)) then
                local dir = vec3.mul(dv, 1 / max(dd, 1e-4))
                local vx, vy, vz = player.get_vel(pid)
                if dd < rh + 0.9 then
                    local out = vec3.mul(dir, -14)
                    player.set_vel(pid, out[1], max(out[2], 4), out[3])
                    S.player_kicks = (S.player_kicks or 0) + 1
                else
                    -- у игрока затухание 10/с (core:mob): установившаяся скорость ~ a/10
                    local a = core.accel(m, dd, 400, 45) * k_force
                    player.set_vel(pid, vx + dir[1] * a * dt, vy + dir[2] * a * dt, vz + dir[3] * a * dt)
                end
            end
        end
    end
end

-- ---------------------------------------------------------------- дыра <-> дыра: притяжение и слияние
local function begin_merge(target_uid)
    if S.phase == "merging" or S.phase == "collapse" or S.phase == "dead" then return end
    S.phase = "merging"
    S.target = target_uid
    S.mtime = 0
    S.mstart = { S.center[1], S.center[2], S.center[3] }
    S.mrh = S.rh_vis
    local o = core.holes[target_uid]
    core.log(("merge start: hole %d (mass %.0f, R %.2f, horizon %.2f) flows into hole %d (mass %.0f, R %.2f, horizon %.2f), distance %.2f")
        :format(uid, S.mass, core.suck_radius(S.mass), core.horizon(S.mass), target_uid, o.mass,
            core.suck_radius(o.mass), core.horizon(o.mass), vec3.length(vec3.sub(o.center, S.center))))
end
S.begin_merge = begin_merge

local function absorb_hole(other)
    local add = other.mass
    local R0 = core.suck_radius(S.mass)
    local rh0 = core.horizon(S.mass)
    add_mass(add, { other.vel[1] * add, other.vel[2] * add, other.vel[3] * add })
    S.merged = S.merged + 1 + (other.merged or 0)
    S.eaten_blocks = S.eaten_blocks + other.eaten_blocks
    S.absorbed_blocks = S.absorbed_blocks + other.absorbed_blocks
    S.eaten_entities = S.eaten_entities + other.eaten_entities
    for _, rec in ipairs(other.debris) do
        if entities.exists(rec.uid) then
            adopt(rec.e, rec.uid, rec.e.transform:get_pos(), rec.id, rec.st)
        end
    end
    for _, it in ipairs(other.eaten_ids_list()) do remember(it[1], it[2]) end
    core.stats.merges = core.stats.merges + 1
    core.log(("merge hole %d (mass %.0f) -> hole %d: mass now %.0f, radius %.2f -> %.2f, horizon %.2f -> %.2f, debris %d")
        :format(other.uid, add, uid, S.mass, R0, core.suck_radius(S.mass), rh0, core.horizon(S.mass), #debris))
    sfx.play("merge", S.center, 1.0, 1.0 - 0.3 * core.mnorm(S.mass))
    particles_burst(S.center, 80, 6)
    core.flash(S.center, 0.4, 0.6)
end
S.absorb_hole = absorb_hole
S.eaten_ids_list = function()
    local t = {}
    for _, v in pairs(eaten_ids) do t[#t + 1] = v end
    return t
end

local function holes_gravity(dt)
    if S.phase ~= "feed" and S.phase ~= "birth" then return end
    local c = S.center
    for ouid, o in pairs(core.holes) do
        if ouid ~= uid and o.phase ~= "dead" and o.phase ~= "merging" then
            local dv = vec3.sub(o.center, c)
            local d = vec3.length(dv)
            -- радиус взаимодействия = 2 R(m) притягивающей дыры
            if d < 2 * core.suck_radius(o.mass) and d > 1e-3 then
                local a = min(30, 2.0 * cfg.hole_gravity * o.mass / (d * d))
                if not S.pulled then
                    S.pulled = ouid
                    core.log(("hole %d (mass %.0f) attracted by hole %d (mass %.0f): distance %.2f < 2R %.2f, a %.2f"):format(uid,
                        S.mass, ouid, o.mass, d, 2 * core.suck_radius(o.mass), a))
                end
                local v = S.vel
                v[1], v[2], v[3] = v[1] + dv[1] / d * a * dt, v[2] + dv[2] / d * a * dt, v[3] + dv[3] / d * a * dt
            end
            -- касание горизонтов -> меньшая втекает в большую
            if (o.phase == "feed" or o.phase == "birth") and d < core.horizon(S.mass) + core.horizon(o.mass) then
                local big_me = S.mass > o.mass or (S.mass == o.mass and uid < ouid)
                if big_me then o.begin_merge(uid) else begin_merge(ouid) end
                return
            end
        end
    end
end

-- ---------------------------------------------------------------- конец коллапса
local function finish_collapse()
    local c = S.center
    local rh = core.horizon(S.mass)
    -- осыпающийся песок (base:falling_block) в зоне тяги проглатывается в момент коллапса: иначе сотни блоков
    -- приземляются разом, base ставит каждый block.place со звуком установки — предел 255 источников OpenAL
    local nfall = 0
    local fidx = entities.def_index("base:falling_block")
    local ok, ids = pcall(entities.get_all_in_radius, c, core.pull_radius(S.mass) + 8)
    if ok and ids and fidx then
        for _, oid in pairs(ids) do
            local e = entities.get(oid)
            if e and e:def_index() == fidx then
                e:despawn()
                nfall = nfall + 1
            end
        end
    end
    S.falling_eaten = nfall
    core.collapse_zones[#core.collapse_zones + 1] = { pos = { c[1], c[2], c[3] }, r = core.pull_radius(S.mass) + 8,
        t0 = time.uptime(), sand = 0 }
    local pool = S.eaten_ids_list()
    local n_eat = min(cfg.max_eject, floor(S.absorbed_blocks * cfg.eject_fraction + 0.5), #pool)
    local n_total = n_eat + #debris
    core.ejecta_start(uid, n_total)
    local function launch(id, st, from)
        local dir = vec3.normalize({ random() * 2 - 1, random() * 1.2 + 0.1, random() * 2 - 1 })
        local p = from or vec3.add(c, vec3.mul(dir, rh + 0.6))
        local sp = 7 + random() * 9 + core.mnorm(S.mass) * 6
        local vel = vec3.add(vec3.mul(dir, sp), { 0, 4 + random() * 5, 0 })
        entities.spawn("blackhole:ejecta", p, { blackhole__ejecta = { block = block.name(id), states = st, src = uid, vel = vel } })
    end
    for i = 1, n_eat do
        local k = random(1, #pool)
        local it = pool[k]
        pool[k] = pool[#pool]; pool[#pool] = nil
        launch(it[1], it[2])
    end
    for i = #debris, 1, -1 do
        local rec = free_debris(i)
        local p = entities.exists(rec.uid) and rec.e.transform:get_pos() or nil
        if p then rec.e:despawn() end
        launch(rec.id, rec.st, p)
    end
    S.ejected = n_total
    core.stats.collapses = core.stats.collapses + 1
    core.log(("hole %d collapsed: mass %.0f, ejected %d blocks (%d from %d absorbed + %d in flight), falling sand swallowed %d")
        :format(uid, S.mass, n_total, n_eat, S.absorbed_blocks, n_total - n_eat, nfall))
    core.flash(c, 1.0 + core.mnorm(S.mass), 1.8)
    sfx.play("collapse", c, 1.0, 1.0 - 0.25 * core.mnorm(S.mass))
    particles_burst(c, 220, 14)
    particles_burst(c, 120, 9, "particles:bh_spark_blue")
    S.phase = "dead"
    entity:despawn()
end

-- ---------------------------------------------------------------- звук
local function sound_update()
    if not cfg.sound then return end
    local k = core.mnorm(S.mass)
    local vol = (0.35 + 0.65 * k) * min(1, S.vis + 0.1)
    local pitch = 1.25 - 0.55 * k - 0.15 * core.rnorm(S.mass)
    if S.phase == "collapse" then pitch = pitch * (1 + S.ctime * 0.5) end
    if S.hum == 0 then
        S.hum = sfx.play("hum", S.center, vol, pitch, true)
        if S.hum ~= 0 then
            local playing = audio.is_playing and audio.is_playing(S.hum)
            core.log(("hole %d hum speaker %d playing %s count_speakers %d"):format(uid, S.hum,
                tostring(playing), audio.count_speakers and audio.count_speakers() or -1))
        else
            S.hum = -1
            core.log(("hole %d hum: audio.play_sound returned 0 (sound off, audio disabled or NoAudio backend)"):format(uid))
        end
    elseif S.hum > 0 then
        audio.set_position(S.hum, S.center[1], S.center[2], S.center[3])
        audio.set_volume(S.hum, min(1, vol * cfg.volume))
        audio.set_pitch(S.hum, max(0.3, pitch))
    end
end

-- ---------------------------------------------------------------- события
local logged_feed = false
function on_update(tps)
    local t0 = now()
    local dt = 1 / (tps or 20) * core.time_scale
    S.age = S.age + dt
    if S.phase == "birth" then
        S.vis = min(1, S.age / 1.0)
        if S.age >= 1.0 then
            S.phase = "feed"
            if not logged_feed then
                logged_feed = true
                core.log(("hole %d phase feed: mass %.0f radius %.2f"):format(uid, S.mass, core.suck_radius(S.mass)))
            end
        end
    elseif S.phase == "feed" then
        if cfg.max_mass > 0 and S.mass >= cfg.max_mass then start_collapse("max mass")
        elseif S.age >= core.lifetime(S.mass) then start_collapse("lifetime") end
    elseif S.phase == "collapse" then
        S.ctime = S.ctime + dt
        if S.ctime >= 2.0 then
            finish_collapse()
            core.stats.logic_s = core.stats.logic_s + (now() - t0)
            return
        end
    end
    if S.phase == "birth" or S.phase == "feed" then
        eat_blocks(dt, S.phase == "birth" and 0.4 or 1)
        holes_gravity(dt)
    end
    if S.phase ~= "dead" then
        local kf = (S.phase == "collapse") and (1 + S.ctime * 2) or (S.phase == "birth" and S.vis or 1)
        if S.phase ~= "merging" then pull(dt, kf) end
        particles_spiral(dt)
        sound_update()
    end
    core.stats.logic_s = core.stats.logic_s + (now() - t0)
end

function on_render(dt)
    dt = dt * core.time_scale
    local t0 = now()
    if S.phase == "dead" then return end
    local hurry = 1
    local rh = core.horizon(S.mass)
    if S.phase == "collapse" then
        local u = min(1, S.ctime / 2.0)
        S.vis = (1 - u * u) * (1 + 0.15 * sin(S.ctime * 40))
        hurry = 3
    elseif S.phase == "merging" then
        -- плавное втекание (~1 с): позиция по smoothstep от старта к (движущейся) большей, горизонт -> 0
        local o = core.holes[S.target]
        S.mtime = S.mtime + dt
        if not o or o.phase == "dead" or o.phase == "collapse" then
            S.phase = "feed"
        else
            local u = min(1, S.mtime / 1.0)
            local e = u * u * (3 - 2 * u)
            S.center = {
                S.mstart[1] + (o.center[1] - S.mstart[1]) * e,
                S.mstart[2] + (o.center[2] - S.mstart[2]) * e,
                S.mstart[3] + (o.center[3] - S.mstart[3]) * e,
            }
            tsf:set_pos(S.center)
            S.merge_u = u
            S.rh_vis = S.mrh * (1 - e)
            S.vis = 1 - e
            if u >= 1 then
                S.phase = "dead"
                o.absorb_hole(S)
                for i = #debris, 1, -1 do debris[i] = nil end
                entity:despawn()
                return
            end
        end
    end
    if S.phase ~= "merging" then
        -- движение по инерции: сохранение импульса — в add_mass; затухание падает с массой; гравитации нет
        local v = S.vel
        local sp2 = v[1] * v[1] + v[2] * v[2] + v[3] * v[3]
        if sp2 > 1e-10 then
            local k = exp(-core.damping(S.mass) * dt)
            v[1], v[2], v[3] = v[1] * k, v[2] * k, v[3] * k
            S.center = { S.center[1] + v[1] * dt, S.center[2] + v[2] * dt, S.center[3] + v[3] * dt }
            tsf:set_pos(S.center)
        end
        -- горизонт для пост-эффекта плавно догоняет массу (после слияния — «вливание» ~1 с)
        local target = rh * S.vis
        S.rh_vis = S.rh_vis + (target - S.rh_vis) * min(1, dt * 3)
    end
    S.strength = (0.35 + 0.65 * core.mnorm(S.mass)) * max(0, S.vis) * (S.phase == "collapse" and (1 + 2 * S.ctime) or 1)
    local size = max(0.001, 2 * rh * 0.95 * max(0, S.vis))
    tsf:set_size({ size, size, size })
    update_debris(dt, hurry)
    core.stats.logic_s = core.stats.logic_s + (now() - t0)
end

function on_despawn()
    core.holes[uid] = nil
    if S.hum and S.hum > 0 then audio.stop(S.hum) end
    if emitter_disk then pcall(gfx.particles.stop, emitter_disk) end
    for i = #debris, 1, -1 do
        local rec = free_debris(i)
        if entities.exists(rec.uid) then rec.e:despawn() end
    end
    if S.phase ~= "dead" then S.phase = "dead" end
end

core.log(("hole %d spawned at %.1f %.1f %.1f mass %.0f vel %.2f %.2f %.2f (instance %d)"):format(uid, S.center[1],
    S.center[2], S.center[3], S.mass, S.vel[1], S.vel[2], S.vel[3], core.INSTANCE))
particles_start()
