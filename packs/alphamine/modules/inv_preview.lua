-- GuiInventory player preview (phase 3, agent U): GuiInventory.drawGuiContainerBackgroundLayer renders the local
-- player (ModelBiped + the held item, RenderPlayer.renderSpecials) under GL lighting into the GUI. XML documents have
-- no 3D, so the model is rasterised here in Lua, like OpenGL 1.x would: the same matrices (glTranslatef/Scalef/Rotatef
-- chain of GuiInventory, RenderLiving.doRenderLiving, ModelRenderer.render), ortho GUI projection (glOrtho(0, w, h, 0)
-- stretched over the frame), per-face fixed-function lighting (RenderHelper standard item lighting: ambient 0.4 +
-- 0.6 * max(0, n.L) per light, GL_FLAT, normals as Tessellator.setNormal bytes), GL_MODULATE with the texel, nearest
-- texels, alpha test (> 0.1), depth test LEQUAL, pixel centres. The result is a Canvas texture (am_inv_preview)
-- placed 1:1 over the frame pixels by an <image>; transparent where nothing was drawn.
-- Java quirk kept: the mouse position the model looks at is the one of the PREVIOUS drawScreen (xSize_lo/ySize_lo are
-- stored after super.drawScreen), 0,0 in the first frame after opening.
local J = require "alphamine:jmath"
local T = require "alphamine:ui_tables"
local mat = require "alphamine:mat"
local fpv = require "alphamine:fpview"
local inv = require "alphamine:inventory"
local items = require "alphamine:items_table"

local fround, F = J.fround, J.F
local floor, sqrt, max, min, atan = math.floor, math.sqrt, math.max, math.min, math.atan

local M = {lo_x = 0, lo_y = 0, canvas = nil, cw = 0, ch = 0, stats = {renders = 0, ms = 0}}

-- the canvas covers GUI x [left + GX0, + GW], y [top + GY0, + GH] (the model with its held item stays inside)
local GX0, GY0, GW, GH = 14, 0, 74, 90
local TEX = "am_inv_preview"

local function log(m) debug.log("[alphamine_preview] " .. m) end

-- ------------------------------------------------------------------ textures
local sources = {}
local function source(name)
    local s = sources[name]
    if s == nil then
        local ok, c = pcall(function()
            return Canvas.decode(file.read_bytes("alphamine:textures/gui/" .. name .. ".png"), "png")
        end)
        if ok and c then
            s = {w = c.width, h = c.height, data = c:get_data()}
        else
            log("cannot read " .. name .. ": " .. tostring(c))
            s = false
        end
        sources[name] = s
    end
    return s or nil
end

-- ------------------------------------------------------------------ state
function M.reset()
    M.lo_x, M.lo_y = 0, 0     -- GuiInventory.xSize_lo / ySize_lo (float fields, 0 when the screen is created)
end

-- the model's pose inputs: mouse of the previous frame, ticks, swing, limbs, held item
function M.key(mx, my, left, top)
    local st = inv.current_item and inv.current_item() or nil
    return ("pv:%g,%g,%d,%g,%g,%g,%s"):format(M.lo_x, M.lo_y, fpv.ticks or 0, fpv.swing or 0, fpv.limb_yaw or 0,
        fpv.limb_swing or 0, st and st.id or 0)
end

-- after the frame's drawScreen (inventory_gui.update): drawScreen stores the mouse for the next frame
function M.end_frame(mx, my)
    M.lo_x, M.lo_y = mx, my
end

