-- olife_client:mobview — UX A3 (03.10, agent olife_a3): what a mob's script did to its look, on the replica.
-- The world sends (client.yaml «UX A3»): EntityAppearance (scale, visible, model, textures by slot, bone transforms /
-- bone models, one text line) — full state on change and when the entity enters the view; EntityAnim (a VCA track of
-- olife_client:animation/*.vca or "asset:<sha>", speed, loop, the animation time when it was sent); EntitySound (an
-- event: play now at pos). Applied every rendered frame through the 0.32 engine APIs: entity.transform:set_rot /
-- set_size, entity.skeleton:set_model / set_texture / set_matrix / set_visible, animation.get_track(name).func(rig, t)
-- (our own clock: speed and loop; animation.play has neither), audio.play_sound, gfx.text3d (attached to the entity).
-- Rotation of every scripted entity (kind 3) is applied too: Euler degrees from the snapshots, R = Ry(y)·Rx(x)·Rz(z).
-- "asset:<sha>" references resolve through olife_client:assets (UX A4): nil = not downloaded yet -> retried.
local LOOKS = require "olife_proto:looks"
local MA = require "olife_proto:mobassets"

local M = {}
local S = {app = {}, anim = {}, applied = {}, texts = {}, sounds = {}, rot_seen = {}, app_ref = {},
           stats = {app = 0, anim = 0, sound = 0, played = 0, play_failed = 0, applied = 0, asset_wait = 0,
                    anim_missing = 0, frames = 0}}
M.S = S
local cl_mod, ol_mod, as_mod
local function cl() cl_mod = cl_mod or require("olife_client:client"); return cl_mod end
local function ol() ol_mod = ol_mod or require("olife_client:olife"); return ol_mod end
local function as()
    if as_mod == nil then
        local ok, m = pcall(require, "olife_client:assets")
        as_mod = ok and m or false
    end
    return as_mod or nil
end

local function log(fmt, ...) print("[olife_client] mobview: " .. string.format(fmt, ...)) end

-- a texture / model / animation reference -> engine name (nil = asset not ready yet)
local function resolve(kind, ref)
    if type(ref) ~= "string" or ref == "" then return nil end
    if ref:sub(1, 6) ~= "asset:" then return ref end
    local A = as()
    if not A then return nil end
    local ok, name = pcall(A[kind], ref)
    if ok and name then return name end
    S.stats.asset_wait = S.stats.asset_wait + 1
    return nil
end

-- ------------------------------------------------------------------ messages
local H = {}
function H.EntityAppearance(m)
    S.stats.app = S.stats.app + 1
    S.app[m.eid] = m
    S.app_ref[m.eid] = nil
    S.applied[m.eid] = nil            -- re-apply on the next frame
end

function H.EntityAnim(m)
    S.stats.anim = S.stats.anim + 1
    if S.stats.anim <= 20 then log("anim eid=%d %s speed=%.2f loop=%s t=%.2f", m.eid, m.name, m.speed, tostring(m.loop), m.t) end
    S.anim[m.eid] = {name = m.name, speed = m.speed, loop = m.loop, t0 = m.t, at = time.uptime(), ver = m.ver,
                     playing = m.name ~= ""}
    S.applied[m.eid] = nil            -- the bones go back to the overrides when it stops
end

function H.EntitySound(m)
    S.stats.sound = S.stats.sound + 1
    local id
    if m.sound:sub(1, 6) == "asset:" then
        local A = as()
        if A and A.play then
            local ok, r = pcall(A.play, m.sound, m.pos.x, m.pos.y, m.pos.z, m.volume, m.pitch)
            id = ok and r or nil
        end
    elseif audio and audio.play_sound then
        local ok, r = pcall(audio.play_sound, m.sound, m.pos.x, m.pos.y, m.pos.z, m.volume, m.pitch, "regular")
        id = ok and r or nil
    end
    if id and id ~= 0 then S.stats.played = S.stats.played + 1 else S.stats.play_failed = S.stats.play_failed + 1 end
    local l = S.sounds
    l[#l + 1] = {eid = m.eid, sound = m.sound, volume = m.volume, pitch = m.pitch, tick = m.tick,
                 pos = {m.pos.x, m.pos.y, m.pos.z}, speaker = id or 0, t = time.uptime()}
    if #l > 64 then table.remove(l, 1) end
end

M.handled = {EntityAppearance = true, EntityAnim = true, EntitySound = true}
function M.on_msg(name, m)
    local h = H[name]
    if h then h(m) end
end

-- ------------------------------------------------------------------ apply
local function bone_matrix(b)
    local m = mat4.idt()
    m = mat4.translate(m, {b.pos.x, b.pos.y, b.pos.z})
    m = mat4.rotate(m, {0, 1, 0}, b.rot.y)
    m = mat4.rotate(m, {1, 0, 0}, b.rot.x)
    m = mat4.rotate(m, {0, 0, 1}, b.rot.z)
    m = mat4.scale(m, {b.scale.x, b.scale.y, b.scale.z})
    return m
end

local function rot_matrix(r)
    local m = mat4.rotate({0, 1, 0}, r.y)
    m = mat4.rotate(m, {1, 0, 0}, r.x)
    m = mat4.rotate(m, {0, 0, 1}, r.z)
    return m
end

local function color4(c)
    c = c or 0xFFFFFFFF
    local r = math.floor(c / 16777216) % 256
    local g = math.floor(c / 65536) % 256
    local b = math.floor(c / 256) % 256
    local a = c % 256
    return {r / 255, g / 255, b / 255, a / 255}
end

local function text3d() return gfx ~= nil and gfx.text3d ~= nil end

local function hide_text(eid)
    local t = S.texts[eid]
    if t then
        if text3d() then pcall(gfx.text3d.hide, t.id) end
        S.texts[eid] = nil
    end
end

local function apply_text(eid, e, ent, m)
    local t = S.texts[eid]
    local txt = m and m.text or ""
    if txt == "" or not text3d() then return hide_text(eid) end
    local sy = m.scale and m.scale.y or 1
    local rel = {0, 0.6 * sy + 0.45, 0}
    if t and t.uid ~= e.uid then hide_text(eid); t = nil end
    if not t then
        local p = e.shown or e.pos
        local ok, id = pcall(gfx.text3d.show, {p.x, p.y + rel[2], p.z}, txt,
            {display = "y_free_billboard", scale = 0.02, render_distance = 32, color = color4(m.color)})
        if not ok then return end
        t = {id = id, uid = e.uid, text = txt, color = m.color, attached = false}
        S.texts[eid] = t
        if gfx.text3d.set_entity then
            t.attached = pcall(gfx.text3d.set_entity, id, e.uid) and pcall(gfx.text3d.set_pos, id, rel)
        end
    else
        if t.text ~= txt then pcall(gfx.text3d.set_text, t.id, txt); t.text = txt end
        if t.color ~= m.color then pcall(gfx.text3d.update_settings, t.id, {color = color4(m.color)}); t.color = m.color end
        if t.attached then pcall(gfx.text3d.set_pos, t.id, rel) end
    end
    if not t.attached then
        local p = e.shown or e.pos
        pcall(gfx.text3d.set_pos, t.id, {p.x, p.y + rel[2], p.z})
    end
end

-- default look of a bench (what olife_client:bench and EntityLook give), then the script's overrides
local function apply_appearance(eid, e, ent, m)
    local rig = ent.skeleton
    if not rig then return false end
    local ready = true
    -- 1. back to the base look: the owner's EntityLook if any, else the bench defaults
    local O = ol()
    local lk = O.S.looks[eid]
    if lk then lk.applied = nil; pcall(O.apply_look, eid)
    else
        pcall(function()
            local idx = rig:index("rody")
            if idx then rig:set_model(idx, LOOKS.DEFAULT_MODEL) end
            for i = 0, 5 do rig:set_texture("$" .. i, LOOKS.DEFAULT_TEXTURE) end
        end)
    end
    for _, bn in ipairs(MA.bones(e.def)) do
        local idx = rig:index(bn)
        if idx then
            pcall(rig.set_matrix, rig, idx, mat4.idt())
            if bn ~= "rody" then pcall(rig.set_model, rig, idx) end
        end
    end
    pcall(rig.set_visible, rig, true)
    pcall(ent.transform.set_size, ent.transform, {1, 1, 1})
    if not m then return true end
    -- 2. the script's state
    pcall(ent.transform.set_size, ent.transform, {m.scale.x, m.scale.y, m.scale.z})
    pcall(rig.set_visible, rig, m.visible)
    if m.model ~= "" then
        local name = resolve("model", m.model)
        local idx = rig:index("rody")
        if name and idx then pcall(rig.set_model, rig, idx, name) elseif not name then ready = false end
    end
    for _, t in ipairs(m.textures) do
        local name = resolve("texture", t.texture)
        if name then
            if t.slot == "*" then for i = 0, 5 do pcall(rig.set_texture, rig, "$" .. i, name) end
            else pcall(rig.set_texture, rig, t.slot, name) end
        else
            ready = false
        end
    end
    for _, b in ipairs(m.bones) do
        local idx = rig:index(b.name)
        if idx then
            if b.flags % 2 == 1 then pcall(rig.set_matrix, rig, idx, bone_matrix(b)) end
            if b.model ~= "" then
                local name = resolve("model", b.model)
                if name then pcall(rig.set_model, rig, idx, name) else ready = false end
            end
        end
    end
    return ready
end

-- bones with a transform override of the script: re-applied after an animation frame (the script wins)
local function reapply_bones(rig, m)
    if not m then return end
    for _, b in ipairs(m.bones) do
        if b.flags % 2 == 1 then
            local idx = rig:index(b.name)
            if idx then pcall(rig.set_matrix, rig, idx, bone_matrix(b)) end
        end
    end
end

local function anim_frame(eid, e, ent, a)
    local name = resolve("animation", a.name)
    if not name then return end
    local track = animation and animation.get_track and animation.get_track(name)
    if not track then
        if not a.missing then a.missing = true; S.stats.anim_missing = S.stats.anim_missing + 1; log("no track %s", name) end
        return
    end
    local t = a.t0 + (time.uptime() - a.at) * a.speed
    -- 0.32: `@configure duration 1` reaches the track as the STRING "1" (vca.lua does not tonumber it)
    local dur = tonumber(track.duration) or math.huge
    if dur ~= math.huge and dur > 0 then
        if a.loop then t = t % dur
        elseif t > dur then
            a.playing, a.done = false, true
            S.applied[eid] = nil          -- back to the static pose
            return
        end
    end
    a.t = t
    local ok, err = pcall(track.func, ent.skeleton, t)
    if not ok and not a.err then a.err = tostring(err); log("track %s: %s", name, a.err) end
    reapply_bones(ent.skeleton, S.app[eid])
    a.frames = (a.frames or 0) + 1
end

-- every rendered frame (hud.lua after olife.frame): rotation of scripted entities, appearance, animation, text
function M.frame()
    if not entities then return end
    S.stats.frames = S.stats.frames + 1
    -- a new session (Welcome after a reconnect or a world restart, the gateway may keep our connection): the world
    -- sends the current appearance / animation again; what we had is not news (an animation the world forgot stops)
    local sess = cl().S.session
    if sess ~= S.session then
        if S.session ~= nil then
            for eid in pairs(S.texts) do hide_text(eid) end
            S.repose = {}                                    -- back to the base look once (bones of an old pose)
            for eid in pairs(S.app) do S.repose[eid] = true end
            for eid in pairs(S.anim) do S.repose[eid] = true end
            S.app, S.anim, S.applied, S.app_ref = {}, {}, {}, {}
            for eid in pairs(S.rot_seen) do S.rot_seen[eid] = nil end
            S.stats.resets = (S.stats.resets or 0) + 1
            log("new session %s (was %s): appearance/animation state dropped", tostring(sess), tostring(S.session))
        end
        S.session = sess
    end
    local ents = cl().S.ents
    for eid, e in pairs(ents) do
        if e.kind == 3 and e.uid then
            -- a new replica of the entity (reconnect, world restart): the state of the old one is not news any more
            -- (appearance comes again with the view, an animation only if the world still plays it)
            local a0, m0 = S.anim[eid], S.app[eid]
            -- (by the engine uid: a keyframe re-creates the replica table but keeps the uid; a reconnect does not)
            if a0 and a0.ref and a0.ref ~= e.uid then S.anim[eid] = nil elseif a0 then a0.ref = e.uid end
            if m0 and S.app_ref[eid] and S.app_ref[eid] ~= e.uid then S.app[eid], S.applied[eid] = nil, nil
            elseif m0 then S.app_ref[eid] = e.uid end
            local ent = entities.get(e.uid)
            if ent then
                local r = e.rot
                local rs = S.rot_seen[eid]
                if r and (not rs or rs.uid ~= e.uid or rs.x ~= r.x or rs.y ~= r.y or rs.z ~= r.z) then
                    if pcall(ent.transform.set_rot, ent.transform, rot_matrix(r)) then
                        S.rot_seen[eid] = {uid = e.uid, x = r.x, y = r.y, z = r.z}
                    end
                end
                local m = S.app[eid]
                local ap = S.applied[eid]
                local lk = ol().S.looks[eid]
                local look_uid = lk and lk.applied
                local rp = S.repose and S.repose[eid]
                if rp then S.repose[eid] = nil end
                if (m or S.anim[eid] or rp) and (rp or not ap or ap.uid ~= e.uid or ap.ver ~= (m and m.ver or 0)
                        or (lk and look_uid ~= ap.look)) then
                    local ready = apply_appearance(eid, e, ent, m)
                    lk = ol().S.looks[eid]
                    S.applied[eid] = ready and {uid = e.uid, ver = m and m.ver or 0, look = lk and lk.applied} or nil
                    S.stats.applied = S.stats.applied + 1
                end
                apply_text(eid, e, ent, m)
                local a = S.anim[eid]
                if a and a.playing then anim_frame(eid, e, ent, a) end
            end
        end
    end
    for eid in pairs(S.app) do
        if not ents[eid] then S.app[eid], S.applied[eid], S.app_ref[eid] = nil, nil, nil; hide_text(eid) end
    end
    for eid in pairs(S.anim) do if not ents[eid] then S.anim[eid] = nil end end
    for eid in pairs(S.rot_seen) do if not ents[eid] then S.rot_seen[eid] = nil end end
    for eid in pairs(S.texts) do if not ents[eid] then hide_text(eid) end end
end

-- ------------------------------------------------------------------ F2F `mobview` (tests): the replica's engine view
local function r4(v) return math.floor(v * 10000 + 0.5) / 10000 end
local function mat_list(m)
    local l = {}
    for i = 1, 16 do l[i] = r4(m[i] or 0) end
    return l
end

function M.f2f(args)
    local out = {}
    local ents = cl().S.ents
    for eid, e in pairs(ents) do
        if e.kind == 3 and (args.eid == nil or args.eid == eid) then
            local r = {eid = eid, uid = e.uid, rot = e.rot and {e.rot.x, e.rot.y, e.rot.z} or nil}
            local ent = e.uid and entities.get(e.uid)
            if ent then
                local ok, sz = pcall(ent.transform.get_size, ent.transform)
                if ok and sz then r.size = {r4(sz[1]), r4(sz[2]), r4(sz[3])} end
                local okr, rm = pcall(ent.transform.get_rot, ent.transform)
                if okr and rm then r.rot_matrix = mat_list(rm) end
                local rig = ent.skeleton
                if rig then
                    local sk = {bones = {}, textures = {}}
                    for i = 0, 5 do
                        local okt, t = pcall(rig.get_texture, rig, "$" .. i)
                        sk.textures[i + 1] = okt and t or nil
                    end
                    local okv, vis = pcall(rig.is_visible, rig)
                    if okv then sk.visible = vis end           -- (false must not become nil)
                    for _, bn in ipairs(MA.bones(e.def)) do
                        local idx = rig:index(bn)
                        if idx then
                            local okm, model = pcall(rig.get_model, rig, idx)
                            local okx, mx = pcall(rig.get_matrix, rig, idx)
                            sk.bones[bn] = {model = okm and model or nil, matrix = okx and mx and mat_list(mx) or nil}
                        end
                    end
                    r.skeleton = sk
                end
            end
            local m = S.app[eid]
            if m then
                r.app = {ver = m.ver, scale = {m.scale.x, m.scale.y, m.scale.z}, visible = m.visible, model = m.model,
                         text = m.text, color = m.color, ntex = #m.textures, nbones = #m.bones}
            end
            r.applied = S.applied[eid] and S.applied[eid].ver or nil
            local a = S.anim[eid]
            if a then r.anim = {name = a.name, speed = a.speed, loop = a.loop, playing = a.playing, t = a.t,
                                frames = a.frames or 0, done = a.done or false, err = a.err, ver = a.ver} end
            local t = S.texts[eid]
            if t then r.text3d = {text = t.text, attached = t.attached} end
            out[#out + 1] = r
        end
    end
    table.sort(out, function(a, b) return a.eid < b.eid end)
    local tracks = {}
    for _, n in ipairs(MA.ANIMS) do
        local tr = animation and animation.get_track and animation.get_track(n)
        tracks[n] = tr and (tonumber(tr.duration) or -1) or false
    end
    return {entities = out, sounds = S.sounds, stats = S.stats, tracks = tracks, session = S.session,
            client_session = cl().S.session}
end

function M.status()
    local s = S.stats
    return string.format("mobview(app=%d,anim=%d,sound=%d,played=%d,play_failed=%d,applied=%d,asset_wait=%d," ..
        "anim_missing=%d)", s.app, s.anim, s.sound, s.played, s.play_failed, s.applied, s.asset_wait, s.anim_missing)
end

return M
