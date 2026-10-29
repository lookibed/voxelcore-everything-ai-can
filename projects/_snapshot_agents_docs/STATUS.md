# Статус (на 30.09; лаборатория — 02.10)

## Сделано
- **Пак `content/blackhole`, волна 2 (15.10, агент blackhole-2; движок не менялся).** Сверхмассивные дыры: притяжение
  дыра↔дыра в радиусе 2 R(m) (`a = 2·0.15·m/d²`), слияние при касании горизонтов с суммой масс и импульсов, R(m) =
  2 + 8·cbrt((m−1)/1500) до `max_radius` 32 (4 × 2000 → одна 8733, R 10.80 → 16.39 за 2.8 с). Диск и преломление —
  в пост-эффекте: raymarch ≤ 72 шагов по лучу пикселя от мировых позиций дыр (`u_holes`/`u_info`/`u_info2`, камера —
  штатные `u_view`/`u_inverseView`/`u_projection`), изгиб луча как в onigiri, тонкий шумовой диск своего цвета (без жёлтого
  `getGlow`), smooth-min горизонтов (мягкое слияние), глубина из G-буфера при advanced-render; спрайт-диск из скелета убран.
  Схлопыватель `blackhole:collapser`, ударная граната `blackhole:impact_grenade`, `hole_egg` по `on_use` с импульсом
  1.2 × скорость игрока, движение по инерции (сохранение импульса, затухание `0.6/(1+m/100)`), время жизни
  `90·(1+ln(1+m/500))`, стирание блоков фрагментом (`VoxelFragment:place` + блок `blackhole:void`: воздух place не ставит)
  с авто-выбором по бюджету. Итог `artifacts/lab/runs/20261015_225714_wasmrt_wasmrt-engine_rt-1` (все проверки волн 1–2,
  16 кадров, `[E]` нет), с advanced-render `20261015_225536_…`; 3 дыры крупно без vsync 298–306 fps. Найдено: звук
  `block.place` (и осыпание песка `base:falling_block`) без ограничения голосов переполняет 255 источников OpenAL, после
  чего динамики остаются 255 — обойдено в паке. Подробно — `content/blackhole/README.md`. Копия —
  `voxelcore-0.32.1_win64\content\blackhole` (прежняя — `artifacts/blackhole_wave1_032_copy/`).
- **Пак `content/blackhole` — чёрная дыра на 0.32.1 (15.10, агент blackhole; движок не менялся).** Граната `blackhole:grenade`
  (ПКМ — бросок сущностью `blackhole:grenade_thrown`: отскоки от пола в `on_grounded` ×0.55, от стен по обнулению скорости,
  фитиль 2.5 с) и `blackhole:hole_egg`; дыра `blackhole:hole` (static, фазы birth/feed/collapse/merging): блоки слоями-кольцами
  изнутри наружу (4945 смещений r≤10 по расстоянию) в обломки с текстурами блока по сходящейся спирали в наклонный диск,
  притяжение `dynamic`-сущностей и игрока, слияние дыр, коллапс с выбросом блоков (`blackhole:ejecta` ставятся, где упали) и
  вспышкой; пост-эффект `blackhole:holes` на 8 дыр (`u_holes[8]`/`u_info[8]`, линза Эйнштейна, закрутка, горизонт, фотонное
  кольцо, аберрация); процедурный звук (WAV моно 22050 в `config:blackhole/sfx/`, играется звуками-ассетами); настройки
  `config:blackhole/settings.toml`. Проверка `tools/scenarios/blackhole_check.py|.lua` (аренда `wasmrt engine_rt` v032), итог
  `artifacts/lab/runs/20261015_035844_wasmrt_wasmrt-engine_rt-1`: 3+1 отскока, слияние, 3/3 предмета поглощены, коллапс 96/96 +
  82/82 + 82/82 блока поставлены, 7 кадров со сверкой горизонта по данным шейдера, `[E]` нет; без vsync 1624/1452/986 fps при
  0/1/3 дырах (логика 0.003/0.034/0.123 мс/кадр). Найдено в движке 0.32.1 (обойдено паком): `audio.play_stream` не освобождает
  динамики (лимит 255 источников OpenAL), `player.get_all_in_radius` сравнивает квадрат расстояния с радиусом, имена
  предметов и сущностей общие. Шаблон `tools/lab/projects/wasmrt/engine_settings.toml`: `[audio] enabled = {param.audio|false}`
  (умолчание прежнее; `.blackhole.bak`). Подробно — `content/blackhole/README.md`. Копия — `voxelcore-0.32.1_win64\content\blackhole`.
- **gpu_worldgen: предел записи за кадр по подаче движка (13.10, главная сессия).** В полёте темп `frame` писал 1 чанк/кадр при
  очереди 2500; теперь нижний предел = EMA чанков от `on_chunk_present` за кадр (≤ 24): полёт 20 ч/кадр, очередь пустая; хэши те же.
  См. README пака «Нижний предел записи за кадр».
- **gpu_worldgen — потолок прохода и «чанков на кадр» (13.10, агент gpu_cap; движок не менялся).** Проход по умолчанию
  768×432 (24 плитки) при любом окне (было — по окну до 2048×2048), `config:gpu_worldgen/settings.toml` поднимает до
  `min(окно, 2048)`; картинка прохода подгоняется под пакет (`gen.cfg.fit`); HUD/лог — размер прохода, плиток за проход,
  чанков на кадр (`gen.cpf`, строка `per frame`); исправлено чтение нижних высот у неполного пакета (`gpu.rle_heightmap`).
  Хэши `b3e5e930`/`47a776dd`/`8589c44b`/`d1b78513` те же, `rle_verify` 50/50, `gpu_compute_both.py v032` зелёный.
  Сценарий `tools/scenarios/gpu_worldgen_throughput.lua|.py` (ld 32 — максимум 80 не влезает в ОЗУ, полёт 160 блоков/с,
  темпы frame/raw, проходы 768×432/1408×902/2048×2048, 32 аренды `artifacts\lab\runs\20261013_003859…005833`, JSON
  `artifacts\gpu_cap\`): новый мир и полёт упираются в подачу движка (≈ 24 пустых чанка за кадр) и его свет/меши —
  больший проход не даёт ч/с (raw: 510–541 ч/с при 768×432, 389–404 при 2048×2048); выигрыш только в перезаписи
  загруженных чанков (raw 24 → 97 → 320 ч/кадр, 550 → 2200 записей/с при 7 fps, свет движка отстаёт). Умолчание 768×432
  оставлено. Найдено: темп `frame` в полёте пишет 1 ч/кадр (fps опускает сам движок) — не исправлялось.
  README пака «Потолок прохода», «Пропускная способность: чанков на кадр»; `GPU_WORLDGEN.md`.
- **gpu_worldgen против стокового генератора (13.10, агент gen_bench; движок и паки не менялись).** Сценарий
  `tools/scenarios/gen_bench_stock.lua|.py` (паки только `base`, та же процедура и метрики, что витрина; A/B чередованием с
  classic C = RLE + `gpu_worldgen_light`, F2F perf + trace). v032, 854×480, ld 8, `load-speed 32`, по 2 прогона
  (`artifacts\lab\runs\20261013_001827…002132`, JSON `artifacts\gen_bench\gen_bench_20261013_0018.json`): от открытия мира
  `base:demo` 764–846 ч/с (193 чанка за 0.27–0.29 с, 27–30 fps, p95 59–79 мс), classic 529–593 ч/с (0.82–0.89 с, 75–78 fps,
  p95 37); зона с мешами 0.36–0.39 против 0.77–0.90 с; CPU движка на чанк зоны 1.9 против 2.7–2.8 мс, на показанный чанк
  потока 2.4 против 2.6 мс; меши в потоке 313/с (прыжки игрока по новым областям) против 378/с (перезапись тех же чанков,
  880 записей/с) — потоки по действию разные, сравнимы только счётчики движка. Генерация CPU стока 0.41–0.59 мс/чанк против
  0.03 мс GPU, но запись поверх пустого чанка (создание 0.40, второй свет и меш, `set_chunk_data`) съедает выигрыш. Нижняя
  граница `base:flat_grass`: 1.0 мс/чанк. `GPU_WORLDGEN.md` «Сравнение со стоковым генератором», строка в README пака.
- **gpu_worldgen — RLE на GPU и свет в шейдерах пака (13.10, агент gpu_pack2; движок не менялся).** Поток extrle16 чанка
  считает цепочка из 7 проходов `gc.chain` (коды 3–9 программы `gpu_worldgen`: генерация, деревья, статистика слоёв, байты,
  префиксная сумма, поток); Lua копирует байты в gzip stored-блок с CRC32 и вызывает `set_chunk_data` (`gen.cfg.rle = true`
  по умолчанию, темп `pace = "frame"`). Паритет: поток GPU == Lua-кодер и == перекодированию движка на 50 чанках каждого
  пресета, хэши областей прежние (v032 и v031). Lua 0.59–0.77 → 0.19–0.22 мс/чанк; поток перезаписи зоны 616/433/443/399 →
  846/549/628/492 ч/с (classic/mountains/caves/islands) при fps не ниже. Пак-дополнение `content/gpu_worldgen_light`:
  небесный свет движка выключен свойством `sky-light-passing` у блоков (переопределение `base:*` из пака), уровень неба —
  шейдер мира по высотам столбцов из цепочки, AO — функцией плотности; `light_chunk` 0.88/1.42/1.34/2.06 → 0.64/0.74/1.00/0.76
  мс/чанк, поток 895/769/567/740 ч/с. Выключить свет движка целиком нельзя (`Lighting` создаётся всегда; граница `expand` и
  лампы остаются). Таблица и кадры — README `gpu_worldgen` («RLE на GPU и свет в шейдерах»), `GPU_WORLDGEN.md` («RLE на GPU»,
  «Свет»); сценарий A/B `tools/scenarios/gpu_worldgen_ab.py`. `gpu_compute_both.py v032` — хэши `b3e5e930`/`b06935b9`, LLM
  13/13 и 32/32; smollm_gpu 34.5–35.3 ток/с (тот же сегодня со старым телом worldgen: 34.1–35.1 — порог 36 сегодня не
  достигает ни одна сборка). Копии — `voxelcore-0.32.1_win64\content\{gpu_compute,gpu_worldgen,gpu_worldgen_light}`.
- **Half-Life (пак `content/halflife`) — 854×480: 8.8 → 18.3–21.7 fps (12.10, агент hl_gpu; движок не менялся).** Без GPU-растеризации:
  ~50% кадра LuaJIT исполнял интерпретатором (горячие функции `ref_soft` не становятся трассами), поэтому — ядра спанов на Lua
  (`modules/hl_kernels.lua`, импорт `vc.hl_spans`, `D_DrawSpans16`/`D_AddSpans16`/`D_DrawZSpans` бит в бит), studio-модели в два
  прохода (`r_studio.c`/`r_triapi.c`), `TriTexCoord2f` без `fmodf`, пост-обработка Lua `tools/f32_inline.py` (помощники f32 и
  загрузки/записи — одна функция вместо 2–3 вызовов), `"jit_opt": ["maxtrace=40000","maxmcode=262144"]` (иначе через ~60 с
  сброс всех трасс и 12 fps). Хэши 845 кадров вне движка совпадают со сборкой до правок. Итог `halflife_check.py`: 18.3 fps
  (ПК свободен, `artifacts/lab/runs/20261012_043033_*`), 640×360 — 22.5; таблица шагов — `content/halflife/README.md`.
  Исходники — Spider `tests/manual/real-world-halflife/` (`patches/xash3d-fwgs.patch`, `build.sh`, `tools/f32_inline.py`,
  `run_luajit.lua`: `HL_PROF_MODE=vF`, `HL_JITSTAT`, JIT как в wasmrt). Копия пака и `content/wasmrt` (hl_port: rgb16,
  `cache_files`) — в `voxelcore-0.32.1_win64/content` (не проверено запуском 0.32.1). Следующее: оставшиеся
  интерпретируемые `R_ClipEdge`, `R_RecursiveClipBPoly`, `R_StudioDrawPoints`; GPU-путь (`gfx_tris`) — к 30+ fps.
- **gpu_compute — API «compute-шейдера» и оба GPU-клиента в одном мире (12.10, агент gpu_api; движок не менялся).** Пак
  `content/gpu_compute`: один общий `shaders/ui.glslf` с диспетчером программ по цвету картинки (`#RRGGBB80`, B = 255:
  R — банк, G — код), собирается заранее `tools/gpu_compute_build.py` из тел `content/<пак>/shaders/gpu_<имя>.glsl` (в Lua
  нет API шейдеров, каталог пака не пишется — проверено в движке); Lua-API `gpu_compute:compute` — program/params/buffer/
  page/pass/submit/read/chain/frame/idle/limits/codec/budget, порядок фреймов — проба с кешем `config:gpu_compute_order.json`.
  `gpu_worldgen` и `smollm_gpu` переведены (свои `ui.glslf` -> `*.api.bak`, тела — `gpu_worldgen.glsl`, `gpu_smollm.glsl`,
  зависимость от gpu_compute). **Сценарий `tools/scenarios/gpu_compute_both.py v031|v032`**: в одном мире генерация
  (хэш `b3e5e930`), ответ LLM 13/13 токенов == C, затем ответ 32/32 == C одновременно с генерацией новой области (хэш
  `b06935b9` == прогону без LLM) — зелёный на обеих версиях. Регресс: worldgen-пресеты `47a776dd`/`8589c44b`/`d1b78513`,
  LLM логиты 24576/24576 бит в бит; цена общего шейдера — регистры: LLM 35–37 ток/с (без тела worldgen 38–39), было 31
  до правок тела worldgen (`GP(i)`, маски, специализация пресета); worldgen classic — A/B с кодом до API подряд
  307 против 309 ч/с (сегодняшний ПК; запись README 420–432 ч/с с ним не сравнима). Пример `examples/noise` + `gpu_compute_check.py`
  (0.047 мс на проход 256², ~207 проходов за кадр 60 fps). Подробно — `content/gpu_compute/README.md`,
  `agents/research/COMPUTE_API.md` «Сделано». Копии — `voxelcore-0.32.1_win64\content\{gpu_compute,gpu_worldgen,smollm_gpu}`.
