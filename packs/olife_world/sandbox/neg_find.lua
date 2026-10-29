-- negative: exponential pattern backtracking inside C string.find (no hook points) -> owner VM frozen across ticks
-- -> hard cap -> killed, owner VM restored from its checkpoint; other owners keep running
function on_tick() string.find(string.rep("a", 40), ".-.-.-.-.-.-.-.-.-.-.-.-b") end
