-- olife_caret (16.10): probe of the editor caret / selection position on VoxelCore 0.32 (F2F build, no server).
-- Run as the app script of `lab lease olife menu_app --param script=<this file> --param packs='[..., "olife_caret_probe"]'`.
-- Loads the client packs (+ olife_caret_probe: font variants) in the menu, adds to the root document a set of
-- <textbox>es like the editor's (multiline, syntax lua, text-wrap false, padding 6) — font x line-numbers variants —
-- each with three lines: ASCII, Cyrillic, mixed (the user's line). Stage file user:export/caret_stage.txt
-- "<variant> <line> <caret|sel|hold> <seq>" picks the visible textbox and the line: `caret` puts the caret at the end
-- of that line every tick (so it never blinks off), `sel` puts it at the line start once (the test then sends
-- Shift+End through F2F input), `hold` leaves the textbox alone. Every change prints one `[olife_caret] stage` line
-- with the textbox rect, caret, viewport; the test takes an F2F shot and measures caret / selection vs the glyphs.
-- `report` changes nothing (only prints the caret: after an F2F mouse click into the text).
local function log(fmt, ...)
    print("[olife_caret] " .. string.format(fmt, ...))
end

local VARIANTS = {
    {font = "olife_mono", ln = true},      -- 1: the editor as shipped (olife_client/fonts/olife_mono.ttf)
    {font = "olife_mono", ln = false},     -- 2
    {font = nil, ln = true},               -- 3: stock engine font
    {font = nil, ln = false},              -- 4
    {font = "caret_unfixed", ln = true},   -- 5: DejaVu Sans Mono, post.isFixedPitch = 0
    {font = "caret_unfixed", ln = false},  -- 6
    {font = "caret_narrow", ln = true},    -- 7: DejaVu Sans Mono condensed to 0.5 em
    {font = "caret_narrow", ln = false},   -- 8
    {font = "caret_narrow2", ln = true},   -- 9: condensed + zero-area anchor at x=0 (ink keeps its side bearing)
    {font = "caret_narrow2", ln = false},  -- 10
    {font = "olife_mono", ln = true, editor = true},  -- 11: the REAL editor document (olife_client:editor) in a menu
                                                      -- page (olife_caret_probe:layouts/pages/caret_editor.xml, iframe)
    {font = "caret_orig", ln = false},     -- 12 (22.10, v0327): original DejaVu Sans Mono (the font before the 16.10 workaround);
    {font = "caret_orig", ln = true},      -- 13   odd = line numbers (the runner's pen model: v % 2 == 1)
}

local function cp_len(s)   -- UTF-8 code points (the textbox works in wchar = code points for the BMP)
    local n = 0
    for i = 1, #s do
        local b = s:byte(i)
        if b < 0x80 or b >= 0xC0 then n = n + 1 end
    end
    return n
end

local function main()
    local loaded = {}
    for _, id in ipairs(app.get_content()) do loaded[id] = true end
    local add = {}
    for _, id in ipairs({"base", "olife_client", "olife_caret_probe"}) do
        if not loaded[id] then add[#add + 1] = id end
    end
    if #add > 0 then app.reconfig_packs(add, {}) end
    if not app.is_content_loaded() then app.load_content() end

    local vp = gui.get_viewport()
    local vw, vh = vp[1], vp[2]
    local LINES
    if vw >= 1200 then
        LINES = {
            "--    Olife  sample:  orbit  flight.  on_tick(dt) is called 20 times per second in the sandbox.",
            "Пример Olife: облёт по кругу. Вызывается двадцать раз в секунду в песочнице сервера.",
            "-- Пример Olife: облёт по кругу. on_tick(dt) вызывается 20 раз в секунду в песочнице.",
        }
    else
        LINES = {
            "--    Olife  sample:  orbit.  on_tick(dt) 20 times/s.",
            "Пример: облёт по кругу, двадцать раз в секунду.",
            "-- Пример Olife: облёт. on_tick(dt) 20 раз в секунду.",
        }
    end
    local text = table.concat(LINES, "\n")
    local starts, acc = {}, 0
    for i, s in ipairs(LINES) do starts[i] = acc; acc = acc + cp_len(s) + 1 end

    local bw = vw - 40
    gui.root.root:add(string.format(
        '<container id="cp_root" pos="0,0" size="%d,%d" color="#000000FF" z-index="100"></container>', vw, vh))
    gui.root.cp_root:add('<label id="cp_title" pos="20,8" size="800,20" color="#808080"></label>')
    for v, cfg in ipairs(VARIANTS) do
        gui.root.cp_root:add(string.format(
            '<textbox id="cp%d" pos="20,40" size="%d,110" color="0" padding="6" multiline="true" line-numbers="%s"'
            .. ' syntax="lua" text-wrap="false" %s keep-line-selection="true" visible="false"></textbox>',
            v, bw, cfg.ln and "true" or "false", cfg.font and ('font="' .. cfg.font .. '"') or ""))
        gui.root["cp" .. v].text = text
    end
    log("ready viewport=%dx%d lines=%d,%d,%d starts=%d,%d,%d", vw, vh, cp_len(LINES[1]), cp_len(LINES[2]),
        cp_len(LINES[3]), starts[1], starts[2], starts[3])

    local function box_of(v)
        if VARIANTS[v].editor then return Document.new("olife_client:editor").code end
        return gui.root["cp" .. v]
    end

    local cur = ""
    local v, l, mode = 1, 1, "hold"
    while true do
        app.tick()
        local s = file.exists("user:export/caret_stage.txt") and file.read("user:export/caret_stage.txt") or ""
        s = s:gsub("%s+$", "")
        if s == "quit" then break end
        if s ~= "" and s ~= cur then
            cur = s
            local a, b, c = s:match("^(%d+)%s+(%d+)%s+(%a+)")
            v, l, mode = tonumber(a) or 1, tonumber(b) or 1, c or "hold"
            local ed = VARIANTS[v].editor
            for i = 1, #VARIANTS do
                if not VARIANTS[i].editor then gui.root["cp" .. i].visible = (i == v) end
            end
            gui.root.cp_root.visible = not ed
            if ed and menu.page ~= "caret_editor" then
                menu.page = "caret_editor"
                Document.new("olife_client:editor").code.text = text
            end
            local box = box_of(v)
            -- 0.32 p_set_focused: `focused = true` on an already focused node DEFOCUSES it (else-branch) -> guard
            if not box.focused then box.focused = true end
            if mode == "caret" then box.caret = starts[l] + cp_len(LINES[l]) end
            if mode == "sel" then box.caret = starts[l] end
            local cfg = VARIANTS[v]
            gui.root.cp_title.text = string.format("v%d font=%s ln=%s line=%d %s", v, cfg.font or "stock",
                tostring(cfg.ln), l, mode)
            local wx, wy = unpack(box.wpos)
            local sx, sy = unpack(box.size)
            log("stage %s v=%d font=%s ln=%s line=%d mode=%s wpos=%d,%d size=%d,%d caret=%d len=%d viewport=%dx%d",
                s, v, cfg.font or "stock", tostring(cfg.ln), l, mode, wx, wy, sx, sy, box.caret,
                cp_len(LINES[l]), vw, vh)
        end
        if mode == "caret" then
            box_of(v).caret = starts[l] + cp_len(LINES[l])
        end
    end
    log("quit")
end

local ok, err = xpcall(main, debug.traceback)
if not ok then log("ERROR %s", tostring(err)) end
