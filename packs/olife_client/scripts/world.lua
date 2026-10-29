-- olife_client: engine events -> the client module, in the MAIN Lua state: pending chunk data is applied when the
-- local chunk appears; the connection (network callbacks) is opened on the first world tick; console commands and
-- the F2F `state` handler are registered here — callbacks created in the start-script coroutine stay bound to it
-- and kill it when the engine calls them between frames ("cannot resume dead coroutine").
local client = require "olife_client:client"
local bot = require "olife_client:bot"

function on_chunk_present(x, z, loaded)
    client.on_chunk_present(x, z)
end

function on_world_tick()
    client.maybe_connect()
end

function on_world_open()
    console.add_command("olife.stop", "Stop the Olife client", function()
        client.S.stop_requested = true
        return "[olife_client] stopping, syncs=" .. client.S.stats.syncs
    end)
    console.add_command("status", "Olife client status", function() return client.status() end)
    console.add_command("olife.quiet", "Stop block actions of the bot (olife_blocks check)", function()
        bot.set({block_every = 0, drop_every = 0})
        return "[olife_client] quiet: block actions off"
    end)
    console.add_command("olife.check_blocks", "Compare user:export/blocks_check.json with the replica",
        function() return client.check_blocks() end)
    -- wave 4c: netcode
    console.add_command("olife.halt", "Stop walking (predicted movement keeps sending idle inputs)", function()
        bot.set({halt = true, block_every = 0, drop_every = 0})
        return "[olife_client] halt"
    end)
    console.add_command("olife.walk", "Walk again after olife.halt", function()
        bot.set({halt = false})
        client.S.freeze_input = false
        return "[olife_client] walk"
    end)
    console.add_command("olife.freeze", "Stop sending movement inputs (the world stops simulating this player)",
        function()
            client.S.freeze_input = true
            return "[olife_client] freeze"
        end)
    console.add_command("olife.move_state", "Exact predicted movement state", function() return client.move_state() end)
    console.add_command("olife.pred_reset", "Reset the prediction statistics", function()
        return client.predict.reset_stats()
    end)
    -- UX A2: chat from the bot / headless client (lab), its log as a line
    console.add_command("olife.say text:str", "Send a chat line or a /command", function(args)
        client.chat(args[1]); client.flush()
        return "[olife_client] said " .. args[1]
    end)
    console.add_command("olife.chat_state", "Chat lines/results/notices as JSON (user:export/chat_state.json)", function()
        local st = require("olife_client:chat").f2f({last = 300})
        st.fx = nil
        pcall(file.write, "user:export/chat_state.json", json.tostring(st))
        return string.format("[olife_client] chat_state lines=%d results=%d notices=%d history_n=%d", st.count, #st.results,
            #st.notices, st.history_n or 0)
    end)
    console.add_command("olife.check_inventory", "Compare user:export/inventory_check.json with the inventory mirror",
        function() return client.inv.check(client.S) end)
    if f2f ~= nil and f2f.is_active ~= nil and f2f.is_active() and f2f.set_handler then
        f2f.set_handler(function(cmd, args)
            if cmd == "state" then return client.f2f_state() end
            if cmd == "status" then return {status = client.status()} end
            if cmd == "olife" then return require("olife_client:olife").f2f(args or {}) end   -- wave 4a
            if cmd == "assets" then return require("olife_client:assets").f2f(args or {}) end   -- UX A4
            if cmd == "mobview" then return require("olife_client:mobview").f2f(args or {}) end -- UX A3
            if cmd == "chat" then return require("olife_client:chat").f2f(args or {}) end     -- UX A2
            if cmd == "fx" then return require("olife_client:fx").state() end                 -- UX A2
            if cmd == "mobs" then return require("olife_client:mobs").f2f(args or {}) end     -- UX B1
            if cmd == "spammer" then return require("olife_client:spammer").f2f(args or {}) end -- UX B2
            if cmd == "menu" then return require("olife_client:menu").f2f(args or {}) end       -- UX B (olife_menu)
            if cmd == "mode" then return {} end
            error("unknown-command: " .. tostring(cmd))
        end)
    end
end
