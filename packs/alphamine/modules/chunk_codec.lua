-- Кодек данных чанка VoxelCore 0.31 для world.set_chunk_data (проверен пробой
-- tools/scenarios/alpha_probes/p2_chunk.lua, числа — agents/ALPHAMINE.md).
--
-- Формат (src/voxels/compressed_chunks.cpp):
--   u8 flags (1 = HAS_VOXELS, 2 = HAS_METADATA), u8 reserved = 0,
--   i32 LE длина, gzip(extrle16(raw)), [i32 LE длина + метаданные, если flags & 2]
--   raw = 65536 × u16 LE id, затем 65536 × u16 LE state (262144 байта; короче нельзя — движок
--   распаковывает в статический буфер и дочитает state из прошлого чанка),
--   индекс вокселя (y*16 + z)*16 + x, x,z 0..15, y 0..255.
-- extrle16 (src/coders/rle.cpp): серия = [len-1 (6 бит) | 0x40 если id > 255 | 0x80 если
--   len-1 >= 64, тогда следующий байт = (len-1) >> 6], затем значение 1 байт (или 2 LE, если > 255);
--   длина серии до 0x4000.
-- Bytearray(n) — malloc без обнуления: raw надо заполнять целиком (M.new_raw обнуляет).
local M = {}

M.CHUNK_VOL = 65536
M.RAW_LEN = 262144 -- CHUNK_DATA_LEN = CHUNK_VOL * 4

local band, rshift = bit.band, bit.rshift

-- Новый буфер raw (262144 байта, все id/state = 0 = core:air).
function M.new_raw()
    local raw = Bytearray(M.RAW_LEN)
    local p = raw.bytes
    for i = 0, M.RAW_LEN - 1 do p[i] = 0 end
    return raw
end

-- Запись id вокселя (x,y,z локальные) в raw.
function M.set_id(raw, x, y, z, id)
    local i = ((y * 16 + z) * 16 + x) * 2
    local p = raw.bytes
    p[i] = band(id, 255)
    p[i + 1] = rshift(id, 8)
end

-- Столб одинаковых id от y0 до y1 включительно.
function M.fill_column(raw, x, z, y0, y1, id)
    local p = raw.bytes
    local lo, hi = band(id, 255), rshift(id, 8)
    for y = y0, y1 do
        local i = ((y * 16 + z) * 16 + x) * 2
        p[i] = lo
        p[i + 1] = hi
    end
end

local rle_out -- переиспользуемый буфер (худший случай 4 байта на значение)

-- extrle16 от raw (262144 байт) -> Bytearray (свой буфер, размер выставлен)
-- zeros (необязательно): отсортированный список {first, last} индексов u16-значений, которые заведомо нули
-- (у чанков альфы y 128..255: id [32768, 65536), state [98304, 131072)) — их серия считается сразу, а не по
-- одному значению; результат побайтно тот же (проверено tools/alphamine/perf/test_extrle16.lua).
function M.extrle16(raw, zeros)
    if not rle_out then rle_out = Bytearray(M.RAW_LEN * 2) end
    local src, dst = raw.bytes, rle_out.bytes
    local n = 0
    local count = M.RAW_LEN / 2
    local c = src[0] + src[1] * 256
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
    local zi = 1
    local znext = zeros and zeros[1] and zeros[1][1] or count
    local i = 1
    while i < count do
        if i == znext then
            -- a known run of zeros [i, last]: the same steps as the element loop below, fast-forwarded
            local last = zeros[zi][2]
            if last > count - 1 then last = count - 1 end
            local left = last - i + 1
            if c ~= 0 or counter == 0x3FFF then
                emit()
                c = 0
                counter = 0
            else
                counter = counter + 1
            end
            left = left - 1
            while left > 0 do
                if counter == 0x3FFF then
                    emit()
                    counter = 0
                    left = left - 1
                else
                    local k = 0x3FFF - counter
                    if k > left then k = left end
                    counter = counter + k
                    left = left - k
                end
            end
            i = last + 1
            zi = zi + 1
            znext = zeros[zi] and zeros[zi][1] or count
            if znext < i then znext = count end
        else
            local stop = znext < count and znext or count
            while i < stop do
                local cn = src[2 * i] + src[2 * i + 1] * 256
                if cn ~= c or counter == 0x3FFF then
                    emit()
                    c = cn
                    counter = 0
                else
                    counter = counter + 1
                end
                i = i + 1
            end
        end
    end
    emit()
    rle_out.size = n
    return rle_out
end

-- raw -> Bytearray для world.set_chunk_data
function M.encode(raw, zeros)
    local rle = M.extrle16(raw, zeros)
    local gz = compression.encode(rle)
    local len = #gz
    local out = Bytearray(6 + len)
    local p, g = out.bytes, gz.bytes
    p[0] = 1 -- HAS_VOXELS, метаданных нет
    p[1] = 0
    p[2] = band(len, 255)
    p[3] = band(rshift(len, 8), 255)
    p[4] = band(rshift(len, 16), 255)
    p[5] = rshift(len, 24)
    for i = 0, len - 1 do p[6 + i] = g[i] end
    return out
end

-- zlib-поток (RFC 1950, как MapChunk альфы) -> gzip-поток для compression.decode:
-- заголовок gzip, deflate-данные без 2 байт заголовка zlib и 4 байт Adler-32, CRC-32 = 0
-- (движок не проверяет результат inflate), ISIZE = ожидаемая длина распакованного.
-- zlib: Bytearray или строка; isize: длина распакованных данных (у MapChunk известна).
function M.zlib_to_gzip(zlib, isize)
    if type(zlib) == "string" then zlib = Bytearray(zlib) end
    local zlen = #zlib
    local dlen = zlen - 6
    local out = Bytearray(10 + dlen + 8)
    local p, z = out.bytes, zlib.bytes
    p[0], p[1], p[2], p[3] = 0x1f, 0x8b, 8, 0
    for i = 4, 8 do p[i] = 0 end
    p[9] = 255
    for i = 0, dlen - 1 do p[10 + i] = z[2 + i] end
    local t = 10 + dlen
    for i = 0, 3 do p[t + i] = 0 end
    p[t + 4] = band(isize, 255)
    p[t + 5] = band(rshift(isize, 8), 255)
    p[t + 6] = band(rshift(isize, 16), 255)
    p[t + 7] = rshift(isize, 24)
    return out
end

function M.inflate_zlib(zlib, isize)
    return compression.decode(M.zlib_to_gzip(zlib, isize))
end

return M
