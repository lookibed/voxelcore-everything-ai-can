-- olife_world:prof — wave 5p (agent olife_w5p): per-tick phase profiler of the world and LuaJIT trace statistics.
-- Off by default (one `if P.on` per instrumented point). On with `--opts prof=1`: every tick one CSV row in
-- user:export/world_prof.csv (fixed columns COLS, milliseconds by time.precise_time — steady clock, 0.1 us step, ~40 ns
-- per call), and with `jitlog=1` the trace events of LuaJIT (jit.attach "trace": start/stop/abort/flush) are counted
-- per tick and aggregated by function and abort reason -> user:export/world_jit.txt (`olife.jit` command / at stop).
-- Columns: phases of server.tick and their sub-steps (see agents/research/OLIFE_WORLD_PERF.md), events of the tick
-- (frames, chunks sent, keyframe sessions, TickResults applied/late), GC (KB at tick start/end, freed between ticks),
-- engine time between ticks (`gap`: end of the previous tick's post-work -> start of this tick).
local M = {on = false, jitlog = false}
local clock = time.precise_time
local function now() return clock() * 1000 end
M.now = now

M.COLS = {
    -- 1 incoming
    "in_recv", "in_frames", "h_move", "h_block", "h_inv", "h_other", "admin",
    -- 2 sandbox TickResult
    "sb_recv", "sb_decode", "sb_conv", "sb_apply", "sb_results",
    -- 3 world
    "w_ents", "w_move", "w_inv", "w_rehash", "w_editor",
    -- 4 replication
    "r_blocks", "r_terms", "r_interest", "r_snap", "r_full", "r_editor", "r_move", "r_inv", "r_sync",
    -- 4b TickInput
    "si_list", "si_index", "si_view", "si_events", "si_encode",
    -- 5 send
    "s_net", "s_sb",
    -- after the tick (outside the measured tick time)
    "post_states", "post_rows", "post_sup", "post_gc",
    -- Lua heap growth (KB) per phase (collectgarbage("count") deltas; negative when a GC cycle finished inside)
    "kb_in", "kb_sb", "kb_world", "kb_repl", "kb_si", "kb_send", "kb_post",
}
local acc, cnt = {}, {}
for _, c in ipairs(M.COLS) do acc[c] = 0 end
M.acc = acc
M.CNT = {"frames", "chunks", "keyframes", "results", "late", "skipped", "sessions", "entities", "gc_cycles",
         "tr_start", "tr_stop", "tr_abort", "tr_flush"}
for _, c in ipairs(M.CNT) do cnt[c] = 0 end
M.cnt = cnt

function M.add(name, dt) acc[name] = acc[name] + dt end
local kb_last = 0
-- heap growth since the previous mark -> column `name`
function M.kb(name)
    local k = collectgarbage("count")
    if name then acc[name] = acc[name] + (k - kb_last) end
    kb_last = k
end
function M.inc(name, n) cnt[name] = cnt[name] + (n or 1) end

local out, rows = nil, 0
local tick_t0, prev_end, kb0, prev_kb_end = 0, nil, 0, nil
local ph = {0, 0, 0, 0, 0}

function M.init(cfg)
    M.on = (cfg.prof or 0) ~= 0
    M.jitlog = (cfg.jitlog or 0) ~= 0
    if M.on then
        local ok, s = pcall(file.open, "user:export/world_prof.csv", "w")
        if ok then out = s else print("[olife_world] prof: cannot open csv: " .. tostring(s)) end
        if out then
            local h = {"tick", "t_ms", "tick_ms", "ph_in", "ph_sb", "ph_world", "ph_repl", "ph_send", "post", "gap",
                       "kb_start", "kb_end", "kb_freed_between"}
            for _, c in ipairs(M.COLS) do h[#h + 1] = c end
            for _, c in ipairs(M.CNT) do h[#h + 1] = c end
            out:write_line(table.concat(h, ","))
        end
    end
    if M.jitlog then M.attach() end
end

-- server.tick: start of the tick (before phase 1)
function M.tick_begin()
    tick_t0 = now()
    kb0 = collectgarbage("count")
end

-- server.tick: the five phase times (ms) of this tick
function M.phases(a, b, c, d, e) ph[1], ph[2], ph[3], ph[4], ph[5] = a, b, c, d, e end

-- server.tick: end of everything (after the post-tick exports) -> one CSV row, reset accumulators
local fmt = string.format
function M.tick_end(tick, tick_ms, post_ms)
    local kb1 = collectgarbage("count")
    if out then
        local gap = prev_end and (tick_t0 - prev_end) or 0
        local freed = prev_kb_end and (prev_kb_end - kb0) or 0       -- > 0: a GC cycle (or more) ran between ticks
        local l = {tick, fmt("%.3f", tick_t0), fmt("%.3f", tick_ms), fmt("%.3f", ph[1]), fmt("%.3f", ph[2]),
                   fmt("%.3f", ph[3]), fmt("%.3f", ph[4]), fmt("%.3f", ph[5]), fmt("%.3f", post_ms),
                   fmt("%.3f", gap), fmt("%.0f", kb0), fmt("%.0f", kb1), fmt("%.0f", freed)}
        for _, c in ipairs(M.COLS) do l[#l + 1] = (c:sub(1, 3) == "kb_") and fmt("%.0f", acc[c]) or fmt("%.3f", acc[c]) end
        for _, c in ipairs(M.CNT) do l[#l + 1] = cnt[c] end
        out:write_line(table.concat(l, ","))
        rows = rows + 1
        if rows % 20 == 0 then out:flush() end
    end
    for _, c in ipairs(M.COLS) do acc[c] = 0 end
    for _, c in ipairs(M.CNT) do cnt[c] = 0 end
    prev_end, prev_kb_end = now(), collectgarbage("count")
end

function M.close()
    if out then out:flush(); out:close(); out = nil end
    if M.jitlog then M.dump_jit() end
end

-- ------------------------------------------------------------------ LuaJIT trace events (jit.attach)
-- traceerr / bcnames: lj_traceerr.h / lj_bc.h of the engine's own LuaJIT 2.1.1788856981 (vcpkg c6ffc141,
-- <repo>\builds\vcpkg-032\buildtrees\luajit); bytecodes after JMP (BNOT..) are not named here
local TRACEERR = {[0] = "error thrown or hook called during recording", "trace too short", "trace too long",
    "trace too deep", "too many snapshots", "blacklisted", "retry recording", "NYI: bytecode %s",
    "leaving loop in root trace", "inner loop in root trace", "loop unroll limit reached", "bad argument type",
    "JIT compilation disabled for function", "call unroll limit reached", "down-recursion, restarting",
    "NYI: unsupported variant of FastFunc %s", "NYI: return to lower frame", "store with nil or NaN key",
    "missing metamethod", "looping index lookup", "NYI: mixed sparse/dense table", "symbol not in cache",
    "NYI: unsupported C type conversion", "NYI: unsupported C function type", "guard would always fail",
    "too many PHIs", "persistent type instability", "failed to allocate mcode memory", "machine code too long",
    "hit mcode limit (retrying)", "too many spill slots", "inconsistent register allocation",
    "NYI: cannot assemble IR instruction %d", "NYI: PHI shuffling too complex", "NYI: register coalescing too complex"}
local BCNAMES = "ISLT  ISGE  ISLE  ISGT  ISEQV ISNEV ISEQS ISNES ISEQN ISNEN ISEQP ISNEP ISTC  ISFC  IST   ISF   ISTYPEISNUM MOV   NOT   UNM   LEN   ADDVN SUBVN MULVN DIVVN MODVN ADDNV SUBNV MULNV DIVNV MODNV ADDVV SUBVV MULVV DIVVV MODVV POW   CAT   KSTR  KCDATAKSHORTKNUM  KPRI  KNIL  UGET  USETV USETS USETN USETP UCLO  FNEW  TNEW  TDUP  GGET  GSET  TGETV TGETS TGETB TGETR TSETV TSETS TSETB TSETM TSETR CALLM CALL  CALLMTCALLT ITERC ITERN VARG  ISNEXTRETM  RET   RET0  RET1  FORI  JFORI FORL  IFORL JFORL ITERL IITERLJITERLLOOP  ILOOP JLOOP JMP   FUNCF IFUNCFJFUNCFFUNCV IFUNCVJFUNCVFUNCC FUNCCW"
local jt = {start = 0, stop = 0, abort = 0, flush = 0, aborts = {}, stops = {}, starts = {}, flushes_at = {}}
M.jt = jt

local function where(func)
    local ok, i = pcall(debug.getinfo, func, "S")
    if not ok or not i then return "?" end
    local src = tostring(i.short_src or i.source or "?"):gsub("^.*[/\\:]", "")
    return src .. ":" .. tostring(i.linedefined)
end

local function reason(code, info)
    local r = TRACEERR[code] or ("err " .. tostring(code))
    if r:find("%%s") or r:find("%%d") then
        local x = info
        if code == 7 and type(info) == "number" then x = BCNAMES:sub(info * 6 + 1, info * 6 + 6):gsub("%s+$", "") end
        r = r:gsub("%%[sd]", tostring(x))
    end
    return r .. " [" .. tostring(code) .. "]"
end

function M.attach()
    if not (jit and jit.attach) then print("[olife_world] prof: jit.attach not available"); return end
    jit.attach(function(what, tr, func, pc, otr, oex)
        jt[what] = (jt[what] or 0) + 1
        local key = "tr_" .. tostring(what)
        if cnt[key] then cnt[key] = cnt[key] + 1 end
        if what == "abort" then
            local k = where(func) .. " pc=" .. tostring(pc) .. " " .. reason(otr, oex)
            jt.aborts[k] = (jt.aborts[k] or 0) + 1
        elseif what == "stop" then
            local k = where(func)
            jt.stops[k] = (jt.stops[k] or 0) + 1
        elseif what == "start" then
            local k = where(func)
            jt.starts[k] = (jt.starts[k] or 0) + 1
        elseif what == "flush" then
            jt.flushes_at[#jt.flushes_at + 1] = M.tick or 0
        end
    end, "trace")
end

local function top(t, n)
    local l = {}
    for k, v in pairs(t) do l[#l + 1] = {k, v} end
    table.sort(l, function(a, b) if a[2] ~= b[2] then return a[2] > b[2] end return a[1] < b[1] end)
    local out = {}
    for i = 1, math.min(n, #l) do out[i] = string.format("%7d  %s", l[i][2], l[i][1]) end
    return out, #l
end

function M.jit_summary(n)
    n = n or 40
    local st = {jit and jit.status and jit.status()}
    local lines = {string.format("[olife_world] jit status=%s start=%d stop=%d abort=%d flush=%d (flush at ticks %s)",
        tostring(st[1]), jt.start, jt.stop, jt.abort, jt.flush, table.concat(jt.flushes_at, " "))}
    local a, na = top(jt.aborts, n)
    lines[#lines + 1] = "-- aborts by function:line pc reason (" .. na .. " distinct)"
    for _, l in ipairs(a) do lines[#lines + 1] = l end
    local s, ns = top(jt.stops, n)
    lines[#lines + 1] = "-- compiled traces by root function (" .. ns .. " distinct)"
    for _, l in ipairs(s) do lines[#lines + 1] = l end
    return table.concat(lines, "\n")
end

function M.dump_jit(path)
    path = path or "user:export/world_jit.txt"
    pcall(file.write, path, M.jit_summary(400) .. "\n")
    return path
end

return M
