-- Расширение wasmrt для пака html (манифест: "extension": "html:html_host"):
--   vc.html_wheel() -> шаги колеса мыши с прошлого вызова (>0 — вверх; 0, если хост не видит колесо).
-- У Lua движка нет API колеса, но прокручиваемая панель GUI (panel scrollable + max-length) получает
-- прокрутку: +1/-1 на щелчок при scroll-step="1". Прозрачная панель на всю страницу, каждый тик читаем
-- scroll, копим шаги и возвращаем панель в середину (тот же приём, что quake:qg_host, проверен в движке).
return function(ctx)
    local doc = ctx.document
    local parent = ctx.parent or (doc and doc.root)
    local WHEEL_BASE = -1000
    local wheel_el, wheel_acc = nil, 0
    if doc and parent and ctx.manifest.wheel ~= false then
        local ok, err = pcall(function()
            parent:add('<panel id="html_wheel" pos="0, 92" size="8192, 8192" max-length="8192" ' ..
                'scrollable="true" scroll-step="1" color="#00000000">' ..
                '<container size="16, 16384" interactive="false" color="#00000000"/></panel>')
            wheel_el = doc["html_wheel"]
            wheel_el.scroll = WHEEL_BASE
        end)
        if not ok then
            wheel_el = nil
            ctx.log("html: wheel panel failed: " .. tostring(err))
        end
    end
    return {
        __tick = function()
            if not wheel_el then return end
            local ok, v = pcall(function() return wheel_el.scroll end)
            v = ok and tonumber(v) or nil
            if v and v ~= WHEEL_BASE then
                wheel_acc = wheel_acc + (v - WHEEL_BASE)
                pcall(function() wheel_el.scroll = WHEEL_BASE end)
            end
        end,
        html_wheel = function()
            local steps = wheel_acc
            wheel_acc = 0
            return steps
        end,
    }
end
