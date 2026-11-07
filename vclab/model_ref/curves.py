"""VCA curves (pure Python, used inside Blender by blender_export.py and by tests).

- VoxelCore 0.32 key evaluation, exactly as res/modules/animation.lua + internal/animation_codegen.lua: keys
  {frame, value, lx, ly, rx, ry} (handles relative to their key), bezier = x solved by 8 Newton steps from u = t,
  clamped; linear; const. Frame = t * fps.
- Blender F-curve segments -> cubic segments (bezier with Blender's handle correction, linear, constant), cropped to
  [start, end] by de Casteljau, mapped value' = a * value + b -> VCA bezier keys.
- Smooth baking: per-frame samples -> bezier keys with Catmull-Rom handles.
"""

EPS_CONST = 1e-3     # a constant segment holds until this close to the next key, then jumps


# ------------------------------------------------------------------------------------------------ engine evaluation
def _bez(a, b, c, d, u):
    s = 1 - u
    return s * s * s * a + 3 * s * s * u * b + 3 * s * u * u * c + u * u * u * d


def _bez_d(a, b, c, d, u):
    s = 1 - u
    return 3 * s * s * (b - a) + 6 * s * u * (c - b) + 3 * u * u * (d - c)


def _neighbors(keys, frame):
    left, right = 1, len(keys)
    while left <= right:
        mid = (left + right) // 2
        f = keys[mid - 1]["frame"]
        if f < frame:
            left = mid + 1
        elif f > frame:
            right = mid - 1
        else:
            return mid, mid
    if left > len(keys):
        left = len(keys)
    return right, left


def engine_value(keys, frame, interp):
    """value_at of the engine (interp: 'const' | 'linear' | 'bezier'); keys 1-based in the engine, 0-based here"""
    li, ri = _neighbors(keys, frame)
    if li == ri:
        return keys[li - 1]["value"]
    if li < 1:
        return keys[ri - 1]["value"]
    k0 = keys[li - 1]
    if interp == "const":
        return k0["value"]
    k1 = keys[ri - 1]
    t = (frame - k0["frame"]) / (k1["frame"] - k0["frame"])
    if interp == "bezier":
        fr = k0["frame"] + t * (k1["frame"] - k0["frame"])
        u = t
        for _ in range(8):
            x = _bez(k0["frame"], k0["rx"] + k0["frame"], k1["lx"] + k1["frame"], k1["frame"], u)
            dx = _bez_d(k0["frame"], k0["rx"] + k0["frame"], k1["lx"] + k1["frame"], k1["frame"], u)
            if abs(dx) < 1e-8:
                break
            u = u - (x - fr) / dx
            u = min(1.0, max(0.0, u))
        return _bez(k0["value"], k0["ry"] + k0["value"], k1["ly"] + k1["value"], k1["value"], u)
    return k0["value"] * (1 - t) + k1["value"] * t


# ------------------------------------------------------------------------------------------------ cubic segments
def _lerp(p, q, u):
    return (p[0] + (q[0] - p[0]) * u, p[1] + (q[1] - p[1]) * u)


def split(seg, u):
    """de Casteljau: segment (P0, P1, P2, P3) at u -> (left, right)"""
    p0, p1, p2, p3 = seg
    a, b, c = _lerp(p0, p1, u), _lerp(p1, p2, u), _lerp(p2, p3, u)
    d, e = _lerp(a, b, u), _lerp(b, c, u)
    f = _lerp(d, e, u)
    return (p0, a, d, f), (f, e, c, p3)


def u_at_x(seg, x):
    lo, hi = 0.0, 1.0
    for _ in range(60):
        mid = (lo + hi) / 2
        if _bez(seg[0][0], seg[1][0], seg[2][0], seg[3][0], mid) < x:
            lo = mid
        else:
            hi = mid
    return (lo + hi) / 2


def correct(seg):
    """Blender's BKE_fcurve_correct_bezpart: handles longer (in x) than the segment are scaled down together"""
    p0, p1, p2, p3 = seg
    L = p3[0] - p0[0]
    h1, h2 = abs(p1[0] - p0[0]), abs(p3[0] - p2[0])
    if h1 + h2 > L > 0:
        f = L / (h1 + h2)
        p1 = (p0[0] + (p1[0] - p0[0]) * f, p0[1] + (p1[1] - p0[1]) * f)
        p2 = (p3[0] + (p2[0] - p3[0]) * f, p3[1] + (p2[1] - p3[1]) * f)
    return (p0, p1, p2, p3)


def line_seg(p0, p3):
    return (p0, _lerp(p0, p3, 1 / 3), _lerp(p0, p3, 2 / 3), p3)


