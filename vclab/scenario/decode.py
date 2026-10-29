"""Декодирование логов, кодировка которых неизвестна заранее.

Логи хранятся сырыми байтами. При чтении каждая строка декодируется отдельно (в одном потоке бывают и UTF-8 движка,
и OEM-кодировка консоли Java/cmd = cp866, и сообщения Windows API в ANSI = cp1251): UTF-8 strict -> иначе из cp866 и
cp1251 выбирается вариант с большей долей «правдоподобных» символов (ASCII, русские буквы А-я Ёё, № и т.п.);
cp866, прочитанный как cp1251, даёт Ђ Ѓ ‚ ѓ „ … (0x80–0xAF), cp1251, прочитанный как cp866, — псевдографику ─│┌ (0xB0–0xDF).
"""

_GOOD_EXTRA = set("ЁёЄєІіЇїЎў№«»—–…€°±·")


def _score(text):
    good = 0
    for ch in text:
        o = ord(ch)
        if o < 0x80 or 0x410 <= o <= 0x44F or ch in _GOOD_EXTRA:
            good += 1
    return good - (len(text) - good) * 2


def decode_line(raw):
    """bytes одной строки (без \\n) -> (str, кодировка)."""
    try:
        return raw.decode("utf-8"), "utf-8"
    except UnicodeDecodeError:
        pass
    best = None
    for enc in ("cp866", "cp1251"):
        s = raw.decode(enc, "replace")
        sc = _score(s)
        if best is None or sc > best[0]:
            best = (sc, s, enc)
    return best[1], best[2]


def decode(data):
    """bytes -> str: построчно (\\n), каждая строка своей кодировкой; \\r в конце строк убирается."""
    if not data:
        return ""
    try:
        return data.decode("utf-8").replace("\r\n", "\n")
    except UnicodeDecodeError:
        pass
    out = []
    for raw in data.split(b"\n"):
        out.append(decode_line(raw.rstrip(b"\r"))[0])
    return "\n".join(out)


def guess(data):
    """Преобладающая кодировка буфера (для отчётов): utf-8 | cp866 | cp1251 | ascii."""
    try:
        data.decode("ascii")
        return "ascii"
    except UnicodeDecodeError:
        pass
    counts = {}
    for raw in data.split(b"\n"):
        if any(b >= 0x80 for b in raw):
            enc = decode_line(raw.rstrip(b"\r"))[1]
            counts[enc] = counts.get(enc, 0) + 1
    return max(counts, key=counts.get) if counts else "ascii"


def read_tail(path, lines=60, max_bytes=512 * 1024, grep=None):
    """Хвост файла лога (декодированный), без блокировки пишущего процесса. grep — regex (str) или None."""
    import os
    import re
    try:
        size = os.path.getsize(path)
        with open(path, "rb") as f:
            if size > max_bytes:
                f.seek(size - max_bytes)
                data = f.read()
                data = data[data.find(b"\n") + 1:]
            else:
                data = f.read()
    except OSError:
        return []
    text = decode(data).split("\n")
    if text and text[-1] == "":
        text.pop()
    if grep:
        rx = re.compile(grep)
        text = [l for l in text if rx.search(l)]
    return text[-lines:] if lines else text
