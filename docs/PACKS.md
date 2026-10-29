# Каталог паков

Машинно-читаемая версия — `catalog/packs.toml` (поля: слой, путь, происхождение, зависимости, последняя зелёная версия
движка, тесты, размер). Как переносить на свежий движок — `docs/PORTING.md`. Определения слоёв — `docs/PROJECTS.md` §0.

Происхождение у всех: снимок `lookibed/voxelcore-workbench-snapshot-2026-10` (`content/<имя>`); у части паков есть свой
репозиторий (`voxelcore-pack-doom|quake|gameboy|videoplayer|pong|wasmdemo|eaglercraft|minecraft2`, `voxelcore-wasmrt`).
Порт 0.31 → 0.32.1 (06–07.10, `port032`): wasmrt, doom, quake, videoplayer, eaglercraft, html, pc_wasmrt, gameboy, pong,
wasmdemo проверены на v032 без пересборки модулей Spider; правки — только у `pc_wasmrt` (`entity.glslf`, `vc.get_version`).
Числа ниже — из README/OPTIMIZATION самих паков (указано), а не новые замеры. «Зелёный» — последняя версия, на которой
пак доказанно работал по `agents/STATUS.md`, `OLIFE.md`, `ALPHAMINE.md` (копии — `projects/_snapshot_agents_docs/`).

## Слои
| слой | что это | паки |
|---|---|---|
| библиотека | пак без своего экрана, его используют другие | `wasmrt`, `gpu_compute`, `olife_proto` |
| пак | переиспользуемая единица: игра, программа, генератор, эффект | `doom`, `quake`, `gameboy`, `videoplayer`, `pong`, `wasmdemo`, `eaglercraft`, `halflife`, `html`, `smollm`, `smollm_gpu`, `gpu_worldgen`, `gpu_worldgen_light`, `blackhole`, `olife_caret_probe` |
| композиция | пак из паков | `pc_wasmrt` |
| проект | приложение со своим меню/сервером/приёмкой; паки + проект лаборатории | `alphamine` (`packs/alphamine` + `projects/alphamine`), `olife` (`olife_world`, `olife_client`, `olife_proto` + `projects/olife`) |

| пак | слой | зависит от | зелёный | размер, МБ | внешнее |
|---|---|---|---|---|---|
| wasmrt | библиотека | — | v032 | 1 | Spider (пересборка) |
| gpu_compute | библиотека | — | v032 | 1 | — |
| olife_proto | библиотека | — | v0327 | 1 | генератор `gen_codecs.py` |
| pong | пак | wasmrt | v032 | 1 | Spider |
| wasmdemo | пак | wasmrt | v032 | 1 | Spider |
| doom | пак | wasmrt | v032 | 17 | `doom1.wad` |
| quake | пак | wasmrt | v032 | 28 | `pak0.pak` |
| gameboy | пак | — | v032 | 2 | ROM |
| videoplayer | пак | — | v032 | 3 | mp4 |
| eaglercraft | пак | wasmrt | v032 | 113 | порт TeaVM (только локально) |
| halflife | пак | wasmrt | v031 (0.32.1 не запускался) | 142 | демо Uplink |
| html | пак | wasmrt | v032 | 41 | litehtml |
| smollm | пак | wasmrt | v032 | 98 | веса ~100 МБ |
| smollm_gpu | пак | gpu_compute | v032 | 158 | веса |
| gpu_worldgen | пак | base, gpu_compute | v032 | 1 | — |
| gpu_worldgen_light | пак | base, gpu_worldgen | v032 | 1 | — |
| blackhole | пак | base | v032 | 1 | — |
| olife_caret_probe | пак (служебный) | — | неизвестно | 2 | — |
| pc_wasmrt | композиция | wasmrt + паки ярлыков | v032 | 5 | — |
| alphamine | проект | base | v031 | 3 | Java-эталон, golden, ассеты |
| olife_world / olife_client | проект | olife_proto | v0327 | 1 / 3 | шлюз, sandboxd |

