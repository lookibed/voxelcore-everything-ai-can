#!/usr/bin/env python3
"""Разбор скриншота пробы 4 (без PIL): R = восстановленный sky-свет *17, G = блочный *17, B = наивный sky *17.
python3 p4_analyze.py artifacts/screens/alpha_p4_shader.png"""
import sys, zlib, struct, collections

def read_png(path):
    d = open(path, 'rb').read()
    assert d[:8] == b'\x89PNG\r\n\x1a\n'
    pos, idat, w = 8, b'', 0
    while pos < len(d):
        n, t = struct.unpack('>I4s', d[pos:pos + 8]); body = d[pos + 8:pos + 8 + n]; pos += 12 + n
        if t == b'IHDR': w, h, bd, ct = struct.unpack('>IIBB', body[:10])
        elif t == b'IDAT': idat += body
    bpp = {2: 3, 6: 4}[ct]
    raw = zlib.decompress(idat); stride = w * bpp; rows = []; prev = bytearray(stride); i = 0
    for _ in range(h):
        f = raw[i]; line = bytearray(raw[i + 1:i + 1 + stride]); i += 1 + stride
        for x in range(stride):
            a = line[x - bpp] if x >= bpp else 0; b = prev[x]; c = prev[x - bpp] if x >= bpp else 0
            if f == 1: line[x] = (line[x] + a) & 255
            elif f == 2: line[x] = (line[x] + b) & 255
            elif f == 3: line[x] = (line[x] + (a + b) // 2) & 255
            elif f == 4:
                p = a + b - c; pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                line[x] = (line[x] + (a if pa <= pb and pa <= pc else b if pb <= pc else c)) & 255
        rows.append(bytes(line)); prev = line
    return w, h, bpp, rows

w, h, bpp, rows = read_png(sys.argv[1])
hist = collections.Counter()
for y in range(45, h - 90):          # без заголовка окна и хотбара
    r = rows[y]
    for x in range(12, w - 12, 1):
        hist[tuple(r[x * bpp:x * bpp + 3])] += 1
world = {c: n for c, n in hist.items() if not (c[2] > c[0] and c[2] > 100)}  # небо — голубое (B > R)
tot = sum(world.values())
exact = sum(n for c, n in world.items() if c[0] % 17 == 0 and c[1] % 17 == 0 and c[2] % 17 == 0)
diff = sum(n for c, n in world.items() if c[0] % 17 == 0 and c[2] % 17 == 0 and c[0] != c[2])
print(f"pixels(world)={tot} exact multiples of 17 in R,G,B: {exact} ({100*exact/max(tot,1):.2f}%)")
print(f"pixels where naive round(v_light*15) != recovered: {diff}")
lv = collections.Counter()
for c, n in world.items():
    if c[0] % 17 == 0 and c[1] % 17 == 0 and c[2] % 17 == 0:
        lv[(c[0] // 17, c[1] // 17, c[2] // 17)] += n
print("levels (sky, block, naive_sky): pixels")
for k, n in sorted(lv.items(), key=lambda t: -t[1])[:40]:
    print(" ", k, n)
odd = [(c, n) for c, n in world.items() if not (c[0] % 17 == 0 and c[1] % 17 == 0 and c[2] % 17 == 0)]
odd.sort(key=lambda t: -t[1])
print("non-exact colors (top):", odd[:10])
