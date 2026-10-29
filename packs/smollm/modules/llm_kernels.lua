-- Ручные ядра smollm под LuaJIT (11.10, llm_cpu): матвек Q8 (один токен и батч prefill) и внимание слоя — вместо
-- кода C -> wasm -> Lua (Spider), где каждая операция идёт через обёртки рантайма. Ядро работает прямо с табличной
-- памятью модуля Spider (memory[1].__w: слова по 4 байта, знаковая форма bit.tobit), веса int8 читаются словом по 4.
--
-- Паритет бит в бит с C (src/model.c): целочисленная сумма группы из gs произведений int8 точна в double
-- (|сумма| < 64 * 127^2 < 2^20), а каждая операция над float (ival * ws, * xs, val +) округляется до binary32 так
-- же, как в C (round_f32: double-операция над двумя binary32 и округление — ровно операция binary32). Проверка —
-- самопроверка ядер (reference/kernels) и логиты первого токена (cmp с reference/logits_*.f32).
--
-- Батч prefill: два токена в одном double. Для пары токенов (a, b) строится X = x_a + x_b * 2^21; сумма группы
-- Σ w_k * X_k = dot_a + dot_b * 2^21 точна (|dot| < 2^20, итог < 2^42), dot_b = floor((acc + 2^20) / 2^21),
-- dot_a = acc - dot_b * 2^21. Одно умножение и одно сложение на две MAC, слово весов разбирается один раз на батч.
--
-- Используется расширением llm_host.lua (импорты vc.llm_matmul / vc.llm_attention); вне движка — стенд
-- Spider tests/manual/real-world-smollm/bench.lua --kernel lua.
local bit = bit or require("bit")
local band, rshift, lshift, arshift, tobit = bit.band, bit.rshift, bit.lshift, bit.arshift, bit.tobit
local floor, abs, log, huge = math.floor, math.abs, math.log, math.huge

local M = {}

-- binary32 <-> число ------------------------------------------------------------------------------------------
local POW = {}            -- POW[e] = 2^(e - 150), e = 0..255
for e = 0, 255 do POW[e] = 2 ^ (e - 150) end
local SUB = 2 ^ -149
local function f32_val(b)
    local e = band(rshift(b, 23), 255)
    local m = band(b, 0x7FFFFF)
    local v
    if e == 0 then v = m * SUB
    elseif e == 255 then if m == 0 then v = huge else v = 0 / 0 end
    else v = (m + 8388608) * POW[e] end
    if b < 0 then return -v end
    return v
end
M.f32_val = f32_val

local SPLIT, MIN_NORMAL, OVERFLOW = 2 ^ 29 + 1, 2 ^ -126, 2 ^ 128 - 2 ^ 103
local SUB_MAGIC = 1.5 * 2 ^ -97
local function round_special(x)
    if x ~= x then return x end
    local a = abs(x)
    if a >= OVERFLOW then if x > 0 then return huge end return -huge end
    local r = (a + SUB_MAGIC) - SUB_MAGIC
    if x < 0 or 1 / x < 0 then return -r end
    return r
end
-- ближайшее binary32 (ties to even), как round_f32 рантайма Spider --f32 number
local function rnd(x)
    local a = abs(x)
    if a >= MIN_NORMAL and a < OVERFLOW then
        local c = x * SPLIT
        return c - (c - x)
    end
    return round_special(x)
end
M.round_f32 = rnd

local INV_LN2 = 1.4426950408889634
-- биты binary32 (знаковая форма) для v, уже точного binary32; NaN -> канонический
local function f32_bits(v)
    if v ~= v then return 0x7FC00000 end
    local s = 0
    if v < 0 or (v == 0 and 1 / v < 0) then s = -2147483648; v = -v end
    if v == huge then return tobit(s + 0x7F800000) end
    if v < MIN_NORMAL then return tobit(s + v * 2 ^ 149) end
    -- v = (2^23 + m) * POW[e], e — смещённая экспонента; логарифм верен с точностью до единицы, поправка
    local e = floor(log(v) * INV_LN2) + 127
    if e > 254 then e = 254 elseif e < 1 then e = 1 end
    local p = POW[e]
    if v < p * 8388608 then e = e - 1; p = POW[e]
    elseif v >= p * 16777216 then e = e + 1; p = POW[e] end
    return tobit(s + (e - 1) * 8388608 + v / p)
end
M.f32_bits = f32_bits

-- fm_exp из src/fmath.c (только +,-,*,/ над double): те же константы и порядок операций — те же биты
local LN2_HI, LN2_LO, INV_LN2_D = 6.93147180369123816490e-01, 1.90821492927058770002e-10, 1.44269504088896338700e+00
local POW2 = {}                                   -- 2^k, k = -1022..1023, точно (удвоение/деление пополам)
do
    local v = 1.0
    for k = 0, 1023 do POW2[k] = v; v = v * 2 end
    v = 1.0
    for k = -1, -1022, -1 do v = v / 2; POW2[k] = v end
