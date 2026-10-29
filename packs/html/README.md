# html — браузерная вёрстка в VoxelCore (прототип)

Демонстрационный сайт из каталога `site/` пака: 5 страниц HTML + CSS + JS с общей шапкой и подвалом —
главная (hero с градиентом, карточки с тенями, лента картинок), галерея (фильтр, просмотр в модальном окне),
документация (заголовки, списки, цитата, код, таблицы, оглавление с якорями), демо (вкладки, счётчик,
форма из кнопок, таймер, модальное окно, аккордеон, тёмная тема) и «О проекте».

Рисует программа `modules/html.lua`: litehtml (HTML5-парсер gumbo, CSS 2.1 + flex + переменные, layout) +
свой растеризатор в RGBA (шрифты Inter и DejaVu через stb_truetype, PNG/JPEG через stb_image, `box-shadow`,
градиенты, скругления) + QuickJS-NG (JS, DOM на JS: `querySelector`, `classList`, `style`, `dataset`,
`innerText`/`innerHTML`, события, таймеры, `localStorage`, `location`). Всё это — C/C++, собранный в wasm
(wasi-sdk) и оттранслированный Spider в Lua; запускает пак `wasmrt` (`wasm.json`: графика `canvas` 854×480,
модель main, кадр — `vc_gfx_present`).

- Запуск: меню → «Сценарии» → `html` (`scripts/app/html.lua`).
- Ввод: мышь (наведение, клики), колесо (`modules/html_host.lua`: прозрачная прокручиваемая панель GUI →
  `vc.html_wheel`), полоса прокрутки справа (клик по дорожке, перетаскивание), клавиши ↑ ↓ PageUp PageDown
  Home End (прокрутка) и Esc / ← → (модальные окна) → `keydown` документа.
- Ссылки `<a href="страница.html">` открывают страницу пака с новым контекстом JS; `#якорь` прокручивает
  с учётом фиксированной шапки. Тема и прочее из `localStorage` живут между страницами.
- `wasm.json` — `args`: страница, ширина, высота; `files` — каталог сайта (виден программе как `/`).
- `site/prelude.js` — DOM на JS (загружается перед скриптами страницы); `site.js` — тема и уведомления,
  `gallery.js`, `demo.js` — страницы.
- `site/fonts/` — Inter (SIL Open Font License 1.1) и DejaVu 2.37 (лицензия Bitstream Vera / DejaVu),
  тексты лицензий рядом. `site/img/` — процедурные картинки и уменьшенные иконки паков.

Не поддержано: поля ввода, `transform`/`opacity`/`transition`, CSS grid и `gap`, `position: sticky`,
`text-shadow`, скруглённый клип (`overflow: hidden` + `border-radius`), сеть. Подробно, с замерами —
Spider, `tests/manual/real-world-html/README.md` (там же исходники, сборка `build.sh`, раскладка
`deploy_pack.sh`, сверка кадров `verify_frames.sh`).

## VoxelCore 0.32.1 (порт 06–07.10)
Без правок пака. Тестовая сборка 0.32 с res 0.32.1, страница `html:wasm.json`: `index.html` parse+style 1364 мс, layout 122 мс,
js 273 мс (1 скрипт), paint 189 мс — первый кадр через ≈1.95 с от старта программы (0.31: ≈2.3 с от клика); кадр совпадает
с 0.31 визуально (шапка, hero, карточки). Колесо (`html_host.lua`, прозрачная scroll-панель) — тот же приём, API `panel`
в 0.32.1 не менялся (в 0.32 появился `input.get_mouse_scroll` — можно упростить, не делалось).
