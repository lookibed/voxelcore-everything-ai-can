-- Стикер «ПКМ — сесть за компьютер» (pc_hint.xml): виден, когда игрок не за ПК и смотрит на компьютер.
local pc_os = require "pc_wasmrt:pc_os"
local TEXT = "ПКМ - сесть за компьютер"
local W = 260
local vw, vh = 0, 0

local function layout()
    local vp = gui.get_viewport()
    vw, vh = vp[1], vp[2]
    local x, y = math.floor(vw / 2 - W / 2), math.floor(vh / 2 + 36)
    document.hint.pos = { x, y }
end

function on_open()
    document.hint_lbl.text = TEXT
    layout()
    document.root:setInterval(50, function()
        local vp = gui.get_viewport()
        if vp[1] ~= vw or vp[2] ~= vh then layout() end
        local want = pc_os.hint_wanted()
        if want ~= pc_os.hint_shown then
            pc_os.hint_shown = want
            document.hint.visible = want
        end
    end)
end