## Библиотеки
**wasmrt** — рантайм WebAssembly-программ, оттранслированных Spider в Lua: WASI (обычная libc: printf, fopen, время),
ABI `vc.h` (модель «кадр» `vc_init/vc_frame` или обычный `main`), графика `posteffect` (шейдер поверх мира), `canvas`
(растеризация на Lua), `gpu` (растеризация в UI-шейдере). Пак-программа описывает себя `wasm.json`. Начинать перенос с него
и `pong`: ломается окружение Lua — ломается всё. Как устроено — `docs/ARCHITECTURE.md`, старое — `agents/ARCHITECTURE.md`.

**gpu_compute** — «compute-шейдер» на стоковом движке, которого в API нет: фреймы `gui.create_frame` рисуются в текстуру
каждый кадр (буферы), один общий `shaders/ui.glslf` на мир (ядра всех клиентов — движок берёт файл одного пака), чтение
результата — `assets.to_canvas`. Проверка — `gpu_compute_both.py v031|v032`: генерация чанков и логиты LLM в одном мире;
общий шейдер стоит ~5 % ток/с (README пака). Дизайн — `agents/research/COMPUTE_API.md`.

**olife_proto** — сгенерированные кодеки протокола Olife (Bytearray, big-endian). Руками не править, `gen_codecs.py --check`.

## Паки
**pong** — минимальная C-игра на wasmrt с двумя бэкендами (`wasm.json` posteffect — в мире, `wasm_canvas.json` — и в меню).
Первый пак для проверки нового движка.

**wasmdemo** — `main()` + libc: плазма 160×100, приветствие из `data/greeting.txt`, долгий расчёт до первого кадра, `q` —
`exit 0`. Смоук WASI.

**doom** — doomgeneric C→wasm→Lua, первый эпизод shareware. Чем интересен: целая игра 1993 года в Lua движка без нативных
библиотек. Числа: 69–70 fps реального времени (35 тиков × 2 кадра) на 0.31 и 0.32.1; timedemo 221–224 fps на 0.31, 201.7 на 0.32.1 при
занятом ПК (`contended`, не регрессия); 120 fps старого пака — виртуальные часы (`packs/doom/OPTIMIZATION.md`, STATUS «port032»). Портировать после pong; проверка — `wasm_timedemo.json`.

**quake** — quakegeneric (GPL-2) C→wasm→Lua; треугольники растеризует GPU в UI-шейдере. 0.32.1, 854×480, realtime:
timedemo 37.3 fps (0.31: 35.8–37.0), на ПК `pc_wasmrt` 1408×902 — 37.6 fps (`packs/quake/README.md`). После демо
`Host_Error (longjmp)` + `[wasmrt] crash` — это нормальный выход Quake, не поломка.

**gameboy** — эмулятор GB/GBC binjgb C→wasm→Lua, без wasmrt (свой загрузчик старого формата — при переносе первым
кандидатом на поломку окружения). Замеры — `packs/gameboy/OPTIMIZATION.md`.

**videoplayer** — MP4/H.264 (h264bsd + minimp4) в Lua, кадры на canvas. h264 ~120 → ~31 мс/кадр с большим кешем,
1280×720 с RGBA ~800 → ~224 мс/кадр (`packs/videoplayer/OPTIMIZATION.md`).

**eaglercraft** — Minecraft 1.8 (Eaglercraft): Java → TeaVM → wasm → Lua. Самый длинный путь «целесообразность не наш
конёк»; вход в мир ≈ 60–70 с, мир на 0.32.1 9.3–10.7 fps (0.31: 7.5–9.2; STATUS «port032»). Порт исходников — только локально в Spider и в приватном `voxelcore-pack-eaglercraft`.
Тестировался MCP-инструментами `eag_*`; в новой лаборатории проекта нет — его надо завести.

