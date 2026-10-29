"""Инструменты проекта в MCP-сервере voxelcore (WSL): vclab/mcp/voxelcore_mcp.py грузит projects/<имя>/mcp_tools.py
и вызывает register(TOOLS, vc, text). vc — модуль сервера (dev(), current_pid(), take_screenshot(), image_result(),
jmeta(), VC_ROOT, WORK_ROOT); text(message, error=False) — результат MCP. Можно расширить наборы журнала
(vclab.mcp.journal.extend) и поставить поставщика состояния игры для scenario_run (vc.STATE = {...})."""


def register(tools, vc, text):
    from vclab.mcp import journal

    def tpl_hello(args):
        """F2F hello экземпляра vc_start (через демон лаборатории)."""
        r = vc.dev().f2f("hello", {})
        return text(str(r.get("result") or r), error=not r.get("ok"))

    tools["tpl_hello"] = (tpl_hello, {
        "description": "template project: F2F hello of the vc_start instance",
        "inputSchema": {"type": "object", "properties": {}},
    })
    journal.extend(no_shot={"tpl_hello"})
    return {"tools": ["tpl_hello"]}
