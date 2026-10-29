-- Lightweight per-frame profiler of the pack (performance suite, tools/alphamine/perf/, agents/ALPHAMINE.md
-- "Производительность").
--
-- Clock: QueryPerformanceCounter through the LuaJIT ffi (wall clock, ~0.1 us; os.clock() on this engine build has
-- 1 ms steps) with os.clock() as the fallback. Works the same in F2F (virtual engine time) and in a normal launch:
-- the profiler measures real CPU/wall cost, not game time.
--
-- Sections are exclusive: push(name) ... pop() subtracts the time of nested sections from the outer one, so the
-- columns of a row add up (net = parsing only, inflate/store of MapChunk are their own columns).
-- Frame boundary = start of alphamine:game.frame (per-frame hook on_render of the am_frame entity, before the
-- world pass). A row covers [previous hook, this hook): the previous frame's world render + HUD + swap and this
-- frame's engine update (on_world_tick). Extra intervals measured inside the frame:
--   world_ms  = end of the stdcomp.render wrapper (hand/particles) -> start of on_hud_render: the engine's world
--               pass (chunk meshes upload, draw calls; the GPU runs asynchronously)
--   other_ms  = frame_ms - all pack sections - world_ms: engine update (chunk lighting, meshing hand-off, physics
--               of the engine), HUD/UI draw, swap + vsync/frame limiter, idle (F2F: waiting for the next command)
-- Ring buffer of N rows (columns as flat arrays); dump(path) writes CSV rows since `from` (normal launch: parts
-- every 5 s into export:alphamine_perf/<run>/part_NNNN.csv when export:alphamine_perf.txt exists; F2F: `perf`).
local t_start_ref   -- set below (frames): start of the profile, the time base of samples
local M = {
    on = false,
    N = 65536,
    rows = 0,              -- rows written since reset (ring index = rows % N)
    dumped = 0,            -- rows already written by the periodic dump
    clock_kind = "os.clock",
    run = nil,             -- normal launch: run name from export:alphamine_perf.txt
    part = 0,
    opts = {},             -- experiment switches from export:alphamine_perf.txt (normal launch only)
}

-- ------------------------------------------------------------------ clock
local clock = os.clock
do
    local ok, err = pcall(function()
        -- stdlib.lua removes the global `ffi` after start-up (`ffi = nil`), the module stays in package.loaded
        local ffi = ffi or (package and package.loaded and package.loaded.ffi)
        if not ffi and debug and debug.getregistry then
            local reg = debug.getregistry()
            ffi = reg and reg._LOADED and reg._LOADED.ffi
        end
        if not ffi then error("no ffi") end
        pcall(ffi.cdef, [[
            int QueryPerformanceCounter(int64_t *count);
            int QueryPerformanceFrequency(int64_t *freq);
        ]])
        local c = ffi.new("int64_t[1]")
        if ffi.C.QueryPerformanceFrequency(c) == 0 then error("QPF failed") end
        local inv = 1 / tonumber(c[0])
        local qpc = ffi.C.QueryPerformanceCounter
        local t = function() qpc(c); return tonumber(c[0]) * inv end
        local a = t()
        if type(a) ~= "number" or a <= 0 then error("QPC failed") end
        clock = t
    end)
    if ok then M.clock_kind = "qpc" else M.clock_error = tostring(err) end
end
-- F2F builds with the engine profiler: f2f.now_us() (steady_clock, us; the same base as the engine trace)
if M.clock_kind ~= "qpc" and type(f2f) == "table" and type(f2f.now_us) == "function" then
    local now_us = f2f.now_us
    if pcall(now_us) then
        clock = function() return now_us() * 1e-6 end
        M.clock_kind = "f2f.now_us"
    end
end
M.clock = clock

-- ------------------------------------------------------------------ columns
-- exclusive pack sections (ms per frame)
local SECTIONS = {"tick", "net", "inflate", "store", "physics", "texfx", "fx_upload", "ents_tick", "lm_write",
                  "lm_setdata", "lm_upload", "encode", "setdata", "bc_flush", "frame", "ents_frame", "hand", "particles",
                  "hud", "gui", "dump"}
-- counters per frame
local COUNTERS = {"ticks", "map_chunks", "pre_chunks", "applied", "lm_writes", "lm_uploads", "block_changes",
                  "bytes_in", "bc_deferred", "bc_applied"}
M.SECTIONS, M.COUNTERS = SECTIONS, COUNTERS

local acc, cnt = {}, {}
for _, s in ipairs(SECTIONS) do acc[s] = 0 end
for _, s in ipairs(COUNTERS) do cnt[s] = 0 end

-- ring columns
local col = {}
local FIXED = {"t", "frame_ms", "engine_ms", "world_ms", "lua_ms", "other_ms", "gc_kb", "gc_step", "dirty",
               "engine_chunks", "x", "z", "phase"}
