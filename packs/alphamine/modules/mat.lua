-- Small column-major 4x4 matrix helpers (glm / VoxelCore mat4 layout: m[1..16], column-major), OpenGL
-- semantics of glTranslatef / glRotatef / glScalef (post-multiplication). Pure Lua: the per-frame entity
-- poses need many products, one C call per bone (rig:set_matrix) instead of dozens of mat4.* calls.
local M = {}
local sin, cos, rad, sqrt = math.sin, math.cos, math.rad, math.sqrt

function M.idt()
    return {1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1}
end

function M.copy(a)
    local r = {}
    for i = 1, 16 do r[i] = a[i] end
    return r
end

function M.mul(a, b)
    local r = {}
    for c = 0, 3 do
        local b0, b1, b2, b3 = b[c * 4 + 1], b[c * 4 + 2], b[c * 4 + 3], b[c * 4 + 4]
        for row = 1, 4 do
            r[c * 4 + row] = a[row] * b0 + a[4 + row] * b1 + a[8 + row] * b2 + a[12 + row] * b3
        end
    end
    return r
end

-- m * T(x, y, z)
function M.translate(m, x, y, z)
    local r = M.copy(m)
    for row = 1, 4 do
        r[12 + row] = m[row] * x + m[4 + row] * y + m[8 + row] * z + m[12 + row]
    end
    return r
end

-- m * S(x, y, z)
function M.scale(m, x, y, z)
    local r = M.copy(m)
    for row = 1, 4 do
        r[row] = m[row] * x
        r[4 + row] = m[4 + row] * y
        r[8 + row] = m[8 + row] * z
    end
    return r
end

-- m * R(angle degrees, axis x, y, z) like glRotatef
function M.rotate(m, deg, x, y, z)
    if deg == 0 then return m end
    local l = sqrt(x * x + y * y + z * z)
    x, y, z = x / l, y / l, z / l
    local a = rad(deg)
    local c, s = cos(a), sin(a)
    local t = 1 - c
    local R = {
        x * x * t + c, y * x * t + z * s, x * z * t - y * s, 0,
        x * y * t - z * s, y * y * t + c, y * z * t + x * s, 0,
        x * z * t + y * s, y * z * t - x * s, z * z * t + c, 0,
        0, 0, 0, 1,
    }
    return M.mul(m, R)
end

return M