end
local ceil = math.ceil
local C14, C13, C12, C11, C10, C9, C8, C7, C6, C5, C4, C3 = 1.0 / 87178291200.0, 1.0 / 6227020800.0,
    1.0 / 479001600.0, 1.0 / 39916800.0, 1.0 / 3628800.0, 1.0 / 362880.0, 1.0 / 40320.0, 1.0 / 5040.0, 1.0 / 720.0,
    1.0 / 120.0, 1.0 / 24.0, 1.0 / 6.0
local function fm_exp(x)
    if x ~= x then return x end
    if x > 709.7 then return huge end
    if x < -745.2 then return 0.0 end
    local t = x * INV_LN2_D
    local k
    if t >= 0 then k = floor(t + 0.5) else k = ceil(t - 0.5) end
    local r = (x - k * LN2_HI) - k * LN2_LO
    local p = C14
    p = p * r + C13
    p = p * r + C12
    p = p * r + C11
    p = p * r + C10
    p = p * r + C9
    p = p * r + C8
    p = p * r + C7
    p = p * r + C6
    p = p * r + C5
    p = p * r + C4
    p = p * r + C3
    p = p * r + 0.5
    p = p * r + 1.0
    p = p * r + 1.0
    if k > 1023 then return p * POW2[1023] * POW2[k - 1023] end
    if k < -1022 then return p * POW2[-1022] * POW2[k + 1022] end
    return p * POW2[k]
end
M.fm_exp = fm_exp

