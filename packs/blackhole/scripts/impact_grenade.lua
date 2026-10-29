-- предмет blackhole:impact_grenade: ПКМ — ударная граната: без отскоков, дыра при первом касании
local throw = require "blackhole:throw"
function on_use(pid) throw.throw(pid, "blackhole:impact_thrown", "blackhole__impact_thrown", "impact_grenade") end
function on_use_on_block(x, y, z, pid, normal)
    throw.throw(pid, "blackhole:impact_thrown", "blackhole__impact_thrown", "impact_grenade")
    return true
end
