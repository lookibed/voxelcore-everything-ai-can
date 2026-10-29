local fx = require "blackhole:fx"

function on_hud_open(pid)
    fx.open(pid)
end

function on_hud_render()
    fx.render()
end

function on_hud_close(pid)
    fx.close()
end