- **gpu_worldgen — три пресета-витрины (12.10, агент gpu_show; движок не менялся).** «Горы и арки» (Amplified: 3D-fbm
  400 блоков на единицу шума, башни и нависания до y 236, туннели насквозь, снег/скалы, водопады), «Пещерные миры» (1.18:
  обычная поверхность, внизу залы-«сыр» с колоннами, «спагетти»/«лапша», воронки к небу, водоносные ячейки воды/лавы с
  барьерами, аметист и светокамень), «Парящие острова» (три уровня, корни-конусы, мосты-арки, водопады в пустоту,
  светокамень под островами). Своя функция плотности и правила материалов в `ui.glslf` (`gw_preset_main`), параметры —
  `modules/presets.lua`, генераторы `gpu_<пресет>.toml`; новые блоки пака snow/lava/crystal/glowstone; деревья в Lua.
  «Сценарии» → gpu_worldgen — страница с кнопками пресетов и полем seed (возврат на неё после мира); в мире F6 /
  `gpuwg.preset` перезаписывает загруженные чанки. **v032, 854×480, load-distance 8, не contended: mountains 306–311
  ч/с, 54.4–54.7 fps; caves 299–304, 53.9–55.7; islands 299–303, 50.1–50.7** (classic сегодня 432 ч/с, 59.6 fps = README).
  Разница с classic — свет и меши движка (`light_chunk` 1.5–2.2 мс/чанк против 1.0), не GPU (0.02–0.06 мс/чанк) и не Lua
  (0.58–0.75 мс/чанк); поэтому меньше светокамня, свет 12 и `target_fps` 50. Детерминизм: хэши `47a776dd`/`8589c44b`/
  `d1b78513` одинаковы в 3 прогонах v032 (854×480 и 1408×902) и на v031. Кадры 1408×902 (по 4–6 на пресет) — README пака
  «Пресеты-витрины». Сценарии `gpu_worldgen_showcase.lua/.py`, `gpu_worldgen_menu_test.py`. Копия — `voxelcore-0.32.1_win64`.
  **Не сделано:** CPU-референс пресетов (паритет проверяется только на classic); замеры 0.31 только contended.
- **smollm: диалог и семплирование по карточке модели (11.10, главная сессия).** Карточка найдена (`longtimedevs/Ru-Small-Instruct`):
  шаблон одноходовый, рекомендованы temperature 0.25 / top_p 0.85 / repetition_penalty 1.15 — теперь умолчания пака (штраф за
  повторы добавлен в `main_vc.c`, param 7); контекст по умолчанию сбрасывается перед каждым вопросом (флажок «помнить диалог»),
  т.к. с историей модель копирует прошлый ответ и в нативном эталоне. Паритет лаборатории при `0 0.85 1 120` — бит в бит на
  v031/v032. Драйвер диалога `tools/scenarios/smollm_dialog.py`. Подробно — `content/smollm/README.md` «Диалог и семплирование».
- **smollm на CPU: 904 → 44.8 мс/токен prefill, 0.93 → 9.13 ток/с (11.10, агент llm_cpu; движок не менялся).** Три шага с
  паритетом бит в бит (логиты `cmp`, токены = эталон): (1) forward разбит на ядра `k_*` + профиль `kprof` + самопроверка ядер
  по `reference/kernels`; (2) Spider `lua-no-ffi`: `--f32 number` (f32 — число Lua, опция; конформанс 272/40, лишние 8 — знак/
  полезная нагрузка NaN) и для всех модулей ветвления по знаку в i32-сравнениях/расширениях убраны, константы f64 литералами
  (конформанс по умолчанию 280/32 как было, lua-jit 312/312, `verify.sh quick` зелёный; Doom timedemo 232/228 fps, Quake 39.1/
  39.9/37.3 — не хуже README, кадры бит в бит в стоковом LuaJIT); wasmrt: поле манифеста `jit_opt`, `ctx.slice_yield`;
  (3) ручные Lua-ядра пака `llm_kernels.lua` (матвек Q8 1.1 GMAC/с, внимание с кэшем K/V в числах) и батч prefill 16
  (два токена в одном double). v032: 49.1 мс/токен, 9.24 ток/с. Таблицы по шагам и ядрам, прогоны — `content/smollm/README.md`
  «Ускорение 11.10». Копия пака и wasmrt — в `voxelcore-0.32.1_win64`.
- **gpu_worldgen — генерация мира на GPU стокового движка средствами пака (11.10, агент gpu_gen; движок не менялся).**
  Пак `content/gpu_worldgen`: мир на стоковом генераторе пустоты `gpu_worldgen:gpu`. По `on_chunk_present` чанк встаёт в
  очередь, свой `ui.glslf` (маркер `#FE03FF80`) во фрейме `gpuwg_fb` 768×431 считает 3D-шум (улучшенный Перлин, fbm из
  5 октав, пещеры-«спагетти» по порогу, слои дёрн/земля/песок/камень/уголь/вода/базальт) — 30 чанков за проход,
  1 пиксель = 6 вокселей. Чтение `assets.to_canvas`, кодирование extrle16+gzip, `world.set_chunk_data` с бюджетом
  6 мс/кадр. **v032: 193 чанка за 0.55 с, 420 ч/с, 59 fps; Lua 0.59 мс/чанк + GPU 0.01 мс против CPU-референса 370–540
  мс/чанк (1.8 ч/с, 1.9 fps); v031: 1.53 с, 136 ч/с, 36 fps.** Паритет с CPU: 1 воксель из 262144 (порог пещеры во
  float32), знак плотности 0/131072. Детерминизм: хэш области `b3e5e930` в 14 прогонах (0.31 и 0.32 одинаково).
  «Сценарии» → gpu_worldgen; лаборатория — `tools/scenarios/gpu_worldgen_run.py` (`--repeat`, `--expect`, sysload,
  кадры F2F). Копия — `voxelcore-0.32.1_win64\content\gpu_worldgen`. Разбор: `agents/research/GPU_WORLDGEN.md`.
  **Не сделано:** биомы, деревья, структуры; паритет бит в бит (fp64); чистые замеры (все contended из-за GPU-фона
  ПК). В движок упирается: нет хука «готовые воксели» у Lua-генератора (его Lua-состояние без `gui/assets`), фрейм не
  больше окна, `ui.glslf` пака конфликтует со `smollm_gpu`.
- **smollm_gpu — чат с моделью на GPU-пути (12.10, агент llm_gpu_chat; движок не менялся).** «Сценарии» → smollm_gpu теперь
  открывает чат (раскладка CPU-пака `smollm`: поле ввода/Enter/«Отправить», лента «Вы/Модель» с печатью по токенам — один токен
  = один кадр движка, статус с ток/с и контекстом из 512, «Стоп», «Очистить», «помнить диалог», «Назад»; прежнее демо —
  кнопка «Демо»). BPE-кодировщик на чистом Lua (`modules/bpe.lua`, перенос `tokenizer.c`): **326 фраз / 7623 токена бит в бит с
  C на стоковом luajit и в движке v031/v032, decode байт в байт**. Семплирование по карточке (0.25 / 0.85 / 1.15 / 120) на Lua
  поверх логитов LG (`get_data`, 0.1–0.4 мс семплер); argmax-режим `0 0.85 1 120` — токены промптов 1, 2, 4 = эталон, логиты
  24576/24576 на обоих движках; «помнить диалог» держит KV-кэш во фреймах между ходами — логиты 2-го хода бит в бит с C на том
  же контексте. **Генерация 40–45 ток/с (с семплированием 40–43), prefill 21–23.5 мс/токен на 0.31 и 0.32** = числам демо 11.10.
  Сценарии `tools/scenarios/smollm_gpu_chat.lua`, `smollm_gpu_check.py v031|v032 [--ui]`, `smollm_gpu_dialog.py`; стенд
  токенизатора — Spider `tests/manual/real-world-smollm-gpu/chat/`. Подробно — README пака «Чат», `agents/research/SMOLLM_GPU.md`
  «Чат». Копия — `voxelcore-0.32.1_win64\content\smollm_gpu`. **Не сделано:** бэкенд «GPU/CPU» в паке `smollm` (чат живёт в
  `smollm_gpu`), top-k на GPU (не нужен: чтение логитов — ожидание того же кадра), скользящее окно контекста.
- **smollm_gpu — та же LLM целиком на GPU стокового движка средствами пака (11.10, агент llm_gpu; движок не менялся).**
  Пак `content/smollm_gpu`: фреймы `gui.create_frame` = страницы памяти (418 фреймов, порядок отрисовки — хеш-таблица
  движка, узнаётся пробой и кешируется), свой `ui.glslf` = вычислительные режимы (маркер цвета `#FF<режим>FF80`, fp64 для
  деления/корня/exp), веса 138 МБ → 117 текстур через `Canvas:_set_data`, результат — `assets.to_canvas`. Весь токен — один
  кадр: **~44 ток/с, prefill ~22–23 мс/токен на 0.31 и 0.32** (промпт 4: 39 ток/с, 22.8 мс/токен против CPU 0.93 ток/с,
  904 мс/токен), загрузка 0.18 с, логиты бит в бит с C, токены 13/13, 32/32, 26/26. Демо — «Сценарии» → smollm_gpu
  (страница с ответами), прямой запуск `tools/scenarios/smollm_gpu_demo.lua`, пробы `smollm_gpu_run.py`. Копия —
  `voxelcore-0.32.1_win64\content\smollm_gpu`. Данные — Spider `tests/manual/real-world-smollm-gpu` (README, пересборка
  `cmp`-совпадает). Разбор и план: `agents/research/SMOLLM_GPU.md`. **Не сделано (на 11.10; чат и семплирование — 12.10,
  запись выше):** бэкенд «GPU/CPU» в паке `smollm`; в движок упирается: перерисовка фреймов
  каждый кадр (копирование весов ~4 мс/кадр, GPU занята, пока экземпляр открыт), одна текстура в UI-шейдере, выход RGBA8
  со смешиванием, порядок фреймов по хеш-таблице. Замеры не через `lab perf` (фон GPU рабочего стола 25–40 %).
- **smollm — LLM Ru-Small-Instruct (94M) в движке через Spider (08.10, агент llm_port; движок не менялся).** Новый пак
  `content/smollm` (пункт «Сценарии» → smollm: XML-страница чата, ответ по токенам, статус, стоп/сброс; README пака),
  исходники — Spider `tests/manual/real-world-smollm` (`export.py` safetensors bf16 → Q8_0 чекпоинт llama2.c v2 100 347 136 Б,
  `tokenizer_export.py` → 645 262 Б, `src/*.c` по `runq.c` llama2.c (MIT, `THIRD_PARTY.md`) + свой ByteLevel BPE, `fmath.c`
  вместо libm, `build.sh`, `run_luajit.lua`, эталоны `reference/`), цель `deploy.sh smollm` (не в `all`).
  **Паритет:** токенизатор 26 фраз = HF `tokenizers` (0 расхождений); логиты первого токена из движка **побайтно равны**
  нативному C (промпты 1, 2, 4), токены при temperature 0 те же; C против numpy-эталона HF-семантики — argmax/top-5 равны,
  |Δ| ≤ 0.157 от Q8 (transformers/torch нет). **Замеры** (F2F 0.31 realtime 854×480, ПК свободен, `lab sysload`): загрузка
  весов 0.71 с, prefill 93 токенов 904 мс/токен, генерация 0.93 ток/с, куча Lua 274–365 МБ (стоковый JIT: 977 мс/токен,
  0.85 ток/с, +loop грузит веса за 0.45 с); нативно 19.8 мс/токен и 49 ток/с. Матвек «веса словом по 4 int8» (`MATMUL=1`):
  1079 → 809 мс/токен в стоковом LuaJIT, бит в бит; сумма в double — медленнее (LESSONS «LLM на wasmrt»).
  **Лаборатория:** `tools/scenarios/smollm_chat.lua` (старт страницы, авто-промпт из `export:`), `smollm_check.py` (аренда
  `wasmrt engine_rt`, ввод F2F `input`, паритет токенов/логитов, кадр) — прогоны `artifacts\lab\runs\20261008_000304…`,
  `…000353…` (перф), `…000554…` (стоковый JIT); **v032** (F2F-032 + res 0.32.1) — `…000806…`: без правок пака, 793 мс/токен,
  1.13 ток/с, логиты бит в бит; копия пака — `voxelcore-0.32.1_win64\content\smollm`. **Не сделано:** батч prefill и дальнейшее ускорение (упёрлось
  в представление f32/i32 у Spider — резерв в трансляторе), repetition penalty/сэмплирование в UI (есть в коде, выключено ради
  детерминизма), крупный шрифт (в XML 0.31 размера шрифта нет), NFC-нормализация входа.
