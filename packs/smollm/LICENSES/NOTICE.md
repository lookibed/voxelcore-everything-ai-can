# Лицензии пака smollm

- **Ru-Small-Instruct** (веса `data/model_q8.bin` — квантование Q8_0 исходных bf16-весов, токенизатор `data/tokenizer.bin`)
  — LongTime Devs, https://huggingface.co/longtimedevs/Ru-Small-Instruct, лицензия MIT (README модели: «Веса свободны
  для коммерческого и исследовательского применения»).
- **llama2.c** (основа кода инференса `modules/smollm.lua`: C → wasm → Lua) — Andrej Karpathy, MIT, `LICENSE-llama2.c.txt`.
- **GPT-2 `bytes_to_unicode`** (таблица байт ↔ символ ByteLevel-токенизатора при экспорте) — OpenAI, MIT.
- Исходники и экспорт — Spider, `tests/manual/real-world-smollm` (`THIRD_PARTY.md`).
