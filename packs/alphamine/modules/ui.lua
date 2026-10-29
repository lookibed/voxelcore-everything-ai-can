-- UI helpers of the Alpha client (phase 3): ScaledResolution and XML snippets for the engine documents.
-- Everything on screen is an engine XML element (<image>, <container>); positions are in Alpha GUI units
-- (ScaledResolution: 854x480 -> factor 2, 427x240 units) multiplied by the factor, so one GUI unit = sf pixels
-- and every textured rect maps texels 1:sf with NEAREST sampling (pixel-exact like Gui.drawTexturedModalRect).
local M = {}

-- ScaledResolution(displayWidth, displayHeight). Java draws the GUI with glOrtho(0, w/sf, h/sf, 0) over the whole
-- frame, so one GUI unit is kx = w / floor(w / sf) by ky = h / floor(h / sf) pixels -- exactly sf only when sf divides
-- the frame size (854x480 -> 2, 2; 1390x855 -> 3.00216, 3). M.kx / M.ky / M.sf are the values of the last call;
-- UINode::calcPos truncates element positions to integers (glm::ivec2), sizes stay float: a quad spanning pixels
-- [a, b) is drawn as the pixels whose centres GL would cover (first ceil(a - 0.5), last ceil(b - 0.5) - 1) and its
-- texture region is widened/shifted so that every pixel centre samples the texel Java samples (M.quad).
function M.scaled(w, h)
    local sf = 1
    while math.floor(w / (sf + 1)) >= 320 and math.floor(h / (sf + 1)) >= 240 do
        sf = sf + 1
    end
    local sw, sh = math.floor(w / sf), math.floor(h / sf)
    M.sf, M.kx, M.ky = sf, w / sw, h / sh
    return sw, sh, sf
end

-- GUI units -> frame pixels (x, y) for the scale factor sf of the current ScaledResolution
function M.kxy(sf)
    if sf == M.sf and M.kx then return M.kx, M.ky end
    return sf, sf
end

local function num(v)
    if v == math.floor(v) then return ("%d"):format(v) end
    return ("%.9g"):format(v)
end
M.num = num

function M.viewport()
    local vp = gui.get_viewport()
    return vp[1], vp[2]
end

local function hex(c)
    -- c = {r, g, b, a} 0..255
    return ("#%02X%02X%02X%02X"):format(c[1], c[2], c[3], c[4] or 255)
end
M.hex = hex

local fmt = string.format

-- XML image `region` = x1,y1,x2,y2 in texture UV, but Image::draw passes flippedY and textures are stored bottom-up:
-- rows counted from the TOP of the png (ty0 < ty1, fractions) become v = 1 - ty1 .. 1 - ty0
local function region(u0, t0, u1, t1)
    return fmt("%.9g,%.9g,%.9g,%.9g", u0, 1 - t1, u1, 1 - t0)
end
M.region = region

-- pixels covered by [a, b) (pixel centres): first index, count
local function span(a, b)
    local p = math.ceil(a - 0.5)
    return p, math.ceil(b - 0.5) - p
end
M.span = span

-- textured quad over frame pixels [ax, bx) x [ay, by) with texture fractions u0..u1, t0..t1 (t from the png top)
function M.quad(buf, src, ax, ay, bx, by, u0, t0, u1, t1, color)
    local px, nx = span(ax, bx)
    local py, ny = span(ay, by)
    if nx <= 0 or ny <= 0 then return end
    if px ~= ax or py ~= ay or nx ~= bx - ax or ny ~= by - ay then
        local su, st = (u1 - u0) / (bx - ax), (t1 - t0) / (by - ay)
        u0, t0 = u0 + (px - ax) * su, t0 + (py - ay) * st
        u1, t1 = u0 + nx * su, t0 + ny * st
    end
    buf[#buf + 1] = fmt('<image src="%s" pos="%d,%d" size="%d,%d" region="%s" color="%s" interactive="false"/>',
        src, px, py, nx, ny, region(u0, t0, u1, t1), color and hex(color) or "#FFFFFFFF")
