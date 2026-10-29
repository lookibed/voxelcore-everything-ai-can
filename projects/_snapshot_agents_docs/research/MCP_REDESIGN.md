# MCP `voxelcore`: перестройка на долгий срок (исследование, 01.10.2026)

Только исследование: движок, Java и MCP не запускались, код не менялся. Замеры ниже — запуск интерпретаторов
и статистика существующего журнала (`artifacts/journal/journal.jsonl`, 9814 записей), а не прогоны игр.

## 0. Коротко

- **Хостинг.** Перенести рабочую часть на Windows (`C:\Python313`) — да. Сетевой путь «WSL → Windows-HTTP» на этой
  машине закрыт: Windows **10.0.19045** (Win10 22H2), режим WSL `nat` (`wslinfo --networking-mode`), а
  `networkingMode=mirrored` требует **Windows 11 22H2+**. Поэтому фронт MCP — **stdio-процесс Windows-питона,
  запущенный из WSL через interop** (этот приём уже работает у пользователя: сервер `EdenSpark` в `~/.claude.json`
  = `/mnt/c/Python313/python.exe -X utf8 -u ...\mcp_bridge.py`, мост stdio ↔ HTTP 127.0.0.1:54300).
- **Цель:** демон `vcd` на Windows (держит процессы, аренды, TCP к F2F, логи, журнал) + тонкий stdio-мост для Claude
  Code + CLI-клиент для раннеров. PowerShell остаётся только для старых `.ps1` (окно/клики) — в том же процессе.
- **SDK.** Официальный `mcp` сейчас 2.2.0 (2.x — «major rework», API переименован `FastMCP` → `MCPServer`,
  требует `pydantic>=2.12`, а в `C:\Python313` стоит 2.11.9). Рекомендация: оставить свой протокол (stdlib, без
  зависимостей), добавить в него `notifications/progress`, `notifications/tools/list_changed`, `_meta` — ~200 строк.
  SDK — опционально позже, в отдельном venv демона.
