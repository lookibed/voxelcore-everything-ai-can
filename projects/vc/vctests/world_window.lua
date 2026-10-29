-- world.lua (upstream dev/tests, release-0.32 @ dc62ccfb) adapted for a WINDOWED test (lab vctest --window, F2F 0.32).
-- Difference: in a window the menu has already loaded the project's base packs (ContentControl::resetContent ->
-- basePacks = ["base"]), so upstream `app.reconfig_packs({"base"}, {})` fails with "pack duplication [base]"
-- (PacksManager::assemble). Headless never resets content at start, so upstream world.lua is headless-only.
-- Here "base" is added only when it is not loaded yet; the rest is upstream.
local function has(list, id)
    for _, v in ipairs(list) do if v == id then return true end end
    return false
end
print("[vctest] content before: " .. table.concat(app.get_content(), ","))
if not has(app.get_content(), "base") then
    app.reconfig_packs({"base"}, {})
end
local t0 = time.uptime()
app.new_world("demo", "2019", "core:default")
assert(world.is_open())
assert(world.get_generator() == "core:default")
assert(app.is_content_loaded())
app.sleep(1)
assert(world.get_total_time() > 0.0)
print("[vctest] total_time " .. world.get_total_time() .. " uptime delta " .. (time.uptime() - t0))

app.close_world(true)
assert(not world.is_open())

app.open_world("demo")
assert(world.is_open())
assert(world.get_total_time() > 0.0)
assert(world.get_seed() == 2019)
app.tick()

app.close_world(true)
app.delete_world("demo")
print("[vctest] world_window done")
