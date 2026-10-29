-- Скрипт мира пака alphamine: события движка -> модули.
-- game (такты альфы, сеть, игрок) <- on_world_tick; chunks <- on_chunk_present/remove; f2f — тесты.
local blocks = require "alphamine:blocks"
local chunks = require "alphamine:chunks"
local game = require "alphamine:game"
local player_mod = require "alphamine:player"
local f2f = require "alphamine:f2f"

function on_world_open()
    debug.log("[alphamine] world open, generator " .. tostring(world.get_generator()))
    blocks.init()
    player_mod.view_init()
    f2f.on_world_open()
end

-- Чанк загружен движком (генератор void — только воздух): данные сервера для него пишутся из
-- хранилища chunks при следующем такте (chunks.flush).
function on_chunk_present(x, z, loaded)
    chunks.on_chunk_present(x, z, loaded)
end

function on_chunk_remove(x, z)
    chunks.on_chunk_remove(x, z)
end

function on_world_tick()
    local ok, err = pcall(game.update)
    if not ok then
        debug.log("[alphamine] tick error: " .. tostring(err))
        game.close()
        game.connection_failed("Connection lost", "Internal exception: " .. tostring(err))
    end
end

function on_world_quit()
    game.close()
end
