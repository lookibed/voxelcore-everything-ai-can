-- model_ref stand, world script (main Lua state): the F2F command `ref` (protocol: ../stand.lua).
-- A handler made inside the app script's coroutine is bound to it: called while that coroutine waits, it
-- kills it ("cannot resume dead coroutine" on the next step) - hence here.
local E = {0.5, 120.5, 0.5}           -- entity position (high above the terrain, which is not drawn anyway)
local S = {ready = false, anims = {}, log = {}}

local function log(fmt, ...)
    local s = string.format(fmt, ...)
    S.log[#S.log + 1] = s
    print("[model_ref] " .. s)
end

local function bytes(path)
    return file.read_bytes("user:" .. path)
end

local function text(path)
    return file.read("user:" .. path)
end

local pid, cam

local function handler(cmd, a)
    if cmd ~= "ref" then error("unknown-command: " .. tostring(cmd)) end
    a = a or {}
    local op = a.op or "info"
    if op == "load" then
        assets.parse_model("vcm", text(a.vcm), "model_ref:model", "model_ref:skel")
        local texs = a.textures or (a.png and {a.png}) or {}      -- texs[i] -> "$<i-1>"
        for i, path in ipairs(texs) do assets.load_texture(bytes(path), "model_ref/tex" .. (i - 1), "png") end
        for name, path in pairs(a.anims or {}) do
            assets.parse_animation("vca", text(path), "model_ref:" .. name)
            S.anims[name] = "model_ref:" .. name
        end
        if S.ent then pcall(S.ent.despawn, S.ent) end
        S.ent = entities.spawn("refview:dummy", E)
        S.ent:set_skeleton("model_ref:skel")
        local rig = S.ent.skeleton
        for i = 1, #texs do rig:set_texture("$" .. (i - 1), "model_ref/tex" .. (i - 1)) end
        rig:reset_pose()
        S.ready = true
        local bones = {}
        local okb, list = pcall(function() return rig:bones() end)
        local na = 0
        for _ in pairs(a.anims or {}) do na = na + 1 end
        log("loaded %s, textures %d, anims %d", a.vcm, #texs, na)
        return {uid = S.ent:get_uid(), bones = okb and list or nil, pos = E}
    elseif op == "cam" then
        local p, t = a.pos, a.target
        cam:set_pos({E[1] + p[1], E[2] + p[2], E[3] + p[3]})
        cam:look_at({E[1] + t[1], E[2] + t[2], E[3] + t[3]})
        if a.fov then cam:set_fov(a.fov) end
        cam:set_zoom(1)
        local pos = cam:get_pos()
        return {pos = {pos[1], pos[2], pos[3]}, fov = cam:get_fov(), front = cam:get_front()}
    elseif op == "pose" then
        local rig = S.ent.skeleton
        S.ent.transform:set_pos(E)                -- static body; put back anyway (no drift between frames)
        rig:reset_pose()
        if a.anim then
            local tr = animation.get_track(S.anims[a.anim] or a.anim)
            if not tr then error("no track " .. tostring(a.anim)) end
            tr.func(rig, a.t or 0)
        end
        return {anim = a.anim, t = a.t}
    else
        local ent = {}
        if S.ent then
            local uid = S.ent:get_uid()
            ent.uid, ent.exists = uid, entities.exists(uid)
            if ent.exists then
                local p = S.ent.transform:get_pos()
                ent.pos = {p[1], p[2], p[3]}
            end
        end
        return {ready = S.ready, anims = S.anims, log = S.log, ent = ent}
    end
end

function on_world_open()
    pcall(world.set_day_time, 0.5)           -- fullbright anyway (F2F render lighting off)
    pcall(world.set_day_time_speed, 0)
    pid = 0
    player.set_flight(pid, true)
    player.set_noclip(pid, true)
    player.set_pos(pid, E[1], E[2] + 6, E[3] + 6)
    cam = cameras.get("refview:view")
    player.set_camera(pid, cam:get_index())
    pcall(function()                               -- the player's own body must not get into the frame
        local pe = entities.get(player.get_entity(pid))
        if pe then pe.skeleton:set_visible(false) end
    end)

    if f2f ~= nil and f2f.set_handler then f2f.set_handler(handler) end
    log("stand ready")
end
