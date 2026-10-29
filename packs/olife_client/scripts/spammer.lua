-- olife_client:spammer (item) — UX B2: RMB = throw a ball with the selected snapshot (one press = one throw: the
-- build binding callback and this on_use both land in olife.rmb, which lets one action per press through, as the
-- GravityGun). LMB (capture) is the attack binding callback in olife_client:olife. Shift+RMB opens the library.
function on_use(playerid)
    require("olife_client:olife").rmb(3, playerid)
end
