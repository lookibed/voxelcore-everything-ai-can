-- olife_world: engine events -> the server module. The server is active only when a start script configured
-- and began it (server_start.lua under --headless); loaded into a client by mistake it stays inert.
local server = require "olife_world:server"

function on_world_tick()
    if vc.is_headless() then
        server.maybe_begin()      -- sockets, callbacks and console commands are created here, in the main Lua state
        server.tick()
    end
end

function on_entity_spawn(uid)
    server.on_engine_spawn(uid)
end

function on_entity_despawn(uid)
    server.on_engine_despawn(uid)
end

function on_world_save()
    if server.S.running then server.save_registry() end
end
