-- olife_client:injector — RMB (no block under the cursor): open the editor of the scripted entity under the cursor;
-- Shift+RMB: the editor of the last opened entity; ` while aiming at a bench: its editor (olife_client:olife).
-- The client only asks (ToolUse injector/use with its eye and look direction); the world raycasts and answers with
-- ScriptState (+ RequestReply). A held RMB repeats on_use every 0.16 s: olife.rmb lets one action per press through.
function on_use(playerid)
    require("olife_client:olife").rmb(1, playerid)
end
