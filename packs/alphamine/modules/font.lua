-- FontRenderer of Alpha 1.0.16 on engine XML: every glyph is an <image> with a region of font/am_default.png
-- (default.png: 16x16 grid of 8x8 glyphs), advance = charWidth from the alpha scan of the glyph columns
-- (generated into ui_tables.lua), colour = image tint, shadow = (colour & 0xFCFCFC) >> 2 at +1,+1.
-- The engine's own fonts are monospaced (fonts/font), so a font pack could not give the Alpha advances.
local T = require "alphamine:ui_tables"
local ui = require "alphamine:ui"

local M = {}
local WIDTHS = T.font_widths
local TEX = "font/am_default"

-- FontRenderer's character table (index + 32 = glyph); the backquote is absent (drawn as nothing)
local CHARS = " !\"#$%&'()*+,-./0123456789:;<=>?@ABCDEFGHIJKLMNOPQRSTUVWXYZ[\\]^_'abcdefghijklmnopqrstuvwxyz{|}~" ..
    "\u{2302}\u{00c7}\u{00fc}\u{00e9}\u{00e2}\u{00e4}\u{00e0}\u{00e5}\u{00e7}\u{00ea}\u{00eb}\u{00e8}\u{00ef}\u{00ee}" ..
    "\u{00ec}\u{00c4}\u{00c5}\u{00c9}\u{00e6}\u{00c6}\u{00f4}\u{00f6}\u{00f2}\u{00fb}\u{00f9}\u{00ff}\u{00d6}\u{00dc}" ..
    "\u{00f8}\u{00a3}\u{00d8}\u{00d7}\u{0192}\u{00e1}\u{00ed}\u{00f3}\u{00fa}\u{00f1}\u{00d1}\u{00aa}\u{00ba}\u{00bf}" ..
    "\u{00ae}\u{00ac}\u{00bd}\u{00bc}\u{00a1}\u{00ab}\u{00bb}"

local function codepoints(s)
    local out = {}
    local i, n = 1, #s
    while i <= n do
        local c = s:byte(i)
        local cp, len
        if c < 0x80 then cp, len = c, 1
        elseif c < 0xE0 then cp, len = (c % 32) * 64 + (s:byte(i + 1) or 0) % 64, 2
        elseif c < 0xF0 then cp, len = ((c % 16) * 64 + (s:byte(i + 1) or 0) % 64) * 64 + (s:byte(i + 2) or 0) % 64, 3
        else cp, len = (((c % 8) * 64 + (s:byte(i + 1) or 0) % 64) * 64 + (s:byte(i + 2) or 0) % 64) * 64 +
            (s:byte(i + 3) or 0) % 64, 4
        end
        out[#out + 1] = cp
        i = i + len
    end
    return out
end
M.codepoints = codepoints

local GLYPH = {}  -- codepoint -> glyph index (first occurrence, like String.indexOf)
do
    for k, cp in ipairs(codepoints(CHARS)) do
        if GLYPH[cp] == nil then GLYPH[cp] = k - 1 + 32 end
    end
end
M.GLYPH = GLYPH

local SECTION = 167  -- '§' colour codes

-- the 32 colours of the font display lists (16 normal + 16 shadow)
local PALETTE = {}
for i = 0, 31 do
    local d = math.floor(i / 8) % 2 * 85
    local r = math.floor(i / 4) % 2 * 170 + d
    local g = math.floor(i / 2) % 2 * 170 + d
    local b = i % 2 * 170 + d
    if i == 6 then r = r + 85 end
    if i >= 16 then r, g, b = math.floor(r / 4), math.floor(g / 4), math.floor(b / 4) end
    PALETTE[i] = {r, g, b}
end

function M.width(s)
    local w = 0
    local cps = codepoints(s)
    local i = 1
    while i <= #cps do
        if cps[i] == SECTION then
            i = i + 1
        else
            local g = GLYPH[cps[i]]
            if g then w = w + WIDTHS[g + 1] end
        end
        i = i + 1
    end
    return w
end

local fmt = string.format

-- FontRenderer.renderString: glyphs at GUI (x, y), colour 0xAARRGGBB (alpha 0 = opaque), shadow flag
local function render(buf, s, x, y, color, shadow, sf)
    if color < 0 then color = color + 4294967296 end
    if shadow then
        -- (c & 0xFCFCFC) >> 2 + alpha: every channel / 4
        local a = math.floor(color / 16777216) % 256
        local r = math.floor(math.floor(color / 65536) % 256 / 4)
        local g = math.floor(math.floor(color / 256) % 256 / 4)
        local b = math.floor(color % 256 / 4)
        color = a * 16777216 + r * 65536 + g * 256 + b
    end
    local a = math.floor(color / 16777216) % 256
    if a == 0 then a = 255 end
    local col = {math.floor(color / 65536) % 256, math.floor(color / 256) % 256, color % 256, a}
    local cps = codepoints(s)
    local px = x
    local i = 1
    local kx, ky = ui.kxy(sf)
    while i <= #cps do
        local cp = cps[i]
        if cp == SECTION and i < #cps then
            local k = ("0123456789abcdef"):find(string.char(cps[i + 1] < 128 and cps[i + 1] or 63):lower(), 1, true)
            k = k and (k - 1) or 15
            local p = PALETTE[k + (shadow and 16 or 0)]
            col = {p[1], p[2], p[3], 255}
            i = i + 2
        else
            local g = GLYPH[cp]
            if g then
                local cx, cy = g % 16, math.floor(g / 16)
                ui.quad(buf, TEX, px * kx, y * ky, (px + 8) * kx, (y + 8) * ky, cx / 16, cy / 16, (cx + 1) / 16,
                    (cy + 1) / 16, col)
                px = px + WIDTHS[g + 1]
            end
            i = i + 1
        end
    end
end

function M.draw(buf, s, x, y, color, sf)
    render(buf, s, x, y, color, false, sf)
end

-- FontRenderer.drawStringWithShadow
function M.draw_shadow(buf, s, x, y, color, sf)
    render(buf, s, x + 1, y + 1, color, true, sf)
    render(buf, s, x, y, color, false, sf)
end

-- Gui.drawCenteredString (always with shadow)
function M.draw_centered(buf, s, x, y, color, sf)
    M.draw_shadow(buf, s, x - math.floor(M.width(s) / 2), y, color, sf)
end

return M