**halflife** — Half-Life 1 на Xash3D FWGS (ref_soft) + hlsdk-portable, C/C++→wasm→Lua, демо Uplink. В паке лежат
`.bak` ветки `hl_gpu`. 854×480: 8.8 → 18.3–21.7 fps (12.10: ядра спанов на Lua, `jit_opt maxtrace=40000` — иначе через ~60 с
сброс трасс и 12 fps; `packs/halflife/README.md`). Зелёный на 0.31; копия в 0.32.1 разложена, но запуском не проверялась.

**html** — браузерная вёрстка: litehtml (gumbo, CSS 2.1 + flex + переменные) в Lua, демонстрационный сайт из 5 страниц
`site/` (вкладки, модальные окна, тёмная тема). Прототип.

**smollm** — LLM Ru-Small-Instruct 94M (Q8_0) на CPU: `runq.c` → wasm → Lua, только LuaJIT движка. 11.10: prefill
904 → 45 мс/токен, генерация 0.93 → 9.1 ток/с; v032 без правок — 49.1 мс/токен, 9.24 ток/с; логиты бит в бит с C
(`packs/smollm/README.md`). Тяжёлый: куча ~270 МБ, гонять только на свободном ПК.

**smollm_gpu** — та же модель целиком на GPU через UI-шейдер `gpu_compute`: токен (12 слоёв, логиты, argmax) — один кадр,
38–44 ток/с, логиты бит в бит (`packs/smollm_gpu/README.md`, `agents/research/SMOLLM_GPU.md`).

**gpu_worldgen** — генератор `gpu_worldgen:gpu`: чанк 16×256×16 считает GPU (3D-шум Перлина 5 октав, пещеры, слои), Lua
пишет `world.set_chunk_data`. Мир бит в бит одинаков на 0.31 и 0.32; хэши областей `b3e5e930/47a776dd/8589c44b/d1b78513`,
`rle_verify 50/50`. Lua 0.59–0.77 → 0.19–0.22 мс/чанк (README пака, `agents/research/GPU_WORLDGEN.md`). На 0.32.7 проверить
generator registry.

**gpu_worldgen_light** — небесный свет в шейдерах пака вместо движка: все блоки `base` и `gpu_worldgen` получают
`sky-light-passing`. A/B — `gpu_worldgen_ab.py`.

**blackhole** — чёрные дыры (0.32.1): граната, слияния в сверхмассивные, процедурный диск, преломление трассировкой луча
в пост-эффекте, звук. Логика 0.003/0.034/0.123 мс/кадр на 0/1/3 дырах (`packs/blackhole/README.md`). Обходит утечку
`audio.play_stream` 0.32.1. Проверка — `blackhole_check.py|.lua`.

**olife_caret_probe** — проба каретки textbox и шрифтов для клиента Olife; на 0.32.3+ обход шрифтом не нужен.

## Композиции
**pc_wasmrt** (до 07.10 — `Minecraft2`) — сущность-компьютер с экраном «Windows XP»: GUI рисуется во фрейм-текстуру на
материале экрана модели, ярлыки запускают wasm-паки, видео и встроенные программы. Паки ярлыков должны быть включены в
мире. Переносить последним из «пакетов» — после всех, кого он запускает.

## Проекты
**alphamine** — нативный клиент Minecraft Alpha 1.0.16 (протокол 14) паком, паритет с Java-эталоном (сервер Alpha SMP 0.1.1)
по F2F, golden и E2E. Фаза 2 (мир сервера виден), зелёный на v031. Внешнее — `projects/alphamine/external` (ref, golden,
assets, tables). Документ — `agents/ALPHAMINE.md` в снимке.

**olife** — сервер-мир (`olife_world`, headless VoxelCore — только симулятор) + клиент (`olife_client`, меню, логин по нику)
+ кодеки (`olife_proto`) + шлюз и песочница вне движка (`projects/olife/external`). Единственный проект, уже переведённый на
0.32.7: все сценарии зелёные кроме давно красного `olife_mobs`, такт мира p50/p95/max 5.99/6.68/8.95 мс = 0.32.0
(`agents/OLIFE.md` «Движок 0.32.7»).
