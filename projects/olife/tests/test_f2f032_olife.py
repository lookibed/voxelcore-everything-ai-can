"""Вынесено из tests/test_f2f032_engine.py (ядро) в волне 1 (фикстура lab — как там)."""
def test_olife_client_smoke(lab):
    r = lab.create_lease("olife", "client_smoke", "agent_T", start=True)
    name = r["lease"]["name"]
    try:
        iso = r["start"]["isolation"]
        assert iso["verified"] and iso["hello_version"] == "0.32-f2f" and iso["flags"]["clock"] == "realtime"
        argv = r["start"]["argv"]
        assert argv.index("--f2f-clock") < argv.index("--")
        h = lab.f2f(name, "hello", {}, owner="agent_T")["result"]
        assert h["screen"] == "level" and h["version"] == "0.32-f2f"
        shot = lab.f2f(name, "shot", {"name": "client_smoke"}, owner="agent_T")["result"]
        assert (shot["w"], shot["h"]) == (854, 480) and os.path.isfile(shot["path"])
    finally:
        rel = lab.release(name, owner="agent_T")
    assert rel["exit"] == "exit 0" and not rel["forced_kill"], rel


