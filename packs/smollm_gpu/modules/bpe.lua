-- smollm_gpu:bpe — BPE-кодировщик промпта Ru-Small-Instruct на чистом Lua (без API движка: тот же файл гоняется стендом
-- на стоковом luajit — Spider tests/manual/real-world-smollm-gpu/chat/tok_lua_check.sh). Перенос 1:1 с
-- real-world-smollm/src/tokenizer.c (ByteLevel BPE как HF tokenizers: added_tokens отрезаются до BPE, регэксп GPT-2 по
-- таблицам Unicode, слияния по рангу, без byte_fallback, BOS не добавляется, NFC не делается).
--
-- Словарь — data/tokenizer.bin (Spider real-world-smollm/tokenizer_export.py, little-endian):
--   "RSTK", u32 version = 1, u32 vocab, u32 merges, u32 special;
--   vocab x (u16 len, байты) — СЫРЫЕ байты токена: таблица GPT-2 bytes_to_unicode уже обращена при экспорте
--     (символ алфавита ByteLevel -> байт), поэтому здесь её нет: 256 однобайтовых токенов = 256 байтов;
--   merges x (u32 left, u32 right, u32 result) — порядок = ранг (0 — самое раннее слияние);
--   special x (u32 id, u16 len, байты) — <|юзер|>, <|юзерзакончил|>, <|я_начал|>, <|я_закончил|> ...
--
-- Регэксп GPT-2: 's|'t|'re|'ve|'m|'ll|'d| ?\p{L}+| ?\p{N}+| ?[^\s\p{L}\p{N}]+|\s+(?!\S)|\s+ (альтернативы по порядку).
local M = {}

local sbyte, schar, floor = string.byte, string.char, math.floor
local KEY = 32768  -- ключ пары слияния: left * KEY + right (словарь 24576 < 32768)

local function in_ranges(cp, r)
    local lo, hi = 1, #r / 2
    while lo <= hi do
        local mid = floor((lo + hi) / 2)
        if cp < r[2 * mid - 1] then hi = mid - 1
        elseif cp > r[2 * mid] then lo = mid + 1
        else return true end
    end
    return false
end

-- byte(i) -> байт по смещению i (0-based), len — длина файла; tables — smollm_gpu:unicode_tables
function M.new(byte, len, tables)
    local function u16(o) return byte(o) + byte(o + 1) * 256 end
    local function u32(o) return u16(o) + u16(o + 2) * 65536 end
    if byte(0) ~= 82 or byte(1) ~= 83 or byte(2) ~= 84 or byte(3) ~= 75 then error("bpe: not RSTK") end
    if u32(4) ~= 1 then error("bpe: version " .. u32(4)) end
    local nv, nm, ns = u32(8), u32(12), u32(16)
    local t = { vocab_size = nv, n_merges = nm, pieces = {}, rank = {}, res = {}, specials = {}, byte_token = {} }
    local o = 20
    local buf = {}
    for i = 0, nv - 1 do
        local l = u16(o)
        for k = 1, l do buf[k] = byte(o + 1 + k) end
        t.pieces[i] = l > 0 and schar(unpack(buf, 1, l)) or ""
        o = o + 2 + l
    end
    for r = 0, nm - 1 do
        local key = u32(o) * KEY + u32(o + 4)
        if t.rank[key] == nil then t.rank[key] = r; t.res[key] = u32(o + 8) end   -- дубликат: первый ранг главнее
        o = o + 12
    end
    local is_special = {}
    t.lt_only = true   -- все спецтокены начинаются с '<' — тогда сравнение только там (проверено ниже)
    for s = 1, ns do
        local id, l = u32(o), u16(o + 4)
        for k = 1, l do buf[k] = byte(o + 5 + k) end
        t.specials[s] = { id = id, str = l > 0 and schar(unpack(buf, 1, l)) or "" }
        is_special[id] = true
        if l == 0 or buf[1] ~= 60 then t.lt_only = false end
        o = o + 6 + l
    end
    if o ~= len then error(("bpe: size %d, parsed %d"):format(len, o)) end
    for i = 0, nv - 1 do
        local p = t.pieces[i]
        if not is_special[i] and #p == 1 and t.byte_token[sbyte(p)] == nil then t.byte_token[sbyte(p)] = i end
    end
    for b = 0, 255 do if t.byte_token[b] == nil then error("bpe: no token for byte " .. b) end end
    t.letter, t.number, t.space = tables.letter, tables.number, tables.space
    return setmetatable(t, { __index = M })
end

-- UTF-8 -> кодовая точка, длина; невалидные байты — как есть (U+DC00+байт: не буква/число/пробел), как в tokenizer.c
local function utf8_decode(s, i, len)
    local c = sbyte(s, i)
    local cp, n
    if c < 0x80 then return c, 1
    elseif c >= 0xC0 and c < 0xE0 then cp, n = c - 0xC0, 1
    elseif c >= 0xE0 and c < 0xF0 then cp, n = c - 0xE0, 2
    elseif c >= 0xF0 and c < 0xF8 then cp, n = c - 0xF0, 3
    else return 0xDC00 + c, 1 end
    if n >= len - i + 1 then return 0xDC00 + c, 1 end
    for k = 1, n do
        local b = sbyte(s, i + k)
        if b < 0x80 or b >= 0xC0 then return 0xDC00 + c, 1 end
        cp = cp * 64 + (b - 0x80)
    end
    return cp, n + 1
end

