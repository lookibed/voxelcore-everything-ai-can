-- gpu_worldgen_light: события мира -> modules/light.lua (регион атласа gwl_world для света в шейдерах мира)
local light = require "gpu_worldgen_light:light"

function on_world_open() light.world_open() end
function on_world_tick() light.tick() end
function on_block_placed(blockid, x, y, z) light.column_later(x, z) end
function on_block_broken(blockid, x, y, z) light.column_later(x, z) end
function on_block_replaced(blockid, x, y, z) light.column_later(x, z) end
