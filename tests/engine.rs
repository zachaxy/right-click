use rustclick::Engine;
use serde_json::{Value, json};
use std::fs;
use tempfile::TempDir;

fn setup() -> (TempDir, Engine) {
    let temp = TempDir::new().unwrap();
    let engine = Engine::new(temp.path().join("settings"));
    (temp, engine)
}
fn first(v: &Value) -> std::path::PathBuf {
    v["paths"][0].as_str().unwrap().into()
}

#[test]
fn new_files_never_overwrite_and_reject_path_traversal() {
    let (t, mut e) = setup();
    let req = json!({"cmd":"create","dir":t.path(),"name":"笔记.md","format":"md"});
    let a = first(&e.execute(req.clone()).unwrap());
    fs::write(&a, "keep me").unwrap();
    let b = first(&e.execute(req).unwrap());
    assert_ne!(a, b);
    assert_eq!(fs::read_to_string(a).unwrap(), "keep me");
    assert!(
        e.execute(json!({"cmd":"create","dir":t.path(),"name":"../escape","format":"txt"}))
            .is_err()
    );
}

#[test]
fn custom_templates_are_copied_without_changing_original() {
    let (t, mut e) = setup();
    let src = t.path().join("original.pages");
    fs::write(&src, b"user supplied template bytes").unwrap();
    let v = e
        .execute(json!({"cmd":"template_add","path":src,"name":"My Pages"}))
        .unwrap();
    fs::remove_file(src).unwrap();
    let out = e
        .execute(json!({"cmd":"create","dir":t.path(),"name":"report","template":v["id"]}))
        .unwrap();
    assert_eq!(
        fs::read(first(&out)).unwrap(),
        b"user supplied template bytes"
    );
}

#[test]
fn copy_keeps_source_symlinks_and_does_not_overwrite() {
    let (t, mut e) = setup();
    let src = t.path().join("source");
    let dst = t.path().join("dest");
    fs::create_dir_all(&src).unwrap();
    fs::create_dir_all(&dst).unwrap();
    fs::write(src.join("x"), "data").unwrap();
    std::os::unix::fs::symlink("x", src.join("link")).unwrap();
    fs::write(dst.join("source"), "existing").unwrap();
    let out = e
        .execute(json!({"cmd":"copy","paths":[src],"dir":dst}))
        .unwrap();
    assert_eq!(
        fs::read_to_string(first(&out).join("link")).unwrap(),
        "data"
    );
    assert!(first(&out).join("link").is_symlink());
    assert_eq!(fs::read_to_string(dst.join("source")).unwrap(), "existing");
    assert!(src.exists());
}

#[test]
fn copy_rejects_its_own_descendant_and_nested_selection() {
    let (t, mut e) = setup();
    let src = t.path().join("source");
    fs::create_dir_all(src.join("child")).unwrap();
    assert!(
        e.execute(json!({"cmd":"copy","paths":[src],"dir":src.join("child")}))
            .is_err()
    );
    assert!(
        e.execute(json!({"cmd":"move","paths":[src,src.join("child")],"dir":t.path()}))
            .is_err()
    );
}

#[test]
fn cut_survives_restart_and_paste_moves_once() {
    let (t, mut e) = setup();
    let src = t.path().join("a.txt");
    fs::write(&src, "hello").unwrap();
    let dst = t.path().join("dest");
    fs::create_dir(&dst).unwrap();
    e.execute(json!({"cmd":"cut","paths":[src]})).unwrap();
    assert!(src.exists());
    let mut e = Engine::new(e.root.clone());
    e.execute(json!({"cmd":"paste","dir":dst})).unwrap();
    assert!(!src.exists());
    assert_eq!(fs::read_to_string(dst.join("a.txt")).unwrap(), "hello");
    assert!(e.execute(json!({"cmd":"paste","dir":dst})).is_err());
}

#[test]
fn hashes_match_known_values() {
    let (t, mut e) = setup();
    let path = t.path().join("abc");
    fs::write(&path, "abc").unwrap();
    let out = e.execute(json!({"cmd":"info","paths":[path]})).unwrap();
    assert_eq!(out["files"][0]["md5"], "900150983cd24fb0d6963f7d28e17f72");
    assert_eq!(
        out["files"][0]["sha256"],
        "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
    );
    assert_eq!(
        out["files"][0]["sha1"],
        "a9993e364706816aba3e25717850c26c9cd0d89d"
    );
}

#[test]
fn permanent_delete_requires_confirmation_and_rejects_root() {
    let (t, mut e) = setup();
    let path = t.path().join("disposable");
    fs::write(&path, "delete").unwrap();
    assert!(e.execute(json!({"cmd":"delete","paths":[path]})).is_err());
    assert!(path.exists());
    e.execute(json!({"cmd":"delete","paths":[path],"confirmed":true}))
        .unwrap();
    assert!(!path.exists());
    assert!(
        e.execute(json!({"cmd":"delete","paths":["/"],"confirmed":true}))
            .is_err()
    );
}

