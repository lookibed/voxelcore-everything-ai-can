-- negative: one huge allocation -> Lua "not enough memory" (heap limit), the owner VM survives
function on_tick() local s = string.rep("x", 2^30) end
