-- Проба 3: zlib-поток (как MapChunk альфы, java.util.zip.Deflater) -> gzip-обёртка (заголовок,
-- CRC-32 = 0, верный ISIZE) -> compression.decode. Данные: export/alpha_probe_{zlib,raw}{,2}.bin
-- (1 — похожий на чанк альфы 81920 байт, 2 — случайные 81920 байт), готовит Python.
-- Headless: vc_start(args=["--headless","--script","tools/scenarios/alpha_probes/p3_zlib.lua"], script="none")
local T = "alpha_p3"
local function log(m) debug.log("[" .. T .. "] " .. m) end
app.config_packs({"alphamine"})
app.load_content()
local codec = require("alphamine:chunk_codec")
for _, sfx in ipairs({"", "2"}) do
    local z = file.read_bytes("export:alpha_probe_zlib" .. sfx .. ".bin")
    local raw = file.read_bytes("export:alpha_probe_raw" .. sfx .. ".bin")
    local ok, out = pcall(codec.inflate_zlib, z, #raw)
    if not ok then
        log("payload" .. sfx .. ": decode error: " .. tostring(out))
    else
        local same = #out == #raw
        local firstdiff = -1
        if same then
            local a, b = out.bytes, raw.bytes
            for i = 0, #raw - 1 do if a[i] ~= b[i] then same = false; firstdiff = i; break end end
        end
        local N = 200
        local t0 = os.clock()
        for i = 1, N do codec.inflate_zlib(z, #raw) end
        local t1 = os.clock()
        local g = codec.zlib_to_gzip(z, #raw)
        local t2 = os.clock()
        for i = 1, N do compression.decode(g) end
        local t3 = os.clock()
        log(("payload%s: zlib %d B -> %d B, identical=%s (firstdiff %d); wrap+decode %.3f ms, decode only %.3f ms (avg of %d)"):format(
            sfx, #z, #out, tostring(same), firstdiff, (t1 - t0) / N * 1e3, (t3 - t2) / N * 1e3, N))
    end
    -- без обёртки: сырой zlib в compression.decode
    local ok2, out2 = pcall(compression.decode, z)
    log(("payload%s: raw zlib into compression.decode: ok=%s len=%s"):format(sfx, tostring(ok2),
        ok2 and tostring(#out2) or tostring(out2)))
end
-- ISIZE меньше/больше реального
local z = file.read_bytes("export:alpha_probe_zlib.bin")
for _, n in ipairs({40000, 81920, 100000}) do
    local ok, out = pcall(codec.inflate_zlib, z, n)
    log(("ISIZE=%d: ok=%s len=%s"):format(n, tostring(ok), ok and tostring(#out) or tostring(out)))
end
log("done")
