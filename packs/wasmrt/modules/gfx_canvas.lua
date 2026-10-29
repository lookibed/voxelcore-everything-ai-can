-- Графика через canvas: команды растеризуются на Lua в RGBA-буфер, либо программа
-- сама отдаёт готовый кадр (present). Буфер -> canvas -> текстура -> <image>,
-- масштабируется на GPU. Работает везде, где есть документ UI (страница меню, HUD-оверлей).

local M = { MAX_CMDS = 65536 }

local font = require "wasmrt:font"

local band, rshift = bit.band, bit.rshift
local floor, max, min = math.floor, math.max, math.min

local generation = 0

-- palette_mode ("cpu" | "gpu") — для vc_gfx_present_indexed: перевод индексов в цвет на
-- Lua или шейдером UI пака wasmrt (shaders/ui.glslf: картинка с цветом-маркером
-- #FF00FF80 берёт индексы по 4 в тексель и палитру из 4 последних строк текстуры).
-- host (необязательно): { parent = Element } — контейнер для картинки вместо корня документа
-- (картинка вписывается в его размер, а не в окно; например окно программы на рабочем столе
-- компьютера pc_wasmrt:pc во фрейме gui.create_frame).
function M.new(document, width, height, palette_mode, host)
    host = host or {}
    local self = { width = width, height = height, count = 0 }
    local fb = Bytearray(width * height * 4)
    local canvas, image

    local function place()
        if not image then return end
        local viewport = host.parent and host.parent.size or gui.get_viewport()
        local margin = host.parent and 0 or 20
        local scale = min((viewport[1] - margin) / self.width, (viewport[2] - margin) / self.height)
        if scale >= 1 then scale = floor(scale) end
        image.size = { max(1, floor(self.width * scale)), max(1, floor(self.height * scale)) }
        image:reposition()
    end

    local indexed_gpu = false   -- текущая текстура в режиме палитры на GPU
    local rgb16 = false         -- текущая текстура: 16-битные пиксели ref_soft Xash (2 в тексель), цвет — шейдер
    local tex_w, tex_h = width, height

    local function build()
        if not document then return end  -- без UI (тесты): только буфер
        generation = generation + 1
        local canvas_id, texture = "wasmrt_canvas_" .. generation, "wasmrt_screen_" .. generation
        if canvas and canvas.exists then canvas:destruct() end
        document.root:add(('<canvas id="%s" size="%d,%d" visible="false"/>'):format(canvas_id, tex_w, tex_h))
        canvas = document[canvas_id]
        canvas.data:create_texture(texture)
        -- Режим палитры: только строки кадра (без 4 строк палитры), цвет-маркер для шейдера.
        local region = indexed_gpu and ("0,%f,1,0"):format(self.height / tex_h) or "0,1,1,0"
        local color = indexed_gpu and "#FF00FF80" or (rgb16 and "#FF02FF80" or "#FFFFFFFF")
        if image and image.exists then
            image.src = texture
            image.region = indexed_gpu and { 0, self.height / tex_h, 1, 0 } or { 0, 1, 1, 0 }
            image.color = indexed_gpu and { 255, 0, 255, 128 } or (rgb16 and { 255, 2, 255, 128 } or { 255, 255, 255, 255 })
        else
            local image_id = "wasmrt_image_" .. generation
            local parent = host.parent or document.root
            parent:add(('<image id="%s" src="%s" size="1,1" gravity="center-center" region="%s" color="%s"/>')
                :format(image_id, texture, region, color))
            image = document[image_id]
        end
        place()
    end

    function self:activate() build() end
    function self:relayout() place() end
    function self:deactivate()
        if image and image.exists then image:destruct() end
        if canvas and canvas.exists then canvas:destruct() end
    end
    function self:set_debug() end

    local function upload()
        if not canvas then return end
        canvas.data:set_data(fb)
        canvas.data:update()
    end


    local p = fb.bytes
    local W, H = width, height

    -- Прямой доступ к кадру (RGBA, 0-based) для хостов, которые рисуют сами (wasm4).
    function self:bytes() return p end
    function self:upload() upload() end

    local function span(x0, x1, y, r, g, b)
        if y < 0 or y >= H then return end
        if x0 < 0 then x0 = 0 end
        if x1 > W - 1 then x1 = W - 1 end
        local o = (y * W + x0) * 4
        for _ = x0, x1 do
            p[o] = r; p[o + 1] = g; p[o + 2] = b; p[o + 3] = 255
            o = o + 4
        end
    end

    local function rect(x, y, w, h, r, g, b)
        for yy = max(y, 0), min(y + h - 1, H - 1) do span(x, x + w - 1, yy, r, g, b) end
    end

    local function circle(cx, cy, radius, r, g, b)
        for dy = -radius, radius do
            local dx = floor(math.sqrt(radius * radius - dy * dy))
            span(cx - dx, cx + dx, cy + dy, r, g, b)
        end
    end

    local textures = {}

    local function text(x, y, str, scale, r, g, b)
        local rows_of, first, last = font.ROWS, font.FIRST, font.LAST
        for k = 1, #str do
            local code = str:byte(k)
            if code >= 97 and code <= 122 then code = code - 32 end
            local rows = rows_of[code] or rows_of[63]
            local cx = x + (k - 1) * font.ADVANCE * scale
            for row = 1, 7 do
                local bits = rows[row]
                if bits ~= 0 then
                    for col = 0, 4 do
                        if band(bits, 2 ^ (4 - col)) ~= 0 then
                            rect(cx + col * scale, y + (row - 1) * scale, scale, scale, r, g, b)
                        end
                    end
                end
            end
        end
    end

    local function sprite(x, y, id, scale)
        local tex = textures[id]
        if not tex then return end
        local tp, tw, th = tex.bytes, tex.w, tex.h
        for ty = 0, th - 1 do
            for tx = 0, tw - 1 do
                local s = (ty * tw + tx) * 4
                if tp[s + 3] >= 128 then
                    if scale == 1 then
                        local px, py = x + tx, y + ty
                        if px >= 0 and px < W and py >= 0 and py < H then
                            local o = (py * W + px) * 4
                            p[o] = tp[s]; p[o + 1] = tp[s + 1]; p[o + 2] = tp[s + 2]; p[o + 3] = 255
                        end
                    else
                        rect(x + tx * scale, y + ty * scale, scale, scale, tp[s], tp[s + 1], tp[s + 2])
                    end
                end
            end
        end
    end

    function self:texture(host, memory, id, ptr, w, h)
        local data = Bytearray(w * h * 4)
        host.copy_out(memory, ptr, w * h * 4, data.bytes, 0)
        textures[id] = { data = data, bytes = data.bytes, w = w, h = h }
    end

    -- Окно -> виртуальный экран (по положению и размеру <image>).
    function self:to_virtual(mx, my)
        if not (image and image.exists) then return nil end
        local pos, size = image.wpos, image.size
        if size[1] <= 0 or size[2] <= 0 then return nil end
        local vx = (mx - pos[1]) / size[1] * self.width
        local vy = (my - pos[2]) / size[2] * self.height
        return floor(vx), floor(vy), vx >= 0 and vy >= 0 and vx < self.width and vy < self.height
    end

    local function line(x0, y0, x1, y1, r, g, b)
        local dx, dy = math.abs(x1 - x0), -math.abs(y1 - y0)
        local sx, sy = x0 < x1 and 1 or -1, y0 < y1 and 1 or -1
        local err = dx + dy
        while true do
            if x0 >= 0 and x0 < W and y0 >= 0 and y0 < H then
                local o = (y0 * W + x0) * 4
                p[o] = r; p[o + 1] = g; p[o + 2] = b; p[o + 3] = 255
            end
            if x0 == x1 and y0 == y1 then break end
            local e2 = 2 * err
            if e2 >= dy then err = err + dy; x0 = x0 + sx end
            if e2 <= dx then err = err + dx; y0 = y0 + sy end
        end
    end

    -- Команды: 6 int32 — тип (1 прямоугольник, 2 круг, 3 линия, 4 очистка, 5 спрайт,
    -- 6 текст), a, b, c, d, цвет.
    function self:submit(host, memory, ptr, count)
        local read = host.read_i32
        for i = 0, count - 1 do
            local o = ptr + i * 24
            local t = read(memory, o)
            local color = read(memory, o + 20)
            local r, g, b = band(rshift(color, 16), 255), band(rshift(color, 8), 255), band(color, 255)
            local a1, a2, a3, a4 = read(memory, o + 4), read(memory, o + 8), read(memory, o + 12), read(memory, o + 16)
            if t == 1 then rect(a1, a2, a3, a4, r, g, b)
            elseif t == 2 then circle(a1, a2, a3, r, g, b)
            elseif t == 3 then line(a1, a2, a3, a4, r, g, b)
            elseif t == 4 then rect(0, 0, W, H, r, g, b)
            elseif t == 5 then sprite(a1, a2, a3, a4 > 0 and a4 or 1)
            elseif t == 6 then text(a1, a2, host.read_cstring(memory, a3, 256), a4 > 0 and a4 or 1, r, g, b)
            end
        end
        self.count = count
        upload()
    end

    -- Кадр с палитрой: w*h индексов и палитра 768 байт (RGB) в памяти программы.
    local indices, pal = {}, {}
    function self:present_indexed(host, memory, ptr, w, h, pal_ptr)
        local gpu = palette_mode == "gpu"
        local want_w, want_h = gpu and w / 4 or w, gpu and h + 4 or h
        if w ~= self.width or h ~= self.height or gpu ~= indexed_gpu or tex_w ~= want_w or rgb16 then
            self.width, self.height, W, H = w, h, w, h
            indexed_gpu, tex_w, tex_h, rgb16 = gpu, want_w, want_h, false
            fb = Bytearray(tex_w * tex_h * 4)
            p = fb.bytes
            build()
        end
        if gpu then
            -- индексы как есть: 4 штуки на тексель; палитра — 256 текселей RGB после кадра
            host.copy_out(memory, ptr, w * h, p, 0)
            host.copy_out(memory, pal_ptr, 768, pal, 0)
            local o = w * h
            for i = 0, 255 do
                p[o] = pal[i * 3]; p[o + 1] = pal[i * 3 + 1]; p[o + 2] = pal[i * 3 + 2]; p[o + 3] = 255
                o = o + 4
            end
        else
            host.copy_out(memory, pal_ptr, 768, pal, 0)
            host.copy_out(memory, ptr, w * h, indices, 0)
            local o = 0
            for i = 0, w * h - 1 do
                local c = indices[i] * 3
                p[o] = pal[c]; p[o + 1] = pal[c + 1]; p[o + 2] = pal[c + 2]; p[o + 3] = 255
                o = o + 4
            end
        end
        upload()
    end

    -- Готовый кадр RGBA w*h из памяти программы.
    function self:present(host, memory, ptr, w, h)
        if w ~= self.width or h ~= self.height or indexed_gpu or rgb16 then
            self.width, self.height, W, H = w, h, w, h
            indexed_gpu, tex_w, tex_h, rgb16 = false, w, h, false
            fb = Bytearray(w * h * 4)
            p = fb.bytes
            build()
        end
        host.copy_out(memory, ptr, w * h * 4, p, 0)
        upload()
    end

    -- Кадр из 16-битных пикселей программного рендера Xash3D (ref_soft pixel_t: старший байт RGB 3-3-2,
    -- младший — добавочные биты GBRGBRGB; 12.10, пак halflife): w*h*2 байт как есть, 2 пикселя в тексель
    -- (текстура w/2 x h), цвет считает шейдер UI (маркер #FF02FF80, формула = таблица R_BuildScreenMap).
    -- В 2 раза меньше данных, чем RGBA, и без перевода цвета на CPU.
    function self:present_rgb16(host, memory, ptr, w, h)
        if w % 2 ~= 0 then error("gfx_present_rgb16: odd width " .. w) end
        if w ~= self.width or h ~= self.height or not rgb16 then
            self.width, self.height, W, H = w, h, w, h
            indexed_gpu, rgb16, tex_w, tex_h = false, true, w / 2, h
            fb = Bytearray(tex_w * tex_h * 4)
            p = fb.bytes
            build()
        end
        host.copy_out(memory, ptr, w * h * 2, p, 0)
        upload()
    end

    return self
end

return M
