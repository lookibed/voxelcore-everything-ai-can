-- Графика через постэффект: команды программы -> uniform-массив шейдера wasmrt_cmds.
-- Работает только в мире (постэффекты есть лишь в рендере мира). Пропускная способность —
-- около 1000 vec4 на кадр (лимит uniform драйвера), здесь 256 команд по 2 vec4.

local font = require "wasmrt:font"

local M = { MAX_CMDS = 256, CMD_WORDS = 6 }
local FILL = 0.9  -- доля окна под экран программы (u_screenFill шейдера)

local pack = byteutil.pack
local band, rshift = bit.band, bit.rshift

local EFFECT = "wasmrt_cmds"   -- ассет эффекта из preload.json грузится без префикса пака
local SLOT = "wasmrt:screen"

function M.new(width, height)
    local self = { width = width, height = height, slot = -1, count = 0, debug = 0 }

    function self:activate()
        self.slot = gfx.posteffects.index(SLOT)
        assert(self.slot >= 0, "post-effect slot " .. SLOT .. " is missing")
        gfx.posteffects.set_effect(self.slot, EFFECT)
        gfx.posteffects.set_intensity(self.slot, 1.0)
        gfx.posteffects.set_params(self.slot, { u_virtual = { width, height }, u_cmdCount = 0, u_screenFill = FILL })
        local packed = Bytearray(0)
        for i = 1, #font.PACKED do
            Bytearray.append(packed, pack("f", font.PACKED[i]))
        end
        gfx.posteffects.set_array(self.slot, "u_font", Bytearray_as_string(packed))
    end

    function self:texture() end  -- спрайтов в постэффекте нет (uniform-канал слишком мал)

    function self:to_virtual(mx, my)
        local viewport = gui.get_viewport()
        local scale = math.min(viewport[1] / width, viewport[2] / height) * FILL
        local vx = (mx - (viewport[1] - width * scale) / 2) / scale
        local vy = (my - (viewport[2] - height * scale) / 2) / scale
        return math.floor(vx), math.floor(vy), vx >= 0 and vy >= 0 and vx < width and vy < height
    end

    function self:deactivate()
        if self.slot >= 0 then
            gfx.posteffects.set_intensity(self.slot, 0.0)
        end
    end

    function self:set_debug(mode, x, y)
        self.debug = mode
        local params = { u_debug = mode }
        if x and y then params.u_probe = { x, y } end
        gfx.posteffects.set_params(self.slot, params)
    end

    local warned_sprite = false

    -- count команд по 6 int32 в памяти программы: тип, a, b, c, d, цвет 0xRRGGBB.
    -- Текст (тип 6) становится командой (x, y, масштаб, длина) и следом командами данных
    -- (тип 7) по 7 кодов символов; спрайты (тип 5) пропускаются.
    function self:submit(host, memory, ptr, count)
        local buffer = Bytearray(0)
        local read = host.read_i32
        local used = 0
        for i = 0, count - 1 do
            local o = ptr + i * 24
            local t = read(memory, o)
            local color = read(memory, o + 20)
            local r, g, b = band(rshift(color, 16), 255) / 255, band(rshift(color, 8), 255) / 255, band(color, 255) / 255
            if t == 6 then
                local str = host.read_cstring(memory, read(memory, o + 12), 256)
                local scale = read(memory, o + 16)
                local chunks = math.ceil(#str / 7)
                if used + 1 + chunks > M.MAX_CMDS then break end
                Bytearray.append(buffer, pack("ffff", read(memory, o + 4), read(memory, o + 8), scale > 0 and scale or 1, #str))
                Bytearray.append(buffer, pack("ffff", r, g, b, 6))
                for c = 0, chunks - 1 do
                    local k = { 32, 32, 32, 32, 32, 32, 32 }
                    for j = 1, 7 do
                        local code = str:byte(c * 7 + j)
                        if code then k[j] = code end
                    end
                    Bytearray.append(buffer, pack("ffff", k[1], k[2], k[3], k[4]))
                    Bytearray.append(buffer, pack("ffff", k[5], k[6], k[7], 7))
                end
                used = used + 1 + chunks
            elseif t == 5 then
                if not warned_sprite then
                    warned_sprite = true
                    debug.log("[wasmrt] VC_CMD_SPRITE is not supported by graphics 'posteffect' (use 'canvas')")
                end
            else
                if used + 1 > M.MAX_CMDS then break end
                Bytearray.append(buffer, pack("ffff", read(memory, o + 4), read(memory, o + 8),
                    read(memory, o + 12), read(memory, o + 16)))
                Bytearray.append(buffer, pack("ffff", r, g, b, t))
                used = used + 1
            end
        end
        gfx.posteffects.set_array(self.slot, "u_cmds", Bytearray_as_string(buffer))
        gfx.posteffects.set_params(self.slot, { u_cmdCount = used })
        self.count = used
    end

    -- Кадр с палитрой: уменьшенный до INDEXED_W x INDEXED_H (ближайший сосед), 3 индекса в
    -- числе, палитра 0xRRGGBB — в эффект wasmrt_indexed.
    local INDEXED_W, INDEXED_H = 120, 90
    local indexed_active = false
    local frame, pal = {}, {}
    function self:present_indexed(host, memory, ptr, w, h, pal_ptr)
        if not indexed_active then
            gfx.posteffects.set_effect(self.slot, "wasmrt_indexed")
            gfx.posteffects.set_intensity(self.slot, 1.0)
            gfx.posteffects.set_params(self.slot, { u_size = { INDEXED_W, INDEXED_H }, u_screenFill = FILL })
            indexed_active = true
        end
        host.copy_out(memory, ptr, w * h, frame, 0)
        host.copy_out(memory, pal_ptr, 768, pal, 0)
        local pixels = Bytearray(0)
        local pack3 = {}
        local n = 0
        local total = INDEXED_W * INDEXED_H
        local values = {}
        for y = 0, INDEXED_H - 1 do
            local row = math.floor(y * h / INDEXED_H) * w
            for x = 0, INDEXED_W - 1 do
                n = n + 1
                values[n] = frame[row + math.floor(x * w / INDEXED_W)]
            end
        end
        local floats = {}
        for f = 0, math.ceil(total / 3) - 1 do
            local b0 = values[f * 3 + 1] or 0
            local b1 = values[f * 3 + 2] or 0
            local b2 = values[f * 3 + 3] or 0
            floats[#floats + 1] = b0 + b1 * 256 + b2 * 65536
        end
        for i = 1, #floats, 4 do
            Bytearray.append(pixels, pack("ffff", floats[i], floats[i + 1] or 0, floats[i + 2] or 0, floats[i + 3] or 0))
        end
        local palette = Bytearray(0)
        for i = 0, 255, 4 do
            local c = {}
            for k = 0, 3 do
                local e = (i + k) * 3
                c[k + 1] = pal[e] * 65536 + pal[e + 1] * 256 + pal[e + 2]
            end
            Bytearray.append(palette, pack("ffff", c[1], c[2], c[3], c[4]))
        end
        gfx.posteffects.set_array(self.slot, "u_pix", Bytearray_as_string(pixels))
        gfx.posteffects.set_array(self.slot, "u_pal", Bytearray_as_string(palette))
    end

    function self:present()
        error("graphics 'posteffect' has no framebuffer mode; use graphics 'canvas' in wasm.json")
    end

    return self
end

return M
