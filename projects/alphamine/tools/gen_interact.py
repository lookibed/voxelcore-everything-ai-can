#!/usr/bin/env python3
"""AlphaMine phase 4 (agent P): tables for world interaction and the inventory screen.

  python3 tools/alphamine/gen_interact.py            -> content/alphamine/modules/interact_table.lua
                                                        content/alphamine/sounds/am/... + preload.json "sounds"

Sources:
  * <repo>\\projects\\alphamine\\external\\tables\\blocks.json / items.json (tools/alphamine/gen_tables.py: values by executing the
    Java registrations): hardness, block bounds (doubles as Java keeps them), material, step sounds, render type,
    tool efficiency (`str_vs_block`), harvest lists (`can_harvest`), max damage/stack, food heal, armour type;
  * the crafting recipes: CraftingManager.getInstance().recipes is dumped by RUNNING the reference client classes
    (ref\\minecraft\\bin + deobfuscated.jar, JDK 8): the list after Collections.sort(RecipeSorter), with
    width/height/ingredientMap/result exactly as findMatchingRecipe walks them;
  * sounds: assets\\sound\\newsound\\{step,random}\\*.ogg -> sounds/am/<dir>/<name>_<n>.ogg (VoxelCore variants
    `name_0..N`, the engine picks one at random like SoundPool.getRandomSoundFromSoundPool).
"""
import json
import os
import re
import shutil
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", ".."))  # корень репозитория (было: рабочий каталог движка)
PACK = os.path.join(REPO, "packs", "alphamine")
ALPHA = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "external"))  # было внешний каталог AlphaMine
TABLES = os.path.join(ALPHA, "tables")
REF = os.path.join(ALPHA, "ref")
WORK = os.path.join(ALPHA, "run", "gen_interact")
JDK = "C:\\Program Files\\Java\\jdk1.8.0_481\\bin"
PS = "/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe"


def win(p):
    return "%s:\\%s" % (p[5].upper(), p[7:].replace("/", "\\")) if re.match(r"^/mnt/[a-z]/", p) else p


JAVA = r"""
import java.lang.reflect.Field;
import java.util.List;
import net.minecraft.src.*;

public class RecipeDump {
    static Object get(Object o, String name) throws Exception {
        Field f = o.getClass().getDeclaredField(name);
        f.setAccessible(true);
        return f.get(o);
    }
    public static void main(String[] a) throws Exception {
        CraftingManager cm = CraftingManager.getInstance();
        List recipes = (List) get(cm, "recipes");
        StringBuilder sb = new StringBuilder("[");
        for (int i = 0; i < recipes.size(); ++i) {
            Object r = recipes.get(i);
            int w = ((Integer) get(r, "width")).intValue();
            int h = ((Integer) get(r, "height")).intValue();
            int[] map = (int[]) get(r, "ingredientMap");
            ItemStack res = (ItemStack) get(r, "resultStack");
            if (i > 0) sb.append(",");
            sb.append("{\"w\":").append(w).append(",\"h\":").append(h).append(",\"map\":[");
            for (int k = 0; k < map.length; ++k) { if (k > 0) sb.append(","); sb.append(map[k]); }
            sb.append("],\"id\":").append(res.itemID).append(",\"count\":").append(res.stackSize).append("}");
        }
        sb.append("]");
        System.out.println("RECIPES " + sb);
    }
}
"""


def dump_recipes():
    os.makedirs(WORK, exist_ok=True)
    with open(os.path.join(WORK, "RecipeDump.java"), "w") as f:
        f.write(JAVA)
    lib = []
    for root, _, files in os.walk(os.path.join(REF, "libraries")):
        lib += [win(os.path.join(root, n)) for n in files if n.endswith(".jar")]
    cp = ";".join(lib + [win(os.path.join(REF, "minecraft", "bin")), win(os.path.join(REF, "minecraft", "jars", "deobfuscated.jar"))])
    w = win(WORK)
    cmd = ("& '{jdk}\\javac.exe' -nowarn -encoding UTF-8 -source 1.8 -target 1.8 -cp '{cp}' -d '{w}' '{w}\\RecipeDump.java' 2>&1 | "
           "Where-Object {{ $_ -notmatch 'bootstrap' }}; "
           "& '{jdk}\\java.exe' -cp '{w};{cp}' RecipeDump 2>&1").format(jdk=JDK, cp=cp, w=w)
    out = subprocess.run([PS, "-NoProfile", "-NonInteractive", "-Command", cmd], capture_output=True, text=True,
                         cwd="/mnt/c")
    txt = out.stdout + out.stderr
    m = re.search(r"^RECIPES (\[.*\])\s*$", txt, re.M)
    if not m:
        raise SystemExit("recipe dump failed:\n" + txt[-3000:])
    return json.loads(m.group(1))