-- ------------------------------------------------------------------ geometry
-- RenderBlocks face quads of a box (bounds in blocks, tile per side): {normal index, 4 x {x, y, z, u, v}}
local function face_quads(b, tiles)
    local x0, y0, z0, x1, y1, z1 = b[1], b[2], b[3], b[4], b[5], b[6]
    local out = {}
    local function base(t) return (t % 16) * 16, floor(t / 16) * 16 end
    local tx, ty = base(tiles[1])
    local u0, u1 = (tx + x0 * 16) / 256, (tx + x1 * 16 - 0.01) / 256
    local v0, v1 = (ty + z0 * 16) / 256, (ty + z1 * 16 - 0.01) / 256
    out[1] = {1, {{x0, y0, z1, u0, v1}, {x0, y0, z0, u0, v0}, {x1, y0, z0, u1, v0}, {x1, y0, z1, u1, v1}}}
    tx, ty = base(tiles[2])
    u0, u1 = (tx + x0 * 16) / 256, (tx + x1 * 16 - 0.01) / 256
    v0, v1 = (ty + z0 * 16) / 256, (ty + z1 * 16 - 0.01) / 256
    out[2] = {2, {{x1, y1, z1, u1, v1}, {x1, y1, z0, u1, v0}, {x0, y1, z0, u0, v0}, {x0, y1, z1, u0, v1}}}
    tx, ty = base(tiles[3])
    u0, u1 = (tx + x0 * 16) / 256, (tx + x1 * 16 - 0.01) / 256
    v0, v1 = (ty + y0 * 16) / 256, (ty + y1 * 16 - 0.01) / 256
    out[3] = {3, {{x0, y1, z0, u1, v0}, {x1, y1, z0, u0, v0}, {x1, y0, z0, u0, v1}, {x0, y0, z0, u1, v1}}}
    tx, ty = base(tiles[4])
    u0, u1 = (tx + x0 * 16) / 256, (tx + x1 * 16 - 0.01) / 256
    v0, v1 = (ty + y0 * 16) / 256, (ty + y1 * 16 - 0.01) / 256
    out[4] = {4, {{x0, y1, z1, u0, v0}, {x0, y0, z1, u0, v1}, {x1, y0, z1, u1, v1}, {x1, y1, z1, u1, v0}}}
    tx, ty = base(tiles[5])
    u0, u1 = (tx + z0 * 16) / 256, (tx + z1 * 16 - 0.01) / 256
    v0, v1 = (ty + y0 * 16) / 256, (ty + y1 * 16 - 0.01) / 256
    out[5] = {5, {{x0, y1, z1, u1, v0}, {x0, y1, z0, u0, v0}, {x0, y0, z0, u0, v1}, {x0, y0, z1, u1, v1}}}
    tx, ty = base(tiles[6])
    u0, u1 = (tx + z0 * 16) / 256, (tx + z1 * 16 - 0.01) / 256
    v0, v1 = (ty + y0 * 16) / 256, (ty + y1 * 16 - 0.01) / 256
    out[6] = {6, {{x1, y0, z1, u0, v1}, {x1, y0, z0, u1, v1}, {x1, y1, z0, u1, v0}, {x1, y1, z1, u0, v0}}}
    return out
end

