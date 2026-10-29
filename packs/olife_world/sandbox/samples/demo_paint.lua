-- demo_paint (UX A4): a procedural animated texture. A 32x32 canvas is redrawn and committed every 10 ticks
-- (2 frames a second, a cycle of 8 frames): the world encodes each frame into the owner's store (sha256 CAS — after
-- the first cycle every frame is already there) and puts it on all six textures of the model; clients fetch the
-- PNG over the gateway HTTP once and apply it at runtime. Cost per commit: 2 + 1 store credits (1024 px) + a put.
local W = 32
local cv = canvas.new(W, W)
local t, n, last = 0, 0, nil
on("canvas", function(ev) last = ev.sha end)
on("rejected", function(ev) print("refused", ev.op, ev.code, ev.reason) end)
function on_tick(dt)
  t = t + 1
  if t % 10 ~= 0 then return end
  n = n + 1
  local f = n % 8
  cv:clear(canvas.rgba(20, 24, 48))
  for i = 0, W - 1, 4 do
    cv:line(0, i, W - 1, (i + f * 4) % W, canvas.rgba(255, 96 + f * 20, 0))
  end
  cv:rect(f * 3, f * 3, 8, 8, canvas.rgba(0, 200, 255))
  cv:rect(W - 8 - f * 3, f * 3, 8, 8, canvas.rgba(255, 255, 255))
  cv:commit("*")
  if f == 0 then print("paint cycle " .. (n / 8) .. " last " .. tostring(last):sub(1, 12)) end
end
