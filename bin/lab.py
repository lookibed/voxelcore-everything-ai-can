"""Точка входа: Windows-Python: CLI лаборатории (обёртка bin/lab из WSL). Модуль — vclab.cli.lab."""
import os
import runpy
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
runpy.run_module("vclab.cli.lab", run_name="__main__", alter_sys=True)
