"""Точка входа: WSL-Python: MCP-сервер voxelcore (vc_*, journal_*, инструменты проектов). Модуль — vclab.mcp.voxelcore_mcp."""
import os
import runpy
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
runpy.run_module("vclab.mcp.voxelcore_mcp", run_name="__main__", alter_sys=True)
