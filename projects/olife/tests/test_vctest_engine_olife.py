"""Вынесено из tests/test_vctest_engine.py (ядро) в волне 1: сессия olife на настоящем 0.32 (фикстура lab — как там)."""
def test_olife_world_stdin_and_session(lab):
    r = lab.create_lease("olife", "world", "agent_T", start=True)
    name = r["lease"]["name"]
    assert r["start"]["isolation"]["verified"] and r["lease"]["engine_version"] == "0.32"
    out = lab.stdin(name, "status", owner="agent_T", wait=5, pattern=r"status tick=\d+ .*headless=true")
    assert out["matched"] and out["poke"]["ok"], out
    rel = lab.release(name, owner="agent_T")
    assert rel["exit"] == "exit 0" and not rel["forced_kill"], rel                        # olife.stop через stdin
    s = lab.call("olife.session", {"clients": 1, "client_kind": "bot", "sandbox": False}, owner="agent_T")["result"]
    time.sleep(3.0)
    c = lab.call("olife.consistency", {"session": s["session"]}, owner="agent_T")["result"]
    assert c["divergence_count"] == 0 and c["compared"] >= 20, c
    rel = lab.call("olife.release", {"session": s["session"]}, owner="agent_T")["result"]["released"]
    assert all(v["exit"] == "exit 0" for v in rel.values()), rel
    assert lab.leases == {}
    print("olife session: compared %d ticks, latency %s, gateway %s" % (c["compared"], c["latency_ms"],
                                                                        c["gateway"]["total"]))
