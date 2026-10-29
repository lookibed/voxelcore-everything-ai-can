-- olife_proto:mobassets — hand-written (NOT generated), UX A3 (03.10, olife_a3): what a mob script may reference by
-- name through the script API (self:play_sound / play_anim / set_texture / set_model / skeleton:set_bone_model).
-- Shared: the world validates against these lists, the client knows what it can apply. Anything else must be an
-- asset of the owner's store: "asset:<hex id>" (UX A4: content/olife_world/modules/store.lua, store.has(owner, id)).
-- Models and textures are the ones of olife_proto:looks (the owner's EntityLook choices) plus the lists below.
local LOOKS = require "olife_proto:looks"
local M = {}

-- sounds of olife_client (sounds/olife/*.ogg, preload.json) — names as audio.play_sound takes them
M.SOUNDS = {"olife/inject", "olife/grab", "olife/release", "olife/delete", "olife/refuse", "olife/ok"}
-- VCA tracks of olife_client (animation/<name>.vca, preload.json "animation"); all animate the bench skeleton bones
M.ANIMS = {"olife_wave", "olife_spin", "olife_bob", "olife_pulse"}
-- bones of the skeletons of scripted entities (skeleton def -> bone names, in the skeleton file's order)
M.BONES = {["olife_client:bench"] = {"body", "rody", "body1", "rody1", "body2", "rody2"}}
M.DEFAULT_BONES = M.BONES["olife_client:bench"]
-- texture slots of the bench model ($0..$5 = the six faces of olife_bench / block)
M.SLOTS = {["$0"] = true, ["$1"] = true, ["$2"] = true, ["$3"] = true, ["$4"] = true, ["$5"] = true, ["*"] = true}

local function set(l) local s = {} for _, v in ipairs(l) do s[v] = true end return s end
local SOUND, ANIM = set(M.SOUNDS), set(M.ANIMS)

-- "asset:<hex 8..64>" -> id, else nil
function M.asset_id(ref)
    if type(ref) ~= "string" then return nil end
    local id = ref:match("^asset:(%x+)$")
    if id and #id >= 8 and #id <= 64 then return id:lower() end
    return nil
end

function M.sound(name) return SOUND[name] == true end
function M.anim(name) return ANIM[name] == true end
function M.model(name) return LOOKS.model(name) ~= nil end
function M.texture(name) return LOOKS.texture(name) ~= nil end
function M.bones(def) return M.BONES[def] or M.DEFAULT_BONES end
function M.bone(def, name)
    for _, b in ipairs(M.bones(def)) do if b == name then return true end end
    return false
end

return M
