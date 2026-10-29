-- Animated terrain textures of Alpha 1.0.16 (phase 3): TextureLavaFX, TextureWaterFX, TextureWaterFlowFX,
-- TextureLavaFlowFX, TextureFlamesFX(0), (1) -- the order of RenderEngine.textureList (Minecraft.startGame), one
-- onTick each per game tick (Minecraft.runTick -> RenderEngine.updateDynamicTextures, before the world tick).
--
-- Math.random() is one shared generator in the F2F Java client (F2FRandom.random: java.util.Random seeded with
-- F2FRandom.mix(seed, "Math.random", 0) at `mode`); per tick the textures draw 256 (lava) + 256 (water) + 256
-- (water flow) + 256 (lava flow) + 64 + 64 (flames: 4 per cell of the bottom row) numbers, in that order. Other
-- Math.random users (particles, entity constructors, BlockFluid fizz) must draw from the same stream: M.random().
-- F2F `mode` also zeroes all FX arrays (F2FAgent.resetTextureFX); game.lua calls M.reset(seed) there.
-- Float arithmetic is Java float (jmath.fround after every operation, as the JVM rounds each float op).
--
-- Output: 16x16 RGBA images written into the "blocks" atlas region am_fx (textures/blocks/am_fx.png, 64x1024,
-- the second tallest atlas texture -> LMPacker puts it at atlas texel (2694, 2), right of am_lightmap; the
-- shaders check the marker "AMFX" in row 1023). Image k at columns 16k..16k+15, rows 0..15 = PNG rows from the
-- top (the texture v of RenderEngine): 0 water (tile 205), 1 water flow (206, drawn as 2x2), 2 lava (237),
-- 3 lava flow (238, 2x2), 4 fire (31), 5 fire (47). One canvas:update() per tick (a 64x1024 sub-image).
local perf = require "alphamine:perf"
local J = require "alphamine:jmath"
local fr = J.fround
local sin_t = J.sin
local band, rshift = bit.band, bit.rshift

local W, H = 64, 1024
local MARKER_ROW = H - 1

local M = {math = J.Random(0), ticks = 0, seed = 0, stats = {ticks = 0, ms = 0, uploads = 0}, failed = nil}

function M.random()
    return M.math:next_double()
end

local function arr(n)
    local t = {}
    for i = 0, n - 1 do t[i] = 0 end
    return t
end

local fx = {}

local function new_fx()
    return {red = arr(256), green = arr(256), blue = arr(256), alpha = arr(256), tick = 0, img = arr(1024)}
end

local F = {}
F.f3_3, F.f0_8, F.f0_05, F.f0_1, F.f0_5, F.f3_2, F.f0_3 = fr(3.3), fr(0.8), fr(0.05), fr(0.1), fr(0.5), fr(3.2), fr(0.3)
F.f0_01, F.f0_06, F.f1_5, F.f1_2, F.f1_06, F.f0_1d = fr(0.01), fr(0.06), fr(1.5), fr(1.2), fr(1.06), fr(0.1)
local PIF = fr(math.pi)

-- TextureWaterFX (flow = false) / TextureWaterFlowFX (flow = true)
local function water_tick(s, flow)
    s.tick = s.tick + 1
    local red, green, blue, alpha = s.red, s.green, s.blue, s.alpha
    for x = 0, 15 do
        for y = 0, 15 do
            local v = 0
            if flow then
                for k = y - 2, y do v = fr(v + red[x + band(k, 15) * 16]) end
                green[x + y * 16] = fr(fr(v / F.f3_2) + fr(blue[x + y * 16] * F.f0_8))
            else
                for k = x - 1, x + 1 do v = fr(v + red[band(k, 15) + y * 16]) end
                green[x + y * 16] = fr(fr(v / F.f3_3) + fr(blue[x + y * 16] * F.f0_8))
            end
        end
    end
    local dec, chance = flow and F.f0_3 or F.f0_1, flow and 0.2 or 0.05
    for x = 0, 15 do
        for y = 0, 15 do
            local i = x + y * 16
            local b = fr(blue[i] + fr(alpha[i] * F.f0_05))
            if b < 0 then b = 0 end
            blue[i] = b
            alpha[i] = fr(alpha[i] - dec)
            if M.random() < chance then alpha[i] = F.f0_5 end
        end
    end
    s.red, s.green = green, red
    red = s.red
    local img = s.img
    for i = 0, 255 do
        local v = flow and red[band(i - s.tick * 16, 255)] or red[i]
        if v > 1 then v = 1 end
        if v < 0 then v = 0 end
        local v2 = fr(v * v)
        img[i * 4] = math.floor(fr(32 + fr(v2 * 32)))
        img[i * 4 + 1] = math.floor(fr(50 + fr(v2 * 64)))
        img[i * 4 + 2] = 255
        img[i * 4 + 3] = math.floor(fr(146 + fr(v2 * 50)))
    end
