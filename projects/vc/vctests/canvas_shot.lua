-- lab vctest: Canvas saved by the script into user:shots/ -> collected into the run (shots\<scenario>\).
local c = Canvas({64, 32})
c:clear(0xff202020)
c:line(0, 0, 63, 31, 0xffffffff)
c:line(0, 31, 63, 0, 0xff4040ff)
file.write_bytes("user:shots/cross.png", c:encode())
print("[vctest] canvas_shot saved")
