local app_module = require "wasmrt:app"
local app = nil

function on_open()
    app = app_module.attach(document)
end

-- Выход в меню делает app-скрипт сценария по событию (reset_content — только из него).
function leave()
    if app then app:stop() end
    app = nil
    events.emit("wasmrt:leave_to_menu")
end

function on_close()
    if app then app:stop() end
end
