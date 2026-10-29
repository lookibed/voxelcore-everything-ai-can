# Оркестрация тестов AlphaMine: долгосрочная архитектура (исследование, 01.10.2026)

Задача: «взрослое решение в долгую» для десяти проблем харнесса паритета (Java Alpha 1.0.16 против пака
`alphamine` на VoxelCore, протокол F2F). Документ — сравнение вариантов с доказательствами, матрица оценок, рекомендуемая
архитектура, план миграции по фазам с оценкой в днях и риски. Исследование только на чтение: движок, Java и код не
запускались и не менялись.

## 0. Исходное состояние (что проверено на этой машине)

| Факт | Доказательство |
|---|---|
| **Windows 10 Pro 22H2, сборка 19045** — не Windows 11 | `[Environment]::OSVersion` → `10.0.19045.0`, `DisplayVersion` → `22H2`, `ProductName` → `Windows 10 Pro` |
| WSL 2.6.3.0, ядро 6.6.87.2, режим сети **NAT** (шлюз `172.25.144.1`) | `wsl --version`, `ip route`; `.wslconfig`: `memory=10GB`, `processors=16`, `[experimental] autoMemoryReclaim, sparseVhd`, `networkingMode` нет |
| Windows-Python **3.13.7** (`C:\Python313`), в нём уже есть `pywin32 311`, `psutil 7.0.0`, `fastapi 0.117.1`, `uvicorn 0.36.0`, `starlette 0.48`, `pydantic 2.11`, `aiosqlite 0.21`, `pytest 8.4.2`, `pytest-asyncio`, `numpy 2.2.6`, `pillow 11.3`, `matplotlib 3.10.9`, `Jinja2 3.1.6`; **нет** `watchdog`, `pytest-xdist`, `mcp` | `python.exe -m pip list` |
| WSL-Python 3.10.12, пакета `mcp` нет (MCP-сервер — свой stdio без зависимостей) | `python3 -c "import mcp"` |
| GPU — **NVIDIA GeForce RTX 3050 Laptop** (ноутбук, вероятно гибридная графика) | `nvidia-smi.exe` |
| Claude Code **2.1.286** | `claude --version` |
| Копии движка: `engine\VoxelCoreF2F{,-c,-d,-e,-p,-u,-v,-main,-main-prev,-prev}.exe`, `VoxelCore-stock.exe`, `VoxelCore-454aa205.exe`; каталоги `userdir{,_454,_c,_d,_e,_p,_render,_rt,_stock,_u}` | `ls D:\Prog\AlphaMine\engine` |
| golden — 33 каталога (39 МБ), **в git не отслеживаются** (`git ls-files golden` → 0), манифестов нет (есть только `report.json`/`run.json` у части) | `du`, `git ls-files` |
| `runs\` — 147 прогонов, 271 МБ, имена `<время>_<impl>_<тег>`; сводной истории нет | `ls runs | wc -l` |
| Журнал MCP — `artifacts/journal/journal.jsonl`, 9814 строк; номер `idx` считается чтением файла без блокировки, пишут несколько процессов WSL | `journal.py: next_idx()` |
| `latest.log` движка — в каталоге `--dir`: у F2F-экземпляров свой (`engine\userdir_e\latest.log`), у рантайма пользователя — `VC_ROOT\latest.log` (перезаписан 01.10, сессия 00:51 потеряна) | `alpha_vc.py:146`, ALPHAMINE §9 |

Карта текущих «экземпляров» (каждый агент придумал сам): `am_server` :25565 `run\server`; `server_v.py` v :25566, p :25567,
e :25570 (тот же порт, что F2F Java-клиента по умолчанию — конфликт снят только тем, что агент E не запускает Java-клиента
на 25570); `run_u.py` сервер :25568, движок F2F :25573; e2e — Java F2F :25582, движок :25575; vc по умолчанию :25571, p :25572.
Остановка: `alpha_tools.kill` — `Stop-Process -Id`, `vc_stop` — `Stop-Process -Name VoxelCore` (все!), `run_u.py` — PID из файла
с проверкой командной строки через `Win32_Process`. Старт Java — WMI (`start_*.ps1`), движка — `Start-Process` через PowerShell-воркер.

Три с половиной исполнителя сценариев с разными форматами и путями вывода: `scenario_run` (eag JSON, журналируется),
`am_scenario`/`am_layers` (alpha JSON внутри MCP), `run_vc_scenario.py` (CLI, вызовы через `call_tool` → журнал), `run_u.py`
(свой `F2F`-клиент — **мимо журнала**), `e2e_run.py` (поверх `run_vc_scenario`), `perf_*.py` (свой запуск, мимо MCP).

## 1. Ключевые ограничения, которые меняют выбор

1. **Mirrored networking недоступен.** Документация Microsoft: «On machines running **Windows 11 22H2 and higher** you can set
   `networkingMode=mirrored`…» — только тогда WSL достаёт Windows по `127.0.0.1`
   ([learn.microsoft.com/windows/wsl/networking](https://learn.microsoft.com/en-us/windows/wsl/networking)). У нас Windows 10
   19045 — вариант (f) «включить mirrored» закрыт без обновления ОС до Windows 11 (решение пользователя; заодно у
   Windows 10 закончилась обычная поддержка 14.10.2025). Hyper-V firewall для WSL тоже только Win11 22H2+ и WSL ≥ 2.0.9.
   В NAT путь из WSL к Windows — **IP хоста** (`ip route show default`), а он закрыт брандмауэром (F2F §6) → нужно правило
   брандмауэра (админ, один раз) **или** вообще не ходить по сети из WSL (см. §3.6).
2. **Процессы, запущенные через WMI `Win32_Process.Create`, не попадают в Job Object родителя** (там же: «Child processes
   created using Win32_Process.Create are not associated with the job») —
   [Job Objects](https://learn.microsoft.com/en-us/windows/win32/procthread/job-objects). Текущий способ старта Java (WMI,
   чтобы оторваться от interop-пайпа WSL) несовместим с управлением деревом процессов. Владеть процессами может только
   тот, кто запускает их сам через `CreateProcess` на стороне Windows.
3. **Зависание `Start-Process` из WSL** — наследование пайпа interop: дочерний процесс держит write-конец stdout, вызывающий
   ждёт EOF вечно (AlphaMine README: «java inherits the interop pipe and the caller hangs»; тот же механизм —
   [chrome-devtools-axi#144](https://github.com/kunchenguid/chrome-devtools-axi/issues/144)). Лечится запуском с
   `bInheritHandles=FALSE`/вывод в файлы — то есть, опять же, процессом на стороне Windows, а не из WSL.
4. **SQLite нельзя делить между WSL и Windows через `/mnt/d`**: блокировки и `-shm` не держатся через 9P/DrvFs →
   «disk I/O error», порча базы ([microsoft/WSL#2395](https://github.com/microsoft/WSL/issues/2395)). База истории может
   иметь только одного писателя на одной стороне.
5. **OpenGL-окно в службе (session 0) не годится**: службы изолированы в неинтерактивной сессии 0 без рабочего стола
   пользователя ([MS Q&A о Task Scheduler](https://learn.microsoft.com/en-us/answers/questions/5789906/scheduler-tasks-with-security-options-run-whether)).
   Всё, что открывает окно движка/LWJGL, должно жить в сессии пользователя: задача планировщика «Run only when user is
   logged on» или автозапуск при входе. Это касается и раннера GitHub Actions в режиме службы (`--runasservice`).
6. **Гибридная графика ноутбука.** Предпочтение GPU в Windows (Параметры → Графика) и профили NVIDIA привязаны к **пути/имени
   exe**. Десять копий `VoxelCoreF2F-*.exe` могут попасть на разные GPU — для паритета (точность растеризации) и тем более
   для замеров. Значит, имя копии exe — не механизм изоляции; в манифест прогона нужно писать `GL_RENDERER`.
7. **Правила пользователя**, которые архитектура обязана соблюдать: 854×480 — единственный стандарт (1390×855 — только из
   поля `size` сценария); снимок — только FBO, ввод — только F2F (PrintWindow/keybd_event — разведка, не результат);
   движок менять только для тестирования; не гонять замеры при занятом ПК; каталог движка — рантайм + MCP/сценарии/доки;
   «стоп» = убить всё; один владелец рантайма `VC_ROOT\VoxelCore.exe`.

## 2. Варианты архитектуры (целиком)

| | Вариант | Суть |
|---|---|---|
| **A** | Статус-кво + соглашения | таблица портов в AGENTS.md, lock-файлы, копирование `latest.log` руками |
| **B** | **Лаб-демон на Windows** (`labd`) + тонкий клиент в WSL | Windows-Python 3.13: реестр экземпляров (Job Objects, пул портов, каталоги на экземпляр, аренды с TTL), хранилище прогонов (SQLite), golden с манифестами, один исполнитель сценариев, отчёты; MCP в WSL — проксирует вызовы |
| **C** | Оркестратор в WSL | то же, но в WSL-Python: реестр — JSON/lock-файлы на `/mnt/d`, процессы — через PowerShell-воркер, F2F — через реле |
| **D** | Только pytest (без демона) | pytest на Windows-Python, фикстуры поднимают сервер/клиентов на сессию pytest; нет общего реестра между агентами |
| **E** | GitHub Actions self-hosted runner как оркестратор | прогоны — workflow на этой машине, отчёты — артефакты Actions |
| **F** | Готовый стек: Robot Framework + Allure + Grafana | ключевые слова RF поверх библиотеки F2F, отчёты Allure, история в Grafana |

### Матрица (0 — не решает, 1 — частично, 2 — в основном, 3 — решает по построению)

| Проблема | A | **B** | C | D | E | F |
|---|---|---|---|---|---|---|
| 1. Владение экземплярами/процессами | 1 | **3** | 2 | 1 | 1 | 1 |
| 2. Один исполнитель, журнал | 0 | **3** | 2 | 3 | 1 | 2 |
| 3. Golden с манифестами, свежесть | 1 | **3** | 3 | 2 | 1 | 1 |
| 4. Ворота регрессий, история % | 0 | **3** | 3 | 2 | 2 | 2 |
| 5. Архив логов на прогон | 1 | **3** | 2 | 2 | 2 | 1 |
| 6. Сессия игры пользователя | 0 | **3** | 2 | 0 | 0 | 0 |
| 7. Реле WSL↔Windows | 0 | **3** | 0 | 3 | 1 | 0 |
| 8. Регистрация инструментов, общий файл | 0 | **3** | 2 | 1 | 0 | 0 |
| 9. Перф-набор, нагрузка 20–50 чанков/с | 0 | **2** | 2 | 2 | 1 | 1 |
| 10. Диагностика падений | 0 | **3** | 1 | 2 | 1 | 1 |
| **Сумма (из 30)** | 3 | **29** | 19 | 18 | 10 | 9 |
| Трудоёмкость до пользы | 0.5 д | 12–15 д (польза с 4-го дня) | 8–11 д | 4–6 д | 3–4 д + B/D всё равно | 8–12 д |

Почему так:
- **C** проигрывает B ровно на Windows-специфике: из WSL нельзя держать Job Object, нельзя слушать `127.0.0.1` Windows,
  нельзя безопасно делить SQLite с Windows-стороной; реле и WMI остаются, падение процесса видно только опросом
  `Get-CimInstance` (~мс через воркер, но без кода выхода и без причины).
- **D** хорош как исполнитель (и войдёт в B), но pytest-сессия живёт в процессе одного агента: два параллельных агента с
  двумя pytest-сессиями снова делят порты и процессы без арбитра. Нет «сессии пользователя» и нет MCP-поверхности.
- **E**: репозиторий Spider — публичный форк; GitHub прямо рекомендует self-hosted раннеры **только для приватных**
  репозиториев (форки публичного репо могут исполнить код на машине через PR) —
  [docs.github.com: add runners](https://docs.github.com/en/actions/how-tos/manage-runners/self-hosted-runners/add-runners),
  [OpenSSF](https://best.openssf.org/SCM-BestPractices/github/runner_group/runner_group_can_be_used_by_public_repositories.html).
  AlphaMine — локальный репозиторий без remote, golden/runs не в git. Раннер в режиме службы — session 0 (п. 1.5). Раннер
  добавляет планирование, но всё содержательное (экземпляры, golden, метрика) пришлось бы писать всё равно.
- **F**: Robot Framework 7.5 (Apache-2.0, [PyPI](https://pypi.org/project/robotframework/)) — ключевые слова поверх тех же
  Python-библиотек, второй язык сценариев к уже имеющимся JSON; Allure считает «прошёл/упал», а не кривые процентов по
  снимку; Grafana — отдельная служба (AGPLv3), плагин SQLite `frser-sqlite-datasource` 4.0.6 со статусом «Needs attention»
  ([grafana.com](https://grafana.com/grafana/plugins/frser-sqlite-datasource/)).

## 3. Разбор по компонентам (a–g)

### 3.a Лаб-демон на Windows (`labd`)

**Где и как живёт.** Код — `VC_ROOT\tools\lab\` (рядом с `tools/mcp`, `tools/alphamine`: харнесс, не исходники игры — правило
«каталог движка — рантайм + MCP/сценарии» соблюдено). Данные — `D:\Prog\AlphaMine\lab\` (`lab.db`, `inst\<id>\`, `store\`,
`reports\`). Процесс — `C:\Python313\python.exe` в отдельном venv `D:\Prog\AlphaMine\lab\venv` (`--system-site-packages`
не нужен: зафиксировать `fastapi uvicorn pywin32 psutil pytest pytest-xdist numpy pillow jinja2`; общий site-packages
Python313 содержит torch, aiortc и т.п. — обновления пользователя не должны ломать демон). Старт — задача планировщика
«При входе в систему», «Только при входе пользователя» (сессия 1: окна и GPU), перезапуск при сбое раз в минуту; окно
консоли скрыто (`pythonw.exe`). Слушает **только `127.0.0.1:47800`** (не `0.0.0.0` — нет запроса брандмауэра и нет
доступа из LAN).

**Объекты.**
```
Instance  {id:"i0042", kind: java_server|java_client|vc_f2f|vc_runtime, build:"vcf2f@3f9a1c2e", size:"854x480",
           ports:{f2f:25603, game:25604}, dir:"D:\Prog\AlphaMine\lab\inst\i0042", world:"world_b@sha256:…",
           job:"Local\\lab_i0042", pids:[…], state: starting|ready|dead|stopped, exit:{code, ntstatus, at},
           lease:{owner:"agent_P", ttl_s:900, heartbeat:"…"}, gl_renderer:"…"}
