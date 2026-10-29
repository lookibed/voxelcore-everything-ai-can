-- Замер (headless 0.32 --test): сколько стоит миру построить и закодировать TickInput песочнице на 500 скриптовых
-- сущностей (olife_world:sandbox send_input): индекс вида (sbmeter.view_index), таблицы входов, json.tostring.
-- Запуск: lab run olife D:\...\tools\olife\tests\bench_tickinput.lua
app.reconfig_packs({"base", "olife_proto", "olife_world"}, {})
if not app.is_content_loaded() then app.load_content() end
local MT = require "olife_world:sbmeter"
local now = function() return time.precise_utc_time() * 1000 end
local spawn = {x = 8.5, y = 70, z = 8.5}
local slots = MT.slots(spawn)
local ents = {}
for i = 1, 500 do
    local p = slots[i]
    ents[i] = {eid = i, kind = 3, owner = math.floor((i - 1) / 10) + 1,
               pos = {x = p.x + math.sin(i) * 1.37, y = p.y, z = p.z + math.cos(i) * 2.11},
               rot = {x = 0, y = (i * 37) % 360 + 0.123456789, z = 0}, vel = {x = 0, y = 0, z = 0}}
end
local function build(with_view, round)
    local t0 = now()
    local view_of = MT.view_index(ents)
    local t1 = now()
    local list = {}
    local nview = 0
    for i = 1, #ents do
        local e = ents[i]
        local ent = {eid = e.eid, owner = e.owner, pos = {e.pos.x, e.pos.y, e.pos.z},
                     rot = {e.rot.x, e.rot.y, e.rot.z}, vel = {e.vel.x, e.vel.y, e.vel.z}}
        if with_view then
            local v = view_of(e)
            nview = nview + #v
            if #v > 0 then ent.view = v end
        end
        list[#list + 1] = ent
    end
    local t2 = now()
    local line = json.tostring({type = "tick", tick = 1, seed = 1, dt = 0.05, entities = list}) .. "\n"
    local t3 = now()
    return t1 - t0, t2 - t1, t3 - t2, #line, nview
end
for _, mode in ipairs({{"view", true}, {"no view", false}}) do
    local acc = {0, 0, 0}
    local bytes, nv
    for k = 1, 30 do
        local a, b, c, n, v = build(mode[2])
        if k > 5 then acc[1], acc[2], acc[3] = acc[1] + a, acc[2] + b, acc[3] + c end
        bytes, nv = n, v
    end
    print(string.format("[bench_tickinput] %s: index %.2f ms, inputs+view %.2f ms, json.tostring %.2f ms, line %d B, view items %d",
        mode[1], acc[1] / 25, acc[2] / 25, acc[3] / 25, bytes, nv))
end
-- hand-built JSON line (table.concat of number strings) instead of json.tostring of nested tables
local fmt, concat, tostr = string.format, table.concat, tostring
local function num(x) return tostr(x) end   -- LuaJIT tostring: %.14g
local function manual()
    local t0 = now()
    local view_of = MT.view_index(ents)
    local b, n = {'{"type":"tick","tick":1,"seed":1,"dt":0.05,"entities":['}, 1
    local nview = 0
    for i = 1, #ents do
        local e = ents[i]
        local p, r, v = e.pos, e.rot, e.vel
        n = n + 1
        b[n] = (i > 1 and ',' or '') .. '{"eid":' .. e.eid .. ',"owner":' .. e.owner .. ',"pos":[' .. num(p.x) .. ',' ..
            num(p.y) .. ',' .. num(p.z) .. '],"rot":[' .. num(r.x) .. ',' .. num(r.y) .. ',' .. num(r.z) .. '],"vel":[' ..
            num(v.x) .. ',' .. num(v.y) .. ',' .. num(v.z) .. ']'
        local vw = view_of(e)
        if #vw > 0 then
            nview = nview + #vw
            n = n + 1
            b[n] = ',"view":['
            for k = 1, #vw do
                local o = vw[k]
                n = n + 1
                b[n] = (k > 1 and ',{"eid":' or '{"eid":') .. o.eid .. ',"kind":' .. o.kind .. ',"pos":[' .. num(o.pos[1]) ..
                    ',' .. num(o.pos[2]) .. ',' .. num(o.pos[3]) .. ']}'
            end
            n = n + 1
            b[n] = ']'
        end
        n = n + 1
        b[n] = '}'
    end
    n = n + 1
    b[n] = ']}\n'
    local line = concat(b)
    return now() - t0, #line, nview, line
end
do
    local acc, bytes, nv, line = 0
    for k = 1, 30 do
        local ms, nb, v, l = manual()
        if k > 5 then acc = acc + ms end
        bytes, nv, line = nb, v, l
    end
    local ok, t = pcall(json.parse, line)
    print(string.format("[bench_tickinput] manual JSON (index+inputs+encode): %.2f ms, line %d B, view items %d, parses back: %s %s",
        acc / 25, bytes, nv, tostring(ok), ok and tostring(#t.entities) or tostring(t)))
end
-- the reply side: json.parse of a TickResult of 500 entities x 2 actions + meter
local res = {}
for i = 1, 500 do
    res[i] = {eid = i, owner = 1, status = "ok", actions = {{op = "set_pos", pos = {1.2345678901, 70, 3.14159265}},
              {op = "set_rot", rot = {0, 123.456789, 0}}}, meter = {fuel = 120000, api_calls = 2, api_credits = 2,
              credits = 14, alloc_bytes = 2000, actions_dropped = 0}}
end
local line = json.tostring({type = "tick_result", tick = 1, entities = res, owners = {}, wall_us = 4000})
local t0 = now()
for k = 1, 25 do local _ = json.parse(line) end
print(string.format("[bench_tickinput] json.parse TickResult %d B: %.2f ms", #line, (now() - t0) / 25))