end

-- Gui.drawTexturedModalRect(x, y, u, v, w, h) of a tex_w x tex_h texture, GUI units -> XML <image>
function M.rect(buf, src, tex_w, tex_h, x, y, u, v, w, h, sf, color)
    local kx, ky = M.kxy(sf)
    M.quad(buf, src, x * kx, y * ky, (x + w) * kx, (y + h) * ky, u / tex_w, v / tex_h, (u + w) / tex_w, (v + h) / tex_h,
        color)
end

-- image in pixels (prerendered at an integer scale; dw/dh: drawn size when stretched)
function M.image_px(buf, src, tex_w, tex_h, px, py, u, v, w, h, color, dw, dh)
    M.quad(buf, src, px, py, px + (dw or w), py + (dh or h), u / tex_w, v / tex_h, (u + w) / tex_w, (v + h) / tex_h, color)
end

-- Gui.drawRect(x0, y0, x1, y1, argb) -> untextured container (alpha blended like GL_SRC_ALPHA)
function M.fill(buf, x0, y0, x1, y1, argb, sf)
    local a = math.floor(argb / 16777216) % 256
    local r = math.floor(argb / 65536) % 256
    local g = math.floor(argb / 256) % 256
    local b = argb % 256
    if x1 < x0 then x0, x1 = x1, x0 end
    if y1 < y0 then y0, y1 = y1, y0 end
    local kx, ky = M.kxy(sf)
    local px, nx = span(x0 * kx, x1 * kx)
    local py, ny = span(y0 * ky, y1 * ky)
    if nx <= 0 or ny <= 0 then return end
    buf[#buf + 1] = fmt('<container pos="%d,%d" size="%d,%d" color="%s" interactive="false"/>',
        px, py, nx, ny, hex({r, g, b, a}))
end

-- GuiScreen.drawDefaultBackground over a world: drawGradientRect(0, 0, w, h, 0xC0101010, 0xD0101010) -- one alpha
-- per frame row, a8 = round(0xC0 + 16 * (y - 0.5) / H) (measured at 480 rows: layer_gui 0_menu); the 480-row column
-- is textures/gui/am_menu_bg.png, other heights get a canvas built here
function M.background(buf, vw, vh)
    local src = "gui/am_menu_bg"
    if vh ~= 480 then
        src = "am_menu_bg_" .. vh
        M.bg_canvases = M.bg_canvases or {}
        if not M.bg_canvases[vh] then
            local c = Canvas({1, vh})
            local data = {}
            for y = 0, vh - 1 do
                local a8 = math.floor(0xC0 + (0xD0 - 0xC0) * (y - 0.5) / vh + 0.5)
                if a8 < 0xC0 then a8 = 0xC0 elseif a8 > 0xD0 then a8 = 0xD0 end
                local o = (vh - 1 - y) * 4          -- canvas rows bottom-up
                data[o + 1], data[o + 2], data[o + 3], data[o + 4] = 16, 16, 16, a8
            end
            c:set_data(data)
            c:create_texture(src)
            c:update()
            M.bg_canvases[vh] = c
        end
    end
    buf[#buf + 1] = fmt('<image src="%s" pos="0,0" size="%d,%d" interactive="false"/>', src, vw, vh)
end

-- wraps generated children into one element (container:add takes a single root element)
function M.group(buf, id, w, h)
    return fmt('<container id="%s" pos="0,0" size="%d,%d" color="#00000000" interactive="false">%s</container>',
        id, w, h, table.concat(buf))
end

-- replaces the children of a document container with generated XML
function M.replace(doc, id, buf, w, h)
    local el = doc[id]
    if not el then return end
    el:clear()
    if #buf > 0 then
        el:add(M.group(buf, id .. "_g", w, h))
    end
end

return M
