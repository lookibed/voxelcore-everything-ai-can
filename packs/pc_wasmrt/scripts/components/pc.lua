
local canvas_width = 1023
local canvas_height = 914
local iMouseX, iMouseY, iMouseZ = 0.0, 0.0, 0.0
local iResolutionX, iResolutionY = canvas_width, canvas_height
local pid = 0
local camera_state = true -- true base / false olife
local player_lock = {pos = {}, rot = {}}


-- Экран компьютера — «Windows XP» (modules/pc_os.lua): фрейм gui.create_frame в текстуре $0.
-- Прежний режим пака (ShaderToy "Minecraft" в шейдере сущностей по данным canvas) — ярлык
-- «Minecraft (shader)»: на время режима $0 = canvas texture_shader, данные пишет код ниже.
local pc_os = require "pc_wasmrt:pc_os"

local w,h = canvas_width, canvas_height
local image = nil  -- canvas ShaderToy: создаётся при первом запуске ярлыка
local texture_name = "texture_shader_" .. entity:get_uid()
local rig = entity.skeleton

local function ensure_canvas()
    if image then return end
    image = Canvas({w,h})
    local data = Bytearray(w * h * 4)
    local bytes = data.bytes
    for i = 0, w * h * 4 - 1 do bytes[i] = 255 end
    image:set_data(data)
    image:update()
    image:create_texture(texture_name)
end



-- для положиьельных
local function setFloatData(x, y, p)
    if p == nil then error("setFloatData p == nil") return end
    -- Время в миллисекундах (например, 12.345 секунд -> 12345)
    local millis = math.floor(p * 1000)
    -- Ограничим до 24 бит (максимум, что влезает в RGB)
    millis = math.min(millis, 0xFFFFFF) -- 16777215
    -- Разбираем на байты
    local r = bit.rshift(millis, 16)            -- старший байт
    local g = bit.band(bit.rshift(millis, 8), 0xFF) -- средний байт
    local b = bit.band(millis, 0xFF)            -- младший байт

    image:set(x, y, r, g, b, 255)
end
-- для любых чисел
local function setFloatAnyData(x, y, p)
    if p == nil then error("setFloatData p == nil") return end
    p = math.min(p, 0xFFFFFF)
    local value = p
    local shifted = value + 1000000  -- теперь в [0 .. 2_000_000]
    local encoded = math.floor(shifted / 2000000 * 16777215)
    local r = bit.rshift(encoded, 16)
    local g = bit.band(bit.rshift(encoded, 8), 0xFF)
    local b = bit.band(encoded, 0xFF)

    image:set(x, y, r, g, b, 255)
end

local function uniform_start()
    -- validate entity texture
    local x, y = 33,33
    setFloatData(x, y, 7898)
    -- resolution uniform
    local x, y = 10,17
    local resX = gui.get_viewport()[1]
    setFloatData(x, y, resX)
    local x, y = 11,17
    local resY = gui.get_viewport()[2]
    setFloatData(x, y, resY)
    local x, y = 12,17
    local resA = resX / resY
    setFloatData(x, y, resA)
    image:update()
end
local oldMouseX, oldMouseY = 0.0, 0.0
local function uniform_update()
    if camera_state then return end
    -- iTime uniform
    local x, y = 13,17
    setFloatData(x, y, time.uptime())

    -- iMouse uniform
    local MouseX = input.get_mouse_pos()[1]
    local deltaX = MouseX - oldMouseX
    iMouseX = iMouseX + deltaX
    if iMouseX < 0 then iMouseX = 0 end
    if iMouseX > w then iMouseX = w end
    
    local MouseY = (gui.get_viewport()[2] - input.get_mouse_pos()[2])
    local deltaY = MouseY - oldMouseY
    iMouseY = iMouseY + deltaY
    if iMouseY < 0 then iMouseY = 0 end
    if iMouseY > h then iMouseY = h end
    
    iMouseZ = 0.0
    if input.is_pressed("mouse:left") then iMouseZ = 1.0 else iMouseZ = -1.0 end
    
    setFloatAnyData(14, 17, iMouseX)
    setFloatAnyData(15, 17, iMouseY)
    setFloatAnyData(16, 17, 1.0)

    oldMouseX = MouseX
    oldMouseY = MouseY

    image:update()
end

