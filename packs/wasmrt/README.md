# wasmrt — запуск WebAssembly-программ в VoxelCore

Рантайм для программ на C (и любых языках с выходом в wasm32), собранных в WebAssembly и
оттранслированных в Lua транслятором Spider. Проект — отдельный пак,
который зависит от `wasmrt` и описывает себя манифестом `wasm.json`; графику проект выбирает сам.

## Что умеет

- **WASI** (`wasi_snapshot_preview1`): обычная libc без заглушек — `printf` (stdout/stderr в лог
  движка), `malloc`, аргументы и окружение, время, `getentropy`, `fopen`/`fread`/`fseek` для
  файлов пака (только чтение, каталог из манифеста виден программе как `/`), запись файлов
  в память, `exit`. Неизвестные вызовы отвечают `ENOSYS` и пишутся в лог один раз.
- **Графика — выбор проекта:**
  - `canvas` — команды (прямоугольник, круг, линия, очистка, спрайт, текст) растеризуются на
    Lua, или программа сама рисует кадр RGBA и отдаёт его (`vc_gfx_present`). Спрайты — из
    текстур `vc_gfx_texture(id, rgba, w, h)`. Работает везде: страница меню, HUD-оверлей в мире.
  - `posteffect` — команды рисует шейдер поверх мира (до 256 команд за кадр, ~1000 `vec4` —
    лимит uniform драйвера; текст занимает 1 + длина/7 команд). Спрайтов и кадрового буфера нет
    (пропускаются с предупреждением в логе). Только в мире: в меню постэффектов нет. Есть
    отладка шейдера через пиксели (параметр `u_debug`, MCP `vc_shader_cells`).
  - Текст (`VC_CMD_TEXT`) — встроенный шрифт 5×7 (символы 32–95, строчные рисуются
    прописными, шаг 6, масштаб — целый), одинаково в обоих бэкендах.
- **Ввод:** `vc_key_down("up")` — имена клавиш движка без `key:`; `vc_mouse(out)` — координаты
  в виртуальном экране и кнопки (в мире курсор обычно захвачен камерой).
  Захват курсора (аналог pointer lock): `vc_mouse_grab(1)` — `gui.set_active_frame("")` (null-фрейм,
  движок прячет и держит курсор), `vc_mouse_grab(0)` — вернуть прежний активный фрейм;
  `vc_mouse_delta(out)` — сдвиг `dx, dy` в пикселях окна с прошлого вызова (из
  `input.get_mouse_delta()`, копится по кадрам движка, пока захвачен). Кнопки при захвате — через
  `vc_mouse`. При выходе/падении программы курсор отпускается.
- **Звук:** `vc_audio_open(rate, channels)` и `vc_audio_write(samples, frames)` — поток PCM
  16 бит (`audio.PCMStream`); очереди нет, подавайте звук по времени.
- **Две модели программы:**
  - «кадр» — экспорты `vc_init()` и `vc_frame(dt_ms)`, хост вызывает `vc_frame` каждый тик;
  - «main» — обычный `main()` с бесконечным циклом в корутине: `vc_gfx_present()` /
    `vc_frame_end()` отдают управление до следующего тика; долгие вычисления сами уступают
    по кванту времени, если модуль собран с `spider-cli --yield-every N`.
- **JIT:** большой кеш трасс и `-loop` на время работы программы, сброс трасс перед новым
  экземпляром модуля (см. `OPTIMIZATION.md` паков gameboy/doom/videoplayer).

## WASM-4: публичные картриджи без пересборки

