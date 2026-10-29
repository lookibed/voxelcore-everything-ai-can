# olife_proto — сгенерированные кодеки протокола Olife

Библиотечный пак: `modules/wire.lua` (рантайм: Bytearray, big-endian, проверки, кадры, `Framer`) и
`modules/{client,internal,sandbox}.lua` — кодеки трёх контрактов. **Файлы генерируются** —
`python3 tools/olife/gen_codecs.py` из `tools/olife/protocol/*.yaml`; руками не править (проверка свежести —
`gen_codecs.py --check`). Описание схемы, формата и API — `tools/olife/README.md`.

```lua
local C = require "olife_proto:client"
local out = Bytearray()
C.append_frame(out, "ChatSend", {text = "hi"})       -- кадр в буфер отправки
local fr = C.framer()                                 -- на соединение
fr:feed(sock:recv(65536))
while true do
    local name, msg, id = C.read(fr)                  -- nil: ждать; false, причина: разорвать соединение
    if not name then break end
end
```

## Волна 4c: общие модули и предметы (рукописные, не генерируются)
- `modules/movement.lua` — детерминированный шаг движения игрока (модель физики игрока движка 0.32 фиксированным шагом
  0.05 с, столкновения по хитбоксам блоков, округление до f32 после шага), один и тот же на мире и клиенте; `hash`
  состояния для `MoveInput`/проверок. Тест в движке — `tools/olife/tests/movement_test.lua`.
- `modules/items.lua` — hash таблицы предметов и инвентаря, чтение движкового инвентаря.
- ~~`items/coin.json` — общий предмет `olife_proto:coin`~~ — **убран в UX round 1 (02.10, olife_ux1)** по замечанию
  пользователя («нахуя монетки»): своих предметов у пака нет (`content.json` пустой), стартовый набор мира — камень и
  доски; тесты инвентаря работают на них (ломание даёт новые). Мир, видевший монету, 0.32 без неё не открывает —
  `olife_world/server_start.lua` убирает её из `indices.json` мира (она последняя: номера других предметов не меняются).

## UX round 1 (02.10, olife_ux1): `modules/looks.lua` (рукописный)
Модели и текстуры, которые владелец может выбрать для сущности на странице «Настройки» (`EntityEdit` op 3): модели
пользователя из прототипа 0.30.6 (`olife_bench`, `olife_bone`, `olife_gravitygun`, `olife_injector` — файлы в
`olife_client/models`) и `block` движка; текстуры — `entities/olife_bench` (оригинал) и блоки `base`. Мир проверяет выбор
по этим спискам (иначе `RequestReply` 15), клиент их показывает и применяет `EntityLook`; `valid_name` — имя сущности.
