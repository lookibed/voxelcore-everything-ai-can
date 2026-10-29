#!/usr/bin/env python3
"""Проверка XML-оверлея вокруг компьютера pc_wasmrt:pc (pc_ux2, 07.10): кнопки «встать / залочить мышь /
приблизить» и стикеры-подсказки в HUD движка (layouts/pc_overlay.xml), стикер «ПКМ — сесть за компьютер»
(layouts/pc_hint.xml), скрытие хотбара и прицела в ПК (режим оверлея движка), маршрутизация мыши между фреймом
экрана и core:main, Right Ctrl как лок мыши, Doom на ПК (fps). Лаборатория: аренда `wasmrt world` 1408x902,
ввод — только F2F `input` (окно), снимки — F2F `shot` (кадровый буфер). Помощники — из pc_ux_check.py.

  python3 tools/scenarios/pc_overlay_check.py v031|v032 [--lease NAME] [--keep] [--skip-doom]

Итог — таблица шагов и путь прогона; код выхода — число провалов.
"""
import json, os, subprocess, sys, time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import pc_ux_check as U  # noqa: E402

U.OWNER = os.environ.get("LAB_OWNER", "pc_ux2")
VC, W, H = U.VC, U.W, U.H


def wsl(path):
    if not path or not path.startswith(("C:", "D:", "c:", "d:")):
        return path
    return subprocess.run(["wslpath", "-u", path], capture_output=True, text=True).stdout.strip()


def region_mean(png, box):
    """Средний цвет области кадра (PIL) — для сравнения полосы хотбара между кадрами."""
    try:
        from PIL import Image
        im = Image.open(wsl(png)).convert("RGB").crop(box)
        px = list(im.getdata())
        n = max(1, len(px))
        return tuple(round(sum(p[i] for p in px) / n, 1) for i in range(3))
    except Exception as e:  # noqa: BLE001
        return ("err", str(e)[:60])


def hover_button(lease, st, name, pause=0.12):
    r = st["overlay"]["rects"][name]
    x, y = r["x"] + r["w"] / 2, r["y"] + r["h"] / 2
    U.mouse(lease, x, y, False)
    time.sleep(pause)
    return x, y


def click_button(lease, st, name, pause=0.08):
    """Клик по XML-кнопке оверлея: подвести мышь (tick переводит активный фрейм на core:main), нажать, отпустить."""
    x, y = hover_button(lease, st, name)
    U.mouse(lease, x, y, True)
    time.sleep(pause)
    U.mouse(lease, x, y, False)
    time.sleep(0.35)
    return U.pc(lease, "state")


