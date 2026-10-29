"""Плагин проекта-шаблона: возможности (lab call template.<имя>, MCP lab_template_<имя> при mcp=True) и хуки сценариев.
Перезагружается демоном горячо (правка файла -> новая версия; ошибка — остаётся прежняя, текст в `lab projects`)."""
PLUGIN_VERSION = 1


def register(api):
    def status(ctx, a):
        """Состояние аренды: hello тестовой сборки (версия, кадр, флаги изоляции)."""
        lease = a.get("lease") or "template-engine-1"
        h = ctx.f2f(lease, "hello", {})                # журналируется как вложенный вызов
        r = h.get("result") or {}
        return {"lease": lease, "version": r.get("version"), "frame": r.get("frame"), "flags": r.get("flags")}

    api.feature("status", status, "hello of a lease of this project",
                {"type": "object", "properties": {"lease": {"type": "string"}}}, mcp=True)

    # Шаг сценария, которого нет в F2F: {"cmd": "frames", "args": {"n": 10}} -> step n кадров.
    def frames(sx, args, step):
        n = int(args.get("n", 1))
        return sx.f2f("step", {"ticks": n, "frames": n})

    api.scenario(steps={"frames": frames})


def selftest():
    """Необязательно: упало — плагин не подменяется, остаётся прежняя версия."""