- **Пак `Minecraft2` переименован в `pc_wasmrt` (07.10, главная сессия)** — id, каталог, `scripts/app/pc_wasmrt.lua`, все
  ссылки в паках/сценариях/лаборатории/документах; миры 0.31 (`fineltest`, `Minecraft2`, `PC Test`, `PC Test Plain`, `New World 1`)
  и копия `fineltest` в 0.32.1 — `packs.list`/`indices.json`/`resources.json` с `.bak_minecraft2` рядом. Паки в
  `voxelcore-0.32.1_win64\content` пересинхронизированы с 0.31. Пак пользователя `voxelcore-0.31.4_win64\content\Minecraft2` не трогался.
- **pc_wasmrt UX 07.10 (агент pc_ux; план «ПК» из README пака — сделан целиком, движок не менялся):** обои
  `textures/gui/wallpaper.png` (скрипт: холм, облака, пиксельная надпись wasmrt); ярлыки перетаскиваются (позиции — `config:pc_wasmrt/
  desktop.json`), ярлык на Корзину — в корзину; Корзина (ярлыки + файлы из проводника в `config:pc_wasmrt/trash/`, восстановление,
  очистка); Paint (холст 800×560, цвета/размеры/ластик, `Canvas:encode("png")` → `export:pc_wasmrt/paint_N.png`); Проводник (`config:`,
  `export:`, `user:screenshots`; `.png` — просмотр `Canvas.decode`, `.mp4` — `videoplayer:decoder` в окне, двойной клик, «в корзину»);
  камера: ПКМ — курсор на экране, **камера на месте**; «залочиться/отпустить» (камера к экрану + курсор заперт в экране),
  вертикальный ползунок зума (0 — своя камера, 1 — экран во весь кадр), Настройки (притягивание и лок при входе — по умолчанию
  выключены). Обработчик F2F `pc` (`state`, `map` экран→окно, `launch`, `enter`, `lock`, `zoom`) регистрируется из `scripts/world.lua`
  (только тестовая сборка). Сценарий `pc_world.lua` ставит ПК сам, если его нет (в `fineltest` старых `minecraft2:pc` нет),
  экраном к игроку. **Проверка `tools/scenarios/pc_ux_check.py`** (24 шага, ввод F2F `input` через `labpipe.py`, кадры F2F `shot`):
  v031 — `artifacts\lab\runs\20261007_005920_wasmrt_wasmrt-world-1` (кадры `036..072_*`), v032 —
  `artifacts\lab\runs\20261007_011014_wasmrt_wasmrt-world-2` (`001..019_*`): 24/24 на обоих; Doom на ПК v031 69.9–70.1 fps, v032
  70.0 fps (README 56–69 / 69.0; ПК занят — `lab sysload` GPU 36–43 %, `contended`). Копия пака — `voxelcore-0.32.1_win64\content\
  pc_wasmrt` (rsync без `*.bak`). Файлы: `content/pc_wasmrt/modules/pc_os.lua` (переписан, `.0710.bak` рядом), `pc_textures.lua`
  (спрайты), `scripts/world.lua`, `textures/gui/wallpaper.png`, `README.md`, `package.json` 0.2.0; `tools/scenarios/pc_world.lua`,
  `pc_ux_check.py`, `tools/scenarios/README.md`; LESSONS «pc_wasmrt UX».
- **pc_wasmrt: XML-оверлей вокруг ПК как у dagger_pc (07.10, агент pc_ux2; движок не менялся):** кнопки «встать»,
  «залочить/отпустить мышь», «приблизить/отдалить» и стикеры-подсказки («камера: на месте/у экрана (поз/рот лок)», «мышь:
  свободная/заперта в экране», «Esc - встать · Right Ctrl - лок мыши», «в программе: Esc удержать 1 с») — в
  `content/pc_wasmrt/layouts/pc_overlay.xml(.lua)`, `hud.show_overlay` при входе за ПК / `hud.close` при «встать» (видны только в
  ПК); стикер «ПКМ - сесть за компьютер» под прицелом при взгляде на ПК — `layouts/pc_hint.xml(.lua)` (`hud.open_permanent`).
  Из экрана убраны кнопки панели задач и ползунок зума. **HUD игрока (хотбар, прицел) в ПК спрятан** режимом оверлея движка
  (`hud.show_overlay` → `inventoryOpen`; функции видимости HUD в `hud` 0.31/0.32 нет; вызов на обеих версиях один и тот же),
  возвращается при «встать». Мышь между фреймом экрана и оверлеем — `PC:route_mouse` (активный фрейм по положению мыши). Right Ctrl —
  лок мыши. Приёмы dagger_pc (не код): оверлей на весь viewport, стикер у кромки с текущим режимом, host key, опрос viewport.
  Проверка `tools/scenarios/pc_overlay_check.py` (14 шагов) и обновлённый `pc_ux_check.py` (24): прогоны — см. «pc_ux2 прогоны» ниже.
  Копия пака — `voxelcore-0.32.1_win64\content\pc_wasmrt` (rsync без `*.bak`). Файлы: `modules/pc_os.lua` (`.0710_ux2.bak`),
  `layouts/pc_overlay.xml(.lua)`, `layouts/pc_hint.xml(.lua)`, `scripts/hud.lua`, `README.md` «Оверлей и управление»;
  `tools/scenarios/pc_overlay_check.py`, `pc_ux_check.py`, `tools/scenarios/README.md`; LESSONS «pc_wasmrt оверлей».
  **pc_ux2 прогоны (07.10):** `pc_overlay_check` v031 — `artifacts\lab\runs\20261007_015408_wasmrt_wasmrt-world-1` (кадры `001..011_*`), v032 — `…20261007_015444_wasmrt_wasmrt-world-1`: 14/14 на обоих (кадры в ПК без хотбара/прицела — `001_…01_in_pc_no_hud`, после «встать» с HUD — `010_…10_standup_hud`), Doom на ПК 70.0 fps на обоих (README 56–69 / 69.0; ПК занят — `lab sysload` GPU 34–39 %, `contended`); `pc_ux_check` v031 — `…20261007_015216_wasmrt_wasmrt-world-1`, v032 — `…20261007_015312_wasmrt_wasmrt-world-1`: 24/24 на обоих (Doom 66.0 fps при 52 % CPU других процессов / 69.8). Первые прогоны оверлея (до замены «—» на «-»): `…015029` (v031), `…015113` (v032), тоже 14/14.
- **Порт паков и мира пользователя на стоковый релиз 0.32.1 (06–07.10, port032):** паки `wasmrt, doom, quake, videoplayer,
  eaglercraft, html, pc_wasmrt, gameboy, pong, wasmdemo` разложены копиями в `D:\Prog\VoxelCore\voxelcore-0.32.1_win64\content`
  (`rsync` из `content/`, без `*.bak`), мир `worlds/fineltest` — копией в `...\voxelcore-0.32.1_win64\worlds\fineltest`
  (оригинал не тронут, `diff -rq` копии = оригинал; миграции не нужно — 0.32 сам переписывает `world.json` version 0.31→0.32,
  `rules.toml`, `resources.json`, `indices.json`/регионы не трогает — проверено на копии под F2F 0.32). Разница dc62ccfb → v0.32.1
  (46 коммитов, 25 файлов; в stdlib/API паков — ничего, только анимации VCA, `xml.tostring`, `selectable` у static,
  лимит очереди чанков 64, deferred-шейдер) — `agents/research/VC032_ADAPTATION.md` §6. **Правки паков:** pc_wasmrt
  `shaders/entity.glslf` (ветка 0.32.1 с `u_dithering`, работает и в 0.31) и убран подменный `entity.glslv` (`legacy_0.31/`),
  `modules/pc_os.lua` (версия движка в меню «пуск» через `vc.get_version()`, в 0.31 «0.31»); остальные паки — без правок,
  модули Spider не пересобирались (md5 = `generated/`). Лаборатория: проект `wasmrt` получил `[engines.v032]` (res/stock
  0.32.1 + F2F-032), `--script` для 0.32 (`by_engine.v032`), виды `engine_rt` (realtime, `ready` по строке лога) и `world`
  (копия мира + паки + `pc_world.lua`, `--param launch=doom|quake|eaglercraft|video`); `tools/scenarios/pc_world.lua` —
  `export:pc_launch.txt`. **Проверено на v032 (F2F dc62ccfb + res 0.32.1, аренды `wasmrt-engine_rt-1`/`wasmrt-world-1`,
  прогоны `artifacts\lab\runs\20261006_2337..20261007_0004_wasmrt_*`):** wasmdemo (40 fps своего темпа), pong canvas, Doom
  69.1 fps / timedemo 201.7 fps (окна 5 с 158→229; ПК занят — `contended`; 0.31: 221–224), Quake 37.3 fps / timedemo **969
  кадров 26.0 с 37.3 fps** (0.31: 35.8–37.0), html (parse+style 1364 мс, layout 122, js 273, paint 189 = 1.95 с до первого
  кадра; 0.31: ≈2.3 с), Eaglercraft: профиль 50.9 fps, меню → Singleplayer → список миров (сервер Node по IPC) → экран создания,
  сохранённый мир **9.3–10.7 fps при 9.4 тыс. треугольников** с туманом (0.31: 7.5–9.2 при 12 тыс.), gameboy (калибровка
  JIT 152–234 fps), videoplayer sample.mp4 12 fps / 39 мс декод, doom-страница старого хоста 144 fps. **Мир fineltest на v032
  при 1408×902:** «ПК» рисуется (рабочий стол XP, меню «пуск» кликом через проекцию курсора F2F), Doom 69.0 fps, Quake 37.6,
  Eaglercraft профиль 59.7, видео 12.2 (0.31 README: 56–69 / 22–38 / 58–74 / 12). Ошибок Lua в логах нет. Регресс на v031:
  тот же мир, Doom на ПК 69.0 fps с новым шейдером. **Грабли:** фрейм 1024×724 не рисуется при окне ниже 724 px (белая
  текстура на обеих версиях — свойство `Frame::draw`, не порт), `vc.get_version()` даёт два числа, realtime-аренда не шагает,
  `lab.toml` ссылается на несуществующий `voxelcore-0.32_dc62ccfb` — LESSONS «Порт … 0.32.1». Движок и ядро лаборатории не
  менялись; стоковый 0.32.1/0.31 не запускался; `verify.sh quick` не гонялся (Spider не менялся, `/root/Spider/target`
  удалён пользователем, на D: свободно 18 ГБ). Пользователю: `voxelcore-0.32.1_win64\VoxelCore.exe` → мир `fineltest` → ПКМ по
  компьютеру → ярлыки; меню «Сценарии» → `quake`/`html`/`doom`/`gameboy`/`video_player`/`eaglercraft` (сервер — `node
  launcher.js`); `wasm4` на 0.32 не прогонялся.
- **Olife — игра с друзьями по сети (16.10, olife_friends):** `play.bat public` (= `lab play olife --user --public`,
  `lab olife play-up --public`): шлюз, сервис билетов и раздача паков на 0.0.0.0, порты 27750/27751/27752 (`[play.public]`),
  admin/f2f и демон — 127.0.0.1, вайтлист включается; друг вводит одну строку `ip:27750#отпечаток` и ник — клиент спрашивает
  шлюз `InfoRequest` -> `ServerInfo` (новые id 7/76, Disconnect 19; кодеки и Rust-шлюз пересобраны, `cargo test` 24/24),
  отпечаток/TOFU ключа сервиса билетов; `play.bat friend НИК` (вайтлист + строки LAN/внешний IP), `lab olife ip`,
  `lab olife bundle` -> `D:\Prog\Olife\dist\olife_client_<дата>.zip` (стоковый 0.32 + копии паков, `OLIFE.bat`, `ПРОЧТИ.txt`).
  Мир: пак закрывает не-loopback соединения на внутреннем порту (движок слушает 0.0.0.0). Сценарии `olife_public`,
  `olife_bundle` + регресс — `agents/OLIFE.md` «Игра с друзьями», модель угроз — `agents/research/OLIFE_PUBLIC_PLAY.md`.
  Движок не менялся, `lab daemon upgrade` не нужен. Не проверено: вторая машина/роутер/брандмауэр, стоковый exe.