def segments_from_keys(keys, start, end):
    """keys: [{"co": (x, y), "hl": (x, y), "hr": (x, y), "interp": "BEZIER"|"LINEAR"|"CONSTANT"}] sorted by x;
    constant extrapolation. -> cubic segments covering [start, end], or None (an interpolation we cannot carry)"""
    if not keys:
        return None
    segs = []
    first, last = keys[0]["co"], keys[-1]["co"]
    if start < first[0]:
        segs.append(line_seg((start, first[1]), first))
    for k0, k1 in zip(keys, keys[1:]):
        p0, p3 = k0["co"], k1["co"]
        if p3[0] - p0[0] < 1e-9:
            continue
        it = k0["interp"]
        if it == "BEZIER":
            segs.append(correct((p0, k0["hr"], k1["hl"], p3)))
        elif it == "LINEAR":
            segs.append(line_seg(p0, p3))
        elif it == "CONSTANT":
            q = (p3[0] - min(EPS_CONST, (p3[0] - p0[0]) / 2), p0[1])
            segs.append(line_seg(p0, q))
            segs.append(line_seg(q, (p3[0], p3[1])))
        else:
            return None
    if end > last[0]:
        segs.append(line_seg(last, (end, last[1])))
    out = []
    for s in segs:                                     # crop to [start, end]
        x0, x3 = s[0][0], s[3][0]
        if x3 <= start or x0 >= end:
            continue
        if x0 < start:
            s = split(s, u_at_x(s, start))[1]
            s = ((start, s[0][1]),) + s[1:]
        if s[3][0] > end:
            s = split(s, u_at_x(s, end))[0]
            s = s[:3] + ((end, s[3][1]),)
        out.append(s)
    if not out:                                        # [start, end] outside the keys: one flat segment
        y = first[1] if end <= first[0] else last[1]
        out = [line_seg((start, y), (end, y))]
    return out


def keys_from_segments(segs, start, a=1.0, b=0.0):
    """cubic segments -> engine bezier keys (frame relative to start, value' = a*value + b)"""
    keys = []
    for i, s in enumerate(segs):
        p0, p1, p2, p3 = s
        if i == 0:
            keys.append({"frame": p0[0] - start, "value": a * p0[1] + b, "lx": 0.0, "ly": 0.0})
        k = keys[-1]
        k["rx"], k["ry"] = p1[0] - p0[0], a * (p1[1] - p0[1])
        keys.append({"frame": p3[0] - start, "value": a * p3[1] + b, "lx": p2[0] - p3[0], "ly": a * (p2[1] - p3[1])})
    keys[-1]["rx"], keys[-1]["ry"] = 0.0, 0.0
    return keys


def hermite_keys(vals, slopes):
    """values at frames 0..n-1 and their slopes (per frame) -> bezier keys (handles at 1/3 of a frame)"""
    return [{"frame": float(i), "value": v, "lx": -1 / 3, "ly": -m / 3, "rx": 1 / 3, "ry": m / 3}
            for i, (v, m) in enumerate(zip(vals, slopes))]


def catmull_keys(vals):
    """per-frame values -> bezier keys at frames 0..n-1, Catmull-Rom tangents (one-sided at the ends)"""
    n = len(vals)
    sl = []
    for i in range(n):
        if n == 1:
            sl.append(0.0)
        elif i == 0:
            sl.append(vals[1] - vals[0])
        elif i == n - 1:
            sl.append(vals[-1] - vals[-2])
        else:
            sl.append((vals[i + 1] - vals[i - 1]) / 2)
    return hermite_keys(vals, sl)


def mid_keys(vals, mids, step=1.0):
    """values at frames 0, step, 2*step... and the values half way between them -> bezier keys at those frames,
    slopes from the midpoints (central difference; the parabola through v0, m0, v1 at the ends)"""
    n = len(vals)
    sl = []
    for i in range(n):
        if n == 1:
            sl.append(0.0)
        elif i == 0:
            sl.append((4 * mids[0] - 3 * vals[0] - vals[1]) / step)
        elif i == n - 1:
            sl.append((3 * vals[-1] + vals[-2] - 4 * mids[-1]) / step)
        else:
            sl.append((mids[i] - mids[i - 1]) / step)
    return [{"frame": i * step, "value": v, "lx": -step / 3, "ly": -m * step / 3, "rx": step / 3, "ry": m * step / 3}
            for i, (v, m) in enumerate(zip(vals, sl))]


def half_keys(vals, halves):
    """per-frame values + the values half way (halves[i] between i and i+1) -> bezier keys whose slope at a key is
    the central difference over half frames (O(h^2) closer than Catmull-Rom), one-sided at the ends"""
    n = len(vals)
    sl = []
    for i in range(n):
        if n == 1:
            sl.append(0.0)
        elif i == 0:                                   # the parabola through v0, h0, v1: slope at 0
            sl.append(4 * halves[0] - 3 * vals[0] - vals[1])
        elif i == n - 1:                               # ... through v[n-2], h[n-2], v[n-1]: slope at the end
            sl.append(3 * vals[-1] + vals[-2] - 4 * halves[-1])
        else:
            sl.append(halves[i] - halves[i - 1])
    return hermite_keys(vals, sl)


def linear_keys(vals):
    return [{"frame": float(i), "value": v} for i, v in enumerate(vals)]


def max_err(keys, interp, samples):
    """samples: [(frame, value)] -> max |engine value - sample|"""
    return max((abs(engine_value(keys, f, interp) - v) for f, v in samples), default=0.0)
