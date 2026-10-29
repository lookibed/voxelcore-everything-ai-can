-- UX A3 cost probe (lab scenario olife_script_api): one API call every 10 ticks, nothing else — the world's
-- per-tick meter rows (export/sandbox_ticks.jsonl, api credits per owner) give the price of each call in order.
-- Queries take two ticks (asking tick: the price; answering tick: 0 API credits).
local CALLS = {
    function() self:set_scale(1.2) end,
    function() self:set_rot(0, 30, 0) end,
    function() self:set_visible(true) end,
    function() self:set_texture("*", "blocks:planks") end,
    function() self:set_model("olife_bench") end,
    function() self.skeleton:set_bone("body", {rot = {0, 10, 0}}) end,
    function() self.skeleton:set_bone_model("rody1", "olife_bone") end,
    function() self.skeleton:reset() end,
    function() self:play_anim("olife_spin", 1, true) end,
    function() self:stop_anim() end,
    function() self:play_sound("olife/ok", 0.5, 1) end,
    function() self:text3d("probe") end,
    function() local p = self.pos; block.set(math.floor(p[1]) + 2, math.floor(p[2]) + 3, math.floor(p[3]), "base:planks") end,
    function() local p = self.pos; local x, y, z = math.floor(p[1]), math.floor(p[2]) + 4, math.floor(p[3])
               block.fill_area(x, y, z, x + 3, y, z + 3, "base:planks") end,
    function() local p = self.pos; block.get(p[1], p[2], p[3]) end,
    function() local p = self.pos; block.get_area(p[1] - 3, p[2] - 3, p[3] - 3, p[1] + 4, p[2], p[3] + 4) end,
    function() block.raycast(self.pos, {0, -1, 0}, 16) end,
    function() local p = self.pos; block.is_replaceable(p[1], p[2], p[3]) end,
    function() block.find("base:stone", 4) end,
    function() self:nearby(8) end,
    function() self.skeleton:bones() end,
    function() memory.keys() end,                   -- memory.load (first access)
    function() memory.set("probe", 12345) end,
}
local NAMES = {"set_scale", "set_rot", "set_visible", "set_texture", "set_model", "skeleton:set_bone",
               "skeleton:set_bone_model", "skeleton:reset", "play_anim", "stop_anim", "play_sound", "text3d", "block.set",
               "block.fill_area 4x1x4", "block.get", "block.get_area 8x4x8", "block.raycast", "block.is_replaceable",
               "block.find r4", "nearby", "skeleton:bones", "memory (load)", "memory.set"}
local n = 0
function on_tick(dt)
    n = n + 1
    local k = n / 10
    if n % 10 == 0 and CALLS[k] then CALLS[k]() end
end
