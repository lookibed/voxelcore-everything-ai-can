-- Lab smoke of the olife `client` kind on the F2F 0.32 build (kind client_smoke, stage 4a): connect-less start.
-- Loads the client packs (only those not loaded yet: in a WINDOW the menu has already loaded the project base packs,
-- so adding "base" again is "pack duplication [base]"), opens a local replica world, prints the ready marker and
-- ticks until olife.stop / F2F quit. No gateway, no network.
local function arg(name, default)
    local v = vc.get_project_arg(name)
    if v == nil or v == "" then return default end
    return v
end
local name = arg("name", "smoke")
local loaded = {}
for _, id in ipairs(app.get_content()) do loaded[id] = true end
local add = {}
for id in string.gmatch(arg("packs", "base"), "[^,]+") do
    if not loaded[id] then table.insert(add, id) end
end
print("[olife_client_smoke] content before: " .. table.concat(app.get_content(), ",") .. "; adding: " .. table.concat(add, ","))
if #add > 0 then app.reconfig_packs(add, {}) end
app.new_world("smoke_" .. name, "1", "core:default")
print("[olife_client_smoke] ready world=" .. tostring(world.is_open()) .. " headless=" .. tostring(vc.is_headless())
      .. " content=" .. table.concat(app.get_content(), ","))
local stop = false
console.add_command("olife.stop", "Stop the smoke client", function() stop = true return "[olife_client_smoke] stopping" end)
while not stop do app.tick() end
app.close_world(false)
