-- gpu_worldgen: события мира -> modules/gen.lua (активен только в мире на генераторах gpu_worldgen:gpu*)
-- Команда консоли: gpuwg.preset [mountains|caves|islands|classic|next] — сменить пресет мира (чанки перезапишутся)
local gen = require "gpu_worldgen:gen"
local presets = require "gpu_worldgen:presets"

function on_world_open()
    gen.open()
    if gen.is_active() then
        pcall(console.add_command, "gpuwg.preset name:str=next", "gpu_worldgen: switch preset (mountains|caves|islands|classic|next)",
            function(args)
                local name = args[1]
                if name == "next" then name = presets.next(gen.preset and gen.preset.name or "classic") end
                local ok, err = gen.set_preset(name)
                return ok and ("preset " .. name) or ("error: " .. tostring(err))
            end)
    end
end
function on_world_save() gen.save() end
function on_chunk_present(x, z, loaded) gen.chunk_present(x, z, loaded) end
function on_chunk_remove(x, z) gen.chunk_remove(x, z) end
