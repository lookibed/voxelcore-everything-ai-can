-- Olife world server start script: VoxelCore 0.32 --headless --script <this file> --tps 20 --stdin-cmd
--   -- --port <internal port> [--sandbox <port>] [--sandbox-proto jsonl|bin] [--secret S] [--ticks N] [--view R]
--      [--world NAME] [--seed SEED] [--generator ID] [--mobs N] [--scripted N] [--journal-every TICKS]
-- Opens (or creates) the world, loads chunks around spawn, starts the authoritative server (ticked from
-- olife_world/scripts/world.lua on_world_tick) and serves admin commands from stdin (--stdin-cmd):
--   status | players | kick <eid> | save | journal [n] | olife.dump_blocks | olife.stop
--   journal_dump [path] | sandbox_reconnect          (stage 6: supervisor, tools/lab/labcore/supervise.py)
assert(vc.is_headless(), "olife_world server must run headless (--headless)")
local function arg(name, default)
    local v = vc.get_project_arg(name)
    if v == nil or v == "" then return default end
    return v
end
local function num(name, default) return tonumber(arg(name, nil)) or default end

local cfg = {
    port = num("port", nil), sandbox_port = num("sandbox", 0), sandbox_proto = arg("sandbox-proto", "jsonl"),
    secret = arg("secret", ""), ticks = num("ticks", 0), view = num("view", 3), world = arg("world", "olife"),
    seed = arg("seed", "2026"), generator = arg("generator", "base:demo"), mobs = num("mobs", 3),
    scripted = num("scripted", 2), journal_every = num("journal-every", 0),
}
assert(cfg.port, "project arg --port is required")
-- wave 4c: --opts "k=v,k=v" (netcode): snap=full|delta, snap_budget=<bytes/tick/session>, keyframe=<ticks>,
-- inv=0|1 (inventory gates place/break), move_burst=<inputs>; "none" = defaults
do
    local o = arg("opts", "none")
    cfg.snap, cfg.inv_enforce = "delta", true     -- wave 4c defaults (opts "snap=full,inv=0" = the wave-2 behaviour)
    for k, v in tostring(o):gmatch("([%w_]+)=([^,]+)") do
        if k == "snap" then cfg.snap = v
        elseif k == "jit" or k == "jitopt" or k == "gc" then cfg[k] = v   -- wave 5p: jit=on|off|tuned|wasm, jitopt=a=1;b=2, gc=tick
        elseif k == "inv" then cfg.inv_enforce = v ~= "0"
        elseif k == "wl" then cfg.wl = v                  -- UX B (olife_menu): whitelist scope (gateway id) for /whitelist
        elseif tonumber(v) then cfg[k] = tonumber(v) end
    end
    print("[olife_world] opts " .. tostring(o) .. " snap=" .. cfg.snap .. " inv=" .. tostring(cfg.inv_enforce))
