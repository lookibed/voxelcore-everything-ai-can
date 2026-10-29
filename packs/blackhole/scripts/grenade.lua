-- предмет blackhole:grenade: ПКМ — бросить гранату с отскоками (сущность blackhole:grenade_thrown)
local throw = require "blackhole:throw"
function on_use(pid) throw.throw(pid, "blackhole:grenade_thrown", "blackhole__grenade_thrown", "grenade") end
function on_use_on_block(x, y, z, pid, normal)
    throw.throw(pid, "blackhole:grenade_thrown", "blackhole__grenade_thrown", "grenade")
    return true
end
