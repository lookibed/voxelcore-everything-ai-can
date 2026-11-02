#!/usr/bin/env python3
"""Fetch VoxelCore docs + Lua binding sources of an engine tag into engines/docs/<version>/ (for MCP vc_docs_*).

    python3 bin/fetch_engine_docs.py v0.32.7      (needs `gh` with access to github.com)
"""
import io
import os
import shutil
import subprocess
import sys
import tarfile

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
KEEP = ("doc/", "src/logic/scripting/lua/libs/", "res/scripts/", "res/layouts/", "res/project/", "LICENSE")


def main():
    tag = sys.argv[1] if len(sys.argv) > 1 else "v0.32.7"
    data = subprocess.check_output(["gh", "api", "repos/MihailRis/voxelcore/tarball/" + tag])
    dst = os.path.join(REPO, "engines", "docs", tag.lstrip("v"))
    if os.path.isdir(dst):
        shutil.rmtree(dst)
    n = 0
    with tarfile.open(fileobj=io.BytesIO(data), mode="r:gz") as tar:
        for m in tar.getmembers():
            rel = m.name.split("/", 1)[1] if "/" in m.name else ""
            if not m.isfile() or not rel.startswith(KEEP) or ".." in rel:
                continue
            out = os.path.join(dst, rel)
            os.makedirs(os.path.dirname(out), exist_ok=True)
            with open(out, "wb") as f:
                f.write(tar.extractfile(m).read())
            n += 1
    with open(os.path.join(dst, "ORIGIN.md"), "w", encoding="utf8") as f:
        f.write("# VoxelCore %s docs and Lua API sources\n\nFrom https://github.com/MihailRis/voxelcore tag `%s`, "
                "fetched by bin/fetch_engine_docs.py. Served by MCP voxelcore: vc_docs_search / vc_docs_read / "
                "vc_docs_list. License: LICENSE (GPL-3.0).\n" % (tag, tag))
    print("%d files -> %s" % (n, dst))


if __name__ == "__main__":
    main()
