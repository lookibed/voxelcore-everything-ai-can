-- Пример Olife (UX A3): счётчик в памяти моба — переживает перезапуск сервера и респавн.
-- memory.get(ключ) / memory.set(ключ, значение) / memory.keys() — хранилище «ключ-значение» моба с квотой;
-- первое обращение загружает его одним запросом, дальше чтение локальное, запись — действие.
local runs = (memory.get("runs") or 0) + 1
memory.set("runs", runs)
local count = memory.get("count") or 0
print(("memory_counter: run #%d, count restored = %d"):format(runs, count))
local n = 0
function on_tick(dt)
    n = n + 1
    if n % 20 == 0 then                       -- раз в секунду
        count = count + 1
        memory.set("count", count)
        self:text3d(("count %d (run %d)"):format(count, runs), "#80ff80")
    end
end