def main():
    engine = sys.argv[1] if len(sys.argv) > 1 else "v031"
    keep = "--keep" in sys.argv
    skip_doom = "--skip-doom" in sys.argv
    lease = sys.argv[sys.argv.index("--lease") + 1] if "--lease" in sys.argv else None
    U.PIPE = U.Pipe()
    check, pc, shot, mouse, f2f = U.check, U.pc, U.shot, U.mouse, U.f2f
    if lease:
        r = U.lab("start", lease, "--restart", timeout=300)
        if not r.get("ok", False):
            print("restart failed:", json.dumps(r, ensure_ascii=False)[:1500])
            return 1
    else:
        r = U.lab("lease", "wasmrt", "world", "--param", "engine=" + engine, "--param", "size=1408x902", "--start", timeout=300)
        if not r.get("ok", False) or not r.get("lease"):
            print("lease failed:", json.dumps(r, ensure_ascii=False)[:2000])
            return 1
        lease = r["lease"]["name"] if isinstance(r["lease"], dict) else r["lease"]
    print("lease", lease, "engine", engine)
    try:
        st = pc(lease, "state")
        vw, vh = (st.get("overlay") or {}).get("viewport") or [1408, 902]
        hot = (int(vw / 2 - 180), int(vh - 95), int(vw / 2 + 180), int(vh - 35))  # полоса хотбара движка
        # 1. в ПК (сценарий сажает сразу): оверлей открыт, режим оверлея движка (хотбар и прицел спрятаны)
        s1 = shot(lease, "01_in_pc_no_hud")
        check("in pc: overlay open", st["active"] and st.get("overlay_open") is True and st.get("inventory_open") is True
              and st.get("overlay") and st["overlay"].get("rects", {}).get("lock"),
              "overlay_open=%s inventory_open=%s rects=%s" % (st.get("overlay_open"), st.get("inventory_open"),
                                                               sorted((st.get("overlay") or {}).get("rects", {}).keys())), s1)
        t = (st.get("overlay") or {}).get("texts") or {}
        check("texts: free mouse, camera here", t.get("cam", "").startswith("камера: на месте") and t.get("mouse") == "мышь: свободная"
              and t.get("lock_btn") == "залочить мышь" and t.get("zoom_btn") == "приблизить", json.dumps(t, ensure_ascii=False)[:160])
        # 2. встать (F2F leave): оверлей закрыт, хотбар на месте; стикер «ПКМ — сесть» при взгляде на ПК
        pc(lease, "leave")
        time.sleep(0.5)
        st = pc(lease, "state")
        s2 = shot(lease, "02_outside_hud")
        m1, m2 = region_mean(s1, hot), region_mean(s2, hot)
        check("outside: overlay closed, hud back", not st["active"] and st.get("overlay_open") is False and st.get("inventory_open") is False,
              "overlay_open=%s inventory_open=%s hotbar band mean in-pc=%s outside=%s" % (st.get("overlay_open"), st.get("inventory_open"), m1, m2), s2)
        check("rmb hint sticker", st.get("hint_wanted") is True and st.get("hint_visible") is True,
              "hint_wanted=%s hint_visible=%s" % (st.get("hint_wanted"), st.get("hint_visible")), shot(lease, "03_hint_rmb"))
        # 3. снова в ПК; маршрутизация мыши: над экраном — фрейм экрана, над кнопкой — core:main
        pc(lease, "enter")
        time.sleep(0.5)
        st = pc(lease, "state")
        check("re-enter: overlay, hud hidden, hint off", st["active"] and st.get("overlay_open") is True and st.get("inventory_open") is True
              and st.get("hint_visible") is False, "hint_visible=%s" % st.get("hint_visible"), shot(lease, "04_in_pc_again"))
        x, y = U.win_point(lease, W / 2, H / 2)
        mouse(lease, x, y, False)
        time.sleep(0.15)
        st = pc(lease, "state")
        frame_pc = st.get("frame")
        hover_button(lease, st, "lock")
        st = pc(lease, "state")
        check("mouse routing", frame_pc == "pc" and st.get("frame") == "main", "over screen=%s over button=%s" % (frame_pc, st.get("frame")))
        # 4. кнопка «залочить мышь»: камера к экрану, курсор заперт; тексты; курсор прижат при мыши мимо экрана
        st = click_button(lease, st, "lock")
        t = (st.get("overlay") or {}).get("texts") or {}
        check("lock button", st["locked"] and st["mouse_lock"] and st["zoom"] >= 0.99 and st["camera"] != 0
              and t.get("lock_btn") == "отпустить мышь" and t.get("mouse") == "мышь: заперта в экране" and t.get("cam", "").startswith("камера: у экрана"),
              "zoom=%s camera=%s mouse_lock=%s texts=%s" % (st["zoom"], st["camera"], st["mouse_lock"], json.dumps(t, ensure_ascii=False)[:120]),
              shot(lease, "05_locked"))
        mouse(lease, 5, 5)
        time.sleep(0.2)
        st = pc(lease, "state")
        cur = st.get("cursor")
        check("locked: cursor clamped, frame pc", bool(cur) and 0 <= cur[0] <= W and 0 <= cur[1] <= H and st.get("frame") == "pc",
              "cursor=%s frame=%s" % (cur, st.get("frame")))
        # кнопка досягаема и при локе: отпустить
        st = click_button(lease, st, "lock")
        t = (st.get("overlay") or {}).get("texts") or {}
        check("unlock button", not st["locked"] and not st["mouse_lock"] and st["zoom"] == 0 and st["camera"] == 0 and t.get("lock_btn") == "залочить мышь",
              "zoom=%s camera=%s texts=%s" % (st["zoom"], st["camera"], json.dumps(t, ensure_ascii=False)[:100]), shot(lease, "06_unlocked"))
        # 5. кнопка «приблизить/отдалить»: зум 0 <-> 1 без лока мыши
        st = click_button(lease, st, "zoom")
        t = (st.get("overlay") or {}).get("texts") or {}
        check("zoom in button", st["zoom"] >= 0.99 and st["camera"] != 0 and not st["mouse_lock"] and t.get("zoom_btn") == "отдалить"
              and t.get("cam", "").startswith("камера: у экрана"), "zoom=%s camera=%s mouse_lock=%s zoom_btn=%s" % (st["zoom"], st["camera"], st["mouse_lock"], t.get("zoom_btn")),
              shot(lease, "07_zoom_in"))
        st = click_button(lease, st, "zoom")
        t = (st.get("overlay") or {}).get("texts") or {}
        check("zoom out button", st["zoom"] == 0 and st["camera"] == 0 and t.get("zoom_btn") == "приблизить",
              "zoom=%s camera=%s zoom_btn=%s" % (st["zoom"], st["camera"], t.get("zoom_btn")), shot(lease, "08_zoom_out"))
        # 6. Right Ctrl — лок мыши (как host key dagger_pc)
        f2f(lease, "input", {"keys": {"RCONTROL": True}})
        time.sleep(0.15)
        f2f(lease, "input", {"keys": {"RCONTROL": False}})
        time.sleep(0.3)
        st = pc(lease, "state")
        on = st["locked"] and st["mouse_lock"]
        f2f(lease, "input", {"keys": {"RCONTROL": True}})
        time.sleep(0.15)
        f2f(lease, "input", {"keys": {"RCONTROL": False}})
        time.sleep(0.3)
        st = pc(lease, "state")
        check("right ctrl toggles lock", on and not st["locked"] and not st["mouse_lock"], "after 1st=%s after 2nd locked=%s" % (on, st["locked"]),
              shot(lease, "09_rctrl"))
        # 7. кнопка «встать»: оверлей закрыт, хотбар и прицел вернулись
        st = click_button(lease, st, "standup")
        s10 = shot(lease, "10_standup_hud")
        check("standup button", not st["active"] and st.get("overlay_open") is False and st.get("inventory_open") is False and st["camera"] == 0,
              "active=%s overlay_open=%s inventory_open=%s hotbar band mean=%s" % (st["active"], st.get("overlay_open"), st.get("inventory_open"), region_mean(s10, hot)), s10)
        # 8. Doom на ПК (fps из лога wasmrt)
        if not skip_doom:
            pc(lease, "enter")
            time.sleep(0.3)
            pc(lease, "lock", on=True)
            time.sleep(0.3)
            pc(lease, "launch", id="doom")
            time.sleep(20)
            fps = [l for l in U.log_grep(lease, r"doom:wasm.json.*fps") if "fps" in l]
            check("doom on pc", len(fps) >= 1, (fps[-1][-80:] if fps else "no fps lines"), shot(lease, "11_doom"))
            pc(lease, "close")
            pc(lease, "leave")
        errs = U.log_grep(lease, r"\[pc\] overlay|error|Error|exception", tail=600)
        print("log (overlay/errors):", *[l[-140:] for l in errs[-12:]], sep="\n  ")
        sysload = U.lab("sysload")
        print("sysload busy=%s reasons=%s" % (sysload.get("busy"), sysload.get("reasons")))
    finally:
        runs = U.lab("ps")
        run = ""
        for l in (runs.get("leases") or []) if isinstance(runs, dict) else []:
            if l.get("name") == lease:
                run = l.get("run", "")
        if not keep:
            U.lab("release", lease)
        U.PIPE.close()
    print("\n| шаг | результат | детали | кадр |\n|---|---|---|---|")
    for name, res, detail, sp in U.ROWS:
        print("| %s | %s | %s | %s |" % (name, res, detail.replace("|", "/"), os.path.basename(sp) if sp else ""))
    print("run:", run, "\nfailed:", len(U.FAILS), U.FAILS)
    return len(U.FAILS)


if __name__ == "__main__":
    sys.exit(main())
