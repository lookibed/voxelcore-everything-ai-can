-- Страница чата smollm_gpu: лента, статус и ввод — из состояния modules/chat.lua; модель крутит app-скрипт
-- (chat.launch: scripts/app/smollm_gpu.lua или tools/scenarios/smollm_gpu_chat.lua).
local chat = require "smollm_gpu:chat"

local TIMER_INTERVAL_MS = 4
local last_status, last_remember = nil, nil

local function ui_tick()
    if chat.dirty then
        chat.dirty = false
        local log_box = document.log
        if log_box and log_box.exists then log_box.text = chat.render_transcript() end
        local st = chat.status_text()
        if st ~= last_status then
            last_status = st
            local label = document.status
            if label and label.exists then label.text = st end
        end
        if chat.remember ~= last_remember then
            last_remember = chat.remember
            local cb = document.remember
            if cb and cb.exists then cb.checked = chat.remember end
        end
    end
end

function on_open()
    last_status, last_remember = nil, nil
    chat.dirty = true
    document.root:setInterval(TIMER_INTERVAL_MS, ui_tick)
    ui_tick()
    debug.log("[smollm_gpu] page open")
end

function on_submit(text)
    if chat.submit(text) then document.prompt.text = "" end
end

function send_click() on_submit(document.prompt.text) end
function stop_click() chat.stop() end
function remember_click(checked) chat.set_remember(checked) end
function reset_click() chat.reset() end
function demo_click() chat.demo_req = true; debug.log("[smollm_gpu] demo requested") end
function leave() chat.leaving = true end
