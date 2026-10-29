-- UX A3 test (lab scenario olife_script_api): every call of the mob script API once, results into the mob's memory
-- (the lab reads them with `mob_api <eid>`); rejections recorded from the "rejected" events.
local n, var, sounds = 0, 0, 0
local function rec(k, v) memory.set(k, v) end

memory.set("loads", (memory.get("loads") or 0) + 1)      -- how many times this chunk ran (fresh load vs kept state)

-- queries (each waits one tick for the world's answer)
local p = self.pos
local hit = block.raycast({p[1], p[2], p[3]}, {0, -1, 0}, 24)
rec("q_ray", hit and (hit.id .. "@" .. hit.pos[2]) or "miss")
local gx, gy, gz = math.floor(p[1]), hit and hit.pos[2] or math.floor(p[2]) - 2, math.floor(p[3])
local id, st = block.get(gx, gy, gz)
rec("q_get", tostring(id) .. "/" .. tostring(st))
rec("q_get_same", hit ~= nil and id == hit.id)
local area = block.get_area(gx - 1, gy, gz - 1, gx + 1, gy, gz + 1)
rec("q_area", area and (area.size[1] .. "x" .. area.size[2] .. "x" .. area.size[3] .. ":" .. tostring(area.get(gx, gy, gz))) or "nil")
rec("q_repl_above", block.is_replaceable(gx, gy + 3, gz))
local found = block.find(id or "base:stone", 4)
rec("q_find", found and #found or -1)
local near = self:nearby(16)
local players = 0
for _, e in ipairs(near or {}) do if e.kind == 1 then players = players + 1 end end
rec("q_near", (near and #near or -1) .. "/" .. players)
rec("q_bones", table.concat(self.skeleton:bones() or {}, ","))
local v, err = block.get(gx + 100, gy, gz)
rec("q_far", tostring(v) .. "/" .. tostring(err))

-- block writes: one block with state, a 3x1x3 fill above the ground (event fill_done -> read back)
local fy = gy + 2
block.set(gx + 2, gy + 1, gz, "base:planks", 0)
block.fill_area(gx - 1, fy, gz - 1, gx + 1, fy, gz + 1, "base:stone")
on("fill_done", function(ev)
    local a = block.get_area(gx - 1, fy, gz - 1, gx + 1, fy, gz + 1)
    local c = 0
    for x = gx - 1, gx + 1 do for z = gz - 1, gz + 1 do if a and a.get(x, fy, z) == "base:stone" then c = c + 1 end end end
    rec("fill", ev.placed .. "/" .. ev.skipped .. "/" .. c)
    rec("q_set_one", (block.get(gx + 2, gy + 1, gz)))
end)
on("rejected", function(ev) rec("rej_" .. tostring(ev.op), tostring(ev.reason)) end)

function on_tick(dt)
    n = n + 1
    if n == 20 then
        self:set_scale({1.5, 2, 1.5})
        self:set_rot({yaw = 45})
        self:set_texture("*", "blocks:stone")
        self.skeleton:set_bone("body", {pos = {0, 0.25, 0}, rot = {0, 0, 30}, scale = 1.2})
        self.skeleton:set_bone_model("rody1", "olife_bone")
        self:text3d("A3 api", "#ffcc00")
        self:play_anim("olife_wave", 1.5, true)
        rec("acted", n)
    elseif n == 30 then                             -- refusals by the world (rejected events)
        self:set_scale(10)
        self:set_texture("$0", "nope:texture")
        self:play_sound("nope/sound", 1, 1)
        self.skeleton:set_bone("nobone", {rot = {0, 1, 0}})
        self:text3d("bad\1text")
        memory.set("big", string.rep("x", 5000))
    end
    if n >= 40 and n % 40 == 0 then
        self:play_sound("olife/ok", 0.8, 1.0)
        sounds = sounds + 1
        rec("sounds", sounds)
    end
    if n % 100 == 0 then self:set_visible((n / 100) % 2 == 0) end   -- hidden 100..199, shown 200..299, ...
    if n % 20 == 0 then
        var = var + 1                                -- a Lua variable: kept across restarts only by the VM state
        rec("var", var)
        rec("count", (memory.get("count") or 0) + 1) -- memory: kept by the world's store
    end
end
