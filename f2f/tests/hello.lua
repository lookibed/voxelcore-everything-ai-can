print("AM_HELLO engine=" .. tostring(app and "app" or "noapp") .. " jit=" .. tostring(jit and jit.version))
print("AM_TIME uptime=" .. tostring(time.uptime()))
print("AM_F2F active=" .. tostring(f2f.is_active()) .. " set=" .. tostring(f2f.set_handler(function() end)))
