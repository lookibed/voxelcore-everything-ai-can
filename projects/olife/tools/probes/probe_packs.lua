-- Проба 0.32 (headless --test), волна 4b: что позволяет горячая перезагрузка паков — запись в world:content,
-- приоритет world:content после reopen_world, load() исходника, sha256, pack.get_info.
local function p(...) print("[probe]", ...) end
app.reconfig_packs({"base", "olife_client"}, {})
app.new_world("packs_probe", "1", "core:default")
p("sha256 type/len", type(crypto.sha256("abc")), #crypto.sha256("abc"))
local info = pack.get_info("olife_client")
p("pack info", json.tostring(info))
p("sources", json.tostring(app.get_content_sources()))
local src = file.read("olife_client:modules/bot.lua")
p("read via pack path", #src)
local f, err = load("return 40 + 2", "=probe")
p("load", type(f), err, f and f())
local ok, e = pcall(file.mkdirs, "world:content/olife_client/modules")
p("mkdirs world:content", ok, e)
-- full pack copy into world:content (as the client does), with a marker module
local n = 0
local function copy(rel)
    local d = "olife_client:" .. rel
    for _, fp in ipairs(file.list(d)) do
        local r = fp:sub(#"olife_client:" + 1)
        if file.isdir(fp) then copy(r) else
            local dst = "world:content/olife_client/" .. r
            pcall(file.mkdirs, dst:match("^(.*)/[^/]+$"))
            file.write_bytes(dst, file.read_bytes(fp)); n = n + 1
        end
    end
end
local okc, ec = pcall(copy, "")
p("copied", okc, ec, n)
file.write("world:content/olife_client/modules/rev.lua", "return {rev = 7}")
p("written", file.exists("world:content/olife_client/modules/rev.lua"))
p("before reopen: rev via pack path", file.exists("olife_client:modules/rev.lua"))
app.save_world()
local okr, er = pcall(app.reopen_world)
p("reopen", okr, er, world.is_open())
local info2 = pack.get_info("olife_client")
p("pack info after", json.tostring(info2))
p("after reopen: rev via pack path", file.exists("olife_client:modules/rev.lua"))
local okq, rv = pcall(require, "olife_client:rev")
p("require rev", okq, okq and json.tostring(rv) or rv)
p("content", json.tostring(app.get_content()))
app.close_world(false)
p("done")