-- Генераторы ядер (код строкой: развёртка группы gs по словам, без внутренних циклов) ------------------------
local function gen_single(gs)
    local W4 = gs / 4
    local L = {}
    L[#L + 1] = "local band, rshift, lshift, arshift, f32_val, rnd = ...\n"
    L[#L + 1] = "return function(W, X, XS, OUT, wrow, wsw, n4, groups, d, step, yield)\n"
    L[#L + 1] = "  for i = 0, d - 1 do\n"
    L[#L + 1] = "    local val = 0\n"
    L[#L + 1] = "    local wb = wrow + i * n4\n"
    L[#L + 1] = "    local sb = wsw + i * groups\n"
    L[#L + 1] = "    for g = 0, groups - 1 do\n"
    L[#L + 1] = "      local k = wb + g * " .. W4 .. "\n"
    L[#L + 1] = "      local j = g * " .. gs .. "\n"
    L[#L + 1] = "      local w = W[k]\n"
    L[#L + 1] = "      local acc = X[j + 1] * arshift(lshift(w, 24), 24) + X[j + 2] * arshift(lshift(w, 16), 24)"
        .. " + X[j + 3] * arshift(lshift(w, 8), 24) + X[j + 4] * arshift(w, 24)\n"
    for q = 1, W4 - 1 do
        local o = q * 4
        L[#L + 1] = ("      w = W[k + %d]\n"):format(q)
        L[#L + 1] = ("      acc = acc + X[j + %d] * arshift(lshift(w, 24), 24) + X[j + %d] * arshift(lshift(w, 16), 24)"
            .. " + X[j + %d] * arshift(lshift(w, 8), 24) + X[j + %d] * arshift(w, 24)\n"):format(o + 1, o + 2, o + 3, o + 4)
    end
    L[#L + 1] = "      val = rnd(val + rnd(rnd(acc * f32_val(W[sb + g])) * XS[g + 1]))\n"
    L[#L + 1] = "    end\n"
    L[#L + 1] = "    OUT[i + 1] = val\n"
    L[#L + 1] = "    if i % step == step - 1 then yield() end\n"
    L[#L + 1] = "  end\n"
    L[#L + 1] = "end\n"
    return table.concat(L)
end

-- P пар токенов (2P токенов): PX[p][j] = x_{2p-1}[j] + x_{2p}[j] * 2^21; XS[t][g] — масштабы токена t;
-- OUT[t][i] — результат. Аккумуляторы пар и значения токенов — локальные (регистры трассы).
local function gen_pairs(gs, P)
    local W4 = gs / 4
    local T = 2 * P
    local L = {}
    local function add(s) L[#L + 1] = s end
    add("local band, rshift, lshift, arshift, f32_val, rnd, floor = ...\n")
    add("return function(W, PX, XS, OUT, wrow, wsw, n4, groups, d, step, yield)\n")
    for p = 1, P do add(("  local PX%d = PX[%d]\n"):format(p, p)) end
    for t = 1, T do add(("  local XS%d, OUT%d = XS[%d], OUT[%d]\n"):format(t, t, t, t)) end
    add("  for i = 0, d - 1 do\n")
    for t = 1, T do add(("    local v%d = 0\n"):format(t)) end
    add("    local wb = wrow + i * n4\n")
    add("    local sb = wsw + i * groups\n")
    add("    for g = 0, groups - 1 do\n")
    add("      local k = wb + g * " .. W4 .. "\n")
    add("      local j = g * " .. gs .. "\n")
    for p = 1, P do add(("      local a%d = 0\n"):format(p)) end
    for q = 0, W4 - 1 do
        local o = q * 4
        add(("      do local w = W[k + %d]\n"):format(q))
        add("        local b0, b1, b2, b3 = arshift(lshift(w, 24), 24), arshift(lshift(w, 16), 24), arshift(lshift(w, 8), 24), arshift(w, 24)\n")
        for p = 1, P do
            add(("        a%d = a%d + PX%d[j + %d] * b0 + PX%d[j + %d] * b1 + PX%d[j + %d] * b2 + PX%d[j + %d] * b3\n")
                :format(p, p, p, o + 1, p, o + 2, p, o + 3, p, o + 4))
        end
        add("      end\n")
    end
    add("      local s = f32_val(W[sb + g])\n")
    for p = 1, P do
        local ta, tb = 2 * p - 1, 2 * p
        add(("      do local hi = floor((a%d + 1048576) * (1 / 2097152)); local lo = a%d - hi * 2097152\n"):format(p, p))
        add(("        v%d = rnd(v%d + rnd(rnd(lo * s) * XS%d[g + 1]))\n"):format(ta, ta, ta))
        add(("        v%d = rnd(v%d + rnd(rnd(hi * s) * XS%d[g + 1])) end\n"):format(tb, tb, tb))
    end
    add("    end\n")
    for t = 1, T do add(("    OUT%d[i + 1] = v%d\n"):format(t, t)) end
    add("    if i % step == step - 1 then yield() end\n")
    add("  end\n")
    add("end\n")
    return table.concat(L)
end

local compile = loadstring or load
local cache = {}
local function kernel(kind, gs, P)
    local key = kind .. ":" .. gs .. ":" .. (P or 0)
    local k = cache[key]
    if not k then
        local src = kind == "single" and gen_single(gs) or gen_pairs(gs, P)
        local chunk = assert(compile(src, "=smollm_kernel_" .. key))
        k = chunk(band, rshift, lshift, arshift, f32_val, rnd, floor)
        cache[key] = k
    end
    return k
end
M.kernel = kernel

-- Экземпляр ядер над памятью модуля -------------------------------------------------------------------------
-- env.words() -> массив слов памяти (memory[1].__w), env.yield() — уступить кадр, если квант исчерпан
-- env.pairs (по умолчанию 4) — пар токенов в проходе батча (до 2P токенов на одно чтение весов)
function M.new(env)
    local K = { stats = { matmul_calls = 0, matmul_tok = 0, refused = 0, attention_calls = 0 } }
    local yield = env.yield or function() end
    local P = env.pairs or 4
    local X, XS1 = {}, {}
    local PX, XS, OUT = {}, {}, {}
    for t = 1, 2 * P do XS[t], OUT[t] = {}, {} end
    for p = 1, P do PX[p] = {} end
    local OUT1 = {}

    -- unpack int8 activations (адрес кратен 4, n кратно 4) в массив dst[1..n], множитель mul добавляется к dst
    local function unpack_x(W, addr, n, dst, mul, add)
        local base = addr / 4 + 1
        for q = 0, n / 4 - 1 do
            local w = W[base + q]
            local j = q * 4
            local b0, b1, b2, b3 = arshift(lshift(w, 24), 24), arshift(lshift(w, 16), 24), arshift(lshift(w, 8), 24), arshift(w, 24)
            if add then
                dst[j + 1] = dst[j + 1] + b0 * mul; dst[j + 2] = dst[j + 2] + b1 * mul
                dst[j + 3] = dst[j + 3] + b2 * mul; dst[j + 4] = dst[j + 4] + b3 * mul
            else
                dst[j + 1] = b0 * mul; dst[j + 2] = b1 * mul; dst[j + 3] = b2 * mul; dst[j + 4] = b3 * mul
            end
        end
    end
    local function read_f32s(W, addr, n, dst)
        local base = addr / 4 + 1
        for i = 0, n - 1 do dst[i + 1] = f32_val(W[base + i]) end
    end
    local function write_f32s(W, addr, n, src)
        local base = addr / 4 + 1
        for i = 0, n - 1 do W[base + i] = f32_bits(src[i + 1]) end
    end

    -- xout[t][d] = W(d x n) @ x[t]; возврат 1 — посчитано, 0 — отказ (C-ядро)
    function K.matmul(xout, xq, xs, wq, ws, n, d, gs, ntok)
        if xout % 4 ~= 0 or xq % 4 ~= 0 or xs % 4 ~= 0 or wq % 4 ~= 0 or ws % 4 ~= 0 or n % gs ~= 0 or gs % 4 ~= 0
            or ntok < 1 then
            K.stats.refused = K.stats.refused + 1
            return 0
        end
        local W = env.words()
        local groups = n / gs
        local n4 = n / 4
        local wrow, wsw = wq / 4 + 1, ws / 4 + 1
        K.stats.matmul_calls = K.stats.matmul_calls + 1
        K.stats.matmul_tok = K.stats.matmul_tok + ntok
        local step = math.max(1, floor(262144 / n))     -- проверка кванта ~ раз в 256K MAC
        if ntok == 1 then
            unpack_x(W, xq, n, X, 1)
            read_f32s(W, xs, groups, XS1)
            kernel("single", gs)(W, X, XS1, OUT1, wrow, wsw, n4, groups, d, step, yield)
            write_f32s(W, xout, d, OUT1)
            return 1
        end
        local done = 0
        while done < ntok do
            local nb = math.min(2 * P, ntok - done)
            local pp = math.ceil(nb / 2)
            for p = 1, pp do
                local ta, tb = done + 2 * p - 2, done + 2 * p - 1    -- 0-based токены пары
                unpack_x(W, xq + ta * n, n, PX[p], 1)
                if tb < done + nb then unpack_x(W, xq + tb * n, n, PX[p], 2097152, true) end
                read_f32s(W, xs + ta * groups * 4, groups, XS[2 * p - 1])
                if tb < done + nb then read_f32s(W, xs + tb * groups * 4, groups, XS[2 * p]) end
            end
            kernel("pairs", gs, pp)(W, PX, XS, OUT, wrow, wsw, n4, groups, d, math.max(1, floor(step / pp)), yield)
            for t = 1, nb do write_f32s(W, xout + (done + t - 1) * d * 4, d, OUT[t]) end
            done = done + nb
        end
        return 1
    end
    -- Внимание слоя (k_attention в model.c, softmax_impl внутри): кэш K/V слоя декодируется из памяти в числа
    -- Lua один раз на строку (ключ — адрес кэша слоя kc/vc: самопроверка ядер со своими буферами не путается);
    -- строки >= pos считаются переписанными (сброс контекста), строка pos только что записана C.
    local kv_cache = {}
    local function rows(W, addr, kv_dim, upto)
        local c = kv_cache[addr]
        if not c then c = { n = 0, data = {} }; kv_cache[addr] = c end
        if upto < c.n then c.n = upto end            -- строки upto.. переписаны: декодировать заново
        local data, base = c.data, addr / 4 + 1
        for r = c.n, upto do
            local o = r * kv_dim
            for i = 0, kv_dim - 1 do data[o + i + 1] = f32_val(W[base + o + i]) end
        end
        c.n = upto + 1
        return data
    end
    local Q, ATT, XB = {}, {}, {}
    function K.attention(xb, q, kc, vc, att, layer, pos, n_heads, hs, kv_dim, kv_mul, seq_len)
        if xb % 4 ~= 0 or q % 4 ~= 0 or kc % 4 ~= 0 or vc % 4 ~= 0 then return 0 end
        local W = env.words()
        K.stats.attention_calls = K.stats.attention_calls + 1
        local Kd = rows(W, kc, kv_dim, pos)
        local Vd = rows(W, vc, kv_dim, pos)
        local dim = n_heads * hs
        read_f32s(W, q, dim, Q)
        local sq = rnd(math.sqrt(hs))             -- sqrtf((float)head_size)
        for h = 0, n_heads - 1 do
            local qo = h * hs
            local ko = floor(h / kv_mul) * hs
            for tt = 0, pos do
                local kb = tt * kv_dim + ko
                local score = 0
                for i = 1, hs do score = rnd(score + rnd(Q[qo + i] * Kd[kb + i])) end
                ATT[tt + 1] = rnd(score / sq)
            end
            -- softmax_impl(att, pos + 1)
            local n = pos + 1
            local mx = ATT[1]
            for i = 2, n do if ATT[i] > mx then mx = ATT[i] end end
            local sum = 0
            for i = 1, n do
                local e = rnd(fm_exp(rnd(ATT[i] - mx)))
                ATT[i] = e
                sum = rnd(sum + e)
            end
            for i = 1, n do ATT[i] = rnd(ATT[i] / sum) end
            for i = 1, hs do XB[qo + i] = 0 end
            for tt = 0, pos do
                local vb = tt * kv_dim + ko
                local a = ATT[tt + 1]
                for i = 1, hs do XB[qo + i] = rnd(XB[qo + i] + rnd(a * Vd[vb + i])) end
            end
            if h % 4 == 3 then yield() end
        end
        write_f32s(W, xb, dim, XB)
        return 1
    end
    return K
end

return M
