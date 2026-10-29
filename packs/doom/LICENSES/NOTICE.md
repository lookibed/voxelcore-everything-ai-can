# Сторонние компоненты пака doom

| Компонент | Где в паке | Автор | Лицензия |
|---|---|---|---|
| [doomgeneric](https://github.com/ozkl/doomgeneric) (коммит `dcb7a8dbc7a16ce3dda29382ac9aae9d77d21284`) — порт DOOM на основе Chocolate Doom | `modules/doom/doom.lua` (C → wasm → Lua) | id Software, авторы Chocolate Doom и doomgeneric | GNU GPL v2, см. `GPL-2.0.txt` |
| wasi-libc (из wasi-sdk 30) | там же | авторы wasi-libc и musl | MIT / Apache-2.0 с исключением LLVM |
| DOOM Shareware 1.9 (`doom1.wad`) | `wads/doom1.wad` | id Software | условия id Software для Shareware, см. `DOOM-SHAREWARE-WAD.txt`; распространять только бесплатно |

## Исходный код (GPL v2)

`doom.lua` — это doomgeneric, собранный clang из wasi-sdk 30 в WebAssembly
(`--target=wasm32-wasip1 -O2 -DCMAP256 -DDOOMGENERIC_RESX=320 -DDOOMGENERIC_RESY=200`) и оттранслированный в Lua транслятором Spider (target `lua-no-ffi`).

Изменения относительно doomgeneric:

- `source/dg_voxelcore.c` — платформенный слой для VoxelCore (весь в этом паке);
- `d_main.c`: `I_AtExit(G_CheckDemoStatus)` заменён обёрткой `void(void)`, иначе
  `call_indirect` в wasm ловит несовпадение типа функции при выходе из игры.

Остальные файлы doomgeneric не менялись и доступны по ссылке выше.