- **Olife — антифрод и бан по IP (16.10, olife_antifraud):** бан по IP/CIDR со сроком и причиной в таблице `bans`
  супервизора — сервис билетов (`ip_banned` «бан по IP … до …»), оба шлюза до Hello и на сессиях (вызов `olife.gw_sync` раз
  в 2 с + F2F `kick_ip` сразу), мир (`/ban ip`, `/unban ip`, `/bans`, `/players` с IP/маской) = `lab olife ban --ip` = панель;
  антифрод (`olife_fraud.py` плагина + мир `fraud.lua`): защита ника (зарезервированные, похожие, в игре с другого IP —
  `nick_in_use`/Disconnect 18, grace), лимиты входа по IP и /24, мультиаккаунт, сессии с IP, автобан IP 60 → 120 с …,
  скоринг в игре (Notice 13 → 14 throttle → kick → автобан аккаунта, 2-й — и IP), `/fraud`, `lab olife fraud …`, доверие
  после снятия. `olife_ipban` 26/26 и `olife_antifraud` 50/50 (vc и rs), регресс 7 сценариев × vc/rs ok. Движок не менялся,
  схема — только комментарии; Rust-шлюз пересобран и разложен. Ждёт `lab daemon upgrade`: секция Antifraud панели
  (`labcore/supervise.py`). Подробно — `agents/OLIFE.md` «Антифрод и бан по IP», `agents/research/OLIFE_ANTIFRAUD.md`.
- **Olife — UX B: меню клиента, экран статуса входа, вайтлист по нику (16.10, olife_menu):** «Сценарии» -> olife открывает
  меню клиента (нативный XML 0.32: `<modelviewer>` VCM-сценки из моделей пака с вращением камеры, ip:port + ник, «Войти»,
  последние серверы в `config:`), экран статуса показывает каждую фазу входа (билет -> шлюз -> Welcome -> манифест -> файлы с
  байтами и полосой -> sha256 -> мир-реплика после паков -> чанки) и ошибки с кодом и причиной + «Повторить»/«Назад»; в игре
  тот же экран (HUD) — паки на лету и «мир перезапускается, держитесь». Вход по нику + вайтлист (`/whitelist`, `lab olife
  whitelist`, панель после upgrade). `olife_menu_status` 21/21 (vc и rs; 9 ошибок, 3 события в игре, вход 1.54 с),
  `olife_menu_whitelist` 20/20 (vc и rs), регресс 8 сценариев + 2 rs ok. Движок и протокол не менялись; ядро: `cli_sup.py`,
  `supervise.py` (ждёт `lab daemon upgrade`). olife перекрывает `[engines.v032]` -> `voxelcore-0.32.0_dc62ccfb` (каталог
  переименован — `lab play olife` 07.10 падал). Подробно — `agents/OLIFE.md` «UX B».
- **Olife — UX A4: хранилище моба и процедурные активы (03.10, olife_a4):** KV моба с квотой и тарифом (память скриптов A3
  теперь в нём), активы владельца в sha256 CAS (png/vcm/ogg/wav/lua/vca, квота 8 МиБ/256 файлов, кредиты хранилища ->
  счётчики supervisor), раздача клиентам по `EntityAssets` + `GET /assets/<sha>` у обоих шлюзов, применение на лету
  (текстура, VCM-модель, звук `play_stream`), canvas в песочнице (`canvas.new` … `commit` -> PNG на мире), share/fork/
  snapshot/restore. Схема +2 c2s / +3 s2c / sandbox tag 10; песочница и Rust-шлюз пересобраны и разложены. `olife_store`
  ok (vc и rs), регресс 9 сценариев + 2 rs ok. Движок не менялся. Итоги и цифры — `agents/OLIFE.md` «UX A4».
- **Olife — UX A1: права «как у репозитория», друзья, форк (03.10, olife_a1):** 9 действий × owner/friends/list/everyone
  на каждую сущность (`content/olife_world/modules/perms.lua`, умолчание: код читают все, остальное — владелец), мир
  проверяет редактор/гравипушку/удаление/вид/форк/хранилище, админ проходит; друзья (запрос/принять/отклонить/удалить) в мире
  и в БД supervisor (`friends`, `account_settings`, миграция 3; `lab olife friend|settings`); UI: панель прав на странице
  «Настройки», страница «Друзья» (Shift+`), «Форк». Протокол c2s 40–43 / s2c 110–112, Rust-шлюз пересобран. `olife_perms`:
  матрица 108/108, админ 9/9, негатив 25/25, друзья и панель через UI; `olife_fork` ok; регресс ok кроме `olife_tariff_live`
  (1 такт, не A1 — см. OLIFE.md). Движок не менялся; ядро демона ждёт `lab daemon upgrade` (плагин работает и без него).
  Подробно — `agents/OLIFE.md` «UX A1».
- **Olife — UX A2: чат, команды оператора, обратная связь (03.10, olife_a2):** чат (лимит, роли, время, история для опоздавших,
  окно на T/Enter на нативном XML, лента HUD), команды `/kill /killall /freeze /unfreeze /limits /kick /ban /unban /tp /mobs /who
  /say /audit` из чата админа = `lab olife op …` = кнопки панели `/sup/panel`, аудит с via, Notice + звук/тост у затронутых,
  каталог событий `fx.lua` (11 синтезированных звуков + 6 пользователя), бирки THROTTLED/FROZEN. Схема +4 s2c (120–123).
  `olife_chat` 18/18, `olife_op` 38/38, `olife_play_dry` ok, регресс (11 vc + 4 rs) ok; `olife_restart_editor`, `olife_blocks`,
  `olife_inventory` в этом прогоне не зелёные (причины — `agents/OLIFE.md` «UX A2»), не перепрогнаны. Движок не менялся.
- **Olife — UX round 1, первые замечания пользователя (02.10, olife_ux1):** редактор в раскладке оригинала на нативном XML 0.32
  (весь кадр, код — самый большой, панель скриптов, вкладки Профайлер/Настройки, одна строка статуса, ` по бенчу), модели/иконки/
  звуки пользователя из прототипа 0.30.6, монета убрана (миграция `indices.json` мира), гравипушка/Injector — одно действие на
  нажатие, бирки только с Injector'ом и вдвое меньше, Shift+ЛКМ удаляет / Shift+ПКМ открывает последнюю сущность. Протокол
  +3 сообщения (аддитивно), Rust-шлюз пересобран. `olife_play_dry` с шагом `olife_play_ux` ok (`20261002_211420_olife_olife_play_dry_vc`), регресс olife 25/25.
  Движок не менялся. Подробно — `agents/OLIFE.md` «UX round 1».
- **Olife — путь игрока: `lab play olife` (02.10, olife_play):** пользователь — `D:\Prog\Olife\play.bat` (или `lab play olife
  --user --wait` из своего терминала): коляска `play_stack` поднимает стек под supervisor (`olife.play_up`: мир на постоянном
  `D:\Prog\Olife\play\worlds`, настоящая песочница, билеты, Rust-шлюз, аккаунт `user` admin, примеры
  `demo_orbit/follow/blink`, тарифы), затем СТОКОВЫЙ 0.32 со скриптом меню `olife_client/scripts/app/olife.lua` (паки —
  junction в `<0.32>\content`, адрес — `export\olife_server.txt`); выход окна → сводка `olife_session.md`, `play_report.md`.
  Меню «Сценарии» -> olife + `play.bat server/down`. `lab play olife --dry-run` (сценарий `olife_play_dry`, F2F 0.32 с тем же
  скриптом) — ok за 41 с: вход по билету, примеры двигаются (follow догоняет), Injector → редактор → Run, GravityGun.
  Стоковый рантайм агентом не запускался (ждёт `lab play olife --user` пользователя / `--final-check` главной сессии).
  Движок и ядро лаборатории не менялись. Подробно — `agents/OLIFE.md` «Путь игрока», `D:\Prog\Olife\README-play.md`.
- **Olife, волна 5p — производительность такта мира (02.10, olife_w5p):** `agents/research/OLIFE_WORLD_PERF.md`. Код мира
  под JIT (`jit=off` — 125 мс/такт), но стоковый кэш LuaJIT (`maxtrace=1000`) мира + base-пака переполнялся: 17–18 сбросов
  за 25 с — главная причина max 71–86 мс и «snapdelta в 10× дороже стенда» (стенд со сбросами — 0.95 мс против 0.03);
  вторая — GC в такте (3.3 МБ мусора/такт). Умолчания мира теперь `jit=tuned`, `gc=tick` (GC после такта); TickInput без
  таблиц вида, TickResult без копий, ключ чанка без массивной части, FNV без ветки. `olife_sandbox_load` p50/p95/max
  10.97/26.03/71.04 → 6.08/6.71/9.98 мс, `olife_load` 1.24/2.59/12.04 → 1.03/1.29/1.72; чистый `lab perf sandbox_load` 11.56/29.27/87.55 → 5.92/6.70/8.19.
  Регресс 29/29 ok. Профиль такта `--opts prof=1,jitlog=1`
  (`modules/prof.lua`, шаги `olife_prof*`, сценарии `olife_w5p_*`). Движок не менялся. Подробно — `agents/OLIFE.md` «Волна 5p».
- **Olife, волна 4c — сетевой код (02.10, olife_w4c):** предсказание движения с переигровкой (`olife_proto:movement` — модель
  физики игрока 0.32 фиксированным шагом, f32 после шага; `MoveInput{keys, look, hash}` → мир шагает тем же кодом →
  `PlayerAck`/`PlayerState`; ведро 20 вводов/с реального времени, спидхак 50/с → смоделировано 69 из 150), дельты снимков
  (`EntityDelta`: база по сессии, 1/256 бл i8/i16/i32, u16-слоты, ключевые кадры, приоритет по расстоянию, бюджет байт),
  серверный инвентарь (движковый инвентарь игрока мира, выбор/перекладка/выброс/подбор, постановка расходует предмет,
  зеркало у клиента с hash; общий предмет `olife_proto:coin`), инжектор задержки в `gateway_dev.py`. `olife_prediction`:
  RTT +50/+150 мс — ~30 поправок/мин при стене перед игроком раз в секунду, скачок p50 0.15/0.52 бл, max 0.29/1.88; без
  помех ошибка 0; конечный hash движения бот = мир. `olife_delta`: снимки −52 %, трафик вниз −43 %; `olife_load` до/после:
  вниз 995 → 755 КБ, вверх 109 → 81 КБ. `olife_inventory`: зеркала = миру, баланс 0, негатив 7/7. Регресс olife (все
  сценарии волн 2–4b + `--impl rs`) — ok. Цена: такт мира под `olife_load` avg 1.0 → 1.5–2.3 мс. Подробно — `agents/OLIFE.md`.
- **Olife, волна 4b — билеты, бинарный мост песочницы, тарифы вживую, паки на лету (02.10, olife_w4b):** сервис билетов
  `tools/olife/auth_service.py` (вид `auth`; HTTPS с самоподписанным сертификатом, запрос запечатан x25519+ChaCha20-Poly1305 к
  закреплённому ключу — у 0.32 schannel без CA, `verify_ssl=true` не проходит) → одноразовый билет ≤ 60 с в `Hello.token`
  (`olife_ticket.py`, HMAC на шлюз); оба шлюза проверяют офлайн, коды 14–17 (`olife_auth_ticket` 11/11 у Python и Rust).
  `olife-sandboxd` говорит бинарный `sandbox.yaml` (транспорт по первому байту), мост мира по умолчанию `bin`: TickResult
  ×2.7 меньше, такт мира p50 9.6 против 14.0 мс (500 сущностей). Тарифы `limits.*` в БД supervisor → ctl `set_limits`
  (`lab olife tariff set` доставляет сразу; `olife_tariff_live`: throttled ровно с такта применения). `PacksChanged` (id 75) +
  `olife_client:packs`: вживую `modules/hot`/`config`, остальное — `reopen_world` с пакетом из `world:content`
  (`olife_packs_reload` ok). Регресс olife (11 сценариев + 4 с `--impl rs`) — ok. Найдено в 0.32: `network.get_binary`/`post`
  сломаны в stdlib (LESSONS). Подробно — `agents/OLIFE.md` «Волна 4b».