`"platform": "wasm4"` в манифесте запускает картридж фэнтези-консоли [WASM-4](https://wasm4.org)
(`modules/w4.lua` — порт эталонного нативного рантайма github.com/aduros/wasm4 на Lua:
кадровый буфер 160×160 и 4 цвета, `blit`/`blitSub`/`rect`/`oval`/`line`/`text`, звук APU из 4
каналов в поток PCM, `diskr`/`diskw` в `export:wasm4/<картридж>.disk`, `trace`/`tracef` в лог).
Картридж транслируется Spider как есть: `spider-cli cart.wasm -t lua-no-ffi > cart.lua`.

```json
{ "platform": "wasm4", "module": "export:wasm4carts/watris.lua" }
```

Клавиши: стрелки — крестовина, X / Space — кнопка X, Z / C — кнопка Z; мышь — над экраном.

Проверено на всех 151 картридже с сайта WASM-4 (репозиторий wasm4, `site/static/carts`,
лицензия CC BY-NC-SA 4.0 — в паки не входят): работают все 151 без правок (180 кадров без
нажатий, у всех что-то на экране; медиана 0.22 мс на кадр при бюджете 16.7 мс, 90% быстрее
2.5 мс); Watris и 3D-рейкастер wasmstein3d вживую идут ровно 60 кадров/с. Пять картриджей
(rolly-dango, spunky, starshard-scavengers, the-romans-are-coming, untangle) раньше упирались в
лимиты LuaJIT на функцию (250 слотов, 16-битные прыжки, 200 уровней синтаксиса); Spider теперь
передаёт широкие вызовы таблицей (`rt_call_spread`) и выносит длинные куски тела в замыкания
(подробности — `Spider/Hosts/README.md`). Проверка: сценарий `tools/scenarios/wasm4_all.lua`.

## Манифест `wasm.json`

```json
{
    "module": "mygame:modules/game.lua",
    "graphics": "canvas",
    "width": 320,
    "height": 200,
    "args": ["game"],
    "env": { "HOME": "/" },
    "files": "mygame:data",
    "slice_ms": 12,
    "frame_pacing": "present",
    "log_fps": false
}
```

`frame_pacing` (модель main): `present` — каждый `vc_gfx_present` заканчивает тик движка;
`slice` — кадры идут без остановки, пока не исчерпан квант `slice_ms`, на экране последний
(для бенчмарков). `log_fps` — раз в 5 с писать частоту кадров программы в лог.

Дополнительные поля:
- `"graphics": "tris"` — программа рисует как OpenGL: треугольники в экранных координатах и текстуры,
  растеризует шейдер UI на GPU (`modules/gfx_tris.lua`, режим `ui.glslf` по маркеру `#FF01FF80`;
  раскладка данных — в заголовке `gfx_tris.lua`). Используется паком `eaglercraft`.
- `"extension": "пак:модуль"` — свои импорты `vc.*` пака: модуль возвращает `function(ctx)` →
  таблицу функций (`ctx`: `manifest`, `gfx`, `log`, `frame_boundary`, `count_frame`, `api()`, `memory()`);
  функция `__tick` вызывается на каждом тике движка.
- `"profile": true` — профиль стека в точках уступки (раз в 5 мс), в лог раз в 5 с `[wasmrt] profile …`
  (номера строк модуля; имена по меткам `--[[fn:]]` переводит MCP `eag_profile`). При падении программы
  всегда пишется `[wasmrt] crash <строки>` (переводит `eag_crash`).
- Программы TeaVM (Java) получают импорты `teavmMath.*` (функции `math`) и `teavm.nanoTime`.
- `"jit_opt": ["+loop", ...]` (11.10) — дополнительные параметры `jit.opt.start` поверх `tuned` на время работы программы
  (smollm: `+loop` — LICM в матвеке, prefill 683 → 454 мс/токен на трансляции).
- `ctx.slice_yield()` (11.10) — для долгих импортов расширения: уступить кадр, если квант `slice_ms` исчерпан (ядра smollm).

## Запуск из своего пака

```lua
-- scripts/hud.lua: программа поверх мира (HUD-оверлей wasmrt:screen)
function on_hud_open()
    require("wasmrt:app").show_overlay("mygame:wasm.json")
end
```

Встраивание в свой документ (например, окно на экране компьютера `pc_wasmrt:pc` — фрейм
`gui.create_frame` в текстуре): `require("wasmrt:app").start(manifest, document, embed)`, где
`embed = { parent = контейнер, mouse_pos = function() -> {x, y}, release_grab = function(),
input_enabled = function() -> bool }` — картинка вписывается в `parent`, курсор берётся из
`mouse_pos` (координаты документа, как `wpos`), после захвата курсора активный фрейм возвращает
`release_grab`, клавиши/мышь (и захват) видны программе, только пока `input_enabled()`. Тики —
`app:tick()` вызывающего. Расширения паков получают `ctx.parent`, `ctx.mouse_pos`, `ctx.is_pressed`,
`ctx.input_enabled`.

В меню (только `canvas`): `require("wasmrt:app").set_pending("mygame:wasm.json")`, затем
`menu.page = "wasmrt_app"`; кнопка Back шлёт событие `wasmrt:leave_to_menu` для app-скрипта.
Из Lua: `app.start(manifest, document)` — экземпляр с `:tick()`, `:stop()`, `.status`,
`.message`, `.exports`.

## Сборка программы

Заголовок `vc.h` и WASI-хост лежат в Spider (`Hosts/VoxelCore/include/vc.h`,
`Hosts/Lua/wasi.lua`; копия последнего — `modules/wasi.lua`). Примеры с `build.sh` —
`tests/manual/real-world-pong` (модель «кадр») и `tests/manual/wasmrt-demo` (модель main).

```bash
clang --target=wasm32-wasip1 -O2 -I<Spider>/Hosts/VoxelCore/include game.c -o game.wasm
spider-cli game.wasm -t lua-no-ffi --yield-every 20000 > game.lua
```
Для модели «кадр» — `-mexec-model=reactor`. Модулю нужен экспорт `__host` (API памяти
Spider): его добавляют версии Spider начиная с этой.

## Примеры

- `pong` — модель «кадр», графика `posteffect` (`wasm.json`) или `canvas` (`wasm_canvas.json`).
- `wasmdemo` — обычный `main()` с libc: плазма в кадровом буфере, чтение файла пака, `printf`.
- `doom` — `doom:wasm.json` / `doom:wasm_timedemo.json`: doomgeneric с платформой на `vc.h`
  (Spider, `tests/manual/real-world-doomgeneric/src/dg_wasmrt.c`), WAD читается обычным
  `fopen` через WASI. Страница пака doom по-прежнему использует свой модуль и обвязку.

Замеры (эта машина): Doom `-timedemo demo1` через wasmrt на странице меню с выводом кадров —
183 кадра/с по счёту самого Doom (`frame_pacing: slice`); в игре — один кадр на тик движка.

## VoxelCore 0.32.1 (порт 06–07.10)
Рантайм работает на 0.32.1 без правок: API (`gui`, `input`, `gfx.posteffects`, `audio`, `jit.opt`, `loadstring`/`setfenv`)
и шейдеры `ui.glsl*`/`effect.glsl*` в 0.32.1 те же, что в 0.31 (`res/shaders` побайтно). Отличия окружения: стартовый сценарий —
штатный `--script <файл>` (не `autorun_app_script.txt`), запись из Lua — только `export:`/`config:` (`user:` требует разрешения
`write-to-user` проекта). Проверено на тестовой сборке 0.32 (dc62ccfb + F2F) с res 0.32.1, аренды лаборатории `wasmrt engine_rt
--param engine=v032` (realtime, 854×480): wasmdemo, pong (canvas), Doom 69.1 fps в игре / timedemo 201.7 fps (0.31: 221–224;
ПК был занят), Quake 37.3 fps / timedemo 969 кадров 26.0 с 37.3 fps (0.31: 35.8–37.0), html, Eaglercraft (профиль 50.9 fps,
мир 9.3–10.7 fps при 9.4 тыс. треугольников; 0.31: 7.5–9.2 при 12 тыс.). Копия пака — `voxelcore-0.32.1_win64\content\wasmrt`.
`wasm4_all` (151 картридж) на 0.32 не прогонялся.

## Дополнения 12.10 (пак halflife, аддитивно)
- WASI: `fd_readdir` и `stat` каталогов файлов программы (опция `list_dir` у `WASI.create`, в `app.lua` — по
  `file.list`/`file.isdir` каталога `files` манифеста): Xash3D ищет `pak`/`wad` списком каталога.
- `"cache_files": true` в манифесте — содержимое прочитанных файлов пака держится в памяти (Xash открывает
  `pak0.pak` 79 МБ заново на каждый файл внутри; без кэша — `file.read_bytes` всего файла на каждое открытие).
- `vc_gfx_present_rgb16(pixels, w, h)` (только `canvas`): кадр 16-битных пикселей программного рендера Xash3D
  (`ref_soft` `pixel_t`), 2 пикселя в тексель, цвет — шейдер UI (`ui.glslf`, маркер `#FF02FF80`, формула =
  таблица `R_BuildScreenMap` ref_soft, сверена на всех 65536 значениях и 845 кадрах Half-Life). Вдвое меньше данных,
  чем RGBA, и без 32-битного blit на CPU.