- **Долгие операции.** Claude Code **не** поддерживает MCP Tasks (SEP-1686; issue #76571 закрыт как дубликат,
  прежние #52137/#18617 — «not planned»). Зато он сам уводит вызов дольше 2 мин в фоновую задачу и ждёт
  до idle-таймаута (stdio — 30 мин без progress). Значит: блокирующие инструменты с progress + свой `job_*`
  (id + опрос) для прогонов, которые должны пережить переподключение.
- **Параллельные агенты.** Аренда `instance` (имя, порты, каталоги, PID, Job Object, TTL) обязательна в каждом
  `am_*`; демон отказывается трогать процесс вне аренды. Сейчас то же самое держится на соглашениях: 9 копий
  `VoxelCoreF2F-<буква>.exe`, `userdir_<буква>`, `run\server_<буква>`, `*.pid`, метка `-Dalphamine.dir=`.
- **Объём:** ≈ 9–12 рабочих дней в 5 этапов, каждый этап оставляет систему рабочей.

## 1. Что есть сейчас (факты)

| Часть | Файл | Как устроено |
|---|---|---|
| Протокол MCP | `tools/mcp/voxelcore_mcp.py` (570 стр.) | stdio JSON-RPC вручную, `protocolVersion 2024-11-05`, `capabilities: {tools: {}}`, однопоточный цикл `for line in stdin`; уведомления от сервера не шлёт |
| Windows | там же, `PSWorker` | один постоянный `powershell.exe`, строка base64 → ответ `@@VCPS OK|ERR base64`; fallback — `powershell_oneshot` |
| Домены | `eagler_tools.py` (755), `alpha_tools.py` (925), `alpha_vc.py` (304), `pixel_debug.py` | `register(TOOLS, vc, text)` дописывает словарь `TOOLS` |
| Журнал/сценарии | `journal.py` (574) | `call()` оборачивает каждый вызов: JSONL, скриншот до/после, пометки `slow/idle/no_change`; сценарии `tools/scenarios/eag/*.json` |
| CLI | `run_tool.py` | импортирует сервер и зовёт `call_tool` — журнал не обходится |
| F2F из WSL | `tools/alphamine/f2f_client.py` + `f2f_relay.ps1` | в WSL сокет к 127.0.0.1 Windows невозможен (NAT) → на каждое соединение отдельный `powershell.exe` с ретранслятором строк |
| Раннеры | `run_u.py`, `run_vc_scenario.py`, `server_v.py`, `e2e/e2e_run.py`, `perf/*` | **свои** `ps()` с `subprocess.run(powershell.exe ...)` на каждый шаг, свои pid-файлы, свои порты; в журнал MCP не попадают (кроме `am_e2e`, который запускает `e2e_run.py` дочерним процессом и пишет одну запись) |
| Запуск Java | `D:\Prog\AlphaMine\ref\start_server.ps1`, `start_client.ps1` | `Invoke-CimMethod Win32_Process Create` + `cmd.exe /c ... > log 2> err` — обход зависания `Start-Process` из WSL (наследование дескрипторов); логи в cp866 |
| Остановка | `alpha_tools.kill`, `server_v.stop` | `Stop-Process -Id` по PID из CIM-поиска `java.exe` с разбором командной строки; `vc_stop` — **`Stop-Process -Name VoxelCore`** (все экземпляры, включая чужие) |

### Замеры (01.10, без нагрузки движком)

| Что | Время | Откуда |
|---|---|---|
| холодный `powershell.exe -NoProfile -Command 1` из WSL | **0.68 с** | `time`, сейчас |
| холодный `C:\Python313\python.exe -c ...` из WSL | **0.06 с**; с `import socket,json,ctypes,win32job` — 0.09 с | `time`, сейчас |
| импорт `voxelcore_mcp` (Linux python) | 0.12 с | `time`, сейчас |
| вызов в тёплом PSWorker | PID 3 мс, скриншот 50 мс | `agents/LESSONS.md` «Процесс» |
| `run_tool.py` из консоли | ~1–2 с | импорт + холодный PowerShell + `Add-Type` при первом скриншоте |
| `am_f2f` верхнего уровня (7465 вызовов) | среднее **0.92 с** | журнал |
| F2F внутри тёплого соединения (`step`/`state`/`input`) | **медиана 0–10 мс**, `shot` 20 мс, `wait` 0.4 с | журнал, вложенные вызовы `am_scenario` |
| `vc_start` / `am_client` / `am_scenario` / `am_layers` | 16.7 / 6.1 / 143 / 137 с в среднем | журнал |

Вывод из замеров: тёплый ретранслятор почти бесплатен — **дорого установление** (≈0.7 с PowerShell на соединение, плюс
переподключения в `f2f()` при обрыве) и каждый новый процесс-раннер, который заново поднимает PowerShell и ретранслятор.
Ожидаемо после переноса: соединение F2F из Windows-питона — единицы мс; `run_tool`-аналог через демон —
0.06 с запуск + RTT к демону (~1 мс); запуск процесса через `CreateProcess` — десятки мс вместо 0.7–1.5 с
(PowerShell + CIM). Цифры «ожидаемо» нужно подтвердить замером на этапе 1 (не при занятом ПК).

## 2. Хостинг

### 2.1 Варианты

| Вариант | Как Claude Code (WSL) достаёт сервер | Что снимает | Минусы |
|---|---|---|---|
| A. Как сейчас: MCP в WSL (Python 3.10) | stdio | — | каждый вызов Windows — через PowerShell; F2F — через ретранслятор; запуск процессов — через CIM/`cmd.exe`; раннеры дублируют это |
| B. MCP целиком на Windows, stdio | `"command": "/mnt/c/Python313/python.exe", "args": ["-X","utf8","-u","D:\\...\\vcmcp.py"]` | PowerShell для процессов, ретранслятор, зависание `Start-Process` | состояние живёт в процессе MCP: `/mcp`-переподключение или рестарт сессии теряют PID-ы, соединения F2F (процессы-сироты); stdio Claude Code **не переподключает сам** |
| C. Демон на Windows + HTTP напрямую | `"type": "http", "url": "http://127.0.0.1:P/mcp"` | всё из B + авто-переподключение HTTP | **не работает здесь**: в NAT из WSL 127.0.0.1 — это сама WSL; IP хоста (`172.25.144.1`) требует слушать не-loopback → правило брандмауэра/всплывающее окно Defender |
| D. Демон на Windows + stdio-мост (как EdenSpark) | stdio → `python.exe vc_bridge.py` → HTTP 127.0.0.1 | всё из B; состояние переживает `/mcp` и перезапуск сессии; раннеры ходят в тот же демон | два процесса; мост надо поддерживать |
| E. `networkingMode=mirrored` + C | HTTP 127.0.0.1 из WSL | — | **недоступно**: Windows 10 19045; режим требует Windows 11 22H2+ (Microsoft Learn «Accessing network applications with WSL») и ещё Hyper-V firewall-правила для входящих |

**Рекомендация: D.** B — промежуточный шаг (этап 1), он проверяет Windows-сторону без демона.

### 2.2 Почему исчезает зависание `Start-Process`
Зависание — ожидание WSL-стороной закрытия канала stdout, который унаследовал запущенный процесс (поэтому и обход
через WMI «без наследования дескрипторов»). В демоне `CreateProcess` вызывается из процесса, у которого stdout — не
interop-канал WSL, а дочернему явно передаются только его лог-файлы (`subprocess.Popen(close_fds=True, stdout=f, stderr=g)`
на Windows использует `PROC_THREAD_ATTRIBUTE_HANDLE_LIST` — наследуются только перечисленные дескрипторы).
Мост и демон — разные процессы, демон стартует с `DETACHED_PROCESS | CREATE_NO_WINDOW | CREATE_BREAKAWAY_FROM_JOB`.

### 2.3 Пути
Демон работает с путями Windows. Перевод `/mnt/d/x` ↔ `D:\x` — чистой функцией (сейчас `to_windows_path` вызывает
`wslpath` подпроцессом; в демоне его нет). Инструменты принимают оба вида, отвечают Windows-путём и WSL-путём.

### 2.4 Брандмауэр и всплывающие окна (пользователь к ним чувствителен)
- Все новые слушатели — **только `127.0.0.1`** (демон, F2F). Окно «Брандмауэр Windows заблокировал некоторые
  функции» показывается при прослушивании не-loopback адресов; loopback его не вызывает. В коде демона — assert на адрес.
- Сейчас уже так: F2F Java `new ServerSocket(port, 4, InetAddress.getByName("127.0.0.1"))`, F2F движка
  `bind 127.0.0.1` (`engine/f2f.patch`). **Но сервер альфы слушает все интерфейсы** (`server-ip=` пустой в
  `ref/minecraft_server/game/server.properties` и `run/server_v/`) — в арендах писать `server-ip=127.0.0.1`
  (поведение игры не меняется: клиент и так ходит на localhost).
- Не использовать HTTP с хоста `172.x` и `netsh portproxy` — это правила брандмауэра и права администратора.
- Окна падения: демон вызывает `SetErrorMode(SEM_FAILCRITICALERRORS | SEM_NOGPFAULTERRORBOX)` — режим наследуется
  детьми, «программа перестала работать» не всплывёт; падение фиксируется кодом выхода и хвостом лога.
- Дочерние процессы без консоли: `CREATE_NO_WINDOW` (сейчас это делает `ShowWindow=0` в CIM).

## 3. Протокол: SDK или свой

| | Свой (сейчас) | `mcp` 2.x (FastMCP/`MCPServer`) |
|---|---|---|
| Зависимости | stdlib | anyio, httpx2, pydantic>=2.12, starlette, uvicorn, sse-starlette, opentelemetry-api, pyjwt… (PyPI `mcp` 2.2.0) |
| Схемы | руками в словаре | из аннотаций типов |
| Транспорты | stdio | stdio, Streamable HTTP, SSE; монтирование в Starlette |
| Динамические инструменты | словарь `TOOLS` | `add_tool`/`remove_tool`, `send_tool_list_changed` |
| Progress/логи | нет | `ctx.report_progress`, `ctx.info` |
| Картинки | `{"type":"image"}` руками (уже работает) | класс `Image` |
| Стабильность API | наша | только что вышел 2.0 с переименованиями; 1.x на поддержке |

Что из протокола реально нужно (по документации Claude Code, code.claude.com/docs/en/mcp):
- **`list_changed`**: «Claude Code supports MCP `list_changed` notifications… automatically refreshes». Оговорка:
  на «v2 runtime» уведомления принимаются по открытому потоку у серверов новой ревизии (2026-07-28); для stdio-серверов
  это включается `MCP_PROTOCOL_NEGOTIATION=auto`. **Проверить пробником** (этап 1): stdio-сервер, который через 5 с
  добавляет инструмент `probe_added` и шлёт `notifications/tools/list_changed`; виден ли он без `/mcp`.
  Горячая перезагрузка **кода** обработчиков от этого не зависит — имена и схемы прежние, меняется только функция.
- **Progress**: уведомления сбрасывают idle-таймаут (`CLAUDE_CODE_MCP_TOOL_IDLE_TIMEOUT`, stdio по умолчанию
  30 мин, HTTP 5 мин); per-server `"timeout"` в `.mcp.json` ≥ 1000 мс — нижняя граница idle.
- **Фоновые вызовы**: вызов дольше 2 мин Claude Code сам переводит в фоновую задачу
  (`CLAUDE_CODE_MCP_AUTO_BACKGROUND_MS`), результат приходит уведомлением — это и есть «async» для агента.
- **MCP Tasks** (`tasks/get`…) клиент не поддерживает — не строить на них.
- **Ресурсы** (`resources/*`) в документации Claude Code не описаны — логи/скриншоты отдавать инструментами
  (путь + хвост/картинка), не ресурсами.
- **Большой вывод**: предупреждение >10k токенов, обрезка 25k (`MAX_MCP_OUTPUT_TOKENS`); `_meta["anthropic/maxResultSizeChars"]`
  в `tools/list` поднимает порог до 500k символов. Картинки PNG видны inline, оригинал сохраняется в `tool-results`.
- Sampling, elicitation, prompts — не нужны.

**Решение:** свой протокольный слой `vccore/mcp_proto.py` (stdio + HTTP на `http.server`/`asyncio`, ~250 строк),
регистрация декоратором, `progress`, `list_changed`, `_meta`. Переход на SDK — отдельным решением, когда 2.x
устоится; ставить тогда в venv демона (`D:\Prog\VoxelCore\vcd-venv`), не трогая `C:\Python313` (им пользуется
EdenSpark и раннеры).

## 4. Раскладка: ядро + плагины

```
tools/vc/                          (каталог движка: это MCP/рантайм-инструменты, не исходники игр)
  vccore/                          общая библиотека — её импортируют и демон, и CLI
    proto.py        JSON-RPC, stdio/HTTP, progress, list_changed, _meta
    registry.py     @tool(name, schema, journal=..., lease=...) ; версии плагинов; reload
    procs.py        ProcessManager: CreateProcess, Job Objects, логи, смерть, хвосты
    leases.py       аренды экземпляров (§7), порт-аллокатор, TTL, файл состояния
    f2f.py          пул TCP-соединений F2F (ключ — instance+impl), переподключение
    winui.py        окно/скриншот/клики: ctypes (PrintWindow, SendInput) + PSWorker для старых .ps1
    logs.py         захват stdout/stderr в файлы, политика декодирования, архив latest.log
    journal.py      формат JSONL как сейчас + каталоги прогонов (§6)
    golden.py       golden-хранилище (D:\Prog\AlphaMine\golden), размеры кадра (§8 F2F)
    compare.py      обёртка над tools/reference/compare.py
    paths.py        /mnt/x <-> X:\ без wslpath
    jobs.py         долгие задачи: job_start/job_wait/job_tail/job_cancel
  plugins/          один модуль на домен, автообнаружение по glob, PLUGIN_VERSION в каждом
    vc.py   eag.py   am.py   perf.py   e2e.py   scen.py   sys.py (am_ps, am_release, plugins_reload, health)
  vcd.py            демон: HTTP 127.0.0.1:<порт из vcd.json>, один на машину (mutex Global\vcd)
  vc_bridge.py      stdio <-> HTTP для Claude Code; поднимает vcd, если тот не отвечает
  vcctl.py          CLI: `vcctl <tool> '<json>'` (замена run_tool.py) — ходит в тот же демон
  dashboard.py      статический HTML по индексу прогонов
```

- **Автообнаружение**: `plugins/*.py`, у каждого `register(r: Registry)`; `PLUGIN_VERSION` попадает в `serverInfo` и в
  каждую запись журнала (`"plugin": "am@7"`) — в отчётах видно, какой версией снят результат.
- **Горячая перезагрузка**: инструмент `plugins_reload(names?)` → `importlib.reload(vccore.<не-состояние>)` и плагинов;
  состояние (аренды, процессы, соединения, задачи) живёт в объектах ядра, которые **не** перезагружаются
  (`procs`, `leases`, `f2f`, `jobs`), плагины получают их через `r.services`. Если набор имён/схем изменился —
  `notifications/tools/list_changed`. Правило AGENTS.md «после правок `tools/mcp/*.py` — `/mcp`» сводится к правкам
  `vc_bridge.py`/`proto.py`.
- **Журнал не обходится**: единственный путь выполнения — `Registry.call()` в демоне. `vcctl` и раннеры
  (`run_u.py`, `run_vc_scenario.py`, `e2e_run.py`, `perf_*`) переписываются так, что каждое действие — вызов
  инструмента демона (или `vccore` в процессе демона через `job_start("e2e", ...)`). Свои `ps()`/`Stop-Process`
  в раннерах удаляются.

## 5. Процессы на Windows из Python

Есть в `C:\Python313`: `pywin32 311` (`win32job` импортируется), `psutil 7.0.0`.

1. **Запуск**: `win32process.CreateProcess(..., CREATE_SUSPENDED | CREATE_NO_WINDOW | CREATE_NEW_PROCESS_GROUP)`,
   `AssignProcessToJobObject(job, h)`, `ResumeThread` — без гонки «ребёнок успел породить внука до назначения».
   stdout/stderr — дескрипторы файлов `runs\...\logs\<proc>.out|.err`, наследуется только они (handle list).
   Без `cmd.exe`, без CIM, без PowerShell.
2. **Job Object на экземпляр** (`instance`): `JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE` (демон упал → дети умерли, сирот
   нет) — по умолчанию; для пользовательского GUI-запуска `vc_start` — флаг `detach` (job без kill-on-close, но
   дерево всё равно убивается `TerminateJobObject`). Состав — `QueryInformationJobObject(JobObjectBasicProcessIdList)`.
3. **Остановка**: сначала мягко (F2F `quit`, у сервера альфы — `/stop` в stdin: только он сохраняет мир полностью,
   LESSONS «AlphaMine»), затем `TerminateJobObject`. **`Stop-Process -Name` не используется нигде**; `vc_stop`
   без аренды останавливает только процессы, запущенные этим демоном.
4. **Идентичность после рестарта демона**: в файле аренд — `pid + create_time` (psutil); процесс считается своим
   только при совпадении обоих (защита от переиспользования PID). Чужой `java.exe` без записи — не трогать никогда.
5. **Смерть**: поток на `WaitForSingleObject(hProcess)` → событие `{instance, proc, exit_code, t, tail[40]}` в журнал и в
   очередь событий аренды; любой следующий вызов `am_*` с этой арендой сразу отвечает «клиент умер, код X, хвост…»
   вместо таймаута. Код `0xC0000005`, «uncaught exception», `utf8 decode error` — распознаются и помечаются.
6. **Кодировки** (сейчас: логи Java через `cmd.exe` — cp866; ошибки Windows в cp1251 сломали F2F-JSON движка —
   LESSONS «utf8 decode error»). Политика `logs.decode(bytes)`: хранить **сырые байты**; при чтении — UTF-8 strict →
   если ошибка, выбор cp866/cp1251 по частоте кириллицы (в cp866 буквы 0x80–0xAF/0xE0–0xEF, в cp1251 0xC0–0xFF) →
   `replace`. Для новых запусков Java проверить, какую кодировку даёт прямой редирект без консоли (ожидаемо
   `file.encoding`=Cp1251), и записать её в аренду; `-Dfile.encoding` не менять без проверки паритета.
   Шаблоны ожидания (`wait_log`) применяются к декодированному тексту — источник «молчащих» Monitor-ов уходит.
7. **`latest.log`** перезаписывается каждым стартом движка: у каждой аренды свой `--dir`, а `logs.archive()` копирует
   `latest.log` в каталог прогона при остановке и **до** старта (лог пользователя 01.10 00:51 был потерян).

## 6. Журнал и наблюдаемость

- Формат записей **сохраняется** (`idx, t, ts, tool, args, session, parent, dur, result, shot, meta`), добавляются
  `instance`, `run`, `plugin`, `agent` (из аренды).
- **Каталог прогона**: `artifacts/runs/<YYYYMMDD_HHMMSS>_<instance>_<tool|scenario>/`:
  `journal.jsonl` (срез), `shots/`, `logs/` (stdout/err процессов, архив `latest.log`), `report.json`, `report.md`.
  Для AlphaMine — тот же формат, что `D:\Prog\AlphaMine\runs\<stamp>_<impl>_<agent>\<scenario>\report.json` (147 каталогов,
  271 МБ) — существующие отчёты читаются индексатором как есть.
- **Индекс** `artifacts/runs/index.jsonl`: одна строка на прогон (время, instance, агент, сценарий, ok, %, длительность,
  путь). Глобальный `journal.jsonl` (сейчас 9814 строк, каталог 134 МБ со снимками) — ротация по месяцам.
- **Дашборд** `dashboard.py` → `artifacts/dashboard/index.html` (статический, без сервера): таблица прогонов с фильтрами,
  % паритета по сценариям во времени, последние пометки `slow/idle/no_change`, текущие аренды (снимок `am_ps`),
  ссылки на `report.md`/картинки. Генерируется по окончании каждого прогона.
- `journal_report` остаётся, плюс `runs_report(last, instance?)`.

## 7. Контракт для параллельных агентов

```
am_lease(agent="U", purpose="hud", ttl_min=120, need=["server","java","vc"]) ->
  {instance:"u", ports:{server:25570, java_f2f:25582, vc_f2f:25575},
   dirs:{server:"D:\\Prog\\AlphaMine\\run\\server_u", world:"...\\world_u", vc_user:"...\\engine\\userdir_u",
         runs:"...\\runs"}, exe:"...\\VoxelCoreF2F-u.exe", expires:"..."}
am_ps()                -> все аренды: агент, порты, PID-ы (+живы ли), каталоги, возраст, последний вызов
am_release(instance)   -> мягкая остановка, TerminateJobObject, архив логов, освобождение портов
am_renew(instance, ttl_min)
```

- **`instance` обязателен** в каждом `am_*`/`e2e`/`perf` (схема: `required`); без него — ошибка с подсказкой
  `am_lease`. Порты/каталоги инструменты берут из аренды, явные `port=` убираются из схем (сейчас
  `DEFAULT_PORT java 25570, vc 25571` + ручные 25573–25583 — источник столкновений).
- **Отказ вне аренды**: процессы, PID которых не в Job Object аренды, не останавливаются и не получают ввод.
- **Порт-аллокатор**: диапазон 25600–25699, проверка `bind 127.0.0.1` перед выдачей, порт фиксируется в аренде.
- **TTL**: истёкшая аренда без вызовов дольше TTL → демон пишет в журнал `lease_expired`, освобождает. Продление —
  автоматически при каждом вызове.
- **Движок пользователя** (`vc_*`, `eag_*`, GUI `VoxelCore.exe`) — отдельная аренда `main`, одна на машину; это
  машинная форма правила AGENTS.md «движком владеет один агент»: второй `vc_start` с другим агентом получает отказ
  с именем владельца.
- Копия exe на аренду (`VoxelCoreF2F-<inst>.exe`, обновление при более новом оригинале) — как в `run_u.py`, но в ядре.

## 8. Карта миграции

| Сейчас | Становится | Судьба |
|---|---|---|
| `voxelcore_mcp.py` (протокол, `handle`, `main`) | `vccore/proto.py` + `vc_bridge.py` | переписать, логика `text()/image_result()` переносится |
| `PSWorker` | `vccore/winui.py` (внутри демона) | **сохранить** для `vc_screenshot/keys/click/geom.ps1`; постепенно заменить ctypes |
| `tool_vc_*`, `pixel_debug.py` | `plugins/vc.py` | перенос; `vc_stop` по Job/аренде, не по имени |
| `eagler_tools.py` | `plugins/eag.py` | перенос почти без изменений |
| `alpha_tools.py`, `alpha_vc.py` | `plugins/am.py` (+`e2e.py`, `perf.py`) | `java_procs/kill/ps_script` → `procs`; `conn/drop` → `f2f` пул |
| `journal.py` | `vccore/journal.py` | **формат и пометки сохранить**; добавить поля и каталоги прогонов |
| сценарии `tools/scenarios/eag/*.json`, `alpha/*.json` | без изменений | **сохранить** формат; `scenario_run`/`am_scenario` — в плагины |
| `run_tool.py` | `vcctl.py` | оставить шим `run_tool.py` → `vcctl` |
| `f2f_client.py` | `vccore/f2f.py` | класс `F2F` сохранить (прямой сокет); `_Relay` и `f2f_relay.ps1` — удалить после этапа 3 |
| `start_server.ps1`, `start_client.ps1` | `procs.spawn` | командные строки Java перенести 1:1 (паритет запуска) |
| `server_v.py`, `run_u.py`, `run_vc_scenario.py`, `e2e_run.py`, `perf_*` | тонкие обёртки над `vcctl`/`job_start` | свои `ps()`, pid-файлы, `Stop-Process` удалить |

### Этапы (дни — чистое время одного агента, без прогонов при занятом ПК)

1. **Пробники и Windows-MCP (вариант B)** — 1.5 д. Пробник `list_changed` по stdio; замер холодного/тёплого вызова;
   текущий сервер запускается Windows-питоном (заменить `wslpath`, `select` на stdin-канале — на Windows `select` не
   работает с пайпами → поток-читатель). `.mcp.json` — второй сервер `voxelcore-win` рядом со старым, старый не трогать.
2. **Ядро + плагины + reload** — 2.5 д. `proto`, `registry`, `paths`, `journal` (совместимый), разнос модулей, `plugins_reload`.
3. **ProcessManager, аренды, F2F-пул** — 3 д. Job Objects, логи/декодирование, смерть, `am_lease/am_ps/am_release`,
   `instance` обязателен; перевод `am_*`; удаление ретранслятора. Проверка: два агента-сценария параллельно на разных
   арендах, `am_release` одного не трогает другой; убийство демона — нет сирот.
4. **Демон + мост (вариант D) + `vcctl` + раннеры** — 2 д. `job_*` для `am_e2e/am_layers/am_scenario`; раннеры через демон.
5. **Каталоги прогонов, индекс, дашборд** — 1.5 д.

Итого ≈ **10.5 д** (диапазон 9–12). Каждый этап — отдельный сервер/флаг, откат — переключение `.mcp.json`.

## 9. Риски

- **Переподключения Claude Code.** stdio не переподключается сам; рестарт сессии убивает stdio-процесс. В варианте D
  умирает только мост, демон и аренды живы; мост при старте отдаёт `tools/list` из демона. Правка `vc_bridge.py`/
  `proto.py` всё ещё требует `/mcp` — держать их маленькими и редко меняемыми.
- **`list_changed` по stdio может не приниматься** без `MCP_PROTOCOL_NEGOTIATION=auto` — тогда добавление инструментов
  требует `/mcp`; reload кода обработчиков работает и без этого. Проверяется пробником на этапе 1.
- **Демон — единая точка отказа**: упал → kill-on-close уносит все экземпляры. Это желаемо (нет сирот), но длинный
  E2E теряется; журнал фиксирует, `job` помечается `lost`. Мьютекс `Global\vcd` против двух демонов.
- **Брандмауэр/всплывающие окна**: только `127.0.0.1`; `server-ip=127.0.0.1` в арендах; новые копии exe — новые пути,
  для loopback-слушателей запроса нет. Не включать Hyper-V firewall-правила и `mirrored` (недоступен на Win10).
- **Defender/SmartScreen** на новые `.exe`-копии: копирование уже практикуется (9 копий) без жалоб; новых бинарников
  демон не создаёт, только `python.exe`.
- **Кодировки**: смена способа запуска Java может сменить кодировку логов (cp866 → cp1251) — шаблоны ожидания
  проверять на свежем логе (правило AGENTS «Ожидания»).
- **Паритет запуска**: командные строки Java/движка, рабочие каталоги, переменные окружения переносить 1:1 и
  сверить снимок `alpha_spawn` с golden до и после (правило «паритет», F2F §0).
- **Python 3.10 → 3.13**: раннеры и `compare.py` запускались Linux-питоном; под Windows проверить пути, `pngio`,
  перевод строк в отчётах.
- **SDK-дрейф**: если позже перейти на `mcp` 2.x — отдельный venv, версия зафиксирована.
- **Параллельные агенты во время миграции**: старый `voxelcore` и новый `voxelcore-win` не должны управлять одним
  экземпляром — на время этапов 3–4 старые `am_*` переводятся в режим «только чтение» для аренд нового демона.

## Источники
- Claude Code MCP: https://code.claude.com/docs/en/mcp (транспорты, `list_changed`, таймауты, автофон, лимиты вывода, картинки)
- MCP Tasks в Claude Code: https://github.com/anthropics/claude-code/issues/76571 ; спецификация 2026-07-28:
  https://blog.modelcontextprotocol.io/posts/2026-07-28/
- Python SDK: https://github.com/modelcontextprotocol/python-sdk , https://pypi.org/project/mcp/ (2.2.0)
- WSL networking (NAT, mirrored, Win11 22H2+): https://learn.microsoft.com/en-us/windows/wsl/networking
- Локально: `~/.claude.json` (EdenSpark-мост), `C:\Users\Andry\.edenspark\mcp_bridge.py`, `tools/mcp/*`,
  `tools/alphamine/*`, `D:\Prog\AlphaMine\ref\start_server.ps1`, `engine/f2f.patch`, `agents/LESSONS.md`, `agents/F2F.md`.
