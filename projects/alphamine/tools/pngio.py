"""Minimal PNG reader/writer (stdlib only) for AlphaMine asset tools.

Reads non-interlaced PNGs with bit depth 8, color types 0/2/3/4/6 (all PNGs in
Minecraft Alpha 1.0.16 minecraft.jar are 8-bit RGBA or 8-bit palette) and
returns RGBA rows. Writes 8-bit RGBA PNGs.
"""
import struct
import zlib

SIG = b"\x89PNG\r\n\x1a\n"


def _chunks(data):
    if data[:8] != SIG:
        raise ValueError("not a PNG")
    pos = 8
    while pos < len(data):
        (length,) = struct.unpack(">I", data[pos:pos + 4])
        ctype = data[pos + 4:pos + 8]
        yield ctype, data[pos + 8:pos + 8 + length]
        pos += 12 + length


def _paeth(a, b, c):
    p = a + b - c
    pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
    if pa <= pb and pa <= pc:
        return a
    return b if pb <= pc else c


def read_rgba(data):
    """Return (width, height, rows) where rows[y] is a bytearray of w*4 RGBA bytes."""
    ihdr = None
    plte = None
    trns = None
    idat = []
    for ctype, body in _chunks(data):
        if ctype == b"IHDR":
            ihdr = struct.unpack(">IIBBBBB", body)
        elif ctype == b"PLTE":
            plte = body
        elif ctype == b"tRNS":
            trns = body
        elif ctype == b"IDAT":
            idat.append(body)
        elif ctype == b"IEND":
            break
    w, h, depth, ctype, _cm, _fm, interlace = ihdr
    if depth != 8 or interlace != 0:
        raise ValueError("unsupported PNG: depth %d interlace %d" % (depth, interlace))
    channels = {0: 1, 2: 3, 3: 1, 4: 2, 6: 4}[ctype]
    stride = w * channels
    raw = zlib.decompress(b"".join(idat))
    rows = []
    prev = bytearray(stride)
    pos = 0
    bpp = channels
    for _y in range(h):
        ft = raw[pos]
        line = bytearray(raw[pos + 1:pos + 1 + stride])
        pos += 1 + stride
        if ft == 1:
            for i in range(bpp, stride):
                line[i] = (line[i] + line[i - bpp]) & 255
        elif ft == 2:
            for i in range(stride):
                line[i] = (line[i] + prev[i]) & 255
        elif ft == 3:
            for i in range(stride):
                left = line[i - bpp] if i >= bpp else 0
                line[i] = (line[i] + ((left + prev[i]) >> 1)) & 255
        elif ft == 4:
            for i in range(stride):
                left = line[i - bpp] if i >= bpp else 0
                upleft = prev[i - bpp] if i >= bpp else 0
                line[i] = (line[i] + _paeth(left, prev[i], upleft)) & 255
        elif ft != 0:
            raise ValueError("bad filter %d" % ft)
        rows.append(line)
        prev = line
    out = []
    for line in rows:
        o = bytearray(w * 4)
        for x in range(w):
            if ctype == 6:
                o[x * 4:x * 4 + 4] = line[x * 4:x * 4 + 4]
            elif ctype == 2:
                o[x * 4:x * 4 + 3] = line[x * 3:x * 3 + 3]
                o[x * 4 + 3] = 255
            elif ctype == 0:
                v = line[x]
                o[x * 4:x * 4 + 4] = bytes((v, v, v, 255))
            elif ctype == 4:
                v = line[x * 2]
                o[x * 4:x * 4 + 4] = bytes((v, v, v, line[x * 2 + 1]))
            elif ctype == 3:
                i = line[x]
                o[x * 4:x * 4 + 3] = plte[i * 3:i * 3 + 3]
                o[x * 4 + 3] = trns[i] if trns is not None and i < len(trns) else 255
        out.append(o)
    return w, h, out


def _chunk(ctype, body):
    return struct.pack(">I", len(body)) + ctype + body + struct.pack(">I", zlib.crc32(ctype + body) & 0xFFFFFFFF)


def write_rgba(w, h, rows):
    raw = b"".join(b"\x00" + bytes(r) for r in rows)
    return (SIG + _chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 6, 0, 0, 0))
            + _chunk(b"IDAT", zlib.compress(raw, 9)) + _chunk(b"IEND", b""))


def crop(rows, x, y, w, h):
    return [bytearray(rows[y + j][x * 4:(x + w) * 4]) for j in range(h)]
