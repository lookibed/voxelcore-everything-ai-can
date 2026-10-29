//! Pack manifest state (wave 4b): client/both files only, load/change by content SHA-256, broken file keeps the state,
//! the PacksChanged message fields.
use olife_gateway::packs::{Check, Packs};

#[test]
fn manifest_load_change_and_message() {
    let dir = std::env::temp_dir().join(format!("olife_packs_test_{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let p = dir.join("manifest.json");
    let m1 = r#"{"version": "v1", "root": "/x", "packs": {"base": {"side": "both", "files": [
        {"path": "a.lua", "sha256": "AB", "size": 3, "side": "client"}, {"path": "s.lua", "sha256": "cd", "size": 1, "side": "server"},
        {"path": "t/b.png", "sha256": "ef", "size": 9, "side": "both"}]}}}"#;
    std::fs::write(&p, m1).unwrap();
    let mut k = Packs::new(Some(p.to_str().unwrap().into()), "http://127.0.0.1:9".into());
    assert!(k.message().is_none());
    assert_eq!(k.check(), Ok(Check::Loaded));
    assert_eq!(k.check(), Ok(Check::Unchanged));
    let m = k.message().unwrap();
    assert_eq!((m.version.as_str(), m.url.as_str(), m.files), ("v1", "http://127.0.0.1:9", 2));
    assert_eq!(k.files["base/a.lua"].sha256, "ab");
    assert!(k.files.contains_key("base/t/b.png") && !k.files.contains_key("base/s.lua"));
    std::fs::write(&p, "{broken").unwrap();
    assert!(k.check().is_err());
    assert_eq!(k.check(), Ok(Check::Unchanged)); // the same broken content is reported once
    assert_eq!(k.message().unwrap().version, "v1");
    std::fs::write(&p, m1.replace("\"v1\"", "7")).unwrap();
    assert_eq!(k.check(), Ok(Check::Changed));
    assert_eq!((k.version, k.message().unwrap().version.as_str()), (2, "7"));
    let _ = std::fs::remove_dir_all(&dir);
}
