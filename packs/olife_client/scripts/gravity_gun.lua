-- olife_client:gravity_gun — one press of LMB (input callback in olife_client:olife) or RMB (here) = one toggle:
-- grab, the next press releases; a held button and presses closer than 150 ms are ignored. The world decides (one
-- holder at a time) and moves the entity; the answer plays the grab / release sound.
function on_use(playerid)
    require("olife_client:olife").rmb(2, playerid)
end
