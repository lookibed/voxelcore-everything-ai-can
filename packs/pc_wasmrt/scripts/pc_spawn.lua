
function on_use_on_block(x, y, z, playerid, normal)
    local pos = vec3.add({x + 0.5,y + 1.0,z + 0.5}, normal)
    local dummy = entities.spawn("pc_wasmrt:pc", pos)
end