def lua(v, ind=""):
    if isinstance(v, bool):
        return "true" if v else "false"
    if v is None:
        return "nil"
    if isinstance(v, (int,)):
        return str(v)
    if isinstance(v, float):
        return repr(v) if v == v else "0/0"
    if isinstance(v, str):
        return json.dumps(v)
    if isinstance(v, list):
        return "{" + ", ".join(lua(x) for x in v) + "}"
    if isinstance(v, dict):
        parts = []
        for k, x in v.items():
            key = ("[%d]" % k) if isinstance(k, int) else (k if re.match(r"^[A-Za-z_]\w*$", k) else "[%s]" % json.dumps(k))
            parts.append("%s = %s" % (key, lua(x)))
        return "{" + ", ".join(parts) + "}"
    raise TypeError(v)


SOUND_DIRS = {"step": "step", "random": "random"}


def copy_sounds():
    """step.* and random.* of newsound -> sounds/am/<dir>/<name>[_n].ogg; returns preload names"""
    src_root = os.path.join(ALPHA, "assets", "sound", "newsound")
    dst_root = os.path.join(PACK, "sounds", "am")
    names = {}
    for d in SOUND_DIRS:
        for fn in sorted(os.listdir(os.path.join(src_root, d))):
            if not fn.endswith(".ogg"):
                continue
            base = fn[:-4]
            m = re.match(r"^(.*?)(\d*)$", base)   # SoundPool: trailing digits are variants of one name
            name = m.group(1).replace(" ", "_")
            names.setdefault("%s/%s" % (d, name), []).append(fn)
    out = []
    for name, files in sorted(names.items()):
        os.makedirs(os.path.join(dst_root, os.path.dirname(name)), exist_ok=True)
        for i, fn in enumerate(sorted(files)):
            d = os.path.dirname(name)
            dst = os.path.join(dst_root, name + ("_%d.ogg" % i if len(files) > 1 else ".ogg"))
            shutil.copyfile(os.path.join(src_root, d, fn), dst)
        out.append("am/" + name)
    return out


def main():
    blocks = json.load(open(os.path.join(TABLES, "blocks.json")))
    items = json.load(open(os.path.join(TABLES, "items.json")))
    B = {}
    for b in blocks:
        ss = b.get("step_sound") or {}
        B[b["id"]] = {
            "name": b["name"], "cls": b["class"], "hardness": b["hardness"], "bounds": b["bounds"],
            "material": b["material"], "render_type": b["render_type"], "normal": b["render_as_normal_block"],
            "opaque": b["opaque_cube_lookup"], "light_opacity": b["light_opacity"], "light_value": b["light_value"],
            "step": {"name": ss.get("step", "step.stone"), "brk": ss.get("break", "step.stone"),
                     "volume": ss.get("volume", 1.0), "pitch": ss.get("pitch", 1.0)},
        }
    I = {}
    for it in items:
        cf = it.get("class_fields") or {}
        e = {"name": it["name"], "cls": it["class"], "max_stack": it["max_stack"], "max_damage": it["max_damage"]}
        if it.get("str_vs_block"):
            e["str"] = {int(k): v for k, v in it["str_vs_block"].items()}
        if it.get("can_harvest"):
            e["harvest"] = {int(k): True for k in it["can_harvest"]}
        if "healAmount" in cf:
            e["heal"] = cf["healAmount"]
        if it["class"] == "ItemArmor":
            e["armor_type"] = cf.get("armorType")
        if it["class"] in ("ItemSeeds", "ItemReed"):
            e["places"] = cf.get("blockType") or cf.get("spawnID")
        I[it["id"]] = e
    recipes = dump_recipes()
    sounds = copy_sounds()
    lines = ["-- GENERATED by tools/alphamine/gen_interact.py -- do not edit.",
             "-- blocks: alpha id -> hardness, bounds (Block.minX..maxZ as Java doubles), material, step sound, render type;",
             "-- items: id -> class, max stack/damage, tool efficiency (str[block]), harvest[block], heal, armour type;",
             "-- recipes: CraftingManager.recipes in the order findMatchingRecipe walks them (dumped by running the",
             "--   reference client classes): w, h, map (ingredientMap, -1 = empty), result id and count.",
             "return {", "blocks = {"]
    for k in sorted(B):
        lines.append("    [%d] = %s," % (k, lua(B[k])))
    lines.append("},")
    lines.append("items = {")
    for k in sorted(I):
        lines.append("    [%d] = %s," % (k, lua(I[k])))
    lines.append("},")
    lines.append("recipes = {")
    for r in recipes:
        lines.append("    %s," % lua(r))
    lines.append("},")
    lines.append("}")
    with open(os.path.join(PACK, "modules", "interact_table.lua"), "w", encoding="utf-8") as f:
        f.write("\n".join(lines) + "\n")
    # preload.json (shared with gen_models.py / gen_ui_assets.py): only our "sounds" entries are refreshed
    pre_path = os.path.join(PACK, "preload.json")
    with open(pre_path, encoding="utf-8") as f:
        pre = json.load(f)
    pre["sounds"] = [s for s in pre.get("sounds", []) if not s.startswith("am/")] + sounds
    with open(pre_path, "w", encoding="utf-8") as f:
        json.dump(pre, f, indent=4, ensure_ascii=False)
        f.write("\n")
    print("gen_interact: %d blocks, %d items, %d recipes, %d sounds" % (len(B), len(I), len(recipes), len(sounds)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