-- BPE одного предтокена (строка байтов) -> ids в out
function M:bpe_segment(s, out)
    local n = #s
    if n == 0 then return end
    local ids, bt, rank, res = {}, self.byte_token, self.rank, self.res
    for i = 1, n do ids[i] = bt[sbyte(s, i)] end
    while n > 1 do
        local best_rank, best_res = math.huge, -1
        for i = 1, n - 1 do
            local r = rank[ids[i] * KEY + ids[i + 1]]
            if r and r < best_rank then best_rank = r; best_res = res[ids[i] * KEY + ids[i + 1]] end
        end
        if best_res < 0 then break end
        -- слить все вхождения лучшей пары слева направо без перекрытий (как tokenizer.c и куча слияний HF)
        local w, i = 0, 1
        while i <= n do
            if i < n and rank[ids[i] * KEY + ids[i + 1]] == best_rank then
                w = w + 1; ids[w] = best_res; i = i + 2
            else
                w = w + 1; ids[w] = ids[i]; i = i + 1
            end
        end
        n = w
    end
    for i = 1, n do out[#out + 1] = ids[i] end
end

-- предтокенизация регэкспом GPT-2 и BPE по сегментам (без спецтокенов внутри)
function M:encode_plain(s, out)
    local len = #s
    if len == 0 then return end
    local cp, off, n, i = {}, {}, 0, 1
    while i <= len do
        n = n + 1
        off[n] = i
        local c, l = utf8_decode(s, i, len)
        cp[n] = c
        i = i + l
    end
    off[n + 1] = len + 1
    local L, N, S = self.letter, self.number, self.space
    local function is_l(c) return in_ranges(c, L) end
    local function is_n(c) return in_ranges(c, N) end
    local function is_s(c) return in_ranges(c, S) end
    local pos = 1
    while pos <= n do
        local e = pos   -- конец совпадения (исключительно)
        local c0 = cp[pos]
        if c0 == 39 and pos + 1 <= n then   -- 's|'t|'re|'ve|'m|'ll|'d
            local a, b = cp[pos + 1], pos + 2 <= n and cp[pos + 2] or 0
            if a == 115 or a == 116 or a == 109 or a == 100 then e = pos + 2
            elseif (a == 114 and b == 101) or (a == 118 and b == 101) or (a == 108 and b == 108) then e = pos + 3 end
        end
        if e == pos then   -- ' ?\p{L}+'
            local j = pos
            if cp[j] == 32 then j = j + 1 end
            if j <= n and is_l(cp[j]) then while j <= n and is_l(cp[j]) do j = j + 1 end; e = j end
        end
        if e == pos then   -- ' ?\p{N}+'
            local j = pos
            if cp[j] == 32 then j = j + 1 end
            if j <= n and is_n(cp[j]) then while j <= n and is_n(cp[j]) do j = j + 1 end; e = j end
        end
        if e == pos then   -- ' ?[^\s\p{L}\p{N}]+'
            local j = pos
            if cp[j] == 32 then j = j + 1 end
            local function other(c) return not is_s(c) and not is_l(c) and not is_n(c) end
            if j <= n and other(cp[j]) then while j <= n and other(cp[j]) do j = j + 1 end; e = j end
        end
        if e == pos and is_s(c0) then   -- \s+(?!\S) | \s+
            local j = pos
            while j <= n and is_s(cp[j]) do j = j + 1 end
            if j == n + 1 then e = j                -- пробелы до конца
            elseif j - pos >= 2 then e = j - 1      -- все, кроме последнего (он уйдёт к следующему)
            else e = j end                          -- один пробел перед не-пробелом
        end
        if e == pos then e = pos + 1 end
        self:bpe_segment(s:sub(off[pos], off[e] - 1), out)
        pos = e
    end
end

-- текст (UTF-8) -> список id (1-based Lua-массив); спецтокены отрезаются до BPE (самый длинный в позиции)
function M:encode(text)
    local out, len, start, i = {}, #text, 1, 1
    local sp = self.specials
    while i <= len do
        local best, best_len = nil, 0
        if not self.lt_only or sbyte(text, i) == 60 then
            for k = 1, #sp do
                local str = sp[k].str
                local sl = #str
                if sl > best_len and i + sl - 1 <= len and text:sub(i, i + sl - 1) == str then best, best_len = sp[k], sl end
            end
        end
        if best then
            self:encode_plain(text:sub(start, i - 1), out)
            out[#out + 1] = best.id
            i = i + best_len
            start = i
        else
            i = i + 1
        end
    end
    self:encode_plain(text:sub(start, len), out)
    return out
end

function M:piece(id) return self.pieces[id] or "" end

function M:decode(ids)
    local parts = {}
    for k = 1, #ids do parts[k] = self.pieces[ids[k]] or "" end
    return table.concat(parts)
end

-- длина префикса строки из целых символов UTF-8 (для печати по токенам: хвост неполного символа ждёт следующий токен)
function M.utf8_complete(s)
    local n = #s
    local i = n
    while i > 1 and sbyte(s, i) >= 0x80 and sbyte(s, i) < 0xC0 do i = i - 1 end
    if n == 0 then return 0 end
    local c, need = sbyte(s, i), 1
    if c >= 0xC0 and c < 0xE0 then need = 2 elseif c >= 0xE0 and c < 0xF0 then need = 3 elseif c >= 0xF0 and c < 0xF8 then need = 4 end
    if n - i + 1 >= need then return n end
    return i - 1
end

return M
