local core = require "blackhole:core"
local sfx = require "blackhole:sfx"

function on_world_open()
    core.reset()
    core.load_settings()
    core.void_id = block.index("blackhole:void")
    local t0 = core.now()
    sfx.prepare_all()
    core.log(("world open: sfx ready in %.1f ms"):format((core.now() - t0) * 1000))
end

function on_world_quit()
    for uid, s in pairs(core.holes) do
        if s.hum and s.hum > 0 then audio.stop(s.hum) end
    end
end

-- после коллапса воронка осыпается: песок (base:falling_block) на месте приземления base ставит block.place со звуком
-- установки, сотни звуков разом исчерпывают 255 источников OpenAL (в 0.32.1 динамики без источника потом не удаляются).
-- 20 с после коллапса падающий песок в радиусе воронки подменяется выброшенным блоком blackhole:ejecta той же скорости:
-- он падает так же и встаёт block.set без звука.
local sand_idx
function on_world_tick()
    local zones = core.collapse_zones
    if #zones == 0 then return end
    sand_idx = sand_idx or entities.def_index("base:falling_block")
    local t = time.uptime()
    for i = #zones, 1, -1 do
        local z = zones[i]
        if t - z.t0 > 20 then
            table.remove(zones, i)
            core.log(("collapse zone at %.1f %.1f %.1f closed: %d falling sand blocks replaced by silent ejecta"):format(
                z.pos[1], z.pos[2], z.pos[3], z.sand))
        else
            local ok, ids = pcall(entities.get_all_in_radius, z.pos, z.r)
            if ok and ids then
                for _, oid in pairs(ids) do
                    local e = entities.get(oid)
                    if e and e:def_index() == sand_idx then
                        local p = e.transform:get_pos()
                        local v = e.rigidbody:get_vel()
                        e:despawn()
                        entities.spawn("blackhole:ejecta", p, { blackhole__ejecta = { block = "base:sand", vel = v } })
                        z.sand = z.sand + 1
                    end
                end
            end
        end
    end
end