-- ItemRenderer.renderItem, flat branch (object space after its own transforms): quads {normal key, 4 x {x,y,z,u,v}}
local function flat_item_quads(icon)
    local u1 = fround((icon % 16 * 16 + 0) / F[256.0])
    local u0 = fround((icon % 16 * 16 + 16) / F[256.0])
    local v0 = fround((floor(icon / 16) * 16 + 0) / F[256.0])
    local v1 = fround((floor(icon / 16) * 16 + 16) / F[256.0])
    -- Java names: var3 = u1 (left), var4 = u0 (right), var5 = v0 (top), var6 = v1 (bottom)
    local var3, var4, var5, var6 = u1, u0, v0, v1
    local d = F[1.0 / 16.0]
    local q = {}
    q[#q + 1] = {"f", {{0, 0, 0, var4, var6}, {1, 0, 0, var3, var6}, {1, 1, 0, var3, var5}, {0, 1, 0, var4, var5}}}
    q[#q + 1] = {"b", {{0, 1, -d, var4, var5}, {1, 1, -d, var3, var5}, {1, 0, -d, var3, var6}, {0, 0, -d, var4, var6}}}
    local e = F[0.001953125]
    for k = 0, 15 do
        local t = fround(k / F[16.0])
        local u = fround(fround(var4 + fround(fround(var3 - var4) * t)) - e)
        local x = t
        q[#q + 1] = {"l", {{x, 0, -d, u, var6}, {x, 0, 0, u, var6}, {x, 1, 0, u, var5}, {x, 1, -d, u, var5}}}
    end
    for k = 0, 15 do
        local t = fround(k / F[16.0])
        local u = fround(fround(var4 + fround(fround(var3 - var4) * t)) - e)
        local x = fround(t + d)
        q[#q + 1] = {"r", {{x, 1, -d, u, var5}, {x, 1, 0, u, var5}, {x, 0, 0, u, var6}, {x, 0, -d, u, var6}}}
    end
    for k = 0, 15 do
        local t = fround(k / F[16.0])
        local v = fround(fround(var6 + fround(fround(var5 - var6) * t)) - e)
        local y = fround(t + d)
        q[#q + 1] = {"u", {{0, y, 0, var4, v}, {1, y, 0, var3, v}, {1, y, -d, var3, v}, {0, y, -d, var4, v}}}
    end
    for k = 0, 15 do
        local t = fround(k / F[16.0])
        local v = fround(fround(var6 + fround(fround(var5 - var6) * t)) - e)
        local y = t
        q[#q + 1] = {"d", {{1, y, 0, var3, v}, {0, y, 0, var4, v}, {0, y, -d, var4, v}, {1, y, -d, var3, v}}}
    end
    return q
end

-- ------------------------------------------------------------------ rasteriser
local cw, ch, color, depth = 0, 0, {}, {}
local kx, ky, ox, oy = 2, 2, 0, 0      -- GUI unit -> frame pixel; canvas origin in frame pixels
local L0e, L1e = {0, 1, 0}, {0, 1, 0}
local depth_sign = 1                   -- 1: larger eye z wins (the player model); -1: smaller (3D item icons, as
                                       -- tools/alphamine/gen_ui_assets.py raster_icon, verified 100 %)
local fixed_lit = nil                  -- per-face light factor given by the caller (icons)

local function xf(m, x, y, z)
    return m[1] * x + m[5] * y + m[9] * z + m[13], m[2] * x + m[6] * y + m[10] * z + m[14],
        m[3] * x + m[7] * y + m[11] * z + m[15]
end

local function light(m, n)
    -- normal * (modelview 3x3); similarity transforms: the inverse transpose is m / s^2, GL_RESCALE_NORMAL * s
    local a, b, c = m[1] * n[1] + m[5] * n[2] + m[9] * n[3], m[2] * n[1] + m[6] * n[2] + m[10] * n[3],
        m[3] * n[1] + m[7] * n[2] + m[11] * n[3]
    local s = sqrt(m[1] * m[1] + m[2] * m[2] + m[3] * m[3])
    a, b, c = a / s, b / s, c / s
    local d0 = a * L0e[1] + b * L0e[2] + c * L0e[3]
    local d1 = a * L1e[1] + b * L1e[2] + c * L1e[3]
    local v = 0.4 + 0.6 * max(0, d0) + 0.6 * max(0, d1)
    if v > 1 then v = 1 end
    return v
end

local function edge(ax, ay, bx, by, px, py)
    return (bx - ax) * (py - ay) - (by - ay) * (px - ax)
end

local dbg_faces, dbg_pix, cur_face = nil, nil, 0
local function tri(a, b, c, src, lit)
    local area = edge(a[1], a[2], b[1], b[2], c[1], c[2])
    if area > -1e-12 and area < 1e-12 then return end
    local x0 = max(0, floor(min(a[1], b[1], c[1])) - 1)
    local x1 = min(cw - 1, floor(max(a[1], b[1], c[1])) + 1)
    local y0 = max(0, floor(min(a[2], b[2], c[2])) - 1)
    local y1 = min(ch - 1, floor(max(a[2], b[2], c[2])) + 1)
    local sw, sh, data = src.w, src.h, src.data
    for py = y0, y1 do
        local sy = py + 0.5
        for px = x0, x1 do
            local sx = px + 0.5
            local w0 = edge(b[1], b[2], c[1], c[2], sx, sy) / area
            local w1 = edge(c[1], c[2], a[1], a[2], sx, sy) / area
            local w2 = 1 - w0 - w1
            if w0 >= -1e-9 and w1 >= -1e-9 and w2 >= -1e-9 then
                local z = w0 * a[3] + w1 * b[3] + w2 * c[3]
                local i = py * cw + px
                local zb = depth[i]
                if zb == nil or depth_sign * z >= depth_sign * zb - 1e-7 then
                    local u = w0 * a[4] + w1 * b[4] + w2 * c[4]
                    local v = w0 * a[5] + w1 * b[5] + w2 * c[5]
                    local tx = floor(u * sw)
                    local ty = floor(v * sh)
                    if tx < 0 then tx = 0 elseif tx >= sw then tx = sw - 1 end
                    if ty < 0 then ty = 0 elseif ty >= sh then ty = sh - 1 end
                    local p = ((sh - 1 - ty) * sw + tx) * 4   -- decoded canvases are bottom-up
                    local al = data[p + 4]
                    if al > 25 then
                        depth[i] = z
                        local o = i * 4
                        color[o + 1] = floor(data[p + 1] * lit + 0.5)
                        color[o + 2] = floor(data[p + 2] * lit + 0.5)
                        color[o + 3] = floor(data[p + 3] * lit + 0.5)
                        color[o + 4] = 255
                        if dbg_pix then dbg_pix[i] = {cur_face, data[p + 1], data[p + 2], data[p + 3]} end
                    end
                end
            end
        end
    end
end

-- quad in object space of `m`: 4 x {x, y, z, u, v}; n = GL normal (object space)
local function quad(m, verts, n, src)
    local lit = fixed_lit or light(m, n)
    if dbg_faces then
        cur_face = #dbg_faces + 1
        local a, b, c = m[1] * n[1] + m[5] * n[2] + m[9] * n[3], m[2] * n[1] + m[6] * n[2] + m[10] * n[3],
            m[3] * n[1] + m[7] * n[2] + m[11] * n[3]
        local s = sqrt(m[1] * m[1] + m[2] * m[2] + m[3] * m[3])
        dbg_faces[cur_face] = {n = {n[1], n[2], n[3]}, e = {a / s, b / s, c / s}, lit = lit}
    end
    local p = {}
    for k = 1, 4 do
        local v = verts[k]
        local gx, gy, gz = xf(m, v[1], v[2], v[3])
        p[k] = {gx * kx - ox, gy * ky - oy, gz, v[4], v[5]}
    end
    tri(p[1], p[2], p[3], src, lit)
    tri(p[1], p[3], p[4], src, lit)
end

-- ------------------------------------------------------------------ the model
local function render_item(m, st)
    local b3 = T.preview.blocks[st.id]
    if st.id < 256 and b3 then
        -- RenderBlocks.renderBlockOnInventory (render types 0, 10, 13)
        local src = source("am_terrain")
        if not src then return end
        m = mat.translate(m, -0.5, -0.5, -0.5)
        for _, bounds in ipairs(b3.parts) do
            for _, fq in ipairs(face_quads(bounds, b3.tiles)) do
                local verts = fq[2]
                if b3.rt == 13 and (fq[1] >= 3) then
                    local nn = ({[3] = {0, 0, -1}, [4] = {0, 0, 1}, [5] = {-1, 0, 0}, [6] = {1, 0, 0}})[fq[1]]
                    local d = 1 / 16
                    local vv = {}
                    for k = 1, 4 do
                        local v = verts[k]
                        vv[k] = {v[1] - nn[1] * d, v[2], v[3] - nn[3] * d, v[4], v[5]}
                    end
                    verts = vv
                end
                quad(m, verts, T.preview.block_normals[fq[1]], src)
            end
        end
        return
    end
    local it = T.icons[st.id]
    if not it then return end
    local icon = it.index or 0
    local src = source(st.id < 256 and "am_terrain" or "am_items")
    if not src then return end
    m = mat.translate(m, 0, F[-0.3], 0)
    m = mat.scale(m, 1.5, 1.5, 1.5)
    m = mat.rotate(m, 50, 0, 1, 0)
    m = mat.rotate(m, 335, 0, 0, 1)
    m = mat.translate(m, -(15 / 16), -(1 / 16), 0)
    for _, q in ipairs(flat_item_quads(icon)) do
        quad(m, q[2], T.preview.item_normals[q[1]], src)
    end
end

local function render(left, top)
    local ents = require "alphamine:entities"
    local src = source("am_char")
    if not src then return false end
    -- GuiInventory: mouse of the previous frame
    local v9 = fround(fround(left + 51) - M.lo_x)
    local v10 = fround(fround(top + 75 - 50) - M.lo_y)
    local a9 = fround(atan(fround(v9 / F[40.0])))
    local a10 = fround(atan(fround(v10 / F[40.0])))
    local body = fround(a9 * F[20.0])
    local yaw = fround(a9 * F[40.0])
    local pitch = -fround(a10 * F[20.0])
    -- light directions (glLight under T * S(-30, 30, 30) * Rz(180) * Ry(135)), eye space, normalized
    local lm = mat.scale(mat.idt(), -30, 30, 30)
    lm = mat.rotate(lm, 180, 0, 0, 1)
    lm = mat.rotate(lm, 135, 0, 1, 0)
    local function ldir(x, y, z)
        local l = sqrt(x * x + y * y + z * z)
        x, y, z = x / l, y / l, z / l
        local a, b, c = lm[1] * x + lm[5] * y + lm[9] * z, lm[2] * x + lm[6] * y + lm[10] * z,
            lm[3] * x + lm[7] * y + lm[11] * z
        local n = sqrt(a * a + b * b + c * c)
        return {a / n, b / n, c / n}
    end
    L0e = ldir(F[0.2], 1.0, F[-0.7])
    L1e = ldir(F[-0.2], 1.0, F[0.7])
    -- modelview (GUI units, y down; the translate z 50 and the GUI's -2000 only order depths)
    local m = mat.translate(mat.idt(), left + 51, top + 75, 50)
    m = mat.scale(m, -30, 30, 30)
    m = mat.rotate(m, 180, 0, 0, 1)
    m = mat.rotate(m, -fround(a10 * F[20.0]), 1, 0, 0)
    m = mat.translate(m, 0, F[1.62], 0)
    -- RenderPlayer.renderPlayer -> doRenderLiving(x, y - yOffset, z), partialTicks 1.0
    m = mat.translate(m, 0, fround(0 - F[1.62]), 0)
    m = mat.rotate(m, fround(F[180.0] - body), 0, 1, 0)
    m = mat.scale(m, -1, -1, 1)
    m = mat.scale(m, F[15.0 / 16.0], F[15.0 / 16.0], F[15.0 / 16.0])
    m = mat.translate(m, 0, fround(F[-24.0] * F[1.0 / 16.0] - F[0.0078125]), 0)
    local limb = fpv.limb_yaw or 0
    if limb > 1 then limb = 1 end
    local st = inv.current_item and inv.current_item() or nil
    local A = ents.biped_angles({}, fpv.limb_swing or 0, limb, fround((fpv.ticks or 0) + 1.0), fround(yaw - body), pitch,
        fpv.swing or 0, st ~= nil)
    local arm
    for _, part in ipairs(T.preview.biped) do
        local ang = A[part.name]
        local px, py, pz = part.point[1], part.point[2], part.point[3]
        if ang and ang[4] then px, py, pz = ang[4], ang[5], ang[6] end
        local pm = mat.translate(m, px / 16.0, py / 16.0, pz / 16.0)
        local r2d = fround(F[180.0] / J.PI_F)
        if ang then
            if ang[3] ~= 0 then pm = mat.rotate(pm, fround(ang[3] * r2d), 0, 0, 1) end
            if ang[2] ~= 0 then pm = mat.rotate(pm, fround(ang[2] * r2d), 0, 1, 0) end
            if ang[1] ~= 0 then pm = mat.rotate(pm, fround(ang[1] * r2d), 1, 0, 0) end
        end
        if part.name == "rarm" then arm = pm end
        for _, q in ipairs(part.quads) do
            local verts = {}
            for k = 0, 3 do
                verts[k + 1] = {q[k * 3 + 1], q[k * 3 + 2], q[k * 3 + 3], q[13 + k * 2], q[14 + k * 2]}
            end
            quad(pm, verts, {q[21], q[22], q[23]}, src)
        end
    end
    -- RenderPlayer.renderSpecials
    if st and arm then
        local im = mat.translate(arm, -(1 / 16), 7 / 16, 1 / 16)
        local b3 = st.id < 256 and T.preview.blocks[st.id]
        if b3 then
            im = mat.translate(im, 0, 3 / 16, -(5 / 16))
            local s = fround(F[0.5] * F[12.0 / 16.0])
            im = mat.rotate(im, 20, 1, 0, 0)
            im = mat.rotate(im, 45, 0, 1, 0)
            im = mat.scale(im, s, -s, s)
        elseif T.preview.full3d[st.id] then
            local s = F[10.0 / 16.0]
            im = mat.translate(im, 0, 3 / 16, 0)
            im = mat.scale(im, s, -s, s)
            im = mat.rotate(im, -100, 1, 0, 0)
            im = mat.rotate(im, 45, 0, 1, 0)
        else
            local s = F[6.0 / 16.0]
            im = mat.translate(im, 0.25, 3 / 16, -(3 / 16))
            im = mat.scale(im, s, s, s)
            im = mat.rotate(im, 60, 0, 0, 1)
            im = mat.rotate(im, -90, 1, 0, 0)
            im = mat.rotate(im, 20, 0, 0, 1)
        end
        render_item(im, st)
    end
    return true
end

-- ------------------------------------------------------------------ 3D item icons at any GUI scale
-- RenderItem.renderItemIntoGUI of a 3D block (render types 0/10/13) rasterised for its exact frame position: needed
-- when one GUI unit is not an integer number of pixels (1390x855: 3.00216 x 3) or during the hotbar pickup "pop"
-- (GuiIngame scales the icon); the integer-scale case uses the prerendered atlas (gen_ui_assets.py, same maths).
local ICON_SIDE_N = {{0, -1, 0}, {0, 1, 0}, {0, 0, -1}, {0, 0, 1}, {-1, 0, 0}, {1, 0, 0}}
local icon_lit = nil
local function icon_factors()
    if icon_lit then return icon_lit end
    local function nrm(v)
        local l = sqrt(v[1] * v[1] + v[2] * v[2] + v[3] * v[3])
        return {v[1] / l, v[2] / l, v[3] / l}
    end
    local r180 = mat.rotate(mat.idt(), 180, 1, 0, 0)
    local function d3(m, v)
        return {m[1] * v[1] + m[5] * v[2] + m[9] * v[3], m[2] * v[1] + m[6] * v[2] + m[10] * v[3],
                m[3] * v[1] + m[7] * v[2] + m[11] * v[3]}
    end
    local l0 = nrm(d3(r180, nrm({F[0.2], 1.0, F[-0.7]})))
    local l1 = nrm(d3(r180, nrm({F[-0.2], 1.0, F[0.7]})))
    local rot = mat.rotate(mat.rotate(mat.idt(), 210, 1, 0, 0), 45, 0, 1, 0)
    icon_lit = {}
    for side = 1, 6 do
        local e = nrm(d3(rot, ICON_SIDE_N[side]))
        local c = 0.4
        for _, l in ipairs({l0, l1}) do c = c + 0.6 * max(0, e[1] * l[1] + e[2] * l[2] + e[3] * l[3]) end
        if c > 1 then c = 1 end
        if math.abs(c - 0.505032) < 1e-4 then c = 0.50447 end   -- the measured +-X factor (gen_ui_assets.py)
        icon_lit[side] = c
    end
    return icon_lit
end

M.icons = {}      -- key -> {canvas, name, x, y, w, h}
M.icon_count = 0

-- buf += <image> of the icon of block item `id` at GUI (gx, gy); k = GUI unit in pixels; pop = animationsToGo -
-- partial (> 0: GuiIngame's scale about (gx + 8, gy + 12)). Returns false when `id` is not a 3D block item.
function M.icon_xml(buf, id, gx, gy, k_x, k_y, pop)
    local b3 = T.preview.blocks[id]
    if not b3 then return false end
    local src = source("am_terrain")
    if not src then return false end
    local m = mat.idt()
    if pop and pop > 0 then
        local kk = 1 + pop / 5
        m = mat.translate(m, gx + 8, gy + 12, 0)
        m = mat.scale(m, 1 / kk, (kk + 1) / 2, 1)
        m = mat.translate(m, -(gx + 8), -(gy + 12), 0)
    end
    m = mat.translate(m, gx - 2, gy + 3, 0)
    m = mat.scale(m, 10, 10, 10)
    m = mat.translate(m, 1, 0.5, 8)
    m = mat.rotate(m, 210, 1, 0, 0)
    m = mat.rotate(m, 45, 0, 1, 0)
    m = mat.translate(m, -0.5, -0.5, -0.5)
    local key = ("%d|%.6f|%.6f|%.6f|%.6f|%.4f"):format(id, gx * k_x, gy * k_y, k_x, k_y, pop or 0)
    local ic = M.icons[key]
    if not ic then
        -- pixel bounds of the unit cube
        local bx0, by0, bx1, by1 = 1e9, 1e9, -1e9, -1e9
        for c = 0, 7 do
            local x, y = xf(m, c % 2, floor(c / 2) % 2, floor(c / 4))
            x, y = x * k_x, y * k_y
            if x < bx0 then bx0 = x end
            if x > bx1 then bx1 = x end
            if y < by0 then by0 = y end
            if y > by1 then by1 = y end
        end
        kx, ky = k_x, k_y
        ox, oy = floor(bx0) - 1, floor(by0) - 1
        cw, ch = floor(bx1) - ox + 2, floor(by1) - oy + 2
        color, depth = {}, {}
        depth_sign = -1
        local lit = icon_factors()
        for _, bounds in ipairs(b3.parts) do
            for _, fq in ipairs(face_quads(bounds, b3.tiles)) do
                local verts = fq[2]
                if b3.rt == 13 and fq[1] >= 3 then
                    local nn = ICON_SIDE_N[fq[1]]
                    local vv = {}
                    for q = 1, 4 do
                        local v = verts[q]
                        vv[q] = {v[1] - nn[1] / 16, v[2], v[3] - nn[3] / 16, v[4], v[5]}
                    end
                    verts = vv
                end
                fixed_lit = lit[fq[1]]
                quad(m, verts, ICON_SIDE_N[fq[1]], src)
            end
        end
        fixed_lit, depth_sign = nil, 1
        local data = {}
        for j = 0, ch - 1 do
            local drow = ch - 1 - j
            for i = 0, cw - 1 do
                local s = (j * cw + i) * 4
                local d = (drow * cw + i) * 4
                if color[s + 4] then
                    data[d + 1], data[d + 2], data[d + 3], data[d + 4] = color[s + 1], color[s + 2], color[s + 3], 255
                else
                    data[d + 1], data[d + 2], data[d + 3], data[d + 4] = 0, 0, 0, 0
                end
            end
        end
        M.icon_count = M.icon_count + 1
        local name = "am_icon_rt" .. M.icon_count
        local cv = Canvas({cw, ch})
        cv:set_data(data)
        cv:create_texture(name)
        cv:update()
        ic = {canvas = cv, name = name, x = ox, y = oy, w = cw, h = ch}
        if not pop or pop <= 0 then M.icons[key] = ic end
    end
    buf[#buf + 1] = ('<image src="%s" pos="%d,%d" size="%d,%d" interactive="false"/>'):format(ic.name, ic.x, ic.y,
        ic.w, ic.h)
    return true
end

-- ------------------------------------------------------------------ XML
-- adds the preview <image> to buf (GUI (left, top), GUI scale sf, frame vw x vh; the Java GUI ortho spans the frame:
-- one GUI unit = vw / w_scaled pixels horizontally, vh / h_scaled vertically)
function M.xml(buf, left, top, mx, my, sf, vw, vh)
    local ui = require "alphamine:ui"
    local w, h = ui.scaled(vw, vh)
    kx, ky = vw / w, vh / h
    ox, oy = floor((left + GX0) * kx), floor((top + GY0) * ky)
    local ncw, nch = floor(GW * kx) + 2, floor(GH * ky) + 2
    if not M.canvas or M.cw ~= ncw or M.ch ~= nch then
        M.canvas = Canvas({ncw, nch})
        M.canvas:create_texture(TEX)
        M.cw, M.ch = ncw, nch
        M.out = {}
    end
    cw, ch = ncw, nch
    color, depth = {}, {}
    if M.debug then dbg_faces, dbg_pix = {}, {} else dbg_faces, dbg_pix = nil, nil end
    local c0 = os.clock()
    local ok = render(left, top)
    M.stats.renders = M.stats.renders + 1
    M.stats.ms = (os.clock() - c0) * 1e3
    if not ok then return end
    -- canvas rows bottom-up
    local out = M.out
    for j = 0, ch - 1 do
        local drow = ch - 1 - j
        for i = 0, cw - 1 do
            local s = (j * cw + i) * 4
            local d = (drow * cw + i) * 4
            if color[s + 4] then
                out[d + 1], out[d + 2], out[d + 3], out[d + 4] = color[s + 1], color[s + 2], color[s + 3], 255
            else
                out[d + 1], out[d + 2], out[d + 3], out[d + 4] = 0, 0, 0, 0
            end
        end
    end
    if M.debug then
        local px = {}
        for i, v in pairs(dbg_pix) do px[#px + 1] = {ox + i % cw, oy + math.floor(i / cw), v[1], v[2], v[3], v[4]} end
        M.debug_out = {faces = dbg_faces, pixels = px, L0 = L0e, L1 = L1e}
        M.debug = false
    end
    M.canvas:set_data(out)
    M.canvas:update()
    buf[#buf + 1] = ('<image src="%s" pos="%d,%d" size="%d,%d" interactive="false"/>'):format(TEX, ox, oy, cw, ch)
end

return M
