-- negative: memory bomb — a table of 1 MB strings grows until the Lua heap limit -> error "not enough memory"
local t = {}
local mb = string.rep("x", 1048576)
function on_tick() while true do t[#t + 1] = mb .. #t end end
