-- предмет blackhole:hole_egg: простой ПКМ — дыра перед игроком (3 блока по взгляду) с импульсом:
-- скорость дыры = 1.2 x |скорость игрока| в направлении взгляда (player.get_vel, player.get_dir).
-- ПКМ по блоку делает то же самое (и не ставит блок).
local api = require "blackhole:api"
local core = require "blackhole:core"
local last = -1

local function spawn(pid, how)
    local t = time.uptime()
    if t - last < 0.5 then return end
    last = t
    local cam = cameras.get(player.get_camera(pid))
    local eye = cam and cam:get_pos()
    if not eye then
        local x, y, z = player.get_pos(pid)
        eye = { x, y + 1.6, z }
    end
    local d = player.get_dir(pid)
    local vx, vy, vz = player.get_vel(pid)
    local sp = math.sqrt(vx * vx + vy * vy + vz * vz)
    local v = vec3.mul(d, 1.2 * sp)
    local pos = vec3.add(eye, vec3.mul(d, 3))
    local uid = api.spawn(pos, 1, v)
    core.log(("hole_egg %s by player %d: hole %d at %.1f %.1f %.1f, player speed %.2f -> hole vel %.2f %.2f %.2f (|v| %.2f)")
        :format(how, pid, uid, pos[1], pos[2], pos[3], sp, v[1], v[2], v[3], 1.2 * sp))
end

function on_use(pid)
    spawn(pid, "on_use")
end

function on_use_on_block(x, y, z, pid, normal)
    spawn(pid, "on_use_on_block")
    return true
end