- **Olife, волна 4a — слой игрока: редактор кода сущности, консоль, Injector/GravityGun (02.10, olife_w4a):** мир
  `content/olife_world/modules/editor.lua` (бенчи с кодом/статусом/консолью в реестре, права владелец/админ, лок одного
  редактора с тайм-аутом, подписка на консоль с ограничением, луч и захват на сервере, счётчики кредитов), схема `client.yaml`
  аддитивно (c2s 16–21, s2c 88–92), клиент `content/olife_client/modules/olife.lua` + `layouts/editor.xml` (нативный XML 0.32:
  multiline textbox с подсветкой Lua, консоль, кнопки, шаблоны `select mode=button`, файлы `config:olife/scripts`), предметы
  Injector/GravityGun, сущность-бенч с биркой `gfx.text3d`. Тесты лаборатории на F2F 0.32 через `input`/`olife gui|state`:
  `olife_editor` (+ `editor_neg` 14/14 и флуд консоли), `olife_gravity`, `olife_restart_editor` — ok (и `--impl rs`); регресс
  `olife_consistency/clients_f2f/restart/negative/negative_proto` ok. Подробно — `agents/OLIFE.md` «Волна 4a».
- **Olife, волна 3c — прод-шлюз `sockets_auth` на Rust (02.10, olife_w3g):** `/root/olife/gateway` (tokio; локальный git без
  коммитов) → `D:\Prog\Olife\gateway\olife-gateway.exe` (нативная сборка MSVC, README рядом). Кодеки — `gen_codecs.py --lang
  rust` из той же схемы: 132 вектора побайтно, фазз-паритет Python↔Rust 30 000 тел — 0 расхождений; тесты 13/13 на Linux и
  Windows. Лаборатория: вид `gateway_rs`, `--impl rs`, виды `world_fake`/`gw_load`, модуль `gateway_rs.py` (шаги
  `olife_gw_load`/`olife_soak`, перф `gateway_load`), сценарии `olife_gw_throughput`, `olife_gw_soak`. `olife_consistency/load/
  blocks/negative_proto --impl rs` — ok, коды негативных 25/25 как у `gateway_dev.py`. 100 ботов × 55/с (чистый `lab perf`):
  CPU 8 % ядра против 126–138 % у Python, TickSync p50 0.34 против 2.35 мс; выдержка 10 мин — память +2.1 %. Разбор
  безопасности — `agents/research/OLIFE_GATEWAY_SECURITY.md`. Найдено в ядре лаборатории (для главной сессии): `lab stdin` на
  логе > 512 КиБ, `WinError 32` на `leases.json`. Подробно — `agents/OLIFE.md` «Волна 3c».
- **Лаборатория, этап 5 — роли, drain, изолированный демон, аудит (02.10, lab5_dev; после инцидента с `lab daemon restart`):**
  `labcore/admin.py` + API `/daemon/*` + CLI `lab daemon drain|undrain|upgrade|reload-core|status|list`, `lab audit`,
  `--daemon P`, `--as-agent`/`LAB_ROLE`; мост — `as_agent` и `lab_daemon` (чтение). Уровень демона, `release --all`, `gate
  accept`, `golden promote` — только admin (`user`, `claude`); немедленные stop/restart/reload-core при чужих арендах — отказ
  при любой роли. Перезапуск изнутри демона (WMI + `--after-pid`), версия кода (`code_hash` против диска), `audit.jsonl`,
  горячая перезагрузка `sysload/compare/gate/dashboard/history/golden`. Тесты: `test_daemon_admin.py` 7 passed, без движка
  86 passed. **Общий демон 25700 ещё на старом коде** — `lab daemon upgrade` главной сессией, когда у него нет аренд
  (README «Этап 5» → «Применение»).
- **Olife, волна 3a — настоящая песочница в сессии (02.10, olife_w3s):** `olife-sandboxd` (Rust + wasmtime + Lua 5.1 в wasm)
  собран под Windows (кросс `x86_64-pc-windows-gnu` из WSL, `/root/olife/sandboxd/scripts/deploy_windows.sh` →
  `D:\Prog\Olife\sandboxd`). `cargo test` под Windows 15/15, `driver.py all` PASS, хэши памяти совпадают с Linux.
  Вид лаборатории `olife.sandbox` — настоящий сервис (JSON-строки по TCP, `--ctl`: hello/meters/stats/quit), заглушка — вид
  `sandbox_stub` (бинарный контракт). `lab call olife.sandbox_meters`. Мир: `spawn_scripted`, `olife.sandbox_dump`,
  `export/sandbox_ticks.jsonl`, проверки `dup`/`flood`, вид через сетку, ручной кодировщик TickInput (×7). Сценарии
  `olife_sandbox_real`, `olife_negative` (настоящий рантайм, 16/16: нарушитель вытеснен или убит, контрольные владельцы
  обновлены в каждом такте, такт мира max 3.33 мс), `olife_sandbox_load` (500 сущностей / 50 владельцев: мир 13.2 мс,
  сервис 4.8 мс — ПК занят, не чистый замер), перф `lab perf olife sandbox_load`. Исправлено в сервисе: топливо до
  инстанцирования (Windows), отложенная загрузка в замороженного владельца, лимит текста. Цифры — `agents/OLIFE.md`
  «Волна 3a».
- **Olife, волна 3b — supervisor (control plane) из лаб-демона (02.10, olife_w3v):** `tools/lab/labcore/supervise.py`
  (общее ядро: службы поверх аренд, health, перезапуск той же аренды с бэкоффом и пределом, инциденты с хвостами логов,
  БД `supervisor.sqlite` — аккаунты/баны/счётчики/тарифы/инциденты/события/входы с миграциями, `/sup/auth|bans|state|panel`,
  манифест паков) + Olife в плагине (`lab olife up|down|status|players|kick|ban|tariff|incidents|packs manifest|...`,
  порядок мир → песочница → шлюз, `sandbox_reconnect`, снимок мира `sup_state_{a,b}.json` с кольцом 256 кадров, учёт и
  кредиты, шлюз с токенами/банами из БД и раздачей паков по HTTP, переподключение ботов `--reconnect`). `olife_restart` ok:
  мир готов через 3.32 с после убийства, боты `reconnects=1 self_div=0`. Тесты без движка 9/9. **Не применено к общему
  демону**: нужен `lab daemon upgrade` главной сессией (README «Этап 6», последний пункт). Правки движка — нет.
- **Olife, волна 2 — протокол, мир, клиент, шлюз на 0.32 (02.10, olife_w2):** схема `tools/olife/protocol/*.yaml`
  (контракты `client`, `internal`, `sandbox`; кадр magic|version|type|len, big-endian, лимиты) → `gen_codecs.py` → Lua
  (`content/olife_proto`) + Python кодеки, векторы побайтно равны (Python 7/7, Lua в движке 815/815). Паки
  `content/olife_world` (авторитетный мир: 20 Гц в `on_world_tick`, фазы ARCHITECTURE §4, проверки движения/блоков/чата,
  чанки по интересу с кэшем и перехешированием, снимки сущностей с dirty-полями, `TickSync` с hash вида, журнал 256
  кадров, `status/players/kick/save/journal`, реестр переживает рестарт, мост песочницы jsonl+bin) и
  `content/olife_client` (бот headless и оконный F2F 0.32: чанки с чтением назад, блоки, сущности с интерполяцией,
  ввод 20 Гц, F2F `state`). `tools/olife/gateway_dev.py` (токены, баны, лимиты, keepalive, мультиплекс),
  `sandbox_stub.py` (протокол `sandboxd`; формат запросов мира проверен на настоящем `olife-sandboxd`), `negative.py`.
  Лаборатория: виды на настоящие паки, сценарии `olife_consistency/load/blocks/negative_proto/sandbox_bin/clients_f2f/
  negative` — все ok, **0 расхождений** на 5 394 сравнённых тактах (до 6 ботов), блоки 160/160 у всех ботов, негативные
  25/25. Цифры и что дальше — `agents/OLIFE.md`; грабли — LESSONS «Olife».
- **Лаборатория, этап 4a — F2F 0.32 в лаборатории (02.10, lab_032):** `VoxelCoreF2F-032.exe` = движок `v032`
  (`f2f_version = "0.32-f2f"`; у `v031` — `"0.31-f2f"`): кроме `flags.input == "isolated"`/`flags.clock` сверяется
  `hello.version`, чужая версия — `engine-mismatch` (дерево убито). Ключи `--f2f-clock/--f2f-window` теперь вставляются до
  `--` (раньше у `olife.client` уходили в аргументы проекта → часы virtual и окно normal). `by_engine` в видах; `vc.dev`/
  новый `vc.engine` с `--param engine=v032` (hidden, 854×480, `--dir` аренды); `olife.client_smoke` (без шлюза).
  `lab engines --table` (sha256, ключи F2F, последний hello сборки), `lab ps --table` — версия `hello`. Оконный vctest под
  `--f2f`: по умолчанию часы virtual (раннер шагает; `app.sleep(1)` = ровно 1.0), realtime — `--clock realtime`; сборка 0.32 не
  выходит сама после конца `--test` (в `f2f::run_loop` нет проверки `testMode && isFinished`) → раннер: маркер в копии теста +
  F2F `quit`. Эталон меню `02a16804…` из аренды совпал. В окне upstream `world.lua` и клиент olife (`client_start.lua:19`)
  падают «pack duplication [base]» (меню уже загрузило base — поведение оконного 0.32). `lab daemon stop|restart` — отказ при
  живых арендах (рестарт этого агента 04:39 убил сессию olife_w2). Подробно — `tools/lab/README.md` «Этап 4a».
- **Лаборатория, этап 4 — версии движка, headless, Olife, vctest (02.10, agent_olife):** `[engines.v031|v032]` в
  `lab.toml` (+ проектные), вид → движок, аренда несёт `engine_version` (`lab ps`), история (`runs.engine_version`,
  миграция), ворота (основание и храповик — своей версии) и панель — по версиям. `role = "headless"`: стоковый exe любой
  версии разрешён, `--headless` обязателен, окна дерева Job проверяются EnumWindows (старт + сторож), иначе убит;
  стоковый exe в оконном виде — отказ для всех версий. `lab stdin` (+ `core.stdin`, MCP `lab_stdin` после `/mcp`):
  `--stdin-cmd` 0.32 на Windows читает только после события в консоли (`_kbhit`) — одно событие в консоль без окна
  (`procs.console_poke`), доказано `--no-poke`. Проект `olife`: мир (headless стоковый 0.32), шлюз и песочница (заглушки
  Python), клиент (F2F 0.32), бот (headless 0.32), `olife.session/release/status/consistency/sandbox_probe`, сценарии
  consistency (0 расхождений, 360 тактов), load (4 бота, 1188 тактов, 0 расхождений), negative (8/8, заглушка).
  Вид сценария `vctest` (`lab run vc world` — upstream `dev/tests/world.lua` ok exit 0; провал → 0xC0000409; Canvas → PNG);
  лабораторный `--project vcproject` (+ `write-to-user`). F2F 0.32 — см. этап 4a. Подробно —
  `tools/lab/README.md` «Этап 4».
- **Лаборатория, этап 3б — lockstep, golden заново, детерминизм частиц (01.10, agent_3b):** хуки ядра `lockstep_tick`/`lockstep_run`,
  `[scenario].server_f2f`, `lab run --realtime`, поле ключа golden `server`; alphamine — сервер `--f2f <порт аренды>`, плагин v3 поверх
  `f2f_server.Lockstep`. Java/Java `e2e_walk1_ls` через демон 73/73 + 157/157. Java `hello.flags` (+ проверка `ref_app` демоном, патчи
  обновлены). 32 golden — regen 3/3 идентичны, все `fresh`. Пак: окно текстуры частиц — паком (движок брал из генератора с сидом-адресом)
  → VoxelCore/VoxelCore `e2e_walk1_ls` 73/73. Набор vc записан в историю как кандидат в основание (не принят; ворота
  `artifacts\lab\gates\20261001_202311_alphamine_all.md`: warn, 0 регрессий). Ворота: серия знает свой golden, основание — тот же
  режим сервера. Подробно — `tools/lab/README.md` «Этап 3б».
