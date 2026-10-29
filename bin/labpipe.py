"""Точка входа: Windows-Python: постоянный канал WSL -> демон (MCP voxelcore). Модуль — vclab.cli.labpipe."""
import os
import runpy
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
runpy.run_module("vclab.cli.labpipe", run_name="__main__", alter_sys=True)
