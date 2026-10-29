#!/usr/bin/env python3
"""Вызов инструмента MCP-сервера voxelcore напрямую из консоли (без Claude Code / переподключения):

  python3 bin/run_tool.py <инструмент> ['{"json": "аргументы"}']
  python3 bin/run_tool.py scenario_run '{"name": "<сценарий>"}'
  python3 bin/run_tool.py journal_report '{"last": 20}'

Печатает текст результата; картинки (скриншоты) сохраняются самим инструментом в <work_root>/mcp/, путь есть в тексте.
Идёт через call_tool, поэтому попадает в журнал как обычный вызов.
"""
import json, os, sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))))
from vclab.mcp import voxelcore_mcp  # noqa: E402


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return 2
    name = sys.argv[1]
    args = json.loads(sys.argv[2]) if len(sys.argv) > 2 else {}
    if name not in voxelcore_mcp.TOOLS:
        print("нет инструмента", name, "; есть:", ", ".join(sorted(voxelcore_mcp.TOOLS)))
        return 2
    result = voxelcore_mcp.call_tool(name, args)
    for item in result.get("content", []):
        if item.get("type") == "text":
            print(item["text"])
        else:
            print("[%s]" % item.get("type"))
    return 1 if result.get("isError") else 0


if __name__ == "__main__":
    sys.exit(main())
