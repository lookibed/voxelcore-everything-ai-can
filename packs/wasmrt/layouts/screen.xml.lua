local app_module = require "wasmrt:app"
local app = nil

function on_open()
    app = app_module.attach(document)
end

function on_close()
    if app then app:stop() end
end