Run       {id:"r20261001_031522_ab12", kind: scenario|layers|e2e|perf|play, owner, instances:[…], scenario@sha,
           golden@manifest-sha, verdict: pass|fail|regress|error, metrics:{…}, artifacts dir}
Golden    {name:"layer_water", manifest.json (см. 3.c), files → CAS}
Lease     {resource:"vc_runtime"|"gpu_exclusive"|"instance:i0042", owner, ttl, expires}
```

**Процессы — Job Objects (`pywin32: win32job`).** Каждый экземпляр — свой именованный Job:
`CreateJobObject` → `JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE` (+ без `BREAKAWAY_OK`) → `CreateProcess` с `CREATE_SUSPENDED`
(Python `subprocess.Popen(creationflags=CREATE_SUSPENDED)`) → `AssignProcessToJobObject` → resume (`psutil.Process.resume`).
Так в Job попадает и всё дерево (`java.exe`, который запустит launchwrapper, и т.п.; вложенные Job поддерживаются с
Windows 8). Стоп — `TerminateJobObject` (никаких `Stop-Process -Name`); падение демона закрывает дескрипторы → ОС убивает
все тестовые экземпляры (чистый лист вместо сирот). Исключение — `vc_runtime` для игры пользователя: Job без
KILL_ON_JOB_CLOSE (перезапуск демона не должен закрыть игру).
Выход процесса — порт завершения Job (`JOBOBJECT_ASSOCIATE_COMPLETION_PORT`, сообщения `JOB_OBJECT_MSG_EXIT_PROCESS` /
`ABNORMAL_EXIT_PROCESS` с кодом) плюс `WaitForSingleObject` на дескриптор главного процесса — второе надёжно (MS: доставка
сообщений порта, кроме notification limits, не гарантирована).

**Порты.** Пул `25600–25699` (ниже — исторические порты агентов, не трогаем до миграции). Выделение = запись в SQLite +
проверка `bind()` на `127.0.0.1`; освобождение — при остановке экземпляра. Порт игрового сервера и F2F выдаёт демон;
сценарий порта не задаёт (поле `setup.server.port` игнорируется или переводится в «логическое имя»).

**Каталоги.** `inst\<id>\userdir` (копия шаблона `engine\userdir_template`: `settings.toml`, `controls.toml`, junction
`content\alphamine` → пак), `inst\<id>\server` (`server.properties` с выданным портом, `level-name=../world`), `inst\<id>\world`
(robocopy из golden-мира по хэшу), `inst\<id>\logs`. Удаляются при `release` (журнал и логи переезжают в каталог прогона).

**Сборки exe.** Не копии по агенту, а одна копия на **содержимое**: `engine\builds\<sha8>\VoxelCoreF2F.exe` (+dll) и
указатель `engine\builds\current`. Несколько экземпляров запускают один и тот же файл с разным `--dir` (Job решает задачу,
ради которой делались копии — «убить своё по имени»). Плюс: одна запись предпочтения GPU на сборку; в манифест —
`build sha`, `GL_RENDERER`/`GL_VENDOR` из `hello` (если движок их не отдаёт — это допустимая тестовая правка F2F-патча).

**Аренды (мульти-агентность).** `lease(kind, owner, ttl)` → экземпляр; каждый вызов от владельца продлевает; истекло —
демон останавливает экземпляр и пишет в журнал `lease_expired`. Чужой экземпляр нельзя остановить/перезапустить
(`403 not-owner`); «стоп» пользователя — `lab stop --all` (единственный путь, который убивает чужое; это и есть правило
AGENTS «стоп = убить всё»). Ресурсы-семафоры: `vc_runtime` (окно пользователя `VC_ROOT\VoxelCore.exe` — максимум 1, это
формализация правила «один владелец движка»), `gpu_exclusive` (перф-прогон: пока держится, демон не выдаёт новые
экземпляры с рендером и отказывает в старте другим), `user_play` (пользователь играет: тестам — только F2F без перф).
`owner` берётся из заголовка клиента (`LAB_OWNER` в окружении агента, задаётся в задании агенту), иначе `pid@host`.

**API.** HTTP/JSON (FastAPI) для CLI и тонкого MCP; те же функции — Python-библиотека для pytest внутри демона.
```
POST /instances {kind, build?, size?, world?, ttl?}  → Instance     DELETE /instances/{id}
POST /instances/{id}/f2f {cmd, args}                    (TCP 127.0.0.1 — без реле)
POST /runs {kind:"scenario", scenarios:[…], impl, golden?:false}   → run_id (асинхронно); GET /runs/{id}
GET  /runs/{id}/events (SSE/long-poll)    POST /golden/{name}/promote {run_id}    GET /gate?suite=parity
POST /sessions/play {…}   → сессия пользователя (3.e)          GET /health
```
Сопоставимые проекты на Windows (как ориентир, не зависимость): `pywin32` (PSF), `psutil` (BSD-3), FastAPI (MIT),
uvicorn (BSD-3) — все уже установлены в `C:\Python313` и поддерживаются.

### 3.b Исполнитель: pytest vs Robot Framework vs свой

| | pytest 9.x (8.4.2 уже стоит) + xdist 3.8.0 | Robot Framework 7.5 | Свой (как сейчас) |
|---|---|---|---|
| Лицензия, состояние | MIT, активен ([PyPI](https://pypi.org/project/pytest/)); xdist MIT, 3.8.0 от 01.07.2025 ([PyPI](https://pypi.org/project/pytest-xdist/)) | Apache-2.0, фонд RF | — |
| Сценарии как данные | `pytest_generate_tests` по `tools/scenarios/alpha/*.json` — формат JSON не меняется | `.robot`-файлы — второй формат | JSON |
| Экземпляры | фикстуры `scope="session"`/`"module"`: `alpha_server(world)`, `java_client(size)`, `vc_client(build)` → аренды у демона | библиотеки-ключевые слова, Suite Setup | у каждого скрипта своё |
| Параллельность | `-n 3` (xdist): каждый воркер берёт свои аренды; общий префикс `alpha_spawn` — фикстура модуля | pabot | нет |
| Отчёты | JUnit XML (встроено), `pytest-html` 4.2.0 (MPL-2.0), `allure-pytest` 2.16.2 (Apache-2.0) | свой HTML/XML | `report.json` |
| Повтор упавшего | `--lf`, `-k layer_water` | `--rerunfailed` | вручную |

Вывод: **pytest как оболочка** (выбор, параметризация, фикстуры-аренды, JUnit/JSON-отчёт, `-n`) поверх **одного**
интерпретатора сценариев `lab/scenario.py` (слияние `run_vc_scenario.py` + `run_u.py` + `e2e_run.py` + `alpha_tools.am_scenario`:
`base`/`base_until`, `look`, `expect`, `client_b`, таймлайн E2E с `pace_ms` и сдвигом расписания, перевод клавиш LWJGL).
Сценарий не знает портов и путей. Метрика — без изменений (`compare.py metrics`, `e2e_compare.py`). Каждый тест возвращает
не только pass/fail, но и запись `results` в SQLite (кадр → `identical_pct`, `within_tol_pct`, покрытие, bbox, max Δ).
Robot Framework не даёт ничего, чего нет у pytest, и добавляет язык. Свой раннер остаётся, но один и внутри демона.

xdist и GPU: параллельные F2F-экземпляры для паритета допустимы (детерминизм не зависит от загрузки — проверено J/J
изоляцией окон), но **не для перф** — перф-тесты помечаются `@pytest.mark.perf` и требуют `gpu_exclusive`.

### 3.c Golden и артефакты

Как делают другие (что заимствуем):
- **Unreal** Screenshot Comparison: ground truth / incoming / difference, история снимков между сборками, допуск по
  каналам и яркости ([docs](https://dev.epicgames.com/documentation/en-us/unreal-engine/screenshot-comparison-tool-in-unreal-engine)).
  → берём: просмотр «эталон / прогон / разница» в отчёте с ползунком; допуск как параметр сценария, а не агента.
- **Unity** Graphics Test Framework: эталоны **по ключу платформы/API/цветового пространства**, `ImageComparisonSettings`
  (`PerPixelCorrectnessThreshold`, средняя ошибка) ([docs](https://docs.unity3d.com/Packages/com.unity.testframework.graphics@8.3/manual/index.html)).
  → берём: golden адресуется ключом `(сценарий, size, java_patch, world)`; другой ключ — другой эталон, а не «сравнили что было».
- **Chromium/Skia Gold**: эталоны вне git, но в lockstep с коммитами; **несколько одобренных изображений на тест**; триаж
  positive/negative; неточное сравнение как опция ([Chromium GPU pixel testing with Gold](https://chromium.googlesource.com/chromium/src/+/HEAD/docs/gpu/gpu_pixel_testing_with_gold.md)).
  → берём: допускаем несколько одобренных снимков на кадр для известного шума эталона (у нас: E2E кадры 158–161 и поток
  `Math.random` после подбора — «типичный исход 2 из 3» превращается в явный набор `approved:[sha_a, sha_b]` с причиной).
- **Godot**: `--fixed-fps` + `--write-movie` — детерминированные кадры и контроль по контрольным суммам
  ([regression-test-project](https://github.com/godotengine/regression-test-project/blob/3.x/README.md)).
  → у нас уже так (виртуальное время F2F, sha256 RGB): быстрый путь сравнения — **сначала sha**, попиксельная метрика
  только при несовпадении.
- **BackstopJS** `approve [--filter]` переносит последние снимки в эталон; `misMatchThreshold` в процентах
  ([BackstopJS](https://github.com/garris/BackstopJS)); **reg-suit** — ключ эталона по git-хэшу родителя
  ([reg-keygen-git-hash-plugin](https://github.com/reg-viz/reg-suit/blob/master/packages/reg-keygen-git-hash-plugin/README.md)).
  → берём: `lab golden promote <run> [--filter kf_015*]` — единственный способ обновить golden, всегда с записью «откуда»
  (сейчас это `run.json.promoted_from` у одного E2E).

Хранение:

| | git-LFS | DVC 3.x | **Манифест + CAS (контент-адресация)** |
|---|---|---|---|
| Лицензия | MIT | Apache-2.0; куплен lakeFS (11.2025) | своё |
| Удалённое хранилище | GitHub: 10 ГиБ хранения/трафика в месяц бесплатно ([docs](https://docs.github.com/billing/managing-billing-for-git-large-file-storage/about-billing-for-git-large-file-storage)); у AlphaMine нет remote | любой каталог/S3; на Windows `hardlink` молча не работает → `cache.type=copy` | каталог `D:\Prog\AlphaMine\lab\store\sha256\ab\…`; бэкап — robocopy |
| Что даёт | версия PNG в истории git | версии + пайплайны (`dvc repro` → свежесть по входам) | версия = sha; свежесть — сравнение хэшей входов (то же, что `dvc status`, 50 строк кода) |
| Цена | git-lfs в двух ОС, smudge на `/mnt/d` медленный | ещё один CLI, `.dvc`-файлы, кэш ×2 места при copy | ничего нового |

Рекомендация: **манифест + CAS**; манифесты (маленькие JSON) — в git AlphaMine (`golden/<name>/manifest.json`), PNG — в CAS
вне git (39 МБ сейчас; рост — сотни МБ, это не нагрузка для D:). DVC можно включить позже поверх тех же файлов, если
понадобится remote.

Манифест golden:
```json
{"name": "layer_water", "schema": 1, "size": "854x480",
 "key": {"scenario": "layer_water@sha256:…", "base": "alpha_spawn@sha256:…",
         "java": {"patch": "f2f-client.patch@sha256:…", "alphamine_git": "fc370d5+dirty:…", "jdk": "1.8.0_481"},
         "server": {"jar": "minecraft_server.jar@sha1:…"}, "world": "world_b@tree-sha256:…", "seed": 20260930},
 "produced": {"run": "r20261001_024218_…", "at": "2026-10-01T02:42:18+03:00", "host": "…", "gl_renderer": "…",
              "harness": "tools/lab@<git sha>"},
 "noise": {"runs": ["r…java2", "r…java3"], "min_identical_pct": {"kf_0158": 99.63}},
 "frames": {"0_yaw0": {"sha256_rgb": "…", "file": "sha256:…", "approved": ["sha256:…"]}}}
```
**Свежесть**: перед прогоном демон считает `key` заново из текущих файлов; любое отличие → golden `stale` (прогон идёт,
но вердикт `stale-golden`, а не `regress`), и в отчёте — что именно изменилось (сценарий / патч Java / мир). **Перегенерация**:
`lab golden regen layer_water --java-runs 3` → три прогона Java, J/J-сверка, promote типичного исхода, `noise` из остальных.
Миграция: скрипт заполняет манифесты существующих 33 каталогов по `report.json`/`run.json`/`scenario.json` и текущим
хэшам (поле `key` с пометкой `backfilled: true`, где вход неизвестен).

### 3.d История и панель

| | Allure 3 | Grafana | **SQLite + генерируемая статическая HTML/MD** |
|---|---|---|---|
| Модель | тест прошёл/упал, история — JSONL (`historyPath`, `historyLimit`) ([docs](https://allurereport.org/docs/v3/configure/)) | временные ряды, панели | ровно наши сущности: прогон → сценарий → кадр → % |
| Зависимости | Node.js (Allure 3) или Java (Allure 2) | служба Grafana (AGPLv3) + плагин SQLite «Needs attention» | jinja2 + numpy/pillow (уже есть), график — inline SVG |
| Кривые % по кадру | нет (только длительности и статусы) | да | да |
| Ссылки на diff/heat | вложения | нет | да (файлы прогона) |

Рекомендация: **SQLite `lab.db` (один писатель — демон) + страница `D:\Prog\AlphaMine\lab\reports\index.html`**, которую
демон перегенерирует после каждого прогона и отдаёт по `http://127.0.0.1:47800/` (из WSL — через клиент, см. 3.f);
плюс `reports\SUMMARY.md` для агентов (машиночитаемое — `GET /runs?…` JSON). Содержимое: таблица «слой/сценарий × последние
N прогонов vc» с % (минимум по кадрам) и спарклайном, J/J-шум, текущий «храповик» (лучшее достигнутое), ссылки на
`diff/heat`; для E2E — кривая `drift` и первый такт расхождения; для перф — fps p5/медиана, кадры > 33 мс, чанков/с
(раздел 3.h). Allure — необязательная надстройка через `allure-pytest` (если пользователь захочет стандартный вид).

Схема (минимум): `runs(id, kind, started, owner, build_sha, java_key, verdict, …)`, `results(run_id, scenario, frame,
identical_pct, within_tol_pct, cov_a, cov_b, max_delta, bbox, sha_rgb)`, `ratchet(scenario, frame, best_pct, run_id)`,
`perf(run_id, metric, value)`, `instances(…)`, `leases(…)`, `events(run_id, t, level, text)`. Импорт истории: 147 каталогов
`runs\` (у кого есть `report.json`/`compare.json`) — разовый скрипт.

**Ворота регрессий (проблема 4).** Для каждой пары (сценарий, кадр): `fail`, если `identical_pct < ratchet.best_pct −
ε`, где `ε = max(0.01, шум J/J этого кадра)`; улучшение поднимает храповик только явным `lab ratchet accept <run>` (чтобы
случайный удачный прогон не сделал следующий «регрессией»). Вердикт набора `gate` — JSON
`{verdict, regressions:[{scenario, frame, was, now, run, diff}], stale:[…], improved:[…]}` — и код выхода для CLI.

### 3.e Сессия игры пользователя (проблема 6) и логи (проблема 5)

`lab play` (или пункт MCP `lab_play_start`): берёт `vc_runtime` + `user_play`, поднимает свой Java-сервер (экземпляр
`java_server` с миром по выбору), запускает `VC_ROOT\VoxelCore.exe` со сценарием `alphamine_world.lua` **в Job без
KILL_ON_JOB_CLOSE**, и наблюдает: хвост `latest.log` построчно копируется в `runs\<play_id>\latest.log` (до любого
перезапуска — то, что потерялось 01.10), строки `status`/fps и CSV профилировщика пака (`perf.lua`) — в `perf`,
`Exception|error|uncaught` — в `events`. На выходе процесса (любой код) — автоматически `report.md`: кривая fps по 5 с и 1 с
(как `perflib.windows`), p5/медиана, кадры > 33 мс, MapChunk/с, ошибки с контекстом, код выхода и причина (п. 3.i).
Пользователь ничего не делает, кроме «играть»; демон не шлёт ему ни клавиш, ни кликов.
Дополнительно (заготовка к 3.h): на время сессии сервер ставится за **записывающий TCP-прокси** демона (клиент ↔ прокси ↔
сервер на `127.0.0.1`), который пишет поток пакетов протокола 14 с метками времени — это готовая «нагрузка пользователя».

Логи вообще: у каждого экземпляра свой `--dir` → свой `latest.log` (уже так у F2F). Для рантайма `VC_ROOT` демон держит
наблюдатель (опрос раз в 1 с: размер + первая строка — тот же признак «новый лог», что в `eagler_tools`), и при смене
первой строки архивирует прежний файл в `D:\Prog\AlphaMine\lab\logs\vc_root\<время>.log` — это закрывает и старты, которые
сделал не демон (`vc_start` старого MCP, пользователь руками). Кодировки — таблица на источник, всё в архиве — UTF-8:
`latest.log` движка — UTF-8; stdout/stderr Java-сервера и клиента — **cp866** (консольная OEM-кодовая страница; либо
запускать Java с `-Dfile.encoding=UTF-8 -Dsun.stdout.encoding=UTF-8 -Dsun.stderr.encoding=UTF-8` и читать UTF-8 —
проверить на JDK 8u481 до перехода); сообщения ошибок Windows API/`std::filesystem` — **cp1251** (урок «utf8 decode
error», LESSONS); вывод PowerShell — UTF-8 только при явном `[Console]::OutputEncoding`. Демон читает байты и декодирует сам
(`errors="replace"`), никакие `Get-Content | iconv` у агентов.

### 3.f Изоляция процессов и сети на одной машине

| Механизм | Что даёт | Ограничения на этой машине |
|---|---|---|
| **Job Objects** | дерево процессов как единица, kill-on-close, код выхода, учёт CPU/IO | только для процессов, запущенных `CreateProcess` на Windows (не WMI) |
| Отдельные сессии пользователя | изоляция рабочего стола | Windows 10 Pro — одна интерактивная сессия (RDP на себя выбивает пользователя); для F2F не нужно — снимок из FBO, ввод по протоколу |
| Виртуальные рабочие столы | убрать окна тестов с глаз пользователя | `IVirtualDesktopManager.MoveWindowToDesktop` даёт `E_ACCESSDENIED` для окон **чужого** процесса ([MaxTo#704](https://github.com/digitalcreations/MaxTo/issues/704)); работает только из самого процесса (Java F2F / движок могут сделать это себе; для движка — тестовая правка) или через недокументированный `IVirtualDesktopManagerInternal` (ломается между сборками Windows). Необязательно: по F2F §0 на результат не влияет |
| Именованные порты | нет конфликтов | пул демона + `bind`-проверка |
| **WSL mirrored** | `127.0.0.1` в обе стороны → реле не нужно | **недоступно: Windows 10 19045** (нужна Windows 11 22H2+); при будущем обновлении ОС — побочные эффекты: смена сетевой архитектуры WSL целиком, Hyper-V firewall включён по умолчанию (входящие в WSL надо разрешать правилами), `::1` не поддерживается, известные проблемы с VPN/Docker — проверять на своих инструментах |
| Правило брандмауэра на `vEthernet (WSL)` | WSL → `172.25.144.1:47800` | один раз от админа; IP шлюза меняется после перезагрузки (читать `ip route`); демон должен слушать и этот интерфейс — шире поверхность |
| **stdio-мост через interop** | WSL запускает `C:\Python313\python.exe lab_mcp.py` как MCP-сервер stdio; он ходит в демон по `127.0.0.1` | без админа и без правил; запуск ~0.3–1 с один раз на сессию Claude; тот же приём, что уже работает у `PSWorker` |

Вывод для проблемы 7: **реле исчезает, потому что F2F-трафик больше не пересекает границу WSL** — им владеет демон на
Windows. Граница остаётся одна: «агент → демон», и её проходит либо stdio-мост (рекомендация, ноль админских шагов), либо
HTTP через правило брандмауэра (если нужен `curl` из WSL; тогда `labctl` в WSL ходит на IP шлюза).

### 3.g Плагины и горячая перезагрузка MCP-инструментов (проблема 8)

Сейчас: `voxelcore_mcp.py` регистрирует `eagler_tools`, `alpha_tools`, `journal` в один словарь `TOOLS`; правка любого файла
→ `/mcp` у каждого агента; `alpha_tools.py` (925 строк) правят параллельно разные агенты.

Предлагаемое:
1. **Стабильная узкая поверхность MCP.** Тонкий MCP (stdio-мост) экспортирует ~10 постоянных инструментов: `lab_instance`
   (start/stop/list/f2f), `lab_run` (scenario/layers/e2e/perf/gate), `lab_status`, `lab_report`, `lab_golden`, `lab_play`,
   `lab_logs`, `lab_call(feature, action, args)` — общий вход в любую возможность демона, и `lab_help(feature?)`.
   Новая возможность = новый модуль в демоне, видимый через `lab_call` **без** перерегистрации инструментов MCP.
2. **Модули возможностей** `tools/lab/features/<имя>.py` с `register(registry)` (`alpha_parity`, `e2e`, `perf`, `play`,
   `golden`, `eagler`…); у каждого модуля один владелец-агент в задании → нет совместных правок одного файла.
3. **Перезагрузка в демоне**: опрос `mtime` раз в 1 с (stdlib; `watchdog` не установлен и не нужен), `importlib.reload`
   модуля в изоляции: сначала импорт в новый объект и самопроверка (`selftest()` модуля), только при успехе — подмена;
   при ошибке остаётся старая версия и событие `plugin_load_failed` с трассой в `lab_status`. Идущие прогоны держат ссылку
   на старый модуль до конца.
4. **Если всё же меняется список инструментов MCP** — сервер шлёт `notifications/tools/list_changed`; Claude Code его
   поддерживает («allowing MCP servers to dynamically update their available tools… without requiring you to disconnect and
   reconnect» — [code.claude.com/docs/en/mcp](https://code.claude.com/docs/en/mcp)), с оговоркой из трекера: новый
   инструмент виден со следующего хода, не в том же ([anthropics/claude-code#31893](https://github.com/anthropics/claude-code/issues/31893)).
5. Журнал вызовов переезжает в демон (один писатель, `idx` — автоинкремент SQLite, связь `run_id`); `journal_report`
   остаётся тем же отчётом. Скриншоты окна (`PrintWindow`) остаются как инструменты **разведки** и в журнале помечаются
   `evidence:false` — их нельзя приложить к результату теста (F2F §0 п. 4).

### 3.h Перф-набор в лаборатории (проблема 9)

- Набор `perf` становится pytest-набором демона: `perf_normal` (рантайм, окно пользователя 1390×855 из его
  `settings.toml`, лимит 120 fps) и `perf_walk` (F2F 854×480) — с `gpu_exclusive`, записью в `perf` и сравнением с
  **записанными** числами (ALPHAMINE §9: before/after1…after3_2 импортируются в `lab.db` как исторические прогоны — правило
  «замеры сверять с записями» превращается в автоматическую колонку «было в записях»).
- **Достоверность**: перед и во время замера демон пишет загрузку ПК — CPU других процессов (`psutil`), `nvidia-smi
  --query-gpu=utilization.gpu`, число чужих экземпляров; если выше порога или пользователь активен (последний ввод через
  `GetLastInputInfo` — только чтение времени, не ввод), прогон помечается `contended` и в ворота не идёт. Это исполняет правило
  «не гонять замеры, когда ПК занят» механически.
- **Нагрузка 20–50 чанков/с.** Сейчас ходьба по сгенерированному `world_b` даёт ~3 MapChunk/с, нагрузка пользователя —
  25–40/с (частичные MapChunk догенерации). Три способа по возрастанию надёжности:
  1. длинный маршрут `--walk 3000+` по свежей копии `world_a` (сервер генерирует) — реально, но зависит от спавна (±10 блоков) и
     от скорости сервера;
  2. серверная команда/плагин телепорта каждые K тактов к новым координатам — тоже генерация, но больше чанков/с;
  3. **воспроизведение записанного потока** (прокси из 3.e): «сервер-повторитель» на Python в демоне проходит логин
     протокола 14, отвечает на KeepAlive и шлёт записанные `PreChunk`/`MapChunk`/`BlockChange` с исходными метками времени ×
     коэффициент (×1, ×1.5, ×2) — детерминированная и масштабируемая нагрузка ровно как у пользователя. Ограничение: это
     нагрузочный, а не игровой тест (движения клиента не влияют на поток); для паритета не используется. Оценка 2–3 дня.

### 3.i Диагностика падений (проблема 10)

- Смерть процесса видна мгновенно (ожидание дескриптора в потоке демона); идущий F2F-вызов получает не таймаут, а
  `{"ok":false,"error":"instance-dead","exit_code":"0xC0000409","log_tail":[…последние 60 строк…],"stderr_tail":[…]}`.
- Код выхода расшифровывается (`0xC0000005` access violation, `0xC0000409` stack buffer overrun/`abort`, `0xE06D7363`
  необработанное исключение C++, `1` обычный выход с ошибкой; Java — `hs_err_pid*.log` в рабочем каталоге экземпляра).
- **WER LocalDumps** на `VoxelCoreF2F.exe`/`VoxelCore.exe`/`java.exe`: `HKLM\…\Windows Error Reporting\LocalDumps\<exe>` с
  `DumpFolder=D:\Prog\AlphaMine\lab\dumps`, `DumpType=1`, `DumpCount=20` — мини-дамп при каждом падении, демон прикладывает его
  к прогону ([Collecting User-Mode Dumps](https://learn.microsoft.com/en-us/windows/win32/wer/collecting-user-mode-dumps); нужен
  админ один раз; правка ОС, не движка).
- `uncaught exception` в `latest.log`, `[main]`-сообщения, Lua-трассы пака — шаблоны в модуле `crash`; на каждый прогон
  — `crash.json` (первый признак, такт, последние F2F-команды из журнала).
- Зависание (не смерть): у F2F-вызова дедлайн; при превышении — снимок стеков (Java: `jcmd <pid> Thread.print`; движок —
  мини-дамп `procdump`-подобным вызовом `MiniDumpWriteDump` из демона) и только потом `TerminateJobObject`.

## 4. Рекомендация

**Вариант B: лаб-демон `labd` на Windows-Python + pytest внутри как исполнитель наборов + манифесты/CAS для golden +
SQLite и генерируемая HTML/MD-панель + ночные ворота через Планировщик Windows; WSL-сторона — тонкий MCP-мост.**
Не брать: Robot Framework, Grafana, git-LFS/DVC (пока), GitHub Actions self-hosted (публичный Spider, session 0).
Mirrored networking — отложить до решения пользователя об обновлении на Windows 11; архитектура от него не зависит.

```
WSL (Claude Code, агенты, скрипты)                 Windows, сессия пользователя
┌────────────────────────────┐ stdio (interop)  ┌──────────────────────────────────────────────┐
│ .mcp.json: voxelcore-lab →─┼─────────────────→│ lab_mcp.py (Windows-Python, мост)            │
│ labctl (CLI, тот же мост)  │                  │   │ HTTP 127.0.0.1:47800                     │
│ старый voxelcore MCP (eag_*│                  │ labd: реестр экземпляров ── Job Objects ──→  │
│  wasmrt, разведка) — пока  │                  │   │   VoxelCoreF2F(build sha) --dir inst\i.. │
└────────────────────────────┘                  │   │   java client F2F / java server          │
                                                │   ├ сценарии (один интерпретатор) + pytest   │
                                                │   ├ lab.db (SQLite, единственный писатель)   │
                                                │   ├ golden: manifest + CAS; ворота; храповик │
                                                │   ├ play-сессии, прокси записи, повторитель  │
                                                │   └ reports\index.html, SUMMARY.md           │
                                                └──────────────────────────────────────────────┘
```

### Что сохраняем как есть
F2F-протокол и обе реализации (Java `F2F*`, пак `f2f.lua` + патч движка); форматы сценариев `tools/scenarios/alpha/*.json`
(включая E2E-таймлайн); метрику `tools/reference/compare.py` и `e2e_compare.py`; `perflib.py`/`perf_compare.py`; `gen_*`
генераторы; журнал как понятие и `journal_report`; инструменты `eag_*`/`vc_*` для wasmrt/Eaglercraft (переносятся в демон
последними или не переносятся — они про рантайм `VC_ROOT`, который демон и так арендует как `vc_runtime`).
Правок движка архитектура не требует. Возможная **тестовая** правка F2F-патча (разрешённая категория): `hello` отдаёт
`GL_RENDERER/GL_VENDOR` и экранирует не-UTF-8 `what()` (урок cp1251) — назвать в отчёте отдельно.

### План миграции

| Фаза | Содержание | Дни | Готово, когда |
|---|---|---|---|
| 0. Быстрые меры | наблюдатель-архиватор `VC_ROOT\latest.log` (может жить даже в старом MCP); бэкфилл манифестов 33 golden; таблица занятых портов в AGENTS.md; WER LocalDumps (админ) | 0.5–1 | лог сессии пользователя больше не теряется; у каждого golden есть `manifest.json` |
| 1. Ядро демона | venv, FastAPI, SQLite, Job Objects, пул портов, каталоги экземпляров, аренды с TTL, наблюдение за выходом + хвост лога, `labctl`, stdio-мост MCP, автозапуск через Планировщик | 2.5–3 | два агента параллельно получают по экземпляру vc_f2f+java_server, `lab stop --all` убивает всё, убийство демона не оставляет сирот |
| 2. Один исполнитель | `lab/scenario.py` из `run_vc_scenario`/`run_u`/`e2e_run`/`am_scenario`; F2F прямым TCP; pytest-наборы `parity_layers`, `parity_scenarios`, `e2e`; запись `results`; старые скрипты → обёртки над демоном (те же аргументы) | 2.5–3 | `alpha_spawn`, 12 слоёв и `e2e_walk1` дают побайтно те же sha, что старые пути (сверка на 3 прогонах) |
| 3. Golden и ворота | CAS, `promote/regen/stale`, набор одобренных sha, храповик с ε из J/J, `gate`, импорт 147 прогонов, `index.html` + `SUMMARY.md` | 2 | `lab gate` выдаёт JSON-вердикт и страницу с историей % по всем слоям |
| 4. Сессия игры и падения | `lab play`, отчёт при выходе, разбор кодов выхода, дампы, `crash.json`, журнал в демоне | 1–1.5 | пользователь играет → по выходу `report.md` с кривой fps и ошибками без участия агента |
| 5. Перф | набор `perf` в демоне, контроль загрузки ПК, импорт записанных чисел §9, прокси записи и повторитель протокола 14 | 2.5–3 | перф-прогон на записанной сессии воспроизводит 25–40 MapChunk/с; в отчёте «было в записях» |
| 6. Ночные ворота и плагины | задача Планировщика (ночью, «если простаивает 15 мин», «остановить при выходе из простоя»), модули `features/*`, перезагрузка, `lab_call` | 1 | утром в `SUMMARY.md` — вердикт ночного прогона; новая возможность без `/mcp` |
| **Итого** | | **12–15** | |

Порядок миграции безопасен для параллельной работы: фазы 1–2 вводят новые порты (25600+) и каталоги `lab\inst\`, старые
скрипты продолжают работать на своих портах до фазы 2; переключать агентов на демон — когда нет запущенных агентов
(правило «перезапуск сессии убивает агентов»).

### Правила для заданий агентам после миграции
- В задании: `LAB_OWNER=<имя>`, нужные виды экземпляров, разрешён ли `gpu_exclusive`/`vc_runtime`; ни портов, ни exe-копий,
  ни `--dir` агент не придумывает.
- Отчёт агента — `run_id` и вердикт из демона (`GET /runs/<id>` — машиночитаемо), числа из `results`, пути из каталога прогона.
- Агент освобождает аренды при завершении; забытые снимет TTL.

## 5. Риски

| Риск | Вероятность / вес | Мера |
|---|---|---|
| Демон — единая точка отказа; при его падении kill-on-close убивает все тестовые экземпляры | средняя / высокий в разгар прогонов | это намеренно (нет сирот); автоперезапуск задачей; прогоны помечаются `aborted`; `vc_runtime` пользователя вне kill-on-close |
| Сдвиг поведения при переносе исполнителя (тайминг `pace_ms`, порядок `keepalive`, перевод клавиш) | средняя | фаза 2 принимается только по совпадению sha с прежними прогонами на 3 повторах |
| Гибридная GPU / разные exe-пути дают разный рендер или fps | средняя | одна сборка = один путь; `GL_RENDERER` в манифестах; явное предпочтение «высокая производительность» для пути сборки |
| Пользователь работает на ПК во время ночных/параллельных прогонов | высокая | F2F не зависит от окон (F2F §0); перф — только с `gpu_exclusive` и проверкой простоя, иначе `contended` |
| Окружение `C:\Python313` пользователя меняется (обновления пакетов) | средняя | свой venv с зафиксированными версиями |
| Админские шаги (WER LocalDumps; правило брандмауэра — только если выбрать HTTP из WSL) | — | однократно, описать в `tools/lab/README.md`; stdio-мост обходится без брандмауэра |
| Сервер альфы недетерминирован по событиям (`World.rand`, такт подбора) — ворота дают ложные регрессии | известно (E2E) | наборы одобренных sha + ε из J/J; настоящее лечение — сервер в lockstep с харнессом (отдельная задача) |
| Claude Code: `list_changed` работает со следующего хода; ограничения вывода MCP (предупреждение > 10k, предел 25k токенов) | известно | узкая поверхность + `lab_call`; большие отчёты — путь к файлу и краткий JSON |
| Windows 10 вне основной поддержки; будущее обновление до 11 меняет сеть WSL (mirrored) | низкая сейчас | архитектура не зависит от режима сети WSL; при переходе можно убрать stdio-мост |
| Объём `runs\` растёт (271 МБ за 2 дня) | высокая | политика хранения: PNG прогонов без регрессий — только diff/heat и sha после 7 дней; CAS дедуплицирует одинаковые кадры |
| Двойная поддержка старых и новых путей в переходный период | высокая | старые скрипты превращаются в обёртки в фазе 2 и помечаются устаревшими в README; срок удаления — после фазы 3 |

## 6. Источники
- WSL networking (NAT, host IP, mirrored — Windows 11 22H2+, Hyper-V firewall): https://learn.microsoft.com/en-us/windows/wsl/networking
- Job Objects (вложенные с Win8, WMI-процессы вне Job, KILL_ON_JOB_CLOSE, порт завершения): https://learn.microsoft.com/en-us/windows/win32/procthread/job-objects
- Наследование пайпов и зависание при запуске фоновых процессов: https://github.com/kunchenguid/chrome-devtools-axi/issues/144
- SQLite через DrvFs/9P: https://github.com/microsoft/WSL/issues/2395
- Session 0 и задачи планировщика: https://learn.microsoft.com/en-us/answers/questions/5789906/scheduler-tasks-with-security-options-run-whether
- Self-hosted runners — только приватные репозитории: https://docs.github.com/en/actions/how-tos/manage-runners/self-hosted-runners/add-runners ; https://best.openssf.org/SCM-BestPractices/github/runner_group/runner_group_can_be_used_by_public_repositories.html
- pytest (MIT): https://pypi.org/project/pytest/ ; pytest-xdist 3.8.0 (MIT): https://pypi.org/project/pytest-xdist/ ; pytest-html 4.2.0 (MPL-2.0): https://pypi.org/project/pytest-html/ ; allure-pytest 2.16.2 (Apache-2.0): https://pypi.org/project/allure-pytest/ ; Robot Framework 7.5 (Apache-2.0): https://pypi.org/project/robotframework/
- Allure 3 history (`historyPath`, JSONL): https://allurereport.org/docs/v3/configure/
- Grafana SQLite plugin 4.0.6 «Needs attention»: https://grafana.com/grafana/plugins/frser-sqlite-datasource/
- Unreal Screenshot Comparison: https://dev.epicgames.com/documentation/en-us/unreal-engine/screenshot-comparison-tool-in-unreal-engine
- Unity Graphics Test Framework: https://docs.unity3d.com/Packages/com.unity.testframework.graphics@8.3/manual/index.html
- Chromium GPU pixel tests / Skia Gold: https://chromium.googlesource.com/chromium/src/+/HEAD/docs/gpu/gpu_pixel_testing_with_gold.md ; https://skia.org/docs/dev/testing/skiagold/
- Godot regression test project: https://github.com/godotengine/regression-test-project/blob/3.x/README.md
- BackstopJS: https://github.com/garris/BackstopJS ; reg-suit: https://github.com/reg-viz/reg-suit
- Git LFS billing (10 ГиБ): https://docs.github.com/billing/managing-billing-for-git-large-file-storage/about-billing-for-git-large-file-storage
- DVC (Windows: hardlink, cache.type=copy): https://doc.dvc.org/user-guide/project-structure/configuration ; https://en.wikipedia.org/wiki/Data_Version_Control_(software)
- Virtual desktops, `MoveWindowToDesktop` для чужих окон: https://learn.microsoft.com/en-us/windows/win32/api/shobjidl_core/nf-shobjidl_core-ivirtualdesktopmanager-movewindowtodesktop ; https://github.com/digitalcreations/MaxTo/issues/704
- WER LocalDumps: https://learn.microsoft.com/en-us/windows/win32/wer/collecting-user-mode-dumps
- Claude Code MCP (`list_changed`, HTTP transport, лимиты вывода): https://code.claude.com/docs/en/mcp ; https://github.com/anthropics/claude-code/issues/31893
- MCP Python SDK (MIT, stdio/Streamable HTTP): https://pypi.org/project/mcp/
