"""Точка входа: Windows-Python: MCP-мост lab (stdio). Модуль — vclab.mcp.mcp_bridge."""
import os
import runpy
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
runpy.run_module("vclab.mcp.mcp_bridge", run_name="__main__", alter_sys=True)
