"""Возможности проекта wasmrt (lab call wasmrt.<имя>).

  wasmrt.status  {lease} — строки [wasmrt]/[wasmrt_page] из latest.log экземпляра: манифест, старт программы,
                 последние fps, ошибки Lua (traceback/error).
  wasmrt.frames  {lease, frames=60, ticks_per_frame=1, shot=true, name} — прогнать N кадров F2F и снять кадр
                 (программа wasmrt работает в кадрах движка); ответ — tick/frame, время и снимок.
"""
import re
import time

PLUGIN_VERSION = 2


def status(ctx, args):
    lines = ctx.log_tail(args["lease"], stream="latest", lines=0)
    wl = [l for l in lines if "[wasmrt" in l]
    fps = [l for l in wl if re.search(r"\bfps\b", l)]
    errors = [l for l in lines if re.search(r"traceback|\berror\b|uncaught", l, re.I) and "assets-loader" not in l]
    return {"wasmrt_lines": wl[-15:], "fps": fps[-3:], "errors": errors[-10:], "log_lines": len(lines)}


def frames(ctx, args):
    lease = args["lease"]
    n = int(args.get("frames", 60))
    t0 = time.time()
    r = ctx.call(lease, "step", {"ticks": n * int(args.get("ticks_per_frame", 1)), "frames": n})
    out = {"step": r, "wall_s": round(time.time() - t0, 3)}
    if args.get("shot", True):
        out["shot"] = ctx.call(lease, "shot", {"name": args.get("name", "frames")})
    return out


def register(api):
    api.feature("status", status, "wasmrt log summary of an engine lease",
                {"type": "object", "properties": {"lease": {"type": "string"}}, "required": ["lease"]}, mcp=True)
    api.feature("frames", frames, "run N F2F frames and shoot",
                {"type": "object", "properties": {"lease": {"type": "string"}, "frames": {"type": "integer"}},
                 "required": ["lease"]})
