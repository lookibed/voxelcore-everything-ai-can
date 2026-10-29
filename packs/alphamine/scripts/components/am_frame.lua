-- Per-frame hook of the pack (entity alphamine:am_frame, spawned at world open, invisible, follows the player):
-- the engine calls on_render of entity components every rendered frame before drawing the world
-- (LevelScreen::draw -> scripting::on_entities_render). alphamine:game.frame applies Alpha mouse look
-- (EntityRenderer.updateCameraAndRender -> setAngles), moves the pack camera and poses the Alpha entities.
local game = require "alphamine:game"

function on_render(delta)
    local ok, err = pcall(game.frame, delta)
    if not ok then
        game.frame_errors = (game.frame_errors or 0) + 1
        if game.frame_errors <= 5 then debug.log("[alphamine] frame error: " .. tostring(err)) end
    end
end