end

-- TextureLavaFX (flow = false) / TextureLavaFlowFX (flow = true)
local LAVA_OFF = {}
for k = 0, 15 do
    -- (int)(MathHelper.sin((float)k * (float)Math.PI * 2.0F / 16.0F) * 1.2F)
    local a = fr(fr(fr(k * PIF) * 2) / 16)
    local v = fr(sin_t(a) * F.f1_2)
    LAVA_OFF[k] = v >= 0 and math.floor(v) or -math.floor(-v)
end
local function lava_tick(s, flow)
    if flow then s.tick = s.tick + 1 end
    local red, green, blue, alpha = s.red, s.green, s.blue, s.alpha
    for x = 0, 15 do
        for y = 0, 15 do
            local v = 0
            local oy, ox = LAVA_OFF[y], LAVA_OFF[x]
            for a = x - 1, x + 1 do
                for b = y - 1, y + 1 do
                    v = fr(v + red[band(a + oy, 15) + band(b + ox, 15) * 16])
                end
            end
            local sb = fr(fr(fr(blue[band(x, 15) + band(y, 15) * 16] + blue[band(x + 1, 15) + band(y, 15) * 16])
                + blue[band(x + 1, 15) + band(y + 1, 15) * 16]) + blue[band(x, 15) + band(y + 1, 15) * 16])
            local i = x + y * 16
            green[i] = fr(fr(v / 10) + fr(fr(sb / 4) * F.f0_8))
            local nb = fr(blue[i] + fr(alpha[i] * F.f0_01))
            if nb < 0 then nb = 0 end
            blue[i] = nb
            alpha[i] = fr(alpha[i] - F.f0_06)
            if M.random() < 0.005 then alpha[i] = F.f1_5 end
        end
    end
    s.red, s.green = green, red
    red = s.red
    local img = s.img
    for i = 0, 255 do
        local idx = flow and band(i - math.floor(s.tick / 3) * 16, 255) or i
        local v = fr(red[idx] * 2)
        if v > 1 then v = 1 end
        if v < 0 then v = 0 end
        img[i * 4] = math.floor(fr(fr(v * 100) + 155))
        img[i * 4 + 1] = math.floor(fr(fr(v * v) * 255))
        img[i * 4 + 2] = math.floor(fr(fr(fr(fr(v * v) * v) * v) * 128))
        img[i * 4 + 3] = 255
    end
end

-- TextureFlamesFX: only the Math.random draws of the bottom row (4 per cell) for now; the fire picture is
-- not produced yet (fire keeps its static tile, BLOCKS_TODO.md)
local function flames_tick(s)
    for _ = 0, 15 do
        M.random(); M.random(); M.random(); M.random()
    end
end

local canvas, buf
local function init()
    if canvas or M.failed then return canvas ~= nil end
    local ok, c = pcall(assets.to_canvas, "blocks:am_fx")
    if not ok or not c or c.width ~= W or c.height ~= H then
        M.failed = "assets.to_canvas(blocks:am_fx): " .. tostring(c)
        debug.log("[alphamine] texfx disabled: " .. M.failed)
        return false
    end
    canvas = c
    buf = Bytearray(W * H * 4)
    local p = buf.bytes
    for i = 0, W * H * 4 - 1 do p[i] = 0 end
    local m = MARKER_ROW * W * 4
    p[m], p[m + 1], p[m + 2], p[m + 3] = 65, 77, 70, 88   -- "AMFX"
    return true
end

local function blit(k, img)
    local p = buf.bytes
    for y = 0, 15 do
        local o = (y * W + k * 16) * 4
        local s = y * 64
        for i = 0, 63 do p[o + i] = img[s + i] end
    end
end

function M.reset(seed)
    M.seed = seed or 0
    M.math:set_seed(J.mix(M.seed, "Math.random", 0))
    for k = 1, 4 do fx[k] = new_fx() end
    M.ticks = 0
end

-- one Minecraft.runTick: RenderEngine.updateDynamicTextures
function M.tick()
    if not fx[1] then M.reset(0) end
    local t0 = os.clock()
    lava_tick(fx[1], false)
    water_tick(fx[2], false)
    water_tick(fx[3], true)
    lava_tick(fx[4], true)
    flames_tick()
    flames_tick()
    M.ticks = M.ticks + 1
    M.stats.ticks = M.stats.ticks + 1
    if init() then
        blit(0, fx[2].img)
        blit(1, fx[3].img)
        blit(2, fx[1].img)
        blit(3, fx[4].img)
        if perf.opts.fx_upload ~= "off" then   -- attribution experiment only
            perf.push("fx_upload")
            canvas:set_data(buf)
            canvas:update()
            perf.pop()
        end
        M.stats.uploads = M.stats.uploads + 1
    end
    M.stats.ms = M.stats.ms + (os.clock() - t0) * 1e3
end

return M