local camPos = { x = 0.0, y = 0.01, z = 0.0 }
local function camPosGet(dt)--iMouseX, iMouseY, iResolutionX, iResolutionY
    local yaw = 0
    local pitch = 0
    local speed = 22.2

    -- управление мышью
    local mouseActive = true

    local mx, my = iMouseX, iMouseY
    local w, h = iResolutionX, iResolutionY

    -- нормализованные координаты мыши
    local mo_x = mx / w
    local mo_y = my / h

    -- пересчитываем углы каждый кадр заново
    yaw   = (mo_x - 0.5) * 2.0 * math.pi
    pitch = (mo_y - 0.5) * 0.5 * math.pi

    -- направления
    local cosP = math.cos(pitch)
    local lookDir = {
        x = cosP * math.sin(yaw),
        y = math.sin(pitch),
        z = cosP * math.cos(yaw)
    }

    local right = {
        x = math.cos(yaw),
        y = 0,
        z = -math.sin(yaw)
    }

    local up = { x = 0, y = 1, z = 0 }

    -- скорость
    local moveSpeed = speed * dt
    if input.is_pressed("key:f") then
        moveSpeed = moveSpeed * 11
    end

    -- авто-движение при неактивной мыши
    if mouseActive then
        if input.is_pressed("key:w") then
            camPos.x = camPos.x + lookDir.x * moveSpeed
            camPos.y = camPos.y + lookDir.y * moveSpeed
            camPos.z = camPos.z + lookDir.z * moveSpeed
        end
        if input.is_pressed("key:s") then
            camPos.x = camPos.x - lookDir.x * moveSpeed
            camPos.y = camPos.y - lookDir.y * moveSpeed
            camPos.z = camPos.z - lookDir.z * moveSpeed
        end
        if input.is_pressed("key:a") then
            camPos.x = camPos.x - right.x * moveSpeed
            camPos.z = camPos.z - right.z * moveSpeed
        end
        if input.is_pressed("key:d") then
            camPos.x = camPos.x + right.x * moveSpeed
            camPos.z = camPos.z + right.z * moveSpeed
        end
        if input.is_pressed("key:space") then
            camPos.y = camPos.y + up.y * moveSpeed
        end
        if input.is_pressed("key:shift") then
            camPos.y = camPos.y - up.y * moveSpeed
        end
    end
    return camPos
end
local function varyng_update(dt)
    -- debug.print(camPos)
    if pid and not camera_state then
        camPosGet(dt)
        local x,y,z = player.get_pos(pid)
        local mama = 1
        setFloatAnyData(17, 17, camPos.x/mama)
        setFloatAnyData(18, 17, camPos.y/mama)
        setFloatAnyData(19, 17, camPos.z/mama)

    end
    image:update()
end
local function item_isSelect(playerid, item_name)
    local inv_id, active_slot = player.get_inventory(playerid) -- Получаем ID инвентаря и активный слот
    local item_id, item_count = inventory.get(inv_id, active_slot) -- Получаем ID предмета и его количество
    if item_id ~= 0 then
        local slot_item = item.name(item_id)
        if slot_item == item_name then
            return true
        end
    end
    return false
end

local function shader_init()
    uniform_start()
    uniform_update()
    setFloatAnyData(14, 17, w/2)--mouseX
    setFloatAnyData(15, 17, h/2)--mouseY
    setFloatAnyData(16, 17, 1.0)--mousez
    varyng_update(0.0016)
    camPosGet(0.0016)
    setFloatAnyData(17, 17, 0.0)--posx
    setFloatAnyData(18, 17, 0.1)--posy
    setFloatAnyData(19, 17, 0.0)--posz
end

local pc = pc_os.new(entity, {
    -- ярлык «Minecraft (shader)»: экран — canvas ShaderToy, WASD/мышь/F/Space/Shift двигают камеру шейдера
    on_shader = function(_, on)
        if on then
            ensure_canvas()
            shader_init()
            rig:set_texture("$0", texture_name)
            camera_state = false
            oldMouseX, oldMouseY = input.get_mouse_pos()[1], gui.get_viewport()[2] - input.get_mouse_pos()[2]
        else
            camera_state = true
        end
    end,
})

function on_render(dt)
    if image and not camera_state then
        uniform_update()
        varyng_update(dt)
    end
    pc:tick(dt)
end

function on_used(playerid)
    pid = playerid
    if item_isSelect(playerid, "andryhass_mod:gravitygun") or item_isSelect(playerid, "olife:injector") then
        return
    end
    if pc:is_active() then pc:leave() else pc:enter(playerid) end
end

function on_despawn()
    pc:destroy()
end

function on_use_on_block(x, y, z, playerid, normal)
    local pos = vec3.add({x + 0.5,y + 1.0,z + 0.5}, normal)
    local dummy = entities.spawn("pc_wasmrt:pc", pos)
end
