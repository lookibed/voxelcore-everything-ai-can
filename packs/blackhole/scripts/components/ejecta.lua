-- blackhole:ejecta — блок, выброшенный коллапсом: летит динамическим телом, вращается, где приземлился — там
-- ставится блоком (если место заменяемое; иначе на 1-2 блока выше), через 12 с — ставится там, где есть.
local core = require "blackhole:core"

local tsf, body = entity.transform, entity.rigidbody
local args = ARGS or {}
local id = block.index(args.block or "base:stone")
local st = args.states or 0
local src = args.src
core.dress(entity, id, st)
if args.vel then body:set_vel(args.vel) end
local life, spin = 0, 0
local axis = vec3.normalize({ math.random() - 0.5, math.random() - 0.5, math.random() - 0.5 })
local done = false

local function land()
    if done then return end
    done = true
    local p = tsf:get_pos()
    local ix, iy, iz = math.floor(p[1]), math.floor(p[2]), math.floor(p[3])
    local placed = false
    for k = 0, 2 do
        if block.get(ix, iy + k, iz) >= 0 and block.is_replaceable_at(ix, iy + k, iz) then
            -- block.place играет звук установки (движок, LevelFrontend) — на сотне блоков разом это сотня
            -- источников OpenAL; со звуком ставятся первые 24 блока коллапса, остальные — block.set без звука и без обновления соседей (иначе осыпается песок — снова звуки)
            if core.ejecta_sound(src) then block.place(ix, iy + k, iz, id, st) else block.set(ix, iy + k, iz, id, st, true) end
            placed = true
            break
        end
    end
    core.ejecta_landed(src, placed)
    entity:despawn()
end

function on_grounded(force)
    land()
end

function on_update(tps)
    life = life + 1 / (tps or 20)
    if life > 12 then land() end
end

function on_render(dt)
    spin = spin + dt * 400
    tsf:set_rot(mat4.rotate(axis, spin))
end

function on_despawn()
    if not done then
        done = true
        core.ejecta_landed(src, false)
    end
end
