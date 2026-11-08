use raw_viewer_core::explorer::Explorer;
use std::fs;
use std::path::PathBuf;
use std::process::Command;

fn cli_bin() -> PathBuf {
    let mut path = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    path.pop(); // apps
    path.pop(); // root
    path.push("target");
    path.push("debug");
    path.push("raw-viewer");
    path
}

fn temp_dir(label: &str) -> PathBuf {
    let mut p = std::env::temp_dir();
    p.push(format!(
        "raw_viewer_grammar_test_{}_{}",
        label,
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos()
    ));
    fs::create_dir_all(&p).expect("create temp dir");
    p
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
    let show_initial = Command::new(&bin)
        .env("HOME", &fake_home)
        .env("XDG_CONFIG_HOME", fake_home.join(".config"))
        .args(["--json", "grammar", "show", "--global"])
        .output()
        .expect("run grammar show initial");
    assert!(show_initial.status.success());
    let stdout_initial = String::from_utf8_lossy(&show_initial.stdout);
    let parsed_initial: serde_json::Value = serde_json::from_str(&stdout_initial).unwrap();
    assert_eq!(parsed_initial["ok"], true);
    assert_eq!(parsed_initial["data"]["source"], "built-in");

    // 2. Set --global with candidate
    let set_output = Command::new(&bin)
        .env("HOME", &fake_home)
        .env("XDG_CONFIG_HOME", fake_home.join(".config"))
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
    let show_after = Command::new(&bin)
        .env("HOME", &fake_home)
        .env("XDG_CONFIG_HOME", fake_home.join(".config"))
        .args(["--json", "grammar", "show", "--global"])
        .output()
        .expect("run grammar show after set");
    assert!(show_after.status.success());
    let stdout_after = String::from_utf8_lossy(&show_after.stdout);
    let parsed_after: serde_json::Value = serde_json::from_str(&stdout_after).unwrap();
    assert_eq!(parsed_after["ok"], true);
    assert_eq!(parsed_after["data"]["source"], "global");
    assert_eq!(parsed_after["data"]["id"], "custom-lab-grammar");
    assert_eq!(
        parsed_after["data"]["template"],
        "{instrument}_{mode}_{device}"
    );

    // 4. Explorer opened in an unconfigured project inherits the global grammar
    let proj = temp_root.join("empty_proj");
    fs::create_dir_all(&proj).unwrap();
    // Set environment so Explorer's paths::resolve_paths_from_env picks up fake_home
    std::env::set_var("HOME", &fake_home);
    std::env::set_var("XDG_CONFIG_HOME", fake_home.join(".config"));

    let explorer = Explorer::open(&proj).expect("open empty project");
    let eff = explorer.effective_grammar();
    assert_eq!(eff.source, raw_viewer_core::explorer::GrammarSource::Global);
    assert_eq!(eff.grammar.id, "custom-lab-grammar");

    // 5. Test grammar test command on matching filename using global grammar
    let test_output = Command::new(&bin)
        .env("HOME", &fake_home)
        .env("XDG_CONFIG_HOME", fake_home.join(".config"))
        .args([
            "--json",
            "grammar",
            "test",
            "--global",
            "--filename",
            "keithley_iv_dev01.csv",
        ])
        .output()
        .expect("run grammar test");
    let test_stdout = String::from_utf8_lossy(&test_output.stdout);
    let test_stderr = String::from_utf8_lossy(&test_output.stderr);
    assert!(
        test_output.status.success(),
        "grammar test failed: status={}, stdout={}, stderr={}",
        test_output.status,
        test_stdout,
        test_stderr
    );
    let test_parsed: serde_json::Value =
        serde_json::from_str(&String::from_utf8_lossy(&test_output.stdout)).unwrap();
    assert_eq!(test_parsed["ok"], true);
    assert_eq!(test_parsed["data"]["all_matched"], true);
    assert_eq!(test_parsed["data"]["grammar_id"], "custom-lab-grammar");
}

#[test]
fn test_project_grammar_overrides_global_grammar() {
    let bin = cli_bin();
    let temp_root = temp_dir("override_grammar");
    let fake_home = temp_root.join("home");
    fs::create_dir_all(&fake_home).unwrap();

    let global_file = temp_root.join("global_grammar.yaml");
    fs::write(
        &global_file,
        r#"
grammar:
  id: global-grammar
  name: Global Grammar
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

    let set_global = Command::new(&bin)
        .env("HOME", &fake_home)
        .env("XDG_CONFIG_HOME", fake_home.join(".config"))
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

    let set_local = Command::new(&bin)
        .env("HOME", &fake_home)
        .env("XDG_CONFIG_HOME", fake_home.join(".config"))
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
    let show_proj = Command::new(&bin)
        .env("HOME", &fake_home)
        .env("XDG_CONFIG_HOME", fake_home.join(".config"))
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
