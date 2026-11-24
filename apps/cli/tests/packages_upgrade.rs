//! `packages upgrade` through the real CLI binary.
//! Every case isolates HOME and XDG_CONFIG_HOME in its own temp dir, so the real global config is never touched.

use raw_viewer_core::profile::sha256_hex;
use serde_json::Value;
use std::collections::BTreeMap;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::{Command, Output};

const KEITHLEY_ID: &str = "usth/keithley-2400";

fn cli_bin() -> PathBuf {
    PathBuf::from(env!("CARGO_BIN_EXE_raw-viewer"))
}

fn temp_home(label: &str) -> PathBuf {
    let home =
        std::env::temp_dir().join(format!("raw_viewer_upgrade_{label}_{}", std::process::id()));
    let _ = fs::remove_dir_all(&home);
    for dir in [".config", "AppData/Roaming", "AppData/Local"] {
        fs::create_dir_all(home.join(dir)).unwrap();
    }
    home
}

fn run(home: &Path, args: &[&str]) -> Output {
    Command::new(cli_bin())
        .args(args)
        .env("HOME", home)
        .env("USERPROFILE", home)
        .env("XDG_CONFIG_HOME", home.join(".config"))
        .env("APPDATA", home.join("AppData/Roaming"))
        .env("LOCALAPPDATA", home.join("AppData/Local"))
        .output()
        .expect("run raw-viewer")
}

fn json(out: &Output) -> Value {
    serde_json::from_slice(&out.stdout).expect("stdout is JSON")
}

fn find_manifest(dir: &Path) -> Option<PathBuf> {
    for entry in fs::read_dir(dir).ok()? {
        let path = entry.ok()?.path();
        if path.is_dir() {
            if let Some(found) = find_manifest(&path) {
                return Some(found);
            }
        } else if path.ends_with("packages/usth-lab/manifest.yaml") {
            return Some(path);
        }
    }
    None
}

/// The global config dir, found from the manifest that `packages install` wrote.
fn global_dir(home: &Path) -> PathBuf {
    let manifest = find_manifest(home).expect("install wrote usth-lab manifest");
    manifest
        .parent()
        .and_then(Path::parent)
        .and_then(Path::parent)
        .expect("global dir above packages/usth-lab")
        .to_path_buf()
}

fn collect(root: &Path, dir: &Path, out: &mut BTreeMap<PathBuf, Vec<u8>>) {
    for entry in fs::read_dir(dir).unwrap() {
        let path = entry.unwrap().path();
        if path.is_dir() {
            collect(root, &path, out);
        } else {
            let rel = path.strip_prefix(root).unwrap().to_path_buf();
            out.insert(rel, fs::read(&path).unwrap());
        }
    }
}

/// Every file under `home` with its bytes, to prove a command changed nothing.
fn snapshot(home: &Path) -> BTreeMap<PathBuf, Vec<u8>> {
    let mut out = BTreeMap::new();
    collect(home, home, &mut out);
    out
}

fn install_usth(home: &Path) {
    let out = run(home, &["--json", "packages", "install", "--usth"]);
    assert!(out.status.success(), "install --usth failed: {out:?}");
}

/// Makes the installed keithley profile one revision behind the bundled copy.
/// The manifest sha is updated too, so the profile counts as unedited, not user-changed.
fn make_keithley_stale(global: &Path) {
    let profile = global.join("profiles/usth/keithley-2400.yaml");
    let old_bytes = fs::read(&profile).expect("installed keithley profile");
    let old_sha = sha256_hex(&old_bytes);
    let new_text = String::from_utf8(old_bytes)
        .unwrap()
        .replacen("revision: 1", "revision: 0", 1);
    let new_sha = sha256_hex(new_text.as_bytes());
    fs::write(&profile, &new_text).unwrap();

    let manifest_path = global.join("packages/usth-lab/manifest.yaml");
    let manifest = fs::read_to_string(&manifest_path).unwrap();
    assert!(
        manifest.contains(&old_sha),
        "manifest records installed sha"
    );
    fs::write(&manifest_path, manifest.replacen(&old_sha, &new_sha, 1)).unwrap();
}

fn keithley_plan_entry(data: &Value) -> Option<&Value> {
    data["plan"]["profiles"]
        .as_array()?
        .iter()
        .find(|p| p["id"] == KEITHLEY_ID)
}

#[test]
fn case1_not_installed_exits_nonzero_with_not_found() {
    let home = temp_home("case1_not_installed");

    let out = run(
        &home,
        &["--json", "packages", "upgrade", "--dry-run", "usth-lab"],
    );

    assert!(
        !out.status.success(),
        "upgrade of a missing package must fail"
    );
    let v = json(&out);
    assert_eq!(v["ok"], false);
    assert_eq!(v["error"]["code"], "not_found");
}

#[test]
fn case2_dry_run_prints_plan_and_changes_nothing_on_disk() {
    let home = temp_home("case2_dry_run");
    install_usth(&home);
    make_keithley_stale(&global_dir(&home));
    let before = snapshot(&home);

    let out = run(
        &home,
        &["--json", "packages", "upgrade", "--dry-run", "usth-lab"],
    );

    assert!(out.status.success(), "dry-run failed: {out:?}");
    let v = json(&out);
    assert_eq!(v["ok"], true);
    assert_eq!(v["data"]["dry_run"], true);
    let entry = keithley_plan_entry(&v["data"]).expect("plan lists keithley");
    assert_eq!(entry["state"], "update_available");
    assert_eq!(entry["installed_revision"], 0);
    assert_eq!(entry["bundled_revision"], 1);
    assert_eq!(v["data"]["would_write"], serde_json::json!([KEITHLEY_ID]));
    assert_eq!(v["data"]["written"], serde_json::json!([]));
    assert_eq!(snapshot(&home), before, "dry-run must not change any file");
}

#[test]
fn case3_upgrade_writes_stale_profile_then_second_run_has_nothing_to_do() {
    let home = temp_home("case3_upgrade");
    install_usth(&home);
    let global = global_dir(&home);
    make_keithley_stale(&global);

    let out = run(&home, &["--json", "packages", "upgrade", "usth-lab"]);

    assert!(out.status.success(), "upgrade failed: {out:?}");
    let v = json(&out);
    assert_eq!(v["data"]["dry_run"], false);
    assert_eq!(v["data"]["written"], serde_json::json!([KEITHLEY_ID]));
    let upgraded = fs::read_to_string(global.join("profiles/usth/keithley-2400.yaml")).unwrap();
    assert!(
        upgraded.contains("revision: 1"),
        "profile moved to bundled revision"
    );
    assert!(!upgraded.contains("revision: 0"), "stale revision is gone");

    let again = run(&home, &["--json", "packages", "upgrade", "usth-lab"]);

    assert!(again.status.success(), "second upgrade failed: {again:?}");
    let v2 = json(&again);
    assert_eq!(v2["data"]["plan"]["profiles"], serde_json::json!([]));
    assert_eq!(v2["data"]["written"], serde_json::json!([]));
}