#[test]
fn archive_round_trip_and_zip_slip_protection() {
    let (t, mut e) = setup();
    let path = t.path().join("文稿.txt");
    fs::write(&path, "hi").unwrap();
    let zip = first(
        &e.execute(json!({"cmd":"compress","paths":[path],"dir":t.path(),"format":"zip"}))
            .unwrap(),
    );
    let out = first(
        &e.execute(json!({"cmd":"extract","paths":[zip],"dir":t.path()}))
            .unwrap(),
    );
    assert_eq!(fs::read_to_string(out.join("文稿.txt")).unwrap(), "hi");
    let bad = t.path().join("bad.zip");
    let mut z = zip::ZipWriter::new(fs::File::create(&bad).unwrap());
    z.start_file("../escaped", zip::write::SimpleFileOptions::default())
        .unwrap();
    std::io::Write::write_all(&mut z, b"bad").unwrap();
    z.finish().unwrap();
    assert!(
        e.execute(json!({"cmd":"extract","paths":[bad],"dir":t.path()}))
            .is_err()
    );
    assert!(!t.path().join("escaped").exists());
}

#[test]
fn images_convert_to_real_webp_and_qr_is_png() {
    let (t, mut e) = setup();
    let p = t.path().join("in.png");
    image::RgbImage::from_pixel(8, 8, image::Rgb([120, 30, 200]))
        .save(&p)
        .unwrap();
    let out = first(
        &e.execute(json!({"cmd":"convert","paths":[p],"dir":t.path(),"format":"webp"}))
            .unwrap(),
    );
    assert_eq!(image::open(out).unwrap().width(), 8);
    let qr = first(
        &e.execute(json!({"cmd":"qr","text":"RustClick 中文","dir":t.path()}))
            .unwrap(),
    );
    assert!(image::open(qr).unwrap().width() >= 256);
}

#[test]
fn office_templates_are_real_packages() {
    let (t, mut e) = setup();
    for (format, member) in [
        ("docx", "word/document.xml"),
        ("xlsx", "xl/workbook.xml"),
        ("pptx", "ppt/presentation.xml"),
    ] {
        let p = first(
            &e.execute(json!({"cmd":"create","dir":t.path(),"name":format,"format":format}))
                .unwrap(),
        );
        let mut z = zip::ZipArchive::new(fs::File::open(p).unwrap()).unwrap();
        assert!(z.by_name("[Content_Types].xml").is_ok());
        assert!(z.by_name(member).is_ok());
    }
}

#[test]
fn preferences_roundtrip_and_no_paid_gate() {
    let (_t, mut e) = setup();
    let mut state = e.execute(json!({"cmd":"state"})).unwrap();
    assert_eq!(state["license"], "free");
    state["config"]["showTray"] = json!(false);
    e.execute(json!({"cmd":"save_config","config":state["config"]}))
        .unwrap();
    let mut restarted = Engine::new(e.root.clone());
    assert_eq!(
        restarted.execute(json!({"cmd":"state"})).unwrap()["config"]["showTray"],
        false
    );
}

#[test]
fn folders_shortcuts_rename_and_scan_are_real_operations() {
    let (t, mut e) = setup();
    let p = t.path().join("résumé.txt");
    fs::write(&p, "content").unwrap();
    let folder = first(
        &e.execute(json!({"cmd":"folder_from_name","paths":[p]}))
            .unwrap(),
    );
    assert!(folder.is_dir());
    let link = first(
        &e.execute(json!({"cmd":"shortcut","paths":[p],"dir":folder}))
            .unwrap(),
    );
    assert_eq!(fs::read_to_string(link).unwrap(), "content");
    let renamed = first(
        &e.execute(json!({"cmd":"rename","paths":[p],"name":"new.txt"}))
            .unwrap(),
    );
    assert!(!p.exists());
    assert!(renamed.exists());
    let scan = e.execute(json!({"cmd":"scan","dir":t.path()})).unwrap();
    assert!(scan["bytes"].as_u64().unwrap() >= 7);
}

#[test]
fn hidden_cut_can_be_cancelled_and_restores_original_flags() {
    use std::os::macos::fs::MetadataExt;
    let (t, mut e) = setup();
    let p = t.path().join("visible");
    fs::write(&p, "data").unwrap();
    let mut s = e.execute(json!({"cmd":"state"})).unwrap();
    s["config"]["hideOnCut"] = json!(true);
    e.execute(json!({"cmd":"save_config","config":s["config"]}))
        .unwrap();
    e.execute(json!({"cmd":"cut","paths":[p]})).unwrap();
    assert_ne!(fs::metadata(&p).unwrap().st_flags() & libc::UF_HIDDEN, 0);
    e.execute(json!({"cmd":"cancel_cut"})).unwrap();
    assert_eq!(fs::metadata(&p).unwrap().st_flags() & libc::UF_HIDDEN, 0);
}

