use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;

fn cli_bin() -> PathBuf {
    let mut p = std::env::current_exe().expect("current test exe path");
    p.pop();
    if p.file_name().map(|n| n == "deps").unwrap_or(false) {
        p.pop();
    }
    p.push(if cfg!(windows) {
        "raw-viewer.exe"
    } else {
        "raw-viewer"
    });
    p
}

fn temp_dir(name: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!("raw_viewer_test_{}_{}", name, std::process::id()));
    let _ = fs::remove_dir_all(&dir);
    fs::create_dir_all(&dir).unwrap();
    dir
}

fn isolate_cmd(cmd: &mut Command, fake_home: &Path) {
    let appdata = fake_home.join("AppData").join("Roaming");
    let localappdata = fake_home.join("AppData").join("Local");
    let config = fake_home.join(".config");
    let _ = fs::create_dir_all(&appdata);
    let _ = fs::create_dir_all(&localappdata);
    let _ = fs::create_dir_all(&config);
    cmd.env("HOME", fake_home)
        .env("USERPROFILE", fake_home)
        .env("XDG_CONFIG_HOME", &config)
        .env("APPDATA", &appdata)
        .env("LOCALAPPDATA", &localappdata);
}

#[test]
fn test_packages_lifecycle_and_global_discovery() {
    let bin = cli_bin();
    let temp_root = temp_dir("packages_test");
    let fake_home = temp_root.join("home");
    fs::create_dir_all(&fake_home).unwrap();

    // 1. Initial packages list shows usth-lab as not installed
    let mut cmd1 = Command::new(&bin);
    isolate_cmd(&mut cmd1, &fake_home);
    let list_output = cmd1
        .args(["--json", "packages", "list"])
        .output()
        .expect("packages list");
    assert!(list_output.status.success());
    let list_parsed: serde_json::Value =
        serde_json::from_str(&String::from_utf8_lossy(&list_output.stdout)).unwrap();
    assert_eq!(list_parsed["ok"], true);
    let usth_pkg = list_parsed["data"]["packages"]
        .as_array()
        .unwrap()
        .iter()
        .find(|p| p["id"] == "usth-lab")
        .expect("usth-lab should be listed");
    assert_eq!(usth_pkg["is_installed"], false);

    // 2. Install usth-lab
    let mut cmd2 = Command::new(&bin);
    isolate_cmd(&mut cmd2, &fake_home);
    let install_output = cmd2
        .args(["--json", "packages", "install", "--usth"])
        .output()
        .expect("packages install --usth");
    assert!(install_output.status.success());
    let install_parsed: serde_json::Value =
        serde_json::from_str(&String::from_utf8_lossy(&install_output.stdout)).unwrap();
    assert_eq!(install_parsed["ok"], true);
    assert_eq!(install_parsed["data"]["package_id"], "usth-lab");
    assert_eq!(install_parsed["data"]["status"], "installed");

    // 3. Re-list packages confirms installed
    let mut cmd3 = Command::new(&bin);
    isolate_cmd(&mut cmd3, &fake_home);
    let list2_output = cmd3
        .args(["--json", "packages", "list"])
        .output()
        .expect("packages list after install");
    assert!(list2_output.status.success());
    let list2_parsed: serde_json::Value =
        serde_json::from_str(&String::from_utf8_lossy(&list2_output.stdout)).unwrap();
    let usth_pkg2 = list2_parsed["data"]["packages"]
        .as_array()
        .unwrap()
        .iter()
        .find(|p| p["id"] == "usth-lab")
        .expect("usth-lab present");
    assert_eq!(usth_pkg2["is_installed"], true);

    // 4. Repeat install without --replace fails
    let mut cmd4 = Command::new(&bin);
    isolate_cmd(&mut cmd4, &fake_home);
    let install_repeat = cmd4
        .args(["--json", "packages", "install", "--usth"])
        .output()
        .expect("packages install repeat");
    assert!(!install_repeat.status.success());

    // 5. Repeat install with --replace succeeds
    let mut cmd5 = Command::new(&bin);
    isolate_cmd(&mut cmd5, &fake_home);
    let install_replace = cmd5
        .args(["--json", "packages", "install", "--usth", "--replace"])
        .output()
        .expect("packages install replace");
    assert!(install_replace.status.success());

    // 6. Remove usth-lab
    let mut cmd6 = Command::new(&bin);
    isolate_cmd(&mut cmd6, &fake_home);
    let remove_output = cmd6
        .args(["--json", "packages", "remove", "usth-lab"])
        .output()
        .expect("packages remove usth-lab");
    assert!(remove_output.status.success());
    let remove_parsed: serde_json::Value =
        serde_json::from_str(&String::from_utf8_lossy(&remove_output.stdout)).unwrap();
    assert_eq!(remove_parsed["ok"], true);
    assert_eq!(remove_parsed["data"]["status"], "removed");
}

#[test]
fn test_profiles_create_and_export() {
    let bin = cli_bin();
    let temp_root = temp_dir("profiles_create_export");
    let fake_home = temp_root.join("home");
    fs::create_dir_all(&fake_home).unwrap();

    let work_dir = temp_root.join("work");
    fs::create_dir_all(&work_dir).unwrap();

    // 1. Create a profile boilerplate
    let out_profile = work_dir.join("test_sensor.yaml");
    let mut cmd1 = Command::new(&bin);
    isolate_cmd(&mut cmd1, &fake_home);
    let create_output = cmd1
        .current_dir(&work_dir)
        .args([
            "--json",
            "profiles",
            "create",
            "mylab/fluorospec",
            "--name",
            "Fluorescence Spectrometer",
            "--out",
            out_profile.to_str().unwrap(),
        ])
        .output()
        .expect("profiles create");
    assert!(create_output.status.success());
    let create_parsed: serde_json::Value =
        serde_json::from_str(&String::from_utf8_lossy(&create_output.stdout)).unwrap();
    assert_eq!(create_parsed["ok"], true);
    assert_eq!(create_parsed["data"]["id"], "mylab/fluorospec");
    assert!(out_profile.is_file());

    let profile_content = fs::read_to_string(&out_profile).unwrap();
    assert!(profile_content.contains("schema_version: 4"));
    assert!(profile_content.contains("Fluorescence Spectrometer"));

    // 2. Export a builtin profile to cwd default
    let mut cmd2 = Command::new(&bin);
    isolate_cmd(&mut cmd2, &fake_home);
    let export_output = cmd2
        .current_dir(&work_dir)
        .args(["--json", "profiles", "export", "--id", "usth/keithley-2400"])
        .output()
        .expect("profiles export to cwd default");
    assert!(export_output.status.success());
    let default_exported = work_dir.join("usth-keithley-2400.yaml");
    assert!(default_exported.is_file());
    let exported_content = fs::read_to_string(&default_exported).unwrap();
    assert!(exported_content.contains("schema_version: 4"));
    assert!(exported_content.contains("Keithley 2400"));
}
