-- Проба API 0.32 для волны 4c (headless --test): свойства блоков (obstacle, hitbox), инвентарь игрока, предметы.
local function p(...) print("[probe4c]", ...) end
app.reconfig_packs({"base"}, {})
app.new_world("probe4c", "2026", "base:demo")
local pid = player.create("p1")
player.set_pos(pid, 8, 90, 8)
player.set_loading_chunks(pid, true)
for i = 1, 60 do app.tick() end
p("blocks", block.defs_count(), "items", item.defs_count())
for _, nm in ipairs({"core:air", "base:stone", "base:grass", "base:water", "base:grass_block", "base:torch", "base:pane", "base:wooden_door"}) do
    local ok, id = pcall(block.index, nm)
    if ok then
        local pr = block.properties[id]
        local okh, hb = pcall(block.get_hitbox, id, 0)
        p(nm, id, "obstacle", pr and tostring(pr.obstacle), "hitbox", okh and json.tostring(hb) or tostring(hb),
          "picking", block.get_picking_item(id), item.name(block.get_picking_item(id)), "rotprof", block.get_rotation_profile and block.get_rotation_profile(id))
    else p(nm, "missing") end
end
local inv, sel = player.get_inventory(pid)
p("inventory", inv, sel, "size", inventory.size(inv))
local stone = item.index("base:stone.item")
p("stone item", stone, "placing", item.placing_block(stone), block.name(item.placing_block(stone)), "stack", item.stack_size(stone))
p("add", inventory.add(inv, stone, 70))
p("slot0", inventory.get(inv, 0), "slot1", inventory.get(inv, 1))
inventory.set(inv, 5, stone, 3)
inventory.decrement(inv, 5, 1)
p("slot5 after decrement", inventory.get(inv, 5))
inventory.set(inv, 5, 0, 0)
p("slot5 cleared", inventory.get(inv, 5))
player.set_selected_slot(pid, 3)
p("selected", select(2, player.get_inventory(pid)))
p("vc.is_headless", vc.is_headless(), "input", type(input), "hud", type(hud))
-- surface
for y = 120, 1, -1 do
    local id = block.get(8, y, 8)
    if id > 0 then p("surface at", y, block.name(id)); break end
end
p("unloaded get", block.get(100000, 50, 100000))
local t0 = time.precise_utc_time()
local n = 0
for i = 1, 100000 do n = n + block.get(8 + i % 7, 60 + i % 5, 8) end
p("block.get x100k ms", (time.precise_utc_time() - t0) * 1000)
t0 = time.precise_utc_time()
local props = block.properties
for i = 1, 100000 do local x = props[1] end
p("props x100k ms", (time.precise_utc_time() - t0) * 1000)
p("rotation api", type(block.get_rotation))
app.close_world(false)
p("done")
