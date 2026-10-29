-- wasmrt в меню (графика canvas, без мира): открывает страницу wasmrt_app с программой из
-- манифеста. Манифест — из export:wasmrt_manifest.txt, по умолчанию wasmdemo:wasm.json.
-- Маркеры: [wasmrt] ... started, [wasmrt_page] ready.
local manifest = "wasmdemo:wasm.json"
if file.isfile("export:wasmrt_manifest.txt") then
    manifest = file.read("export:wasmrt_manifest.txt"):gsub("%s+$", "")
end
-- Паки: пак манифеста; манифесту вне паков (export:, user:, config:, например export:membench/*.json)
-- нужны паки из его полей module / files / extension ("doom:wads" -> doom).
local NOT_PACKS = { export = true, user = true, config = true, wasmrt = true }
local packs, seen = { "wasmrt" }, { wasmrt = true }
local function add_pack(path)
    local pack = type(path) == "string" and path:match("^([^:]+):")
    if pack and not NOT_PACKS[pack] and not seen[pack] then
        seen[pack] = true
        packs[#packs + 1] = pack
    end
end
add_pack(manifest)
local manifest_pack = manifest:match("^([^:]+):")
if NOT_PACKS[manifest_pack] and file.isfile(manifest) then
    local ok, m = pcall(function() return json.parse(file.read(manifest)) end)
    if ok and type(m) == "table" then
        add_pack(m.module)
        add_pack(m.files)
        add_pack(m.extension)
    else
        debug.log("[wasmrt_page] manifest not parsed: " .. tostring(m))
    end
end
debug.log("[wasmrt_page] manifest " .. manifest .. ", packs " .. table.concat(packs, " "))
app.config_packs(packs)
app.load_content()
app.tick()
require("wasmrt:app").set_pending(manifest)
menu.page = "wasmrt_app"

events.on("wasmrt:leave_to_menu", function()
    time.post_runnable(function()
        app.reset_content()
        menu:reset()
        menu.page = "main"
    end)
end)
app.sleep(1)
debug.log("[wasmrt_page] ready")
