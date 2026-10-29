-- Проба UI: canvas + Bytearray + create_texture + <image> с масштабированием.
local W, H = 160, 144
local function log(m) debug.log("[ui_probe] " .. m) end

gui.root.root:add(string.format('<canvas id="probe_canvas" size="%d,%d" pos="20,60"/>', W, H))
local canvas = gui.root.probe_canvas
log("canvas exists=" .. tostring(canvas.exists))

-- шахматка 8x8 + градиент, чтобы было видно размытие
local buf = Bytearray(W * H * 4)
local p = buf.bytes
local t0 = os.clock()
for y = 0, H - 1 do
    for x = 0, W - 1 do
        local i = (y * W + x) * 4
        local on = (math.floor(x / 8) + math.floor(y / 8)) % 2 == 0
        p[i] = on and 255 or x
        p[i + 1] = on and 255 or y
        p[i + 2] = on and 255 or 64
        p[i + 3] = 255
    end
end
log(("fill Bytearray %.4fs size=%d type=%s"):format(os.clock() - t0, #buf, type(buf)))

local data = canvas.data
t0 = os.clock()
for _ = 1, 100 do
    data:set_data(buf)
    data:update()
end
log(("100x set_data(Bytearray)+update %.4fs"):format(os.clock() - t0))

local tbl = {}
for i = 1, W * H * 4 do tbl[i] = p[i - 1] end
t0 = os.clock()
for _ = 1, 100 do
    data:set_data(tbl)
    data:update()
end
log(("100x set_data(table)+update %.4fs"):format(os.clock() - t0))

local ok, err = pcall(function() data:create_texture("probe_tex") end)
log("create_texture ok=" .. tostring(ok) .. " " .. tostring(err))
gui.root.root:add('<image id="probe_image" src="probe_tex" size="480,432" pos="220,60" region="0,1,1,0"/>')
log("image exists=" .. tostring(gui.root.probe_image.exists))
log("done")
