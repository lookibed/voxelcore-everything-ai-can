-- model_ref stand (vclab/model_ref, agent tool, 07.11.2026): F2F test build under --test. A world with ONE entity (refview:dummy, no
-- components) wearing a model loaded at run time exactly as a game client does (assets.parse_model with a skeleton,
-- assets.load_texture, assets.parse_animation), a fixed camera (refview:view). Driven by the F2F command `ref`:
--   {op="load", vcm, textures={path, ...} ($0, $1, ...), anims={name=path}}   paths relative to user: (lease dir)
--   {op="cam", pos={x,y,z}, target={x,y,z}, fov}  relative to the entity
--   {op="pose", anim=name|nil, t=seconds}        rest pose when anim is nil
--   {op="info"}
-- The tool turns every render layer off except entities (F2F `render`), fullbright, a flat clear colour.
-- options of the tool (model_ref.py writes user:ref/stand_opts.json): engine settings before the world opens;
-- default graphics.ssao = 0 (screen-space AO darkens corners and adds grain: not the model's export)
local okf, opts = pcall(function() return json.parse(file.read("user:ref/stand_opts.json")) end)
opts = okf and type(opts) == "table" and opts or {}
for k, v in pairs(opts.settings or {["graphics.ssao"] = 0}) do
    local ok, err = pcall(app.set_setting, k, v)
    print("[model_ref] setting " .. k .. " = " .. tostring(v) .. (ok and "" or (" failed: " .. tostring(err))))
end
app.config_packs({"base", "refview"})
app.new_world("model_ref", "1", "core:default")
while true do
    local ok, err = pcall(app.tick)
    if not ok then print("[model_ref] tick error: " .. tostring(err)) end
end
