# ADR 0009: `machine.toml` вместо зашитых путей (29.10.2026)

**Контекст.** В рабочем каталоге пути одного ПК (`D:\Prog\…`, `C:\Python313`) были в `lab.toml`, дескрипторах проектов и
коде; на другой машине ничего не запускалось.

**Решение.** Единственное место путей — `machine.toml` (в `.gitignore`; образец `machine.toml.example`, ключи —
`vclab/machine.py KEYS`): `engines_root`, `builds_root`, `work_root`, `python_win` (обязательные), `python_wsl`, `msys2`,
`vc_root`, `wsl_mount`, `powershell`, `cargo`, перекрытия `[engines.<id>]`. Остальное ссылается подстановками
(`{machine.<ключ>}`, `{work_root}`, `{vc_root}`, `{engine.*}`). `lab doctor` проверяет и подсказывает (`install/doctor.md`).

**Последствия.** Перенос проекта — замена путей подстановками (`docs/PROJECTS.md` §8). Новый корень — новый ключ в `KEYS` и в
образце. Читается и на WSL-Python 3.10 (простое подмножество TOML без `tomllib`).