M.FIXED = FIXED
local function alloc()
    col = {}
    for _, c in ipairs(FIXED) do col[c] = {} end
    for _, c in ipairs(SECTIONS) do col[c] = {} end
    for _, c in ipairs(COUNTERS) do col[c] = {} end
end
alloc()

-- ------------------------------------------------------------------ sections (exclusive, stack)
local st_name, st_t0, st_child = {}, {}, {}
local depth = 0

function M.push(name)
    if not M.on then return end
    depth = depth + 1
    st_name[depth], st_t0[depth], st_child[depth] = name, clock(), 0
end

function M.pop()
    if not M.on or depth == 0 then return end
    local el = clock() - st_t0[depth]
    local n = st_name[depth]
    acc[n] = (acc[n] or 0) + (el - st_child[depth]) * 1e3
    depth = depth - 1
    if depth > 0 then st_child[depth] = st_child[depth] + el end
end

function M.count(name, n)
    if not M.on then return end
    cnt[name] = (cnt[name] or 0) + (n or 1)
end

-- per-event samples (t, name, value), e.g. the delay MapChunk -> world.set_chunk_data of every written chunk; written
-- next to the frame rows (normal launch: samples_NNNN.csv with every part; F2F dump: <path>.samples.csv)
local smp_t, smp_n, smp_v = {}, {}, {}
local smp_dumped = 0
function M.sample(name, v)
    if not M.on then return end
    local t0 = t_start_ref and t_start_ref()
    if not t0 then return end
    local i = #smp_t + 1
    smp_t[i], smp_n[i], smp_v[i] = clock() - t0, name, v
