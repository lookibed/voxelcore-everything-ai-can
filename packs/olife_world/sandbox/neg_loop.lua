-- negative: endless Lua loop in on_tick -> preempted by the count hook every tick (status throttled), owner budget only
function on_tick() while true do end end
