"""Волна 7: репозиторий самодостаточен — ни symlink'ов, ни путей к другим установкам (старый рабочий каталог движка,
каталоги AlphaMine/Olife машины-источника, домашний каталог WSL) в коде, дескрипторах проектов и паках. Документы (docs/,
catalog/) и снимок журналов агентов (projects/_snapshot_agents_docs) — история, их не проверяем. Шаблоны собраны из
частей, чтобы этот файл не находил сам себя; то же проверяет `git grep` из отчёта волны 7."""
import os
import re

from conftest import LAB

_PARTS = ["D:" + "\\\\" + "Prog", "D:" + "\\" + "Prog", "/mnt/" + "d/", "/ro" + "ot/", "vc_" + "root",
          "voxelcore-0.31.0_" + "pre_gemini"]
RX = re.compile("|".join(re.escape(x) for x in _PARTS))
SKIP_DIRS = {".git", "docs", "catalog", "_snapshot_agents_docs", "__pycache__", ".pytest_cache", "work", "builds",
             "engines", "node_modules", "target", "golden", "ref", "worlds", "dist"}
TEXT = (".py", ".toml", ".lua", ".json", ".md", ".sh", ".ps1", ".bat", ".js", ".yaml", ".rs", ".txt", ".glsl")


def _files():
    for top, dirs, files in os.walk(LAB):
        dirs[:] = [d for d in dirs if d not in SKIP_DIRS]
        for f in files:
            p = os.path.join(top, f)
            if f.endswith(TEXT) and f not in ("machine.toml",) and \
                    not f.endswith("_PROGRESS.md") and os.path.getsize(p) < (2 << 20):
                yield p


def test_no_outside_paths():
    bad = []
    for p in _files():
        try:
            with open(p, encoding="utf-8", errors="replace") as f:
                for n, line in enumerate(f, 1):
                    if RX.search(line):
                        bad.append("%s:%d: %s" % (os.path.relpath(p, LAB), n, line.strip()[:120]))
        except OSError:
            pass
    assert not bad, "paths outside the repository:\n" + "\n".join(bad[:40])


def test_no_symlinks():
    links = []
    for top, dirs, files in os.walk(LAB):
        dirs[:] = [d for d in dirs if d not in (".git", "__pycache__", "work")]
        for n in dirs + files:
            p = os.path.join(top, n)
            if os.path.islink(p) or (hasattr(os.path, "isjunction") and os.path.isjunction(p)):
                links.append(os.path.relpath(p, LAB))
    assert not links, "symlinks/junctions in the repository: %s" % links
