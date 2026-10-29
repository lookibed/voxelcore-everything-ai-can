-- Бенчмарк декодера: старый адаптер (config:real-world-h264bsd-mp4, старая трансляция,
-- RGBA в таблице) против videoplayer:decoder (новая трансляция, RGBA в Bytearray).
-- Декодирует одни и те же кадры и сверяет RGBA побайтно. Метка в логе: [codec_bench].

app.config_packs({"videoplayer"})
app.load_content()

local MP4 = "config:videoplayer/videos/test-h264bsd.mp4"
local FRAMES = { 0, 1, 5 }

local function log(message)
    debug.log("[codec_bench] " .. message)
end

local function checksum(bytes)
    local sum = 0
    for i = 1, #bytes do
        sum = (sum * 31 + bytes[i]) % 2147483647
    end
    return sum
end

local function load_lua_file(path)
    local chunk = assert(loadstring(file.read(path), "=" .. path))
    return chunk()
end

local CASES = {
    { "old", function()
        local session = load_lua_file("config:real-world-h264bsd-mp4/voxelcore_decoder.lua").create_decoder_session(MP4)
        return function(index)
            local frame = session:decode_frame(index)
            return frame.width, frame.height, frame.rgba_bytes
        end
    end },
    { "new", function()
        local session = require("videoplayer:decoder").create_session(MP4)
        return function(index)
            local frame = assert(session:decode_frame(index), "frame not decoded")
            return frame.width, frame.height, frame.rgba
        end
    end },
}

local results = {}
log("start")
for _, case in ipairs(CASES) do
    local label = case[1]
    local ok, err = pcall(function()
        local t0 = os.clock()
        local decode = case[2]()
        log(("%s session %.2fs"):format(label, os.clock() - t0))
        results[label] = {}
        for _, index in ipairs(FRAMES) do
            t0 = os.clock()
            local width, height, rgba = decode(index)
            local elapsed = os.clock() - t0
            local sum = checksum(rgba)
            results[label][index] = sum
            log(("%s frame %d %dx%d rgba=%d sum=%d %.2fs"):format(label, index, width, height, #rgba, sum, elapsed))
        end
    end)
    if not ok then
        log(label .. " FAIL: " .. tostring(err))
    end
    collectgarbage("collect")
end
for _, index in ipairs(FRAMES) do
    local a = results.old and results.old[index]
    local b = results.new and results.new[index]
    log(("frame %d match=%s"):format(index, tostring(a ~= nil and a == b)))
end
log("done")
