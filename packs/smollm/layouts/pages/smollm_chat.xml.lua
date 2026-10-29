-- Страница чата smollm: запускает программу wasmrt (smollm:wasm.json, расширение llm_host) и крутит её тики
-- таймером документа; лента, статус и ввод — из состояния modules/llm_host.lua.
local app_module = require "wasmrt:app"
local host = require "smollm:llm_host"
local launch = require "smollm:launch"

local TIMER_INTERVAL_MS = 4
local CTX_MAX = 512
local app = nil
local last_status = nil

local function ui_tick()
    if app then app:tick() end
    if host.dirty then
        host.dirty = false
        local text = host.render_transcript()
        local log_box = document.log
        if log_box and log_box.exists then log_box.text = text end
        local st = host.status_text(CTX_MAX)
        if st ~= last_status then
            last_status = st
            local label = document.status
            if label and label.exists then label.text = st end
        end
    end
    if app and app.status ~= "running" and host.status.phase ~= 4 then
        host.status = { phase = 4, a = 0, b = 0, c = 0 }
        host.dirty = true
        debug.log("[smollm] program " .. tostring(app.status) .. ": " .. tostring(app.message))
    end
end

function on_open()
    local manifest = launch.manifest()
    local ok, result = pcall(app_module.start, manifest, document, { parent = document.canvas_box })
    if not ok then
        debug.log("[smollm] start failed: " .. tostring(result))
        host.status = { phase = 4, a = -1, b = 0, c = 0 }
        host.dirty = true
    else
        app = result
        app_module.current = app
    end
    document.root:setInterval(TIMER_INTERVAL_MS, ui_tick)
    host.dirty = true
    ui_tick()
    debug.log("[smollm] page open, manifest " .. manifest)
end

function on_submit(text)
    if host.submit(text) then
        document.prompt.text = ""
    end
end

function send_click()
    on_submit(document.prompt.text)
end

function stop_click() host.stop() end
function remember_click(checked) host.set_remember(checked) end
function reset_click() host.reset() end

function leave()
    if app then app:stop() end
    app = nil
    events.emit("wasmrt:leave_to_menu")
end

function on_close()
    if app then app:stop() end
    app = nil
end
