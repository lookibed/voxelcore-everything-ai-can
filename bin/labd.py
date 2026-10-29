"""Точка входа: Windows-Python: демон labd (его поднимает labctl через WMI). Модуль — vclab.daemon.labd."""
import os
import runpy
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
runpy.run_module("vclab.daemon.labd", run_name="__main__", alter_sys=True)
