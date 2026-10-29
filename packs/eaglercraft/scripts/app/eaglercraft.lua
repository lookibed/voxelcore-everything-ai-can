-- Сценарий меню «Сценарии»: Eaglercraft (Minecraft 1.5.2, TeaVM -> wasm -> Lua) на странице меню
-- wasmrt, манифест eaglercraft:wasm.json (тот же путь, что tools/scenarios/wasmrt_page.lua).
-- Одиночной игре нужен внешний сервер: оригинальный classes_server.js в Node (Spider,
-- tests/manual/real-world-eaglercraft/native_server/launcher.js, TCP 127.0.0.1:25599); из Lua его
-- не запустить. Сначала пробуем порт: не отвечает — страница с сообщением вместо игры
-- (иначе мир «висел» бы на Connecting). Маркеры: [eaglercraft_app] server ok|server down, ready.
local HOST, PORT = "127.0.0.1", 25599
local LAUNCHER = "/root/Spider/tests/manual/real-world-eaglercraft/native_server/launcher.js"

app.config_packs({ "wasmrt", "eaglercraft" })
app.load_content()
app.tick()

local result = nil
local ok, err = pcall(network.tcp_connect, HOST, PORT, function(sock)
    result = "ok"
    pcall(sock.close, sock)
end, function(_, e)
    result = "fail: " .. tostring(e)
end)
if not ok then result = "fail: " .. tostring(err) end
local t0 = time.uptime()
while result == nil and time.uptime() - t0 < 3 do
    app.sleep(0.05)
end
result = result or "fail: timeout 3 s"

local wasmrt = require("wasmrt:app")
if result == "ok" then
    debug.log(("[eaglercraft_app] server ok %s:%d"):format(HOST, PORT))
    wasmrt.set_pending("eaglercraft:wasm.json")
else
    debug.log(("[eaglercraft_app] server down %s:%d (%s)"):format(HOST, PORT, result))
    wasmrt.set_notice({
        ("Сервер Eaglercraft не запущен: %s:%d не отвечает (%s)."):format(HOST, PORT, result),
        "Одиночной игре нужен внешний Node-сервер (оригинальный classes_server.js).",
        "Запустите его в WSL:",
        "    node " .. LAUNCHER,
        "(или MCP eag_start), затем вернитесь в меню и откройте сценарий снова.",
    })
end
menu.page = "wasmrt_app"

-- Событие приходит, когда корутина сценария уже завершилась, а перезагружать контент
-- можно только из неё или из post_runnable (stdlib: call_in_app_script_co).
events.on("wasmrt:leave_to_menu", function()
    time.post_runnable(function()
        app.reset_content()
        menu:reset()
        menu.page = "main"
    end)
end)
app.sleep(1)
debug.log("[eaglercraft_app] ready")