end
local function samples_csv(from)
    local out = {"t,name,value"}
    for i = from + 1, #smp_t do
        out[#out + 1] = ("%.4f,%s,%.3f"):format(smp_t[i], smp_n[i], smp_v[i])
    end
    return table.concat(out, "\n") .. "\n", #smp_t - from
end

-- world pass interval: mark(end of the pre-render wrapper), then world_end() at on_hud_render
local world_t0, world_ms = nil, 0
function M.world_begin()
    if M.on then world_t0 = clock() end
end
function M.world_end()
    if M.on and world_t0 then
        world_ms = world_ms + (clock() - world_t0) * 1e3
        world_t0 = nil
    end
end

-- ------------------------------------------------------------------ frames
local t_start, t_last = nil, nil
t_start_ref = function() return t_start end
local last_gc = 0
M.phase = 0          -- set by the autowalk program (0 idle/loading, 1 stand, 2 walk, 3 settle, 4 done)
M.info = nil         -- function() -> dirty, engine_chunks, x, z (set by alphamine:game)

function M.reset()
    alloc()
    smp_t, smp_n, smp_v, smp_dumped = {}, {}, {}, 0
    M.rows, M.dumped, M.part = 0, 0, 0
    t_start, t_last = nil, nil
    depth, world_t0, world_ms = 0, nil, 0
    for k in pairs(acc) do acc[k] = 0 end
    for k in pairs(cnt) do cnt[k] = 0 end
end

function M.start()
    if not M.on then
        M.on = true
        M.reset()
    end
end

function M.stop()
    M.on = false
end

-- at the frame hook: close the row of the previous frame
function M.frame_boundary()
    if not M.on then return end
    local now = clock()
    if not t_last then
        t_start, t_last = now, now
        for k in pairs(acc) do acc[k] = 0 end
        for k in pairs(cnt) do cnt[k] = 0 end
        world_ms = 0
        last_gc = collectgarbage("count")
        return
    end
    depth = 0   -- a section left open by an error must not leak into the next row
    local i = M.rows % M.N + 1
    local frame_ms = (now - t_last) * 1e3
    local lua = 0
    for _, s in ipairs(SECTIONS) do
        local v = acc[s]
        col[s][i] = v
        lua = lua + v
        acc[s] = 0
    end
    for _, s in ipairs(COUNTERS) do
        col[s][i] = cnt[s]
        cnt[s] = 0
    end
    local gc = collectgarbage("count")
    col.t[i] = now - t_start
    col.frame_ms[i] = frame_ms
    local okd, d = pcall(time.delta)
    col.engine_ms[i] = okd and d and d * 1e3 or 0
    col.world_ms[i] = world_ms
    col.lua_ms[i] = lua
    col.other_ms[i] = frame_ms - lua - world_ms
    col.gc_kb[i] = gc
    col.gc_step[i] = gc - last_gc     -- < 0: a GC cycle freed memory during this frame
    last_gc = gc
    local dirty, ec, x, z = 0, 0, 0, 0
    if M.info then
        local ok, a, b, c, e = pcall(M.info)
        if ok then dirty, ec, x, z = a or 0, b or 0, c or 0, e or 0 end
    end
    col.dirty[i], col.engine_chunks[i], col.x[i], col.z[i] = dirty, ec, x, z
    col.phase[i] = M.phase
    world_ms = 0
    M.rows = M.rows + 1
    t_last = now
end

-- ------------------------------------------------------------------ CSV
local function header()
    local h = {}
    for _, c in ipairs(FIXED) do h[#h + 1] = c end
    for _, c in ipairs(SECTIONS) do h[#h + 1] = c end
    for _, c in ipairs(COUNTERS) do h[#h + 1] = c end
    return table.concat(h, ",")
end

local function fmt(v)
    if v == math.floor(v) and v > -1e9 and v < 1e9 then return tostring(math.floor(v)) end
    return ("%.4f"):format(v)
end

-- rows [from, M.rows) that are still in the ring -> CSV text
function M.csv(from)
    from = math.max(from or 0, M.rows - M.N, 0)
    local out = {header()}
    local names = {}
    for _, c in ipairs(FIXED) do names[#names + 1] = c end
    for _, c in ipairs(SECTIONS) do names[#names + 1] = c end
    for _, c in ipairs(COUNTERS) do names[#names + 1] = c end
    local line = {}
    for r = from, M.rows - 1 do
        local i = r % M.N + 1
        for k, c in ipairs(names) do line[k] = fmt(col[c][i] or 0) end
        out[#out + 1] = table.concat(line, ",")
    end
    return table.concat(out, "\n") .. "\n", M.rows - from
end

-- F2F `perf {dump:path}`: all rows in the ring
function M.dump(path)
    local text, n = M.csv(0)
    file.write(path, text)
    if #smp_t > 0 then file.write(path .. ".samples.csv", (samples_csv(0))) end
    return n
end

-- summary for F2F `perf` / logs
function M.summary()
    local n = math.min(M.rows, M.N)
    local s = {rows = M.rows, clock = M.clock_kind, phase = M.phase, sections = {}}
    for _, c in ipairs(SECTIONS) do
        local sum = 0
        for i = 1, n do sum = sum + (col[c][i] or 0) end
        s.sections[c] = sum
    end
    return s
end

-- ------------------------------------------------------------------ normal launch: export:alphamine_perf.txt
-- file content: `run=<name>` (optional, default "run"); parts: export:alphamine_perf/<run>/part_NNNN.csv
local DIR = "export:alphamine_perf"
function M.config_normal()
    if not file.isfile("export:alphamine_perf.txt") then return false end
    local txt = file.read("export:alphamine_perf.txt") or ""
    M.run = txt:match("run%s*=%s*([%w_%-%.]+)") or "run"
    M.period = tonumber(txt:match("period%s*=%s*([%d%.]+)") or "") or 5
    -- experiment switches (attribution runs): key=value words after the run line, e.g. `lm_upload=off`
    for k, v in txt:gmatch("([%w_]+)%s*=%s*([%w_%.%-]+)") do
        if k ~= "run" and k ~= "period" then M.opts[k] = tonumber(v) or v end
    end
    pcall(file.mkdirs, DIR .. "/" .. M.run)
    M.start()
    M.next_dump = nil
    if M.clock_error then debug.log("[alphamine_perf] qpc clock unavailable: " .. M.clock_error) end
    local o = {}
    for k, v in pairs(M.opts) do o[#o + 1] = k .. "=" .. tostring(v) end
    debug.log(("[alphamine_perf] profiling on (clock %s), parts every %.0f s -> %s/%s/, switches: %s"):format(
        M.clock_kind, M.period, DIR, M.run, table.concat(o, " ")))
    return true
end

-- called once per frame in a normal launch; the dump's own cost goes to the `dump` column of the next row
function M.periodic(force)
    if not M.on or not M.run then return end
    local now = clock()
    if not M.next_dump then M.next_dump = now + M.period end
    if not force and now < M.next_dump then return end
    M.next_dump = now + M.period
    if M.rows <= M.dumped then return end
    M.push("dump")
    local text, n = M.csv(M.dumped)
    M.part = M.part + 1
    local path = ("%s/%s/part_%04d.csv"):format(DIR, M.run, M.part)
    local ok, err = pcall(file.write, path, text)
    M.dumped = M.rows
    if #smp_t > smp_dumped then
        pcall(file.write, ("%s/%s/samples_%04d.csv"):format(DIR, M.run, M.part), (samples_csv(smp_dumped)))
        smp_dumped = #smp_t
    end
    M.pop()
    if not ok then debug.log("[alphamine_perf] dump failed: " .. tostring(err)) end
    return path, n
end

return M
