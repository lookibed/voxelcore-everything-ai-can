-- Olife client / bot start script. Bot: VoxelCore 0.32 --headless --script <this file> --tps 20 --stdin-cmd
--   -- --gateway <port> --name <name> [--token T] [--ticks N] [--blocks EVERY_N_TICKS] [--walk 0|1] [--reconnect S]
-- F2F client: the 0.32 test build runs the same script (client-side --script is supported in 0.32).
-- Opens its own local world (empty generator; every chunk comes from the server), connects, ticks the client
-- after every engine tick. Admin (stdin): status | olife.quiet | olife.check_blocks | olife.stop
local function arg(name, default)
    local v = vc.get_project_arg(name)
    if v == nil or v == "" then return default end
    return v
end
local gw = tonumber(arg("gateway", ""))
local name = arg("name", "bot")
local token = arg("token", "olife-bot")
local max_ticks = tonumber(arg("ticks", "0")) or 0
local block_every = tonumber(arg("blocks", "0")) or 0
local walk = arg("walk", "1") ~= "0"
local reconnect = tonumber(arg("reconnect", "0")) or 0      -- stage 6: reconnect after a world restart (seconds)
-- wave 4b: --auth https://host:port (ticket service; empty = static token in Hello), --gw-id <gateway audience id>,
-- --auth-pub <b64url x25519 key of the auth service, pinned>, --auth-verify 0|1 (verify_ssl; 0 for a dev self-signed cert)
local auth = arg("auth", "")
local opts = {reconnect = reconnect, auth = auth ~= "" and auth or nil, gw_id = arg("gw-id", ""),
              auth_pub = arg("auth-pub", ""), auth_verify = arg("auth-verify", "0") == "1"}
assert(gw, "project arg --gateway is required")
-- wave 4c: --opts "k=v,..." (netcode): move=predict|legacy (predicted movement or the old position input),
-- drops=<every N ticks: drop 1 item>, radius=<walk radius>, sprint=0|1; "none" = defaults (predict)
local netopts = {move = "predict"}         -- wave 4c default; "move=legacy" = the old position input
for k, v in tostring(arg("opts", "none")):gmatch("([%w_]+)=([^,]+)") do netopts[k] = v end
print("[olife_client] opts " .. tostring(arg("opts", "none")) .. " move=" .. netopts.move)
local function apply_netopts(cl, bt)
    cl.S.move = netopts.move
    bt.set({drop_every = tonumber(netopts.drops) or 0, radius = tonumber(netopts.radius) or 10,
            sprint = netopts.sprint == "1"})
end

-- add only the packs that are not loaded yet: in a WINDOW (F2F build) the menu already loaded the project's base
-- packs and adding "base" again aborts with "pack duplication [base]" (0xC0000409)
local function ensure_packs(ids)
    local loaded = {}
    for _, id in ipairs(app.get_content()) do loaded[id] = true end
    local add = {}
    for _, id in ipairs(ids) do
        if not loaded[id] then add[#add + 1] = id end
    end
    if #add > 0 then app.reconfig_packs(add, {}) end
end
ensure_packs({"base", "olife_client"})   -- olife_proto comes as a dependency
pcall(app.set_setting, "chunks.load-distance", 6)
app.new_world("replica_" .. name, "1", "core:default")
print("[olife_client] world=" .. tostring(world.is_open()) .. " headless=" .. tostring(vc.is_headless()) .. " name=" .. name)

local client = require "olife_client:client"
local bot = require "olife_client:bot"
bot.configure(name, {block_every = block_every})
apply_netopts(client, bot)                        -- wave 4c
if walk then client.S.on_tick = bot.on_tick end
client.request_connect(gw, name, token, opts)     -- opened by the first world tick (main Lua state), see scripts/world.lua

-- wave 4b: a pack update that cannot be applied live (olife_client:packs) -> reopen the world: the engine re-scans
-- content sources and takes the pack from world:content; Bye, reopen, reset the replica, new ticket, reconnect
local function reopen_for_packs()
    local P = require "olife_client:packs"
    local why = table.concat(P.S.reopen_paths, ","):sub(1, 200)
    client.leave_for_reopen("packs reload")
    local t0 = os.clock()
    app.save_world()
    app.reopen_world()
    -- 0.32: reopen_world re-scans content (the pack now comes from world:content) but does NOT reset the module cache
    -- of this script: `require` returns the same instances (checked: same table) -> reset their state explicitly
    local same = require("olife_client:client") == client
    P.S.reopen, P.S.reopen_paths, P.S.hot = false, {}, {}
    P.S.reopens = (P.S.reopens or 0) + 1
    client.reset_after_reopen(P.S.reopens)
    apply_netopts(client, bot)                    -- wave 4c options survive (same module instances)
    client.request_connect(gw, name, token, opts)
    print(string.format("[olife_client] packs reopen #%d in %.0f ms cpu (%s), pack path %s, same module %s",
        P.S.reopens, (os.clock() - t0) * 1000, why, tostring((pack.get_info("olife_client") or {}).path), tostring(same)))
end

local n = 0
while not client.S.stop_requested do
    app.tick()
    client.tick()
    local P = require "olife_client:packs"
    if P.reopen_pending() and not P.S.busy then reopen_for_packs() end
    n = n + 1
    if max_ticks > 0 and n >= max_ticks then break end
    if client.closed() and not client.will_reconnect() and n > 100 then break end
end
print(client.status())
client.bye("client stopping")
print("[olife_client] finished ticks=" .. n)
app.close_world(false)
