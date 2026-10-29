"""Точка входа: WSL-Python: вызов инструмента MCP voxelcore из консоли. Модуль — vclab.mcp.run_tool."""
import os
import runpy
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
runpy.run_module("vclab.mcp.run_tool", run_name="__main__", alter_sys=True)