- **Лаборатория, этап 3а — принуждение правил софтом (01.10, agent_3a):** `tools/lab/labcore/policy.py`: exe движка
  только тестовой сборкой с `--f2f`, ядро добавляет `--f2f-clock`/`--f2f-window` (если сборка знает), после `hello`
  сверяет `hello.flags {input: isolated, clock}` — иначе убивает (`isolation-failed`); стоковый `VoxelCore.exe` (путь
  или sha) — только вид `role=runtime` через `lab play --user` (пользователь, интерактивный терминал) или
  `--final-check --reason` (claude/user), запись `runtime_session` в истории; сторож `foreign` в `lab ps` (не убивает).
  `labcore/perf.py` + `lab perf`: ожидание простоя (30 с подряд, ≤ 600 с; пороги `[perf]` lab.toml), отказ / `contended`,
  alphamine `perf_normal`/`perf_walk` на виде `rt` (realtime, пак в обычном режиме по `export\alphamine_realtime.txt`,
  правка `content/alphamine/modules/f2f.lua M.realtime()`); `perf_normal.py`/`perf_walk.py`/`perf_stream.py` — обёртки,
  `perf_compare.py` отклоняет contended. MCP `vc_start` = аренда `vc.dev` (новый проект `tools/lab/projects/vc`,
  канал `tools/lab/labpipe.py`), `vc_input` (F2F), `vc_keys`/`vc_click` отключены, `eag_mouse` и сценарии `eag_*` —
  через F2F; `tools/test_mp4_canvas.ps1` (стоковый exe) отключён; legacy `am_client` убивает свой экземпляр без
  изоляции. Проверено на новой сборке `527e3084` (`1c03a0c3…`): `vc_start wasmrt_page.lua` 2.6 с, `scenario_run
  eag_world` 65.0 с (норма 60–70), проба `lab perf alphamine perf_walk` (clean), тесты `test_policy` 15/15,
  `test_realtime_engine` 3/3, весь набор без движка — см. отчёт `tools/lab/README.md` «Этап 3а». **Демон перезапущен**
  с новым кодом (17:35, аренд не было). **Не сделано:** Java-клиент не сообщает `hello.flags` (проверяется только
  `--f2f`); `am_client`/`e2e_run --legacy` по-прежнему вне аренд; `lab play --user` у пользователя в терминале не
  прогонялся (агенту — отказ, проверено).
- **Лаборатория, этап 2а (01.10):** один интерпретатор сценариев в демоне (`tools/lab/labcore/scenario.py`: шаговые +
  таймлайны, base, размер, хуки проекта — всё про Minecraft в `projects/alphamine/plugin.py`; точка lockstep `server_step`
  без реализации сервера), `labcore/compare.py` (снимки + серии, порт e2e_compare), `labcore/golden.py` (golden.json, CAS
  `D:\Prog\AlphaMine\lab\store`, status/import/promote/regen). CLI `lab run|compare|golden|jobs`, MCP `lab_run`,
  `lab_compare`, `lab_golden`; старые раннеры делегируют демону. Приёмка (sha старый раннер = лаборатория на java и vc, шум
  realtime-сервера оценён повторами) и импорт 32 golden — `tools/lab/README.md` «Приёмка этапа 2а». Найдено: F2F `shot.sha256`
  движка — sha PNG-файла, у Java — RGB (интерпретатор пишет оба + `sha256_rgb`).