end
-- wave 5p (OLIFE_WORLD_PERF.md): LuaJIT mode for the whole engine Lua state (the world tick runs in the main state,
-- jit.on/off are global): jit=tuned (DEFAULT since wave 5p: bigger trace cache maxtrace/maxmcode, hotexit/maxside —
-- with the stock limits (1000 traces) the world flushed the whole trace cache 17-18 times in 25 s under
-- olife_sandbox_load and re-recorded ~20 000 traces: tick p95 26-28 ms, max 71-86 ms), on (stock LuaJIT parameters),
-- off (interpreter only, ~12x slower), wasm (= wasmrt host.lua JIT_TUNED incl. -loop); jitopt="k=v;k=v" extra
-- jit.opt.start flags; gc=tick (DEFAULT since wave 5p: the collector is stopped and stepped after every world tick,
-- server.lua gc_after_tick; gcbudget=<ms> 6, gcmax=<MB> 512) | auto (stock incremental GC); gcpause / gcstepmul —
-- collectgarbage setpause / setstepmul (Lua defaults 200 / 200)
do
    cfg.jit, cfg.gc = cfg.jit or "tuned", cfg.gc or "tick"
    local mode = cfg.jit
    if mode == "off" then
        jit.off(); jit.flush()
    elseif mode == "tuned" then
        jit.opt.start("maxtrace=8000", "maxmcode=65536", "hotexit=200", "maxside=400", "maxsnap=1000")
    elseif mode == "wasm" then
        jit.opt.start("-loop", "maxtrace=8000", "maxmcode=65536", "hotexit=200")
    end
    if cfg.jitopt then
        local flags = {}
        for f in tostring(cfg.jitopt):gmatch("[^;]+") do flags[#flags + 1] = f end
        if #flags > 0 then jit.opt.start(unpack(flags)) end
    end
    if cfg.gcpause then collectgarbage("setpause", cfg.gcpause) end
    if cfg.gcstepmul then collectgarbage("setstepmul", cfg.gcstepmul) end
    print(string.format("[olife_world] jit mode=%s opt=%s status=%s gc=%s gcpause=%s gcstepmul=%s prof=%s jitlog=%s",
        mode, tostring(cfg.jitopt), tostring(jit.status()), cfg.gc, tostring(cfg.gcpause), tostring(cfg.gcstepmul),
        tostring(cfg.prof), tostring(cfg.jitlog)))
end
print("[olife_world] engine " .. table.concat({app.get_version()}, ".") .. " headless=" .. tostring(vc.is_headless()))

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
ensure_packs({"base", "olife_world"})   -- olife_proto comes as a dependency
pcall(app.set_setting, "chunks.load-distance", cfg.view + 3)
-- UX round 1 (02.10): items removed from the Olife packs (the test coin, «нахуя монетки»). A world that has seen
-- them lists them in indices.json and 0.32 refuses to open it (headless: "missing content" -> abort). The removed
-- entries are the LAST items of the index (olife_proto loads after base), so dropping them shifts no other id;
-- the original file is kept once as indices.json.ux1.bak. Inventories are kept by item NAME in the registry
-- (unknown names are skipped), engine inventories of the world players are emptied on every attach.
local REMOVED_ITEMS = {"olife_proto:coin"}
local function migrate_indices(wname)
    local path = "user:worlds/" .. wname .. "/indices.json"
    if not file.exists(path) then return end
    local src = file.read(path)
    local okp, d = pcall(json.parse, src)
    if not okp or type(d) ~= "table" or type(d.items) ~= "table" then return end
    local text, removed = src, {}
    for _ = 1, #REMOVED_ITEMS do
        local last = d.items[#d.items]
        local hit = false
        for _, n in ipairs(REMOVED_ITEMS) do if n == last then hit = true end end
        if not hit then break end
        -- textual edit (no re-serialisation: empty objects like "blocks-data": {} must stay objects):
        -- ',<ws>"<name>"<ws>]' -> '<ws>]' — only as the last element of an array
        local pat = ',%s*"' .. last:gsub("%p", "%%%0") .. '"(%s*%])'
        local t2, n = text:gsub(pat, "%1", 1)
        if n ~= 1 then break end
        text = t2
        table.remove(d.items)
        removed[#removed + 1] = last
    end
    for _, n in ipairs(d.items) do
        for _, r in ipairs(REMOVED_ITEMS) do
            if n == r then print("[olife_world] indices: removed item " .. n .. " is not last in " .. path .. ", left as is") end
        end
    end
    if #removed == 0 then return end
    local okc, d2 = pcall(json.parse, text)
    if not okc or type(d2) ~= "table" or #d2.items ~= #d.items then
        print("[olife_world] indices: edit check failed, " .. path .. " left as is")
        return
    end
    if not file.exists(path .. ".ux1.bak") then file.write(path .. ".ux1.bak", src) end
    file.write(path, text)
    print("[olife_world] indices: dropped removed items " .. table.concat(removed, ",") .. " from " .. path)
end

if world.exists(cfg.world) then
    migrate_indices(cfg.world)
    app.open_world(cfg.world)
    print("[olife_world] opened existing world " .. cfg.world)
else
    app.new_world(cfg.world, cfg.seed, cfg.generator)
end
assert(world.is_open())

local server = require "olife_world:server"
server.configure(cfg)
server.start()
app.sleep_until(server.spawn_ready, 2000, 60)

-- sockets, their callbacks and the admin commands are created by the first world tick (main Lua state), never in
-- this script's coroutine (see olife_world/modules/server.lua register_commands)
server.request_begin()
while not server.should_stop() do
    app.tick()
    server.app_tick()
    if server.take_save() then
        app.save_world()
        print("[olife_world] saved at tick " .. server.get_tick())
    end
end
server.finish()
app.close_world(true)
print("[olife_world] closed")
