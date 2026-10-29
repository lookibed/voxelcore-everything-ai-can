-- olife_proto:looks — hand-written (NOT generated), UX round 1 (02.10, olife_ux1): the models and textures an owner may
-- pick for a scripted entity on the «Настройки сущности» page (EntityEdit op 3). Shared: the world validates the choice
-- against these lists, the client offers them and applies EntityLook. Models live in olife_client/models (the user's
-- originals from the 0.30.6 prototype) or are engine models ("block"); `retex` = the model has the $0..$5 materials,
-- so the chosen texture is applied to all six; other models carry their own texture.
local M = {}

M.MODELS = {
    {id = "olife_bench", caption = "Bench (original)", retex = true},
    {id = "olife_bone", caption = "Bone (original)", retex = false},
    {id = "olife_gravitygun", caption = "Gravity gun (original)", retex = false},
    {id = "olife_injector", caption = "Injector (original)", retex = false},
    {id = "block", caption = "Block (engine)", retex = true},
}
M.TEXTURES = {
    {id = "entities/olife_bench", caption = "Bench (original)"},
    {id = "blocks:planks", caption = "Planks"},
    {id = "blocks:green_lamp", caption = "Green lamp"},
    {id = "blocks:red_lamp", caption = "Red lamp"},
    {id = "blocks:stone", caption = "Stone"},
    {id = "blocks:wood", caption = "Wood"},
    {id = "blocks:metal", caption = "Metal"},
}
M.DEFAULT_MODEL, M.DEFAULT_TEXTURE = "olife_bench", "entities/olife_bench"

local function find(list, id)
    for _, v in ipairs(list) do if v.id == id then return v end end
    return nil
end
function M.model(id) return find(M.MODELS, id) end
function M.texture(id) return find(M.TEXTURES, id) end

-- entity name (EntityEdit op 2): 1..32 bytes, no control characters, not only spaces
function M.valid_name(s)
    if type(s) ~= "string" or #s < 1 or #s > 32 then return false end
    if s:find("[%z\1-\31\127]") then return false end
    return s:find("%S") ~= nil
end

return M