- **Лаборатория тестов `tools/lab`, этап 1 (01.10):** демон `labd` (Windows-Python 3.13, FastAPI, только
  127.0.0.1:25700), аренды экземпляров в Job Object с kill-on-close (порты 25600–25699, TTL, владелец, `state\leases.json`,
  восстановление после рестарта по pid+create_time), F2F-пул (постоянный TCP, без реле PowerShell), журнал JSONL
  (формат `journal.py` + instance/run/agent/plugin), каталоги прогонов (`journal.jsonl`, `logs\`, `shots\`, `report.json`),
  зеркало `VC_ROOT\latest.log` при каждом старте (и чужом), декодер логов utf-8/cp866/cp1251 построчно, `instance-dead`
  с кодом выхода и хвостом лога. Проекты — дескрипторы `tools/lab/projects/<имя>/project.toml` + `plugin.py` с
  перезагрузкой без рестарта; зарегистрированы `alphamine` (engine, server, ref_app; плагин wait/gui/session) и
  `wasmrt` (engine со стартовым сценарием `wasmrt_page.lua`; плагин status/frames). CLI `tools/lab/lab`, `labctl`
  (старт демона через WMI), MCP-мост `tools/lab/mcp_bridge.py` (stdio, `list_changed`). Тесты `tools/lab/tests`:
  27 (25 без движка + 2 смоука на VoxelCoreF2F). Замеры: `hello` старым путём `run_tool.py am_f2f` 1.07–1.13 с, через
  демон — 1.0 мс (CLI, тёплое соединение), 1.48 мс (MCP-мост из WSL), холодный CLI из WSL 0.14–0.18 с; убитый демон —
  дерево экземпляра исчезает за 0.07 с. Проверено вживую: wasmrt engine (wasmdemo, плазма в кадре FBO), alphamine
  engine (void-мир), alphamine server (Java, `Done!` за 1.2 с) + connect + `alphamine.wait` 441 чанк → снимок мира.
  **Не сделано:** запись `lab` в `.mcp.json` (сниппет в `tools/lab/README.md`; правка конфигурации — решение
  пользователя), проверка `list_changed` живым Claude Code. Этап 2 — интерпретатор сценариев, golden-манифесты,
  история/ворота, `lab play` (`tools/lab/README.md` «Миграция»).
- **Лаборатория, этап 2б (01.10, агент agent_2b):** история `artifacts\lab\history.sqlite` (писатель — демон; таблицы
  runs/shots/series/perf/gates/ratchet; импорт как есть старых раннеров, E2E, перфа, сессий пользователя, прогонов
  лаборатории и единого отчёта 2а: 183 каталога → 316 записей за 0.3 с), ворота-храповик `lab gate` (ε из шума J/J,
  `eps_by_scenario`, stale по mtime golden, перф по семействам тегов, contended игнорируется, без автоподъёма; `accept`),
  панель `artifacts\lab\index.html` + `dashboard\<проект>.html` + `SUMMARY.md`, `lab play` (дескриптор `[play]`, вид
  `runtime` alphamine — `VoxelCore.exe`, аренда `vc-main`; наблюдатель, `play_report.md/json/svg`, история), `sysload`,
  ночные ворота (`tools/lab/schedule/nightly_gate.xml`, `lab schedule install|remove|status` — **не установлено**,
  ставит пользователь), MCP `lab_history`/`lab_gate`/`lab_play`. Тесты 14 (`test_history`, `test_gate`, `test_play_report`,
  `test_play_session`). Первые ворота по истории (latest): layers fail 23/77, all fail 40/444 — против лучшего когда-либо
  записанного, храповик не принят. **Не сделано:** смоук `lab play` с настоящим рантаймом (ПК занят: другой агент гонял
  VoxelCoreF2F/Java, рантайм `VoxelCore.exe` уже был запущен — `exclusive_exe` отказал бы), режим `gate --mode run` вживую
  (нужен свободный движок), рестарт демона для свежих правок play/history (в демоне шли задания этапа 2а), запись пакетов
  (только точка `play.CAPTURE_HOOKS`), `host_load` в перф-раннерах `tools/alphamine/perf`.
- **Spider / WASM-4:** все 151 публичный картридж WASM-4 транслируются и работают в движке без правок
  (`wasm4_all`: ok 151, fail 0). Конформанс `lua-no-ffi` 280/312 (32 известных NaN), `lua-jit` 312/312.
- **wasmrt:** ABI `vc.h` (команды, кадр RGBA, кадр с палитрой, текстуры/спрайты, текст, ввод, мышь, звук PCM,
  время, лог), WASI, модели frame/main, графика canvas / posteffect / tris, профиль и стеки падений.
- **Quake (quakegeneric):** пак `quake`, три способа вывода. Показ кадра: canvas + GPU-палитра
  0.16–0.27 мс, canvas + CPU 0.68–0.78 мс, постэффект 1.6 мс (кадр уменьшен до 120×90). Сам Quake
  25–29 кадров/с (узкое место — программный рендер на Lua), timedemo 23–25 кадров/с (с 29.09 — 36–37,
  см. «Память Spider»). `content/quake/README.md`.
  **В мире по умолчанию — HUD-оверлей canvas + GPU-палитра в полном разрешении 320×240** (пользователь
  вернул: постэффект 120×90 даёт мыло и остаётся только для сравнения).
- **Quake: управление (28.09, ночь):** схема WASD+мышь по умолчанию (захват курсора `vc_mouse_grab` в игре,
  отпускание в меню/консоли, дельты `vc_mouse_delta`, ЛКМ огонь, `+mlook`) и классическая (default.cfg,
  взгляд по ПКМ); кнопка «Управление: …» переключает на лету, выбор в `config:quake/controls.txt`.
  Инъекция `bind` в буфер команд Quake (`qg_wasmrt.c`, импорт `vc.qg_controls` из `quake:qg_host`).
  Колесо только без захвата (GUI движка не отдаёт прокрутку при захваченном курсоре). Запуск из меню
  «Сценарии»: `quake [quake]`, `eaglercraft [eaglercraft]` (проба порта 25599, без сервера — сообщение
  на странице; **в движке не проверен**). Исправлено отпускание курсора в `wasmrt:app` (см. LESSONS).
- **Doom, Pong, wasmdemo** — работают на wasmrt (Doom timedemo `doom:wasm_timedemo.json` 220–230 кадров/с с
  выводом, старый хост `doom.lua` без вывода 358–389). В игре на wasmrt (страница, компьютер pc_wasmrt) —
  **70 кадров/с по реальному времени** (35 тиков × 2 кадра, `DG_SleepMs` уступает движку); 112–123 fps из
  README пака doom — старый хост с виртуальными часами (игра идёт быстрее реального времени, «35 fps lock»
  возвращает 35). Это паритет, не регрессия; режим «кадр = тик» на wasmrt не делался.
- **Eaglercraft 1.5.2 (Minecraft):** Java → TeaVM wasm → Spider → Lua, отрисовка треугольниками на GPU.
  Меню, настройки, профиль с 3D-моделью, панорама, список миров, создание мира, вход в мир и отрисовка
  мира, **HUD (хотбар, здоровье, прицел, F3, чат) и пауза** (replay FBO в `VcGL`), лайтмапа и
  освещение сущностей запекаются в цвет вершины, линии (рамка блока), тики 20/20. Одиночная игра —
  оригинальный сервер в Node. Сделано 28.09 (вечер): монотонное `steadyTimeMillis`; `teavm.nanoTime` в
  миллисекундах (было ×10⁶); копирование буферов через `arraycopy`; путь рисования `VcGL` на `double`
  без выделений; кэш чанков в `ChunkProviderClient`, таблица символов в `FontRenderer`; в хосте
  `gfx_tris` **тайловый биннинг** (шейдер перебирает только треугольники своего тайла 32×32, побитово тот
  же результат; `host` в мире 372 → 7 мс/кадр), предел 32768 треугольников, режимы смешивания 4–7 и
  бит «цвет не пишется»; в Spider «кадровый режим» и разрезанные последовательности без замыканий на
  вызов (FNEW не мешает JIT); `hotexit=200` в настройках JIT (`host.lua`).
- **HTML + CSS + JS (пак `html`):** litehtml + gumbo, QuickJS-NG, stb_truetype, свой растеризатор →
  wasm → Spider → Lua (36 МБ модуль). С 29.09 (вечер) — демонстрационный сайт из 5 страниц (hero, карточки
  с `box-shadow`, галерея с фильтром и просмотром, типографика и таблицы, демо: вкладки, форма из кнопок,
  таймер, модальное окно, аккордеон, тёмная тема в `localStorage`), холст 854×480, колесо мыши
  (`html:html_host`), полоса прокрутки, переходы с новым контекстом JS, частичная перерисовка (hover,
  прокрутка сдвигом кадра), каскад только изменённых поддеревьев; кадры Lua = натив = полная отрисовка
  (`verify_frames.sh`). Проверено в движке кликами по всем страницам. Первый показ ≈ 2.3 с от клика,
  клик с правкой DOM 0.2–0.45 с, hover 15–30 мс. JS в кадровом режиме (временный патч Spider
  `SPIDER_FRAMED_STATEMENTS`, бинарник `target-html`; правильный путь — вынос ветвей гигантских `switch`
  в принтере). Подробности и список неподдержанного: `/root/Spider/tests/manual/real-world-html/README.md`.
- **Инструменты:** MCP `voxelcore` (`vc_*`, `eag_*`; с 28.09 — автоматический журнал каждого вызова со
  скриншотом и таймингом `artifacts/journal/`, `journal_report` с пометками затыков, сценарии
  `scenario_save`/`scenario_run` (`eag_menu`, `eag_world` ≈ 60–70 с до мира с сидом 1234567890 включая пересчёт
  света, `eag_saved_world`), `eag_wait`, `eag_mouse`; один постоянный PowerShell вместо процесса на вызов —
  PID 3 мс и скриншот 50 мс вместо 0.9 с и 2.1 с; консольный запуск любого инструмента
  `tools/mcp/run_tool.py`), эталон в headless Edge (`tools/reference/`), `smoke_all.py`, конвейер
  `deploy.sh` / `verify.sh`. wasmrt ABI: `vc_mouse_grab` / `vc_mouse_delta` (захват курсора через
  `gui.set_active_frame("")`, дельты `input.get_mouse_delta()`); Eaglercraft — pointer lock как в браузере.

- **Компьютер pc_wasmrt:pc с «Windows XP» (29.09):** рабочий стол во фрейме `gui.create_frame` в
  текстуре экрана сущности, курсор ОС проецируется лучом камеры на экран (`set_active_frame` с
  locator), ярлыки Doom / Quake / Eaglercraft (wasmrt в окне стола: `app.start(..., embed)`), видео
  (`videoplayer:decoder`), «Minecraft (shader)» (прежний ShaderToy). Проверено в мире `PC Test` (копия
  «New World 1»): Doom 56–69 fps с клавишами, Quake 22–38 (Esc-меню, новая игра, захват мыши и
  возврат курсора), Eaglercraft — профиль/меню/список миров кликами по экрану, видео 720p ~5 fps.
  `content/pc_wasmrt/README.md`, сценарий `tools/scenarios/pc_world.lua`.

- **Olife (02.10, волна 4 ЗАВЕРШЕНА):** слой игрока (Injector → редактор кода в игре на нативном XML, консоль по
  подписке, замок/права, гравипушка с одним держателем, bench с кодом в реестре; 3 сценария ok на обоих шлюзах),
  безопасность и протокол (одноразовые подписанные билеты вместо токена 11/11, бинарный контракт песочницы: такт мира
  14 → 9.6 мс, живые тарифы по владельцам, горячая перезагрузка паков с переоткрытием мира), сетевой код
  (предсказание движения с переигровкой: при +150 мс RTT скачок p50 0.5 бл, hash движения = сервер; дельты снимков
  −42–52 % трафика; серверный инвентарь, баланс предметов 0). Открытое: такт мира под нагрузкой подрос 1.0 → 1.5–2.3 мс
  (дельты 0.5 мс/такт в живом мире против 0.04 на стенде — подозрение на отсутствие JIT, не проверено); инжектор
  задержки только у Python-шлюза; чистые замеры не сняты (ПК занят); два забытых процесса агента 3c в WSL
  (`world_fake.py`, `olife-gateway` 27001–27005) ждут решения пользователя.
- **Olife (02.10, волны 1–3 ЗАВЕРШЕНЫ, см. `agents/OLIFE.md`):** на 0.32 (`release-0.32` @ dc62ccfb): схема протокола
  (3 контракта YAML → кодеки Lua/Python/Rust, 132 вектора побайтно), world-пак с серверным авторитетом и планировщиком
  20 Гц (такт 1 мс с 6 ботами), клиентский пак (бот и F2F-клиент), шлюз Rust `olife-gateway` (8 % CPU на 100 ботах против
  130 % у Python, soak 10 мин, 72 630 тактов без расхождений), песочница `olife-sandboxd` (wasmtime + Lua 5.1 в wasm,
  Windows-сборка, негативные тесты через мир 16/16: виновник гасится, соседи работают, такт мира ≤ 3.3 мс; 500 сущностей —
  мир 13 мс, сервис 4.8 мс), супервизор в лаб-демоне (перезапуск мира за 3.3 с с возвратом ботов, инциденты с журналом
  последних 256 кадров, БД аккаунтов/банов/тарифов, панель, манифест паков). Лаборатория: версии движка как измерение,
  роль headless, роли admin/agent, drain, изолированный демон, аудит; тестовая сборка `VoxelCoreF2F-032.exe`.
  Не сделано: слой Olife для игрока (Injector, редактор/консоль в игре, bench, гравипушка с владением), предсказание
  движения с откатом, инвентарь, дельты снимков, бинарный контракт песочницы, HTTPS-билеты вместо токена (главная дыра,
  `agents/research/OLIFE_GATEWAY_SECURITY.md`), горячая перезагрузка паков у клиентов, тарифы `set_limits`.
- **VoxelCore 0.32 (02.10, анализ):** `agents/research/VC032_ADAPTATION.md` — что даёт main (lib `test` с `test.click`/
  `find_by_text`, `gui.screenshot`, оконный `--test`, `start_background_instance`, `vc.is_headless`, колесо мыши), что
  остаётся в патче F2F (виртуальные часы, изоляция ввода, слои, perf), что ломается (deferred lighting → шейдеры
  паков, stdlib, LuaJIT 2.1.1788856981), план адаптации лаборатории (версия движка как измерение, порт F2F, vctest-раннер).
- **Olife (02.10, анализ без кода; код — волна 2 выше):** прототип `voxelcore-0.30.6_win64_multiplayer` разобран (`agents/research/OLIFE_ASSESSMENT.md`);
  целевая архитектура по принципам пользователя — `OLIFE_ARCHITECTURE.md` (шлюз sockets_auth, world = headless VC,
  внешняя песочница с тарификацией, supervisor из лаб-демона); рантайм песочницы — `OLIFE_SANDBOX.md` (wasmtime +
  Lua 5.1 в wasm, запасной Luau). Следующий шаг по слову пользователя: прототип песочницы 2–3 дня и проверка Neutron.
- **Исследование тестовой инфраструктуры (01.10):** `agents/research/{ORCHESTRATION,MCP_REDESIGN,DETERMINISM,RECOMMENDATION}.md` —
  решение: демон `labd` на Windows-Python (127.0.0.1) + stdio-мост MCP + аренды экземпляров (Job Objects) + один
  интерпретатор сценариев + golden-манифесты + история/ворота + `f2f-server` (пошаговый Java-сервер). ≈20 дней
  последовательно, этапы параллелятся; запуск по слову пользователя.
- **AlphaMine (01.10, «перед фазой 4» ЗАВЕРШЕНО + мир разработчика + E2E):** производительность (худшее 5-с окно
  17.6 → 42–43 fps, загрузка 441 чанка 20 → 60 fps; причина — тройная запись чанков в движок + регион света 14 МБ +
  пересборка HUD; физика Lua 0.2 %; набор `tools/alphamine/perf/`), ломание/установка/подбор как в Java (state
  совпал в 15 точках), инвентарь на I/E XML-экраном (99.9 %), анимации руки и покачивание (99.2–100 %), чат
  (`u_chat` 100 % ×12), Disconnect/обрыв → меню движка, пауза при потере фокуса отключена. Падение на Enter:
  `app.delete_world` в окне — скрытый диалог подтверждения (убран). **Мир разработчика** `golden\devworld`
  (729 чанков, все блоки по meta, 8 видовых точек, свет посчитан генератором = серверному) — слои на нём
  terrain_flat 97.8–99.6, lit 97.4–99.2, water 99.7–100, full 97.4–99.1 %; 105 моделей состояний (факелы, лестницы,
  рельсы, ступени, двери, кактус, посевы). **E2E** `e2e_walk1` (600 тактов): игрок/инвентарь/блоки/чат бит в бит на
  всех 157 дампах, кадры 79–98 % (остаток — мир: облака, ±1 неба, рамка выделения); Java/Java 70 из 73 кадров —
  случайность сервера (позиция дропа, такт подбора). Открытые решения пользователя: (1) все блоки пропускающими
  свет ради перф (изменит свет частиц); (2) пошаговый Java-сервер по команде харнесса для детерминизма E2E.
  Осталось в рендере: облака, лава в шейдере, плоские блоки без множителя 0.6/0.8 в lit, таблички, печи
  (направление по соседям), плиты, провод, рамка выделения и трещины (шейдер), свет грани руки на yaw 90/270,
  `e2e_dev1` на devworld не записан. Два бага движка обойдены паком (текстуры моделей состояний только у
  состояния по умолчанию; meta 15 никогда не готовится). Подробно — `agents/ALPHAMINE.md` §6a–§11.
- **AlphaMine (01.10, фаза 3 ЗАВЕРШЕНА, движок не менялся):** слои против golden Java (% идентичных пикселей,
  4 направления): terrain_flat/lit/fog 99.87–99.96, water 99.4–99.9, sky 95.8 (остаток ±1), hud 100, gui 100,
  hand 100/97.7, entities 99.88–100 (с игроком B 98.3, с допуском 3 — 99.99), particles по покрытию, полный кадр
  `alpha_spawn` 74.6–93.1 (остаток почти весь — **облака, не сделаны**). Решения: точный свет сервера в регионе
  атласа блоков (`lightmap.lua`), подмены `main/translucent/background/entity` шейдеров пака, анимация воды тем же
  потоком `Math.random` (`texfx.lua`), HUD/меню паузы XML-документами, рука через `gfx.skeletons`, частицы через
  `gfx.particles`, сущности как нативные сущности с моделями из Java-кода (`gen_models.py`), инвентарь 91 предмет.
  Коллизии: Lua-физика совпадает с Java до бита, тело движка — нет (отстаёт на 0.92 блока за 10 тактов, не прыгает)
  → по умолчанию Lua, движковый вариант по флагу `--collision engine`. Мышь: через `input.get_mouse_delta`, проверена
  F2F-вводом; реальной мышью проверяет пользователь (в `latest.log` строки `look dx … -> yaw …`).
  **Инцидент 01.10:** агент двигал мышь скриптом ОС — запрещено навсегда (AGENTS.md). Осталось (фаза 4): облака
  моделью пака, лава (анимация есть, шейдер нет), одна грань предмета в руке (0.7250 против 0.7298), рендер-типы
  из `BLOCKS_TODO.md`, тень сущностей, покачивание камеры, ломание/установка блоков, экраны инвентаря/настроек/чата,
  пауза движка при потере фокуса в обычном запуске рвёт соединение через 60 с. Подробно — `agents/ALPHAMINE.md` §6–7.
- **AlphaMine (30.09, фазы 1–2 ЗАВЕРШЕНЫ):** послойные тесты паритета работают на обеих сторонах (`render` со
  слоями в Java `F2FRender` и в `VoxelCoreF2F.exe`, `am_compare` в процентах, `am_layers`, golden 12 слоёв на
  `golden\world_b`, повторяемость Java 100 %). Пак `alphamine`: 69 блоков из таблиц, протокол 14 целиком, чанки
  сервера через `set_chunk_data` (441 чанк за 15 с), хэш блоков совпадает с Java бит в бит, позиция после `/tp` до бита.
  Проценты VoxelCore против golden: **terrain_flat 99.2–99.5 %**, water 77–94 %, terrain_lit 13–53 %, sky 0 %
  (небо/свет/туман/HUD/рука/облака — фаза 3). Прогон `alpha_spawn` Java 57 с, VoxelCore 51 с; 11 сценариев за 86 с.
  Таблицы и пути — `agents/ALPHAMINE.md` §4–5; заглушки блоков — `content/alphamine/BLOCKS_TODO.md`.
  Следующая фаза 3 по порядку слоёв из `agents/F2F.md` §7: terrain_flat до 100 % (края текселей 15.99), `lighting`
  (таблица яркости альфы в `main.glslv`), `fog`, `sky`, `water` по уровням, `clouds`, `hand`, `hud`, `entities`.
- **AlphaMine (30.09, фаза 0 ЗАВЕРШЕНА):** нативный клиент Minecraft Alpha 1.0.16 на VoxelCore с 1:1 снимками и
  оригинальным Java-сервером; план, результаты проб и чек-лист — `agents/ALPHAMINE.md`, протокол — `agents/F2F.md`.
  Готово: рабочая копия и пересборка эталона (`D:\Prog\AlphaMine\ref`, JDK 8, RetroMCP); F2F в Java-клиенте
  (FBO 854×480, ввод только по протоколу, виртуальное время, сиды) — сценарий `alpha_spawn` даёт 0 отличий пикселей
  при обычном/перекрытом/свёрнутом окне (`golden\alpha_spawn`, `runs\...`); MCP `am_*` (`tools/mcp/alpha_tools.py`,
  сценарии `tools/scenarios/alpha/`); движок по релизному рецепту (MSYS2 clang64 + vcpkg `x64-mingw-static`, коммит
  `454aa205`, Lua-окружение = рантайм) + патч F2F → `D:\Prog\AlphaMine\engine\VoxelCoreF2F.exe` (снимки одинаковы
  при любом состоянии окна); пробы движка (void-генератор, `set_chunk_data` 0.4 мс/чанк, zlib→gzip, подмена
  `main.glslv`, TCP); ассеты (904 файла) и таблицы 69 блоков/91 предмет; каркас `content/alphamine` с прямым запуском
  `tools/scenarios/alphamine_world.lua`; git-репозиторий `D:\Prog\AlphaMine` (первый коммит; правки F2F Java и
  README **не закоммичены** — по просьбе). Открытые решения для фазы 1–2: сервер сам меняет мир (огонь, рост) — точка
  снимков выбирается вдали, флаг «заморозить случайные тики» в сервере не делался; побайтная идентичность exe
  движка (нужен снимок пакетов MSYS2 на 26.02) — не требуется для Lua; `impl="vc"` в `am_*` — фаза 2.

## Не сделано / известные проблемы (по приоритету)
- **Лаборатория: звук тестовых движков утекает в Windows (06.10, пользователь).** Экземпляры движка из аренд (F2F-сборки,
  dry-run клиенты) должны быть беззвучными: `[audio] enabled = false` в `settings.toml` собственного `--dir` аренды (kind `vc.dev`
  сейчас использует `--dir VC_ROOT` — перевести на каталог аренды, не трогая settings пользователя), проверка после старта как у
  изоляции ввода. Правка `labcore`/`project.toml` → изолированный демон, затем `lab daemon upgrade` главной сессией.
- **Olife (после волны 2):** прод-шлюз (Go/Rust), ~~настоящий `sandboxd` в сессии~~ (волна 3a; осталось — бинарный
  контракт в `sandboxd`, `set_limits` по тарифу, чистый перф на свободном ПК), инвентарь, предсказание движения с откатом, дельта-сжатие снимков (55 % трафика), supervisor — `agents/OLIFE.md`
  «Чего нет».
- **Этап 3б, остатки:** (1) решение пользователя — принять основание `lab gate accept alphamine <run>` по прогонам vc 19:52–20:22;
  (2) движок: `particle.random` эмиттера (тот же генератор с сидом-адресом) умножает свет частицы на 0.9…0.999 — на дневном свету
  пикселей не меняет, при блочном свете может; вариант для тестовой сборки — сид эмиттера из счётчика с `mode` при `--f2f` (движок не
  менялся); (3) `e2e_walk1` vc/vc — 1 пиксель на kf_0080 в одной паре (просвет неба в листве), причина не найдена; (4) `client_b` в
  lockstep (`layer_entities_player` идёт в реальном времени, но 3/3 идентичен).
0. **Eaglercraft в мире с дождём падает** (`StrictMath.log` получает nil из `nextGaussian`, строка
   1835543 модуля; воспроизводится и на странице `eag_saved_world`, сценарий `scenario_run("eag_rain")`).
   Причина найдена: Spider передавал trap token импортам хоста (LESSONS «Фреймы GUI», последний пункт).
   **Отложено пользователем (30.09). Фикс на диске, не проверен:** незакоммиченные правки в `/root/Spider` (см. «Незакоммичено»), бинарник
   `target/release/spider-cli` и `content/eaglercraft/modules/eaglercraft.lua` пересобраны 29.09 14:31
   (md5 модуля = `generated/`), агент убит до проверки. Довести: `verify.sh quick` (конформанс + новый тест
   `host_imports`), `smoke_all.py wasm4` (регрессия кодогенерации: изменены Builder всех целей), затем
   `scenario_run("eag_rain")` в движке; только потом коммит по просьбе пользователя.
1. **Eaglercraft: скорость в мире 7.5–9 кадров/с** (было 0.03–0.2; после трёх раундов: очередь чанков без
   `List.contains`, кэши в VcGL, горячие циклы VcGL через `Address`, `EaglercraftRandom` без `long`,
   `checkChunksExist` у клиента, транслятор без FNEW и с hotexit). Взвешенный профиль (5 с, 4.4 с в программе):
   `VcGL.draw` 1.2 с (`positionsFast` 0.48, `copyColorsFast` 0.17, `lightmapFast` 0.14, `emitQuads` 0.14),
   `runTick` 0.67 (`doVoidFogParticles` 0.18, `getCollidingBoundingBoxes` 0.27), `clipRenderersByFrustum` 0.29.
   Хост и GPU не узкое место (Java получает ~99% времени). Идеи: `vc.eag_draw` — цикл рисования в хосте на Lua по памяти модуля (`__w`), LuaJIT
   «register coalescing too complex» в огромных функциях (`WasmHeap_initHeap`, `InfCodes_proc`, `IntBuffer_get`),
   память в `Bytearray` (`spider-cli --memory bytearray`): перемерено 2026-09-29 — не быстрее таблицы
   (меню 8.0–9.3 против 8.8–9.6 fps, мир 5.5–7.0 против 5.8–9.2), см. `content/gameboy/OPTIMIZATION.md`.
- **Память Spider (2026-09-29):** `--memory table|bytearray` вместо цели `lua-bytearray`; замер обоих в движке —
  `export/membench/` (README, results). Bytearray не даёт выигрыша сам по себе; Quake +45% даёт отказ от хвостовых
  вызовов в хелперах памяти (и у таблицы: 23.6–24.8 → 35.7–41.4 fps), binjgb от того же отказа в 2–3 раза
  медленнее (лотерея LuaJIT). **Сделано 29.09:** флаг `spider-cli --memory-helpers notail` (печать хелперов
  `buffer_*` без хвостовых вызовов, текст совпадает с `membench_notail.py` байт в байт), включён в сборках Quake
  (`build.sh`) и Doom (`build_wasmrt.sh`), `MEMORY_HELPERS=tail` — выключить. Пак quake: timedemo 35.8–37.0 fps
  (было 23.6–25.8), Doom wasmrt timedemo 221–224 (было 220–231, в пределах разброса). gameboy/binjgb — без флага.
  Модули замера из `export/membench/` удалены (остались README.txt и results.txt).
2. **Паритет с эталоном: инструмент есть, сравнение начато** (`tools/reference/README.md`): оригинал в headless
   Edge по CDP, `compare.py` — попиксельная разница. Меню и экран сида совпадают (кнопки/текст попиксельно),
   мир — та же местность при том же сиде. Рука игрока рисуется со скином (высокополигональный скин «Baby Charles» выглядит как блок — это его текстура), облака выключены настройкой. Инструмент: Windows Edge (`/mnt/c/Program Files (x86)/Microsoft/Edge/
   Application/msedge.exe`) headless по CDP из Node (WebSocket есть в Node 22), страница `upstream/javascript`
   через `python3 -m http.server`; Playwright/Chromium в WSL нет (установка — решение пользователя).
   Туман `CC_fog` сделан (Java + хост + шейдер, проверен зондом `tris_verify: 3`: коэффициент и цвет совпадают с формулой эталона). Панорама меню: как в оригинале, размытая и вращающаяся — копия экрана в текстуру (запись SNAPSHOT + CPU-растеризатор `gfx_snap.lua`, первая цепочка за один кадр ~113 мс, дальше порциями по 25 мс/кадр, `snapshot_budget_ms` в манифесте); меню с размытием 9–10 fps (без него ~41; `NO_PANO_BLUR=1` в deploy.sh — вариант с флагом `title/no-pano-blur.flag`). Известные расхождения: панорама меню: размытие в оригинале включено
   (`GuiMainMenu.initGui` перезаписывает `panoramaBlur` по ресурсу `title/no-pano-blur.flag`, у нас
   `glCopyTexSubImage2D` — заглушка, картинка без размытия), анимации воды/лавы/огня (`TextureTerrainMap`
   копирует кадры через FBO + `copyTexSubImage`), фильтрация LINEAR/CLAMP (виньетка, лайтмапа с AO),
   `TEX_GEN` — только портал End (облака и небо End его не используют), `_wglColorMask` для воды сделан,
   replay HUD даёт `c·a` вместо `c·a²` у полупрозрачных. Стабы `EaglerAdapterImpl2`: нет событий движения
   мыши (раскладка стака перетаскиванием), колесо с кнопкой −1 и сырым значением, нет автоповтора клавиш,
   `sleep` пустой, `openRelay*` возвращают null (NPE на экранах Мультиплеер/LAN при наличии реле),
   `isFocused` всегда true, звук заглушен (`isPlaying=false` → музыка меню будет перезапускаться каждый тик).
   Настройки по умолчанию отличаются от эталона ради скорости: дальность 3 (эталон 2), частицы 2 (эталон 0).
3. **Хранилище сохраняется** (сделано 28.09): клиент — `SimpleStorage` через импорты `vc.eag_storage_get/set/list`
   → файлы `export/eaglercraft/storage/{a,g,p}`; сервер — снимки fake-indexeddb в
   `native_server/data/<hex(имя базы)>.idb` (`persist.js`: запись через 2 с после изменения, не реже раза в
   10 с и при выходе воркера; `EAGLER_DATA` — другой каталог). Проверено: профиль и мир пережили перезапуск
   движка и лаунчера, мир загрузился с той же позицией игрока. Экран профиля при старте — поведение эталона.
   Риск: снимок всей базы целиком (на большом мире запись задержит тики), при SIGKILL воркера теряются ≤ 10 с.
4. **Сервер в wasm** — баг кодогенерации TeaVM 0.10.2 в `IntegratedServer.handleIpcPacket`
   (невалидный wasm: «expected 1 elements on the stack for fallthru»). Не обязателен (есть Node).
5. **Spider:** i64-константы в модульной таблице проверены и **отвергнуты** (Doom −8–10%: JIT сворачивает
   константу, созданную на месте, а из таблицы — нет). Следующее: специализированные хелперы для
   константных сдвигов i64, меньше живых слотов в огромных функциях.

## Незакоммичено (на 30.09 03:50) и что с этим делать
- **Spider, рабочее дерево** (`git status --short`): 14 изменённых файлов фикса импортов хоста — `IR/Graph/src/node/{simple,sinks,sources}.rs`,
  `Sources/WebAssembly/Lifter/src/{control_flow_lifter/{basic_block_lifter,mod},function_lifter,global_state,lib}.rs`,
  `Targets/{LuaJIT,LuaNoFFI,Luau}/Builder/src/{code_handler,data_handler}.rs` (+171/−17); новые
  `Conformance/tests/host_imports.rs`, `tests/manual/real-world-html/` (прототип litehtml + QuickJS, не под git),
  (мусорный `SPIDER_CRASH_AGENTS_…txt` удалён 30.09). Последний коммит `16fab6c` (Quake WASD, notail) запушен в
  `lookibed/Spider`. Каталог `target-html/` (3.4 МБ, бинарник с патчем `SPIDER_FRAMED_STATEMENTS`; патч в дерево Printer не
  внесён, лежит файлом `real-world-html/patches/spider-framed-statements.patch`, `build.sh` собирает его во
  временном worktree в `target-html`) — без этого бинарника JS пака `html` не соберётся, см. `real-world-html/README.md`.
- **VC_ROOT** не под git; паки и инструменты выложены в приватные репозитории (список в ONBOARDING) по
  состоянию на 29.09 ~02:30 — всё, что сделано позже (компьютер pc_wasmrt «XP», пак `html`, `eag_rain`,
  правки документов), в GitHub **не** выложено.
- **Диск:** пользователь ждёт сжатия `D:\Backups\wsl\ext4.vhdx` (инструкция в ONBOARDING «Диск»); можно
  ещё удалить `/root/Spider/target` (7 ГБ) и `D:\Prog\VoxelCore\edge_ref_profile` (476 МБ) по его слову.
- Живой процесс: лаунчер сервера Eaglercraft (`node launcher.js`, :25599) — нужен `eag_start`, не мешает.

## Замеры (ориентиры, 28.09 вечер, окно 1408×902, манифест с `profile: true`)
- Eaglercraft: загрузка до экрана профиля ~8–10 с (было ~18–20); экран профиля 45–50 fps, меню 9–10 fps с размытием панорамы (41 без)
  (было 3–5 с профилем); мир (сид 1234567890, спавн) 7.5–9.2 fps при 12 тыс. треугольников (было
  0.03–0.1, кадр 10–30 с); хост `gfx_tris` 5–7 мс/кадр (copy 1–2, биннинг 0.3–0.8, set_data 2.3, update 2.2),
  движок 23 тика/с, вне тиков 0.1 мс; программа получает ~4.7 с из 5. Стартовый пересчёт света на клиенте
  после входа в мир — ещё ~1.5–2 минуты на 0.1 fps.
- Сервер Node: создание мира и старт 220 мс.
- WASM-4: медиана 0.22 мс на кадр; Watris, wasmstein3d — ровно 60 кадров/с.

## Olife — API скриптов моба (UX A3, olife_a3, 03.10)
- Готово: `block.*` (get/get_area/set с state/fill_area по тактам/raycast/is_replaceable/find), `self:*` (pos/rot/scale/visible,
  текстуры/модель, скелет: кости и модели костей, анимации VCA, звук, 3D-текст, nearby, look_at), `memory.*` (KV хранилища A4)
  — действия и запросы с ответом через такт, проверки мира, права (A1 + `olife.api_deny`), цены `api_price_action`; репликация
  `EntityAppearance/EntityAnim/EntitySound` и применение API движка 0.32 на клиенте (`mobview.lua`); переменные Lua через рестарт
  мира (`LoadKeep`) и через падение песочницы (`--state-dir`). Сценарий `olife_script_api` ok ×2, регресс 10/10 ok, сухой
  прогон ok. Подробно — `agents/OLIFE.md` «UX A3»; справочник — `/root/olife/sandboxd/README.md` «UX A3».
- Не сделано: Luau без API; цена ответа по размеру и «отклонённое — 50 %»; прогоном не проверены анимации/звуки из активов
  (`asset:<sha>`, только код); Rust-шлюз не пересобран (s2c 130–132 он пропускает как есть, исходники кодеков обновлены).
- Не закоммичено (по правилам — только по просьбе): всё перечисленное; `/root/olife/sandboxd` вообще без коммитов.
- `D:\Prog\Olife\sandboxd\README.md` (краткий README Windows-раскладки) по ошибке перезаписан полным README исходников; сверху
  добавлен краткий раздел о раскладке — прежний текст не восстановлен.