#[test]
fn encrypted_archive_round_trip_and_wrong_password_preserve_archive() {
    let (t, mut e) = setup();
    let p = t.path().join("confidential.txt");
    fs::write(&p, "private text").unwrap();
    let archive=first(&e.execute(json!({"cmd":"archive7z","paths":[p],"dir":t.path(),"format":"7z","password":"testing123"})).unwrap());
    assert!(
        e.execute(
            json!({"cmd":"extract_auto","paths":[archive],"dir":t.path(),"password":"wrong"})
        )
        .is_err()
    );
    let result = first(
        &e.execute(
            json!({"cmd":"extract_auto","paths":[archive],"dir":t.path(),"password":"testing123"}),
        )
        .unwrap(),
    );
    assert_eq!(
        fs::read_to_string(result.join("confidential.txt")).unwrap(),
        "private text"
    );
    assert!(archive.exists());
}
#[test]
fn filename_repair_has_preview_before_change() {
    let (t, mut e) = setup();
    let p = t.path().join("cafÃ©.txt");
    fs::write(&p, "café").unwrap();
    let preview = e
        .execute(json!({"cmd":"repair_preview","paths":[p],"encoding":"latin1"}))
        .unwrap();
    assert_eq!(preview["names"][0]["new"], "café.txt");
    assert!(p.exists());
    let result = e
        .execute(json!({"cmd":"repair_apply","paths":[p],"encoding":"latin1"}))
        .unwrap();
    assert_eq!(fs::read_to_string(first(&result)).unwrap(), "café");
    assert!(!p.exists());
}

#[test]
fn ipad_pro_icon_uses_only_the_valid_two_x_scale() {
    let (t, mut e) = setup();
    let p = t.path().join("icon.png");
    image::RgbImage::new(32, 32).save(&p).unwrap();
    let result = e
        .execute(json!({"cmd":"convert","paths":[p],"dir":t.path(),"format":"ios_icons"}))
        .unwrap();
    let manifest: Value =
        serde_json::from_slice(&fs::read(first(&result).join("Contents.json")).unwrap()).unwrap();
    let entries: Vec<_> = manifest["images"]
        .as_array()
        .unwrap()
        .iter()
        .filter(|x| x["size"] == "83.5x83.5")
        .collect();
    assert_eq!(entries.len(), 1);
    assert_eq!(entries[0]["scale"], "2x");
}

#[test]
fn menu_levels_persist_and_reject_invalid_depths() {
    let (t, mut e) = setup();
    let mut config = e.execute(json!({"cmd":"state"})).unwrap()["config"].clone();
    config["menuLevels"] = json!({"copy_path":1,"create:md":2,"open_app:com.apple.Terminal":3});
    e.execute(json!({"cmd":"save_config","config":config}))
        .unwrap();
    let mut restarted = Engine::new(t.path().join("settings"));
    assert_eq!(
        restarted.execute(json!({"cmd":"state"})).unwrap()["config"]["menuLevels"],
        config["menuLevels"]
    );
    for invalid in [
        json!({"copy_path":0}),
        json!({"copy_path":4}),
        json!({"copy_path":true}),
        json!({"copy_path":1.5}),
        json!([]),
    ] {
        let mut bad = config.clone();
        bad["menuLevels"] = invalid;
        assert!(
            e.execute(json!({"cmd":"save_config","config":bad}))
                .is_err(),
            "invalid menu depth must be rejected"
        );
    }
    assert_eq!(
        e.execute(json!({"cmd":"state"})).unwrap()["config"]["menuLevels"],
        config["menuLevels"]
    );
}

#[test]
fn legacy_configs_can_be_saved_without_menu_levels() {
    let (_t, mut e) = setup();
    let mut config = e.execute(json!({"cmd":"state"})).unwrap()["config"].clone();
    config.as_object_mut().unwrap().remove("menuLevels");
    config.as_object_mut().unwrap().remove("menuGroupLevels");
    e.execute(json!({"cmd":"save_config","config":config}))
        .unwrap();
}

#[test]
fn menu_group_positions_are_independent_and_validated() {
    let (t, mut e) = setup();
    let mut config = e.execute(json!({"cmd":"state"})).unwrap()["config"].clone();
    config["menuLevels"] = json!({"create:md":1});
    config["menuGroupLevels"] = json!({"create":1,"copy":2});
    e.execute(json!({"cmd":"save_config","config":config}))
        .unwrap();
    let mut restarted = Engine::new(t.path().join("settings"));
    assert_eq!(
        restarted.execute(json!({"cmd":"state"})).unwrap()["config"],
        config
    );
    for invalid in [
        json!({"create":0}),
        json!({"create":3}),
        json!({"create":true}),
        json!({"create":1.5}),
        json!([]),
    ] {
        let mut bad = config.clone();
        bad["menuGroupLevels"] = invalid;
        assert!(
            e.execute(json!({"cmd":"save_config","config":bad}))
                .is_err(),
            "invalid group position must be rejected"
        );
    }
    assert_eq!(e.execute(json!({"cmd":"state"})).unwrap()["config"], config);
}
