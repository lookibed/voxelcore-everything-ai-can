-- negative: endless loop inside pcall (non-preemptible C boundary) -> doomed at doom_factor x budget -> killed
function on_tick() while true do pcall(function() while true do end end) end end
