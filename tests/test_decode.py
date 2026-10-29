from vclab.scenario import decode

RU = "Привет, мир: ошибка доступа № 5"


def test_utf8():
    assert decode.decode(RU.encode("utf-8")) == RU


def test_cp866_and_cp1251_lines():
    assert decode.decode_line(RU.encode("cp866")) == (RU, "cp866")
    assert decode.decode_line(RU.encode("cp1251")) == (RU, "cp1251")


def test_mixed_stream_per_line():
    data = b"\r\n".join([b"plain ascii", "Сервер запущен".encode("cp866"), "Отказано в доступе".encode("cp1251"),
                         "движок utf-8".encode("utf-8")])
    out = decode.decode(data).split("\n")
    assert out == ["plain ascii", "Сервер запущен", "Отказано в доступе", "движок utf-8"]
    assert decode.guess("Сервер запущен\nещё строка".encode("cp866")) == "cp866"


def test_short_ambiguous_word():
    # короткие слова: cp866 'р-я' совпадают по байтам с cp1251 'а-п' — эвристика не должна падать и выдаёт кириллицу
    s, enc = decode.decode_line("Готово".encode("cp866"))
    assert enc == "cp866" and s == "Готово"
    s, enc = decode.decode_line("Готово".encode("cp1251"))
    assert enc == "cp1251" and s == "Готово"


def test_read_tail(tmpdir_win):
    import os
    p = os.path.join(tmpdir_win, "x.log")
    with open(p, "wb") as f:
        f.write(b"\n".join(("строка %d" % i).encode("cp866") for i in range(100)))
    t = decode.read_tail(p, 3)
    assert t == ["строка 97", "строка 98", "строка 99"]
    assert decode.read_tail(p, 0, grep=r"а [12]$") == ["строка 1", "строка 2"]
