#!/usr/bin/env python3
"""Отладка шейдеров через пиксели окна VoxelCore (без зависимостей, только zlib).

Используется MCP-сервером (vc_shader_cells, vc_pixels) и из командной строки.

Шейдер в режиме отладки рисует в левом верхнем углу окна полосу квадратов: первый —
маркер цвета 5A A5 3C, дальше числа в RGB (24 бита, фиксированная точка с шагом 0.001,
смещение 2^23; см. dbg_encode в content/pong/shaders/effects/pong.glsl).

    python3 pixel_debug.py screenshot.png [имена ячеек через запятую]
"""
import struct
import sys
import zlib

MARKER = (0x5A, 0xA5, 0x3C)


def read_png(path):
    data = open(path, "rb").read()
    assert data[:8] == b"\x89PNG\r\n\x1a\n", "not a PNG"
    pos, idat, width = 8, b"", 0
    while pos < len(data):
        length, kind = struct.unpack(">I4s", data[pos:pos + 8])
        body = data[pos + 8:pos + 8 + length]
        if kind == b"IHDR":
            width, height, depth, color = struct.unpack(">IIBB", body[:10])
            assert depth == 8 and color in (2, 6), "only 8-bit RGB/RGBA"
            bpp = 3 if color == 2 else 4
        elif kind == b"IDAT":
            idat += body
        pos += 12 + length
    raw = zlib.decompress(idat)
    stride = width * bpp
    rows, prev = [], bytearray(stride)
    for y in range(height):
        f = raw[y * (stride + 1)]
        line = bytearray(raw[y * (stride + 1) + 1:(y + 1) * (stride + 1)])
        for i in range(stride):
            a = line[i - bpp] if i >= bpp else 0
            b = prev[i]
            c = prev[i - bpp] if i >= bpp else 0
            if f == 1:
                line[i] = (line[i] + a) & 255
            elif f == 2:
                line[i] = (line[i] + b) & 255
            elif f == 3:
                line[i] = (line[i] + (a + b) // 2) & 255
            elif f == 4:
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                line[i] = (line[i] + (a if pa <= pb and pa <= pc else b if pb <= pc else c)) & 255
        rows.append(line)
        prev = line
    return width, height, bpp, rows


def pixel(img, x, y):
    _, _, bpp, rows = img
    o = x * bpp
    return tuple(rows[y][o:o + 3])


def find_marker(img):
    width, height, _, _ = img
    for y in range(height):
        for x in range(width):
            if pixel(img, x, y) == MARKER:
                size = 0
                while x + size < width and pixel(img, x + size, y) == MARKER:
                    size += 1
                return x, y, size
    return None


def decode(rgb):
    q = (rgb[0] << 16) | (rgb[1] << 8) | rgb[2]
    return (q - 8388608) / 1000.0


def read_cells(path, names=(), max_cells=64):
    """-> (marker (x, y, size) | None, [(index, name, value, rgb)]).

    Читает ячейки вправо от маркера, пока не встретит ячейку цвета маркера фона
    (чистый чёрный) после именованных или не упрётся в max_cells / край."""
    img = read_png(path)
    found = find_marker(img)
    if not found:
        return None, []
    x0, y0, cell = found
    cells = []
    k = 1
    while k < max_cells and x0 + k * cell + cell // 2 < img[0]:
        rgb = pixel(img, x0 + k * cell + cell // 2, y0 + cell // 2)
        if not names and rgb == (0, 0, 0):
            break
        name = names[k - 1] if k - 1 < len(names) else f"cell{k}"
        cells.append((k, name, decode(rgb), rgb))
        k += 1
        if names and k > len(names):
            break
    return found, cells


def read_pixels(path, x, y, w=1, h=1):
    """RGB пикселей прямоугольника скриншота: список строк [(r, g, b), ...]."""
    img = read_png(path)
    return [[pixel(img, xx, yy) for xx in range(x, min(x + w, img[0]))] for yy in range(y, min(y + h, img[1]))]


def format_cells(found, cells):
    if not found:
        return "маркер не найден: режим отладки шейдера выключен или угол окна перекрыт"
    x0, y0, size = found
    lines = [f"marker at {x0},{y0}, cell {size}px"]
    for k, name, value, rgb in cells:
        lines.append(f"  {k:2d} {name:<12} {value:>12.3f}   rgb={rgb[0]:02x}{rgb[1]:02x}{rgb[2]:02x}")
    return "\n".join(lines)


def main():
    names = sys.argv[2].split(",") if len(sys.argv) > 2 else []
    found, cells = read_cells(sys.argv[1], names)
    print(format_cells(found, cells))
    return 0 if found else 1


if __name__ == "__main__":
    sys.exit(main())
