-- предмет blackhole:collapser: ПКМ — бросить схлопыватель; попадание в горизонт дыры сразу запускает её коллапс
local throw = require "blackhole:throw"
function on_use(pid) throw.throw(pid, "blackhole:collapser_thrown", "blackhole__collapser_thrown", "collapser", 22) end
function on_use_on_block(x, y, z, pid, normal)
    throw.throw(pid, "blackhole:collapser_thrown", "blackhole__collapser_thrown", "collapser", 22)
    return true
end
