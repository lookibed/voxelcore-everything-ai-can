# Эталон Eaglercraft: браузерный оригинал в headless Edge

Оригинал (`<Spider>/tests/manual/real-world-eaglercraft/upstream/javascript`: `index.html`,
`classes.js`, `classes_server.js`, `assets.epk`) запускается в Windows-Edge без окна (`--headless=new`,
WebGL 2 через ANGLE) и управляется по CDP. Порт CDP 9222 закрыт для WSL брандмауэром, поэтому клиент —
Windows-`node.exe` (`C:\Program Files\nodejs`), а обёртка из WSL зовёт его через PowerShell.

```bash
python3 tools/reference/edge_ref.py serve        # раздать upstream/javascript на :8765 (Edge видит localhost WSL)
python3 tools/reference/edge_ref.py start        # Edge headless 854×480, dpr 1, профиль <work_root>\edge_ref_profile (--fresh — чистый)
python3 tools/reference/edge_ref.py run artifacts/ref_menu.json   # сценарий шагов (см. edge_ref.js)
python3 tools/reference/edge_ref.py stop
python3 tools/reference/compare.py artifacts/screens/<наш>.png artifacts/screens/<эталон>.png --rect x,y,w,h --out diff.png
```

Шаги сценария: `navigate`, `wait`, `eval`, `wait_eval`, `screenshot` (в `artifacts/screens`, 854×480), `click [x,y]`,
`move`, `key` (Escape, Enter, Space, F3, стрелки, буква), `type`. Координаты — экран игры 854×480; у нас тот же
экран лежит в окне движка 1:1 по смещению (277, 225) — `compare.py` вырезает его сам.

Проход эталона (28.09): страница → «press any key» (клик + Space) → Edit Profile (случайные имя и скин) →
Done (427,436) → changelog SP2 (крестик 740,37; у нас отключён флагом `seenAcknowledgementsSP2`) → главное меню
(размытая панорама, случайный сплэш из `index.html`) → Singleplayer (427,236) → Create New World (584,396) →
«What do you wanna do?» → Create New World (427,220) → More World Options (427,394) → поле сида (426,140) →
Create New World (266,444) → мир через ~15 с.

Сравнение с нашим портом (тот же сид 1234567890):
- кнопки и текст версий главного меню совпадают попиксельно (рамка текста x 4–147, y 440–453 в обоих);
  различия только там, где сквозь них видна панорама (у эталона размытие включено — `title/no-pano-blur.flag`
  в `assets.epk` нет);
- экран сида: 80% пикселей в допуске 8, 20 пикселей с Δ>64;
- мир: та же местность (равнина, заснеженное озеро), спавн −216/81/169 против наших −217…−224/78–80/168–174
  (случайный разброс спавна на сервере). У эталона: туман у горизонта, облака (в свежем профиле облака
  включены по умолчанию), рука игрока со скином (у нас тоже: «блок» на первых скриншотах — текстура высокополигонального скина
  «Baby Charles»); туман у нас есть (дальность «tiny»: 8…28.8 блока против «short» у эталона), облаков нет
  (выключены в `MinecraftMain` ради скорости). Для честного сравнения мира эталону нужны те же настройки
  (Options → Video Settings: дальность tiny, частицы minimal, облака выкл).
