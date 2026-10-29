# Сторонние компоненты пака videoplayer

| Компонент | Где в паке | Автор | Лицензия |
|---|---|---|---|
| [h264bsd](https://github.com/oneam/h264bsd) — декодер H.264 | `modules/h264mp4/h264mp4.lua` (C → wasm → Lua) | The Android Open Source Project; standalone-версия — oneam | Apache 2.0, см. `h264bsd-Apache-2.0.txt` |
| [minimp4](https://github.com/lieff/minimp4) — демуксер MP4 | там же | lieff | CC0 1.0, см. `minimp4-CC0-1.0.txt` |

`h264mp4.lua` получен трансляцией wasm-сборки (minimp4 + h264bsd + обвязка) в Lua
транслятором Spider (target `lua-no-ffi`).

Изменение h264bsd: в `h264bsd_slice_data.c` после декода каждого макроблока
вызывается `h264mp4_mb_hook()` (точка, где хост может прервать декод кадра).

`videos/sample.mp4` сгенерирован ffmpeg (`testsrc2`, 96x64, 12 кадров).
