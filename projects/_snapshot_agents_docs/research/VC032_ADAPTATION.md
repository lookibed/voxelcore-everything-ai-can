# VoxelCore 0.32 (main) и адаптация лаборатории/тестов (02.10)

Источник фактов: `origin/main` репозитория MihailRis/voxelcore, подтянутый в `voxelcore-0.31.0_src_pre/voxelcore`
(HEAD `e802753f` «Merge #997 update-deferred-lighting», 01.10.2026, **882 коммита** после нашей базы `454aa205`),
бинарник `D:\Prog\VoxelCore\voxelcore-0.32_win64_pre` (engine version 0.32, LuaJIT `2.1.1788856981`),
`dev/tests/*.lua`, `res/modules/internal/test.lua`, `src/logic/scripting/lua/libs/libtest.cpp`, `libgui.cpp`,
`libapp.cpp`, `src/devtools/AppScriptsControl.cpp`, `src/engine/Mainloop.cpp`. В WSL каталога `/root/voxelcore` нет;
«последний успешный action» = артефакт CI (`windows-clang.yml`) с этого коммита — его и считать рантаймом 0.32.

## 0. Что у оригинала на 02.10 (проверено через `gh`)
- Релизы: последний **v0.31.4** (04.05.2026). Релиза 0.32 ещё нет, но есть ветка **`release-0.32`**, HEAD `dc62ccfb`
  «update CHANGELOG.md» (26.09.2026): **все четыре CI-задания зелёные** (Windows CLang, MSVC, macOS, AppImage),
  CHANGELOG 0.32 написан (дата `20xx.xx.xx`). Это и есть «последний успешный action»: run 36266877824, артефакт
  `Windows-Build` (9.8 МБ, доступен до 25.12.2026). `main` ушёл на 24 коммита вперёд (`e802753f`), но его CI с 07.09
  не зелёный (action_required/failures); разница main↔release-0.32 — 20 файлов, deferred lighting есть в обеих.
- Форка движка у `lookibed` нет: есть `goxelcore` (эксперимент порта на Go, 12.2025), репозитории паков и прототип
  multiplayer. Каталога `/root/voxelcore` в WSL нет. Форк понадобится, когда захотим публиковать ветку F2F.
- **Вывод: база для 0.32 = `release-0.32` @ `dc62ccfb` и его артефакт**, не HEAD main.
- Заголовки CHANGELOG 0.32: animation, semi-transparent entities, client-side `--script`/`--test`, environments,
  translators (`register_compiler`), VCA; события `on_scripts_loading`, `on_content_loaded`, `on_entity_spawned/despawned`;
  библиотеки `animation`, `crypto`, `ctypes`, `test`, `vc`, `xml`; классы `debug.Logger`, `I8view`…`DBLview`;
  разрешение `sub-instances`; `--log`; сигнал `hot-reload` VC-DBG; UI `onrightclick/onmiddleclick`; **настройка
  `graphics.enable-fog`** (важно для слоя `fog`); функции `app.start_background_instance/terminate_instance/is_instance_alive`,
  `Bytearray:copy/fill/move`, большой `crypto.*`.

## 1. Что 0.32 даёт для тестирования штатно (чего не было в 0.31)
| Возможность | Где | Что это значит для нас |
|---|---|---|
| Библиотека **`test`**: `test.click(node, {button, timeout})`, `test.find_by_text/attr/attr_presence`, низкоуровневые `set_button_pressed/set_key_pressed/enter_text` через `Input::simulateCursorPos/simulateClick/simulateKey/simulateCodepoint` | `libtest.cpp`, `res/modules/internal/test.lua` | **синтетический ввод стал штатным**: ровно то, что делал наш патч F2F `input`/`gui`. Клик по элементу XML по тексту/атрибуту — без координат |
| **`gui.screenshot([frameId]) -> Canvas`** | `libgui.cpp:1229` | снимок окна или фрейма из Lua (наш F2F `shot`, но штатно); Canvas можно сохранить файлом |
| Режим **`--test`** в окне | `Mainloop.cpp:59`: цикл с рендером, выход, когда скрипт закончился | UI-автотесты с картинкой штатно (в 0.31 `--test` был только headless) |
| **Дочерние экземпляры из Lua**: `app.start_background_instance(script, log, args)` (headless, `--sub-depth`, `--log`), `app.start_debug_instance(port)` | `libapp.cpp:353–440`, разрешения `sub-instances`, `debugging` | оркестрация «сервер + клиенты» силами движка (важно для Olife) |
| `AppScriptsControl`: app-скрипт + `project_client.lua` + `project:start.lua` штатно | `src/devtools/AppScriptsControl.cpp` | наш прямой запуск через `project_client.lua` — теперь официальная механика |
| `vc.is_headless()/is_client()`, `vc.get_version()` | `res/scripts/stdmin.lua` | единый способ ветвить код пака |
| `input.get_mouse_scroll` | `libinput.cpp` | колесо мыши в Lua (в 0.31 его не было — Quake/html крутились костылями) |
| `__vc_internals.register_compiler(pack, exts, module)` | `stdmin.lua` | подключаемые компиляторы скриптов (кандидат: Spider-Lua, daScript) |
| `vctest --debugger`, `dev/tests/*.lua` (world, chunks, network tcp/udp, bytearray…) | `vctest/main.cpp`, `dev/tests` | образцы движковых тестов на `app.*` |
| Новые библиотеки: `xml`, `crypto`, `ctypes`, `animation`, `libnetwork` переписан (+158 строк) | `libs/` | полезно Olife (подписи, протокол) |

## 2. Чего по-прежнему нет (остаётся в нашем патче F2F)
- **Виртуальных часов в оконном режиме**: `--test` крутит `time.update(window.time())` — кадры по стенным часам;
  детерминированный `step` с `partial` — только наш.
- **Изоляции от реального ввода**: `test.*` добавляет синтетический ввод, но колбэки GLFW остаются, курсор
  захватывается, окно берёт фокус. Требование пользователя «ввод ОС невозможен программно» закрывает только патч
  (нерегистрация колбэков, `WS_EX_NOACTIVATE`, `--f2f-window hidden`).
- **Слоёв рендера `render`**, **`perf` по фазам кадра**, **`hello.flags/gl/build`**, **сброса таймеров в `mode`**,
  **безопасного UTF-8 в ответах**, командного порта как такового.
Итог: патч F2F на 0.32 **сокращается** (ввод и снимок можно опереть на `Input::simulate*` и `Window::takeScreenshot`),
но не исчезает. Протокол F2F оставить без изменений — лаборатория и сценарии тогда не меняются.

## 3. Что ломается или требует проверки
1. **Рендер переписан** (deferred lighting: `WorldRenderer.cpp` 510 строк, `Skybox.cpp` 268, `ChunksRenderer`,
   `MainBatch`; шейдеры `lib/fog.glsl`, `entity.glsl*`, `effects/deferred_lighting.glsl`, `clouds.glslv`). Подмены
   шейдеров пака alphamine (`main.glsl*`, `translucent.*`, `background.*`, `entity.*`, `lib/am_*`) и wasmrt (`ui.glslf`)
   нужно портировать заново; слои terrain/sky/water/entities пересчитать против golden (эталон Java не меняется).
2. **stdlib перестроен**: `console.*`, `time.post_runnable`, `session.*`, `__vc_on_*` ушли из `stdlib.lua` (переехали или
   переименованы), `internal_events.lua` удалён, появился `gui.process_template`. Наши паки используют
   `time.post_runnable`, `events`, `console`, `hud.*` — нужен совместимостный прогон каждого пака.
3. **LuaJIT другой**: 0.32 pre — `2.1.1788856981` (коммит LuaJIT от 09.2026) против `2.1.1771261233` у нашего 0.31.
   Правило «сборка = релиз» остаётся: F2F-сборку 0.32 собирать по тому же рецепту на коммите CI-артефакта и с vcpkg
   той же даты, сверять `jit.version` и дамп окружения с артефактом.
4. **Патч F2F**: хуки в `GLFWWindow.cpp`, `Mainloop.cpp`, `Engine.cpp`, `LevelScreen.cpp`, `ChunksRenderer.cpp`,
   `WorldRenderer.cpp`, `lua_engine.cpp`, `command_line.cpp` (переписан на `ArgsReader`) — все эти файлы менялись в
   main; перенос через `git rebase`/ручной порт, ожидаемо 2–4 дня с проверкой пробами `f2f_probe_vc.py`.
5. **Политика лаборатории** привязана к `hello.flags` — сохраняется, если протокол не менять.

## 4. Как адаптировать (план)
0. **Зафиксировать рантайм 0.32**: коммит последнего зелёного прогона CI, скачать артефакт (или собрать по рецепту с
   тем же vcpkg), положить как `D:\Prog\VoxelCore\voxelcore-0.32_<commit>` (новый VC_ROOT не делаем: рантайм 0.31 остаётся
   для AlphaMine до переноса). 0.5 дня.
1. **Лаборатория: версии движка как измерение.** Вид экземпляра получает параметр `engine=0.31|0.32` (exe, res, рецепт),
   golden-ключ уже содержит sha exe — добавить явное поле `engine_version` в историю/панель, чтобы сравнивать проценты
   между версиями на одном сценарии. Совместимостный набор: `wasmrt_page` (wasmdemo), quake, `eag_menu`, html,
   `pc_world`, `alphamine` void — по одному прогону на 0.32 с отчётом «работает / что сломалось». 2 дня.
2. **Порт патча F2F на 0.32** (ветка `f2f-032`): виртуальные часы, изоляция ввода и окно без фокуса, `render`, `perf`,
   `hello`, `mode`-сброс, UTF-8; внутри `input`/`gui`/`shot` — на штатные `Input::simulate*`/`takeScreenshot`, чтобы
   патч стал тоньше. Проверка пробами и `lab`-смоуками. 3–4 дня.
3. **Штатные UI-автотесты как вид сценария**: `--test` + `test.click/find_by_text` + `gui.screenshot` → новый раннер в
   лаборатории («vctest-сценарий»: Lua-файл в стиле `dev/tests`, запуск под арендой, лог и Canvas-снимки в прогон).
   Для меню паков (Сценарии → пункт) это проще нашего F2F `gui` по координатам. 2 дня.
4. **AlphaMine на 0.32**: порт шейдеров под deferred lighting, прогон слоёв, таблица 0.31 vs 0.32. 3–5 дней (отдельное
   решение пользователя: переносить ли AlphaMine сейчас или держать на 0.31 до релиза 0.32).
5. **Olife — сразу на 0.32**: `start_background_instance`, новый `libnetwork`, `crypto`, `xml`, `--log` — брать как базу.
6. `register_compiler` — оценить для Spider-Lua/daScript (заметка, без срока).

## 5. Решения за пользователем
- Какой коммит считать «0.32 рантаймом»: HEAD main (`e802753f`) или конкретный зелёный прогон CI.
- Переносить ли AlphaMine на 0.32 сейчас (рендер переписан — порт шейдеров) или после релиза 0.32.
- Держать ли два рантайма параллельно в лаборатории (рекомендую: да, версия движка — измерение в истории).

## 6. Релиз 0.32.1: разница dc62ccfb → v0.32.1 и порт паков (06–07.10, port032)
Источник: `git -C voxelcore-0.31.0_src_pre/voxelcore fetch --tags` (теги `v0.32.0` = `f6a7a99a`, `v0.32.1` = `99a62710`,
есть ветка `patch-0.32.2`); `git log dc62ccfb..v0.32.1` — 46 коммитов, `git diff --stat` — 25 файлов (+264/−119).
Бинарный релиз `D:\Prog\VoxelCore\voxelcore-0.32.1_win64` (`engine version: 0.32`, exe 19 331 072 Б, `vctest.exe` 91 648 Б);
`diff -rq` его `res` с артефактом dc62ccfb (`voxelcore-0.32.0_dc62ccfb`) — ровно 6 файлов, все из списка ниже.
Что касается паков (Lua stdlib, XML, API) — **в `src/logic/scripting` изменений нет**, кроме `libxml.cpp`:
| что | коммит | смысл для паков |
|---|---|---|
| `res/modules/animation.lua`, `internal/animation_codegen.lua`, `formats/vca.lua`, `scripts/components/animator.lua` | `d3de449b`, `ea63d292`, `0151fdfb`, `6b369921`, `76e5e5b6` | VCA/анимации: абсолютные bezier-ключи, blending в `core:animator`, `reset_pose` перед треком, `@configure` через `tonumber` (грабли LESSONS «VCA 0.32: duration строкой» закрыты в 0.32.1). Наши паки анимаций не используют |
| `src/logic/scripting/lua/libs/libxml.cpp` | `61af506f` «fix xml.tostring» | `xml.tostring`: строки-дети как текстовые узлы, `tag` обязателен (`requirefield`). Паки `xml` не используют |
| `src/objects/Entities.cpp` | `3c7755f6` «fix 'selectable' with static entities» | `selectable` применяется и к `body-type: static`. `pc_wasmrt:pc` — `dynamic`, не затронут |
| `src/graphics/render/ChunksRenderer.cpp` | `ef85592e` «fix chunks render limits» | до 64 чанков в очереди меша за кадр (было 4/10): быстрее появляются чанки после входа в мир |
| `res/shaders/effects/deferred_lighting.glsl`, `clouds.glslv`, `src/engine/Time.hpp` (`timeMultiplier`) | `2b8d97a2`, `ffba11e8`, `f6a7a99a` | цветовая компенсация при тенях, нормаль облаков; на экран `pc_wasmrt:pc` (emission = 1) не влияет |
| `src/graphics/core/Font.cpp`, `coders/vector_fonts.cpp`, `ui/elements/TextBox.cpp` | `7211e99b`, `64ba1dad` | векторные шрифты и каретка textbox (Olife); наши паки — растровый шрифт |
Остальное — CMake/README/доки/`stack_vector`. Вывод: тестовая сборка `VoxelCoreF2F-032.exe` (dc62ccfb + патч F2F) с **res 0.32.1**
— честный прокси релиза для проверки паков; так и настроен движок `v032` проекта `wasmrt` (`[engines.v032]` в
`tools/lab/projects/wasmrt/project.toml`: res/stock/vctest из `voxelcore-0.32.1_win64`, exe — та же F2F-сборка).

### Что сломалось / что пришлось менять в паках (итог порта)
- **API паков (Lua) — без изменений.** Все функции, которыми пользуются паки (`gui.create_frame/set_active_frame/get_active_frame/
  get_viewport`, `input.add_callback/get_mouse_delta`, `gfx.posteffects.*`, `audio.play_stream_2d`, `assets.load_texture`,
  `network.tcp_connect`, `time.post_runnable`, `hud.show_overlay`, `pack.is_installed`, `menu.page`, `jit.opt.start`, `loadstring`/
  `setfenv`), есть и в 0.32.1 (`libgui/libinput/libposteffects/libaudio/libassets.cpp`, `stdlib.lua`). Запись — только
  `export:`/`config:` (в 0.32 `user:` пишется лишь с разрешением `write-to-user` проекта; у стокового `res/project.toml` его нет).
- **Шейдеры:** `res/shaders/ui.glsl*`, `effect.glsl*`, `effects/*.glsl`, `lib/*.glsl` в 0.32.1 **побайтно равны** 0.31 — подмены
  wasmrt (`ui.glslf`, `effects/wasmrt_*.glsl`) работают как есть. Изменился только `entity.glslv` (`v_color` стал `vec4`:
  полупрозрачные сущности) и `entity.glslf` (дизеринг Байера по `u_dithering`). Пак pc_wasmrt подменял оба: вершинный
  (копия движкового 0.31) убран из подмены (`shaders/legacy_0.31/entity.glslv`), фрагментный получил ветку 0.32.1 с
  `u_dithering` (в 0.31 униформа не задаётся = false → прежняя логика). Проверено на обеих сборках.
- **Запуск сценариев:** в 0.32 стартовый скрипт — штатный `--script <файл>` (`src/util/command_line.cpp`; наш `autorun_app_script.txt`
  читает только `project_client.lua` в res 0.31). Виды `wasmrt.engine/engine_rt/world` с `--param engine=v032` используют его.
- **Мир 0.31 → 0.32:** открывается без миграции: движок сам переписывает `world.json` (`version 0.31 → 0.32`, поле `weather`
  убрано), `rules.toml` (порядок ключей), `resources.json`; `indices.json`, `packs.list`, регионы и сущности не трогает
  (проверено на копии `fineltest` под F2F 0.32: diff до/после).
