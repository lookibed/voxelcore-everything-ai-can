-- negative: oprint flood — 100 x 4000-byte texts per tick: billed by length, cut to 1024 bytes by the service,
-- 64 per entity-tick at most (rest dropped), the world prints at most one per 20 ticks per entity ("rate")
function on_tick() for i = 1, 100 do oprint(string.rep("y", 4000)) end end
