"""Декодирование логов, кодировка которых неизвестна заранее.

Логи хранятся сырыми байтами. При чтении каждая строка декодируется отдельно (в одном потоке бывают и UTF-8 движка,
и OEM-кодировка консоли Java/cmd = cp866, и сообщения Windows API в ANSI = cp1251): UTF-8 strict -> иначе из cp866 и
cp1251 выбирается вариант с большей долей «правдоподобных» символов (ASCII, русские буквы А-я Ёё, № и т.п.);
cp866, прочитанный как cp1251, даёт Ђ Ѓ ‚ ѓ „ … (0x80–0xAF), cp1251, прочитанный как cp866, — псевдографику ─│┌ (0xB0–0xDF).
"""
import itertools
import json
import os
import threading
import time

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


def read_since(path, offset):
    """Строки, дописанные в лог после байтового смещения offset (декодированные, последняя — даже без перевода строки)
    -> (lines, новое смещение = размер файла). Не зависит от длины лога, в отличие от окна read_tail. Файл короче
    смещения (пересоздан) — читается с начала; файла нет — ([], 0)."""
    import os
    try:
        size = os.path.getsize(path)
        if size < offset:
            offset = 0
        with open(path, "rb") as f:
            f.seek(offset)
            data = f.read(size - offset)
    except OSError:
        return [], 0
    text = decode(data).split("\n")
    if text and text[-1] == "":
        text.pop()
    return text, offset + len(data)


_TMP_SEQ = itertools.count(1)
_LOCKS = {}
_LOCKS_GUARD = threading.Lock()


def path_lock(path):
    """Один threading.Lock на файл состояния в процессе: запись/замена одного файла из разных потоков — по очереди."""
    key = os.path.normcase(os.path.abspath(path))
    with _LOCKS_GUARD:
        return _LOCKS.setdefault(key, threading.Lock())


def _busy(exc):
    """Файл занят на Windows (антивирус, индексатор, другой писатель/читатель): ERROR_ACCESS_DENIED 5,
    ERROR_SHARING_VIOLATION 32, ERROR_LOCK_VIOLATION 33 — PermissionError; ждать и повторить."""
    return isinstance(exc, PermissionError) or getattr(exc, "winerror", None) in (5, 32, 33)


def replace_retry(src, dst, attempts=10, delay=0.02, max_delay=0.5):
    """os.replace с повтором, пока dst/src заняты другим процессом (пауза 20 мс, вдвое, не больше 500 мс).
    После attempts неудач — последнее исключение."""
    for i in range(attempts):
        try:
            os.replace(src, dst)
            return i + 1
        except OSError as exc:
            if not _busy(exc) or i == attempts - 1:
                raise
        time.sleep(delay)
        delay = min(delay * 2, max_delay)


def write_json_atomic(path, obj, attempts=10, **dump_kw):
    """JSON в файл через уникальный временный файл (<path>.<pid>.<n>.tmp) + replace_retry, под замком файла
    (path_lock). Ошибка — исключение (решает вызывающий), временный файл при этом удаляется."""
    dump_kw.setdefault("ensure_ascii", False)
    text = json.dumps(obj, **dump_kw)
    tmp = "%s.%d.%d.tmp" % (path, os.getpid(), next(_TMP_SEQ))
    with path_lock(path):
        try:
            with open(tmp, "w", encoding="utf-8") as f:
                f.write(text)
            replace_retry(tmp, path, attempts=attempts)
        except BaseException:
            try:
                os.remove(tmp)
            except OSError:
                pass
            raise
