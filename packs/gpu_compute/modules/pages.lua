-- gpu_compute:pages — «страница» = одна canvas-текстура RGBA8, в которую склеены несколько буферов и параметров:
-- UI-шейдер видит одну текстуру на картинку (u_texture), поэтому всё, что нужно проходу, кладётся в одну страницу
-- (как страницы весов + вход у smollm_gpu). Каждая часть начинается с новой строки.
--   local pg = pages.build{ id = "mypage", width = 768, parts = {
--       { name = "w", bytes = ba, offset = 0, size = n },   -- байты как есть (4 на тексель) из Bytearray/строки
--       { name = "x", rows = 1 } } }                       -- пустые строки (заполнить pg:set_row / canvas:set)
--   pg.parts.w.row0, pg.parts.w.rows; pg:update() после правок
local M = {}

local function ptr_of(ba)
    local s = tostring(ba.bytes or ba)
    local hex = s:match("0x(%x+)")
    if not hex then return nil end
    -- tonumber(hex, 16) в LuaJIT насыщается на 2^32-1 (LESSONS «LLM на GPU»): разбор по цифрам
    local n = 0
    for i = 1, #hex do n = n * 16 + tonumber(hex:sub(i, i), 16) end
    return n
end
M.ptr_of = ptr_of

-- скопировать size байт Bytearray ba (с offset) в canvas с байта dst (memcpy через Canvas:_set_data, если есть)
function M.blit(canvas, w, dst_row, ba, offset, size)
    offset = offset or 0
    local p = type(ba) == "cdata" and ptr_of(ba) or nil
    if p and dst_row == 0 and canvas._set_data then
        canvas:_set_data(string.format("%.0f", p + offset), size)
        return
    end
    -- по текселям (медленно, для малых частей и строк)
    local get = type(ba) == "string" and function(i) return ba:byte(i + 1) end or function(i) return ba[i + 1] end
    for t = 0, math.floor((size + 3) / 4) - 1 do
        local b = offset + 4 * t
        local x, y = t % w, dst_row + math.floor(t / w)
        canvas:set(x, y, get(b) or 0, get(b + 1) or 0, get(b + 2) or 0, get(b + 3) or 0)
    end
end

function M.build(o)
    local w = o.width or 256
    local parts, row = {}, 0
    for _, p in ipairs(o.parts) do
        local size = p.size or (p.bytes and (type(p.bytes) == "string" and #p.bytes or p.bytes.size or #p.bytes)) or 0
        local rows = p.rows or math.max(1, math.ceil(math.ceil(size / 4) / w))
        parts[p.name] = { row0 = row, rows = rows, size = size, spec = p }
        row = row + rows
    end
    local c = Canvas({ w, row })
    c:clear()
    for _, p in pairs(parts) do
        if p.spec.bytes then
            if p.row0 == 0 and #o.parts == 1 then
                M.blit(c, w, 0, p.spec.bytes, p.spec.offset, p.size)
            else
                M.blit(c, w, p.row0, p.spec.bytes, p.spec.offset, p.size)
            end
        end
    end
    c:create_texture(o.id)
    local pg = { id = o.id, canvas = c, width = w, height = row, parts = parts }
    function pg:update() self.canvas:update() end
    return pg
end

return M
