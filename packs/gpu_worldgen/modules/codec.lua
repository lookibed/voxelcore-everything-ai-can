-- gpu_worldgen:codec — данные чанка для world.set_chunk_data из массива id блоков.
-- Формат (src/voxels/compressed_chunks.cpp, одинаков в 0.31 и 0.32; тот же, что в alphamine:chunk_codec):
--   u8 flags = 1 (HAS_VOXELS, без метаданных), u8 0, i32 LE длина, gzip(extrle16(raw)),
--   raw = 65536 x u16 id (индекс (y*16 + z)*16 + x), затем 65536 x u16 state (здесь все 0) — всего 262144 байта.
-- extrle16 (src/coders/rle.cpp): серия = байт [len-1 младшие 6 бит | 0x40 если значение > 255 | 0x80 если
--   len-1 >= 64, тогда следующий байт (len-1) >> 6], затем значение 1 байт (2 LE при 0x40); длина серии <= 0x4000.
-- Серии считаются прямо по массиву id (без промежуточного raw), нулевые state — 4 серии по 16384.
local M = {}

local band, rshift, lshift, bxor, tobit = bit.band, bit.rshift, bit.lshift, bit.bxor, bit.tobit

M.last_rle = 0  -- длина extrle16 последнего encode (до gzip)
local rle -- переиспользуемый Bytearray (худший случай 3 байта на значение + хвост)

-- ids[0..65535] -> Bytearray (rle.size = длина), вызывающему не хранить: буфер переиспользуется
function M.extrle16(ids)
    if not rle then rle = Bytearray(65536 * 4 + 64) end
    local dst = rle.bytes
    local n = 0
    local c = ids[0]
    local counter = 0
    local function emit()
        local wide = c > 255 and 0x40 or 0
        if counter >= 0x40 then
            dst[n] = 0x80 + wide + band(counter, 0x3F)
            dst[n + 1] = rshift(counter, 6)
            n = n + 2
        else
            dst[n] = counter + wide
            n = n + 1
        end
        if wide ~= 0 then
            dst[n] = band(c, 255)
            dst[n + 1] = rshift(c, 8)
            n = n + 2
        else
            dst[n] = c
            n = n + 1
        end
    end
    for i = 1, 65535 do
        local cn = ids[i]
        if cn ~= c or counter == 0x3FFF then
            emit()
            c = cn
            counter = 0
        else
            counter = counter + 1
        end
    end
    -- state: 65536 нулей подряд за последним id (как сделал бы rle::encode16 по raw целиком)
    local left = 65536
    if c == 0 then
        -- последняя серия id — тоже нули: продолжаем её
        while left > 0 do
            if counter == 0x3FFF then
                emit(); counter = 0; left = left - 1
            else
                local k = 0x3FFF - counter
                if k > left then k = left end
                counter = counter + k
                left = left - k
            end
        end
    else
        emit()
        c = 0
        counter = 0
        left = left - 1
        while left > 0 do
            if counter == 0x3FFF then
                emit(); counter = 0; left = left - 1
            else
                local k = 0x3FFF - counter
                if k > left then k = left end
                counter = counter + k
                left = left - k
            end
        end
    end
    emit()
    rle.size = n
    return rle
end

-- FNV-1a 32 по байтам Bytearray (умножение на 16777619 = 2^24 + 403 разложено, чтобы double оставался точным)
function M.fnv(bytes, h)
    h = h or tobit(2166136261)
    local p = bytes.bytes
    for i = 0, #bytes - 1 do
        h = bxor(h, p[i])
        h = tobit(lshift(h, 24) + h * 403)
    end
    return h
end

-- готовый поток extrle16 (Bytearray, size = длина; RLE на GPU) -> Bytearray для world.set_chunk_data, FNV потока
function M.encode_rle(r, want_hash)
    M.last_rle = r.size
    local h = want_hash and M.fnv(r) or nil
    local gz = compression.encode(r)
    local len = #gz
    local out = Bytearray(6)
    local p = out.bytes
    p[0] = 1
    p[1] = 0
    p[2] = band(len, 255)
    p[3] = band(rshift(len, 8), 255)
    p[4] = band(rshift(len, 16), 255)
    p[5] = rshift(len, 24)
    out:append(gz)
    return out, h
end

