use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;

fn cli_bin() -> PathBuf {
    PathBuf::from(env!("CARGO_BIN_EXE_raw-viewer"))
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
fn test_global_grammar_set_and_show_roundtrip() {
    let bin = cli_bin();
    let temp_root = temp_dir("global_grammar");
    let fake_home = temp_root.join("home");
    fs::create_dir_all(&fake_home).unwrap();

    let candidate_file = temp_root.join("custom_grammar.yaml");
    let candidate_content = r#"
grammar:
  id: custom-lab-grammar
  name: Custom Lab Grammar
  template: "{instrument}_{mode}_{device}"
  fields:
    - name: instrument
      type: string
    - name: mode
      type: string
    - name: device
      type: string
"#;
    fs::write(&candidate_file, candidate_content).unwrap();

    // 1. Initial show --global with isolated HOME returns built-in
    let mut cmd1 = Command::new(&bin);
    isolate_cmd(&mut cmd1, &fake_home);
    let show_initial = cmd1
        .args(["--json", "grammar", "show", "--global"])
        .output()
        .expect("run grammar show initial");
    assert!(show_initial.status.success());
    let stdout_initial = String::from_utf8_lossy(&show_initial.stdout);
    let parsed_initial: serde_json::Value = serde_json::from_str(&stdout_initial).unwrap();
    assert_eq!(parsed_initial["ok"], true);
    assert_eq!(parsed_initial["data"]["source"], "built-in");

    // 2. Set --global with candidate
    let mut cmd2 = Command::new(&bin);
    isolate_cmd(&mut cmd2, &fake_home);
    let set_output = cmd2
        .args([
            "--json",
            "grammar",
            "set",
            "--global",
            "--file",
            candidate_file.to_str().unwrap(),
        ])
        .output()
        .expect("run grammar set global");
    let set_stdout = String::from_utf8_lossy(&set_output.stdout);
    let set_stderr = String::from_utf8_lossy(&set_output.stderr);
    assert!(
        set_output.status.success(),
        "grammar set failed: status={}, stdout={}, stderr={}",
        set_output.status,
        set_stdout,
        set_stderr
    );
    let set_parsed: serde_json::Value = serde_json::from_str(&set_stdout).unwrap();
    assert_eq!(set_parsed["ok"], true);
    assert_eq!(set_parsed["data"]["id"], "custom-lab-grammar");

    // 3. Show --global must now return the custom grammar with source global
    let mut cmd3 = Command::new(&bin);
    isolate_cmd(&mut cmd3, &fake_home);
    let show_after = cmd3
        .args(["--json", "grammar", "show", "--global"])
        .output()
        .expect("run grammar show after set");
    assert!(show_after.status.success());
    let stdout_after = String::from_utf8_lossy(&show_after.stdout);
    let parsed_after: serde_json::Value = serde_json::from_str(&stdout_after).unwrap();
    assert_eq!(parsed_after["ok"], true);
    assert_eq!(parsed_after["data"]["source"], "global");
    assert_eq!(parsed_after["data"]["id"], "custom-lab-grammar");

    // 4. Test that explorer on a new project without local config inherits global grammar
    let proj = temp_root.join("test_proj");
    fs::create_dir_all(&proj).unwrap();

    let mut cmd4 = Command::new(&bin);
    isolate_cmd(&mut cmd4, &fake_home);
    let show_proj = cmd4
        .args([
            "--json",
            "grammar",
            "show",
            "--project",
            proj.to_str().unwrap(),
        ])
        .output()
        .expect("run grammar show project");
    assert!(show_proj.status.success());
    let stdout_proj = String::from_utf8_lossy(&show_proj.stdout);
    let parsed_proj: serde_json::Value = serde_json::from_str(&stdout_proj).unwrap();
    assert_eq!(parsed_proj["ok"], true);
    assert_eq!(parsed_proj["data"]["source"], "global");
    assert_eq!(parsed_proj["data"]["id"], "custom-lab-grammar");

    // 5. grammar test uses this effective global grammar
    let mut cmd5 = Command::new(&bin);
    isolate_cmd(&mut cmd5, &fake_home);
    let test_run = cmd5
        .args([
            "--json",
            "grammar",
            "test",
            "--project",
            proj.to_str().unwrap(),
            "--filename",
            "keithley_iv_d1.txt",
        ])
        .output()
        .expect("run grammar test");
    assert!(test_run.status.success());
    let test_stdout = String::from_utf8_lossy(&test_run.stdout);
    let test_parsed: serde_json::Value = serde_json::from_str(&test_stdout).unwrap();
    assert_eq!(test_parsed["ok"], true);
    assert_eq!(test_parsed["data"]["all_matched"], true);
    assert_eq!(test_parsed["data"]["grammar_id"], "custom-lab-grammar");
    assert_eq!(test_parsed["data"]["results"][0]["matched"], true);
    assert_eq!(
        test_parsed["data"]["results"][0]["tokens"]["instrument"],
        "keithley"
    );
    assert_eq!(test_parsed["data"]["results"][0]["tokens"]["mode"], "iv");
    assert_eq!(test_parsed["data"]["results"][0]["tokens"]["device"], "d1");
}

#[test]
fn test_project_grammar_overrides_global_grammar() {
    let bin = cli_bin();
    let temp_root = temp_dir("override_grammar");
    let fake_home = temp_root.join("home");
    fs::create_dir_all(&fake_home).unwrap();

    // Set global grammar first
    let global_file = temp_root.join("global_grammar.yaml");
    fs::write(
        &global_file,
        r#"
grammar:
  id: global-custom-grammar
  name: Global Custom Grammar
  template: "{instrument}_{mode}_{device}"
  fields:
    - name: instrument
      type: string
    - name: mode
      type: string
    - name: device
      type: string
"#,
    )
    .unwrap();

    let mut cmd1 = Command::new(&bin);
    isolate_cmd(&mut cmd1, &fake_home);
    let set_global = cmd1
        .args([
            "--json",
            "grammar",
            "set",
            "--global",
            "--file",
            global_file.to_str().unwrap(),
        ])
        .output()
        .expect("set global grammar");
    assert!(set_global.status.success());

    // Project with local grammar
    let proj = temp_root.join("local_proj");
    fs::create_dir_all(&proj).unwrap();

    let local_file = temp_root.join("local_grammar.yaml");
    fs::write(
        &local_file,
        r#"
grammar:
  id: project-specific-grammar
  name: Project Grammar
  template: "{sample}_{run}"
  fields:
    - name: sample
      type: string
    - name: run
      type: string
"#,
    )
    .unwrap();

    let mut cmd2 = Command::new(&bin);
    isolate_cmd(&mut cmd2, &fake_home);
    let set_local = cmd2
        .args([
            "--json",
            "grammar",
            "set",
            "--project",
            proj.to_str().unwrap(),
            "--file",
            local_file.to_str().unwrap(),
        ])
        .output()
        .expect("set local grammar");
    assert!(set_local.status.success());

    // Show with --project returns project source
    let mut cmd3 = Command::new(&bin);
    isolate_cmd(&mut cmd3, &fake_home);
    let show_proj = cmd3
        .args([
            "--json",
            "grammar",
            "show",
            "--project",
            proj.to_str().unwrap(),
        ])
        .output()
        .expect("show project grammar");
    assert!(show_proj.status.success());
    let parsed_proj: serde_json::Value =
        serde_json::from_str(&String::from_utf8_lossy(&show_proj.stdout)).unwrap();
    assert_eq!(parsed_proj["ok"], true);
    assert_eq!(parsed_proj["data"]["source"], "project");
    assert_eq!(parsed_proj["data"]["id"], "project-specific-grammar");
}
