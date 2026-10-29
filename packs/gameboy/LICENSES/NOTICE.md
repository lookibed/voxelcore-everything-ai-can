# Сторонние компоненты пака gameboy

| Компонент | Где в паке | Автор | Лицензия |
|---|---|---|---|
| [binjgb](https://github.com/binji/binjgb) — ядро эмулятора | `modules/binjgb/binjgb.lua` (C → wasm → Lua) | Ben Smith | MIT, см. `binjgb-MIT.txt` |
| [cgb-acid2](https://github.com/mattcurrie/cgb-acid2) — тестовый ROM | `roms/cgb-acid2.gbc` | Matt Currie | MIT |

`binjgb.lua` получен трансляцией wasm-сборки binjgb в Lua транслятором Spider
(target `lua-no-ffi`). Обвязка для wasm (`module.c`, `shim.c`) написана для этого пака.