-- gzip без сжатия (stored-блок deflate) вокруг готового потока: заголовок set_chunk_data (6 Б) + gzip-заголовок (10) +
-- заголовок stored-блока (5: BFINAL=1 BTYPE=00, LEN, NLEN) + поток (n <= 65535) + CRC32 + ISIZE (8). Движок
-- (coders/gzip.cpp) берёт размер из ISIZE и распаковывает zlib inflate — stored-блок просто копируется.
-- CRC32 (полином 0xEDB88320, таблица) считает вызывающий по байтам потока, пока копирует их (M.CRC, M.stored_finish).
M.STORED_OFF = 21
M.CRC = {}
do
    for i = 0, 255 do
        local c = i
        for _ = 1, 8 do
            if band(c, 1) ~= 0 then c = bxor(rshift(c, 1), tobit(0xEDB88320)) else c = rshift(c, 1) end
        end
        M.CRC[i] = tobit(c)
    end
end
local stored_buf, stored_cap
-- буфер на n байт потока (переиспользуется; вызывающему не хранить): поток писать с байта M.STORED_OFF
function M.stored_begin(n)
    local size = M.STORED_OFF + n + 8
    if not stored_buf or stored_cap < size then
        stored_cap = size + 4096
        stored_buf = Bytearray(stored_cap)
    end
    stored_buf.size = size
    local p = stored_buf.bytes
    local glen = 10 + 5 + n + 8
    p[0] = 1; p[1] = 0
    p[2] = band(glen, 255); p[3] = band(rshift(glen, 8), 255); p[4] = band(rshift(glen, 16), 255); p[5] = 0
    -- gzip: 1f 8b, CM 8, FLG 0, MTIME 0, XFL 0, OS 255
    p[6] = 0x1f; p[7] = 0x8b; p[8] = 8; p[9] = 0; p[10] = 0; p[11] = 0; p[12] = 0; p[13] = 0; p[14] = 0; p[15] = 255
    p[16] = 1
    p[17] = band(n, 255); p[18] = rshift(n, 8)
    p[19] = 255 - band(n, 255); p[20] = 255 - rshift(n, 8)
    return stored_buf
end
-- crc — CRC32 потока без финального xor (начальное 0xFFFFFFFF -> tobit(-1)), см. M.CRC
function M.stored_finish(buf, n, crc)
    local p = buf.bytes
    local o = M.STORED_OFF + n
    crc = bit.bnot(crc)
    p[o] = band(crc, 255); p[o + 1] = band(rshift(crc, 8), 255)
    p[o + 2] = band(rshift(crc, 16), 255); p[o + 3] = band(rshift(crc, 24), 255)
    p[o + 4] = band(n, 255); p[o + 5] = band(rshift(n, 8), 255); p[o + 6] = band(rshift(n, 16), 255); p[o + 7] = 0
    M.last_rle = n
    return buf
end
-- FNV-1a 32 по байтам [off, off + n) (хэш потока для детерминизма)
function M.fnv_range(bytes, off, n)
    local h = tobit(2166136261)
    local p = bytes.bytes
    for i = off, off + n - 1 do
        h = bxor(h, p[i])
        h = tobit(lshift(h, 24) + h * 403)
    end
    return h
end

-- ids -> Bytearray для world.set_chunk_data; второй результат — FNV extrle16 (хэш содержимого чанка)
function M.encode(ids, want_hash)
    local r = M.extrle16(ids)
    M.last_rle = r.size
    local h = want_hash and M.fnv(r) or nil
    local gz = compression.encode(r)
    local len = #gz
    local out = Bytearray(6)
    local p = out.bytes
    p[0] = 1
    p[1] = 0
    p[2] = band(len, 255)
    p[3] = band(rshift(len, 8), 255)
    p[4] = band(rshift(len, 16), 255)
    p[5] = rshift(len, 24)
    -- копия блоком (Bytearray 0.32 на FFI); если append недоступен — побайтно
    if not pcall(out.append, out, gz) then
        out = Bytearray(6 + len)
        p = out.bytes
        p[0] = 1; p[1] = 0
        p[2] = band(len, 255); p[3] = band(rshift(len, 8), 255)
        p[4] = band(rshift(len, 16), 255); p[5] = rshift(len, 24)
        local g = gz.bytes
        for i = 0, len - 1 do p[6 + i] = g[i] end
    end
    return out, h
end

return M
