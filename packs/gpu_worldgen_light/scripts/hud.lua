-- gpu_worldgen_light: буфер региона атласа gwl_world -> атлас (canvas:set_data + update) не чаще раза в кадр
local light = require "gpu_worldgen_light:light"

function on_hud_render() light.flush() end
