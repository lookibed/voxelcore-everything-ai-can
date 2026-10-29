print(SAVED_DATA.trash)
local UID = entity:get_uid()
local name = entity:def_name()
local tsf = entity.transform
local function on_block_pos()
end
-- Find player in radius (return random player)
local function detect_player(pos, radius)
    local pos = tsf:get_pos()
    local ents = entities.get_all_in_radius(pos, radius)
    -- debug.print(ents)
    for i, e_uid in ipairs(ents) do
        local name = entities.def_name(entities.get_def(e_uid))
        -- print(name)
        if name == "base:player" then
            -- print("player detected!")
            return entities.get(e_uid).transform:get_pos()
        end
    end
end
local function move(player_pos)
    local pos = tsf:get_pos()
    local dist = vec3.normalize(vec3.sub(player_pos, pos))
    local move = vec3.mul(dist, 0.05)
    local new_pos = vec3.add(pos, move)
    tsf:set_pos(new_pos)
end
local function rotation_matrix_to_euler(matrix)
    local r11, r12, r13 = matrix[1], matrix[2], matrix[3]
    local r21, r22, r23 = matrix[5], matrix[6], matrix[7]
    local r31, r32, r33 = matrix[9], matrix[10], matrix[11]

    local sy = math.sqrt(r11 * r11 + r21 * r21)
    local singular = sy < 1e-6

    local x, y, z
    if not singular then
        x = math.atan2(r32, r33)
        y = math.atan2(-r31, sy)
        z = math.atan2(r21, r11)
    else
        x = math.atan2(-r23, r22)
        y = math.atan2(-r31, sy)
        z = 0
    end

    local rad_to_deg = 180 / math.pi
    return {x * rad_to_deg, y * rad_to_deg, z * rad_to_deg}
end
local function get_rotation_angle(mob_pos, player_pos)
    local dx = player_pos[1] - mob_pos[1]
    local dz = player_pos[3] - mob_pos[3]
    local angle_radians = math.atan2(dz, dx)
    local angle_degrees = (angle_radians * 180 / math.pi + 360) % 360
    return angle_degrees
end
local function rotate(player_pos)
    local pos = tsf:get_pos()
    local rot = rotation_matrix_to_euler(tsf:get_rot())
    print(rot[1],rot[2],rot[3])
    pos[2] = 0
    player_pos[2] = 0
    
    local rotation_angle = get_rotation_angle(pos, player_pos)
    local mat_rot = mat4.rotate(mat4.idt(), {0,1,0}, -rotation_angle-90)
    tsf:set_rot(mat_rot)
end
-- Main bechavor mob
function on_update()
    local player_pos = detect_player({}, 5)
    if player_pos then
        -- Player find, KILL HIM!
        move(player_pos)
        rotate(player_pos)
    end
end

function on_attacked()
    entity:despawn()
end

function on_save()
    SAVED_DATA["trash"] = "I am save... " .. entity:get_uid() .. " " .. time.uptime()
end



