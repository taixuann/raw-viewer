use std::fs;
use std::path::PathBuf;
use std::process::Command;

fn cli_bin() -> PathBuf {
    PathBuf::from(env!("CARGO_BIN_EXE_raw-viewer"))
}

fn fixture_usth_lab() -> PathBuf {
    let mut path = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    path.pop();
    path.pop();
    path.push("fixtures");
    path.push("workspaces");
    path.push("usth-lab");
    path
}

fn temp_dir(label: &str) -> PathBuf {
    let mut p = std::env::temp_dir();
    p.push(format!(
        "raw_viewer_cli_test_{}_{}",
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
fn test_cli_help_on_subcommands() {
    let bin = cli_bin();
    let subcommands = [
        vec!["--help"],
        vec!["doctor", "--help"],
        vec!["projects", "--help"],
        vec!["config", "--help"],
        vec!["grammar", "--help"],
        vec!["profiles", "--help"],
        vec!["files", "--help"],
        vec!["skills", "--help"],
    ];

    for args in subcommands {
        let output = Command::new(&bin)
            .args(&args)
            .output()
            .expect("run command");
        assert!(
            output.status.success(),
            "failed on args: {:?}, stderr: {}",
            args,
            String::from_utf8_lossy(&output.stderr)
        );
    }
}

#[test]
fn test_doctor_from_tmp() {
    let bin = cli_bin();
    let output = Command::new(&bin)
        .current_dir(std::env::temp_dir())
        .args(["--json", "doctor"])
        .output()
        .expect("run doctor");

    assert!(output.status.success());
    let stdout = String::from_utf8_lossy(&output.stdout);
    let parsed: serde_json::Value = serde_json::from_str(&stdout).expect("parse json");
    assert_eq!(parsed["ok"], true);
    assert_eq!(parsed["command"], "doctor");
    assert_eq!(parsed["data"]["auth"], "not_required");
    assert_eq!(parsed["data"]["grammar_source"], "built-in");
}

#[test]
fn test_grammar_test_from_tmp() {
    let bin = cli_bin();
    let sample = "201226-154955_keithley-2400.dual-sweep_[cu-ec-pda.c1-ito.2_r1-c4]_iv.dual-sweep_r.[300K]_f.[x]_001";
    let output = Command::new(&bin)
        .current_dir(std::env::temp_dir())
        .args(["--json", "grammar", "test", "--filename", sample])
        .output()
        .expect("run grammar test");

    assert_eq!(output.status.code(), Some(0));
    let stdout = String::from_utf8_lossy(&output.stdout);
    let parsed: serde_json::Value = serde_json::from_str(&stdout).expect("parse json");
    assert_eq!(parsed["ok"], true);
    assert_eq!(parsed["data"]["all_matched"], true);
    assert_eq!(
        parsed["data"]["results"][0]["tokens"]["device"],
        "keithley-2400"
    );

    // Non matching filename should exit 4
    let bad_output = Command::new(&bin)
        .current_dir(std::env::temp_dir())
        .args([
            "--json",
            "grammar",
            "test",
            "--filename",
            "random_unmatched_file.xyz",
        ])
        .output()
        .expect("run grammar test bad");

    assert_eq!(bad_output.status.code(), Some(4));
    let bad_stdout = String::from_utf8_lossy(&bad_output.stdout);
    let bad_parsed: serde_json::Value = serde_json::from_str(&bad_stdout).expect("parse json");
    assert_eq!(bad_parsed["ok"], false);
    assert_eq!(bad_parsed["error"]["code"], "grammar_test_failed");
}

#[test]
fn test_files_match_and_export_on_fixture() {
    let bin = cli_bin();
    let usth = fixture_usth_lab();
    let file_rel = "data/raw/2026-10-07/071026-143703_keithley-2400.dual-sweep_[cu-ec-pda.q14-ito.2_r2-c6]_iv.dual-sweep_r.[reproducible]_010.txt";

    // 1. Match
    let match_output = Command::new(&bin)
        .current_dir(std::env::temp_dir())
        .args([
            "--json",
            "files",
            "match",
            "--project",
            usth.to_str().unwrap(),
            "--file",
            file_rel,
        ])
        .output()
        .expect("run files match");

    assert_eq!(match_output.status.code(), Some(0));
    let match_stdout = String::from_utf8_lossy(&match_output.stdout);
    let match_parsed: serde_json::Value = serde_json::from_str(&match_stdout).expect("parse json");
    assert_eq!(match_parsed["ok"], true);
    assert_eq!(
        match_parsed["data"]["outcome"]["profile_id"],
        "usth/keithley-2400"
    );

    // 2. Export --dry-run
    let export_output = Command::new(&bin)
        .current_dir(std::env::temp_dir())
        .args([
            "--json",
            "files",
            "export",
            "--project",
            usth.to_str().unwrap(),
            "--file",
            file_rel,
            "--format",
            "csv",
            "--out",
            "/tmp/out.csv",
            "--dry-run",
        ])
        .output()
        .expect("run files export");

    assert_eq!(export_output.status.code(), Some(0));
    let export_stdout = String::from_utf8_lossy(&export_output.stdout);
    let export_parsed: serde_json::Value =
        serde_json::from_str(&export_stdout).expect("parse json");
    assert_eq!(export_parsed["ok"], true);
    assert_eq!(export_parsed["data"]["row_count"], 121);
    assert_eq!(export_parsed["data"]["column_count"], 3);
}

#[test]
fn test_two_when_hits_exits_3_ambiguous_profile() {
    let bin = cli_bin();
    let root = temp_dir("ambiguous_cli");

    let profiles_dir = root.join(".raw-viewer/profiles");
    fs::create_dir_all(&profiles_dir).expect("create profiles dir");

    let profile_a = r#"
schema_version: 4
id: test/profile-a
instrument:
  id: test-a
  name: Test A
variants:
  default:
    format:
      kind: tabular
      extensions: [".txt"]
      delimiter: "\t"
    rows:
      names_prefix: x
      data_prefix: "1"
    columns:
      x:
        role: channel
        header: x
        quantity: voltage
        unit: V
        label: X
      y:
        role: channel
        header: y
        quantity: current
        unit: A
        label: Y
    plot:
      x: x
      y: [y]
    when:
      filename_contains_all: ["sample"]
"#;

    let profile_b = r#"
schema_version: 4
id: test/profile-b
instrument:
  id: test-b
  name: Test B
variants:
  default:
    format:
      kind: tabular
      extensions: [".txt"]
      delimiter: "\t"
    rows:
      names_prefix: x
      data_prefix: "1"
    columns:
      x:
        role: channel
        header: x
        quantity: voltage
        unit: V
        label: X
      y:
        role: channel
        header: y
        quantity: current
        unit: A
        label: Y
    plot:
      x: x
      y: [y]
    when:
      filename_contains_all: ["sample"]
"#;

    fs::write(profiles_dir.join("profile-a.yaml"), profile_a).expect("write a");
    fs::write(profiles_dir.join("profile-b.yaml"), profile_b).expect("write b");

    let data_dir = root.join("data/raw");
    fs::create_dir_all(&data_dir).expect("create data dir");
    fs::write(data_dir.join("sample_01.txt"), "x\ty\n1.0\t2.0\n").expect("write sample");

    // files match must exit 3 (ambiguous_profile)
    let match_output = Command::new(&bin)
        .args([
            "--json",
            "files",
            "match",
            "--project",
            root.to_str().unwrap(),
            "--file",
            "data/raw/sample_01.txt",
        ])
        .output()
        .expect("run files match");

    assert_eq!(
        match_output.status.code(),
        Some(3),
        "two when hits must exit code 3"
    );
    let match_stdout = String::from_utf8_lossy(&match_output.stdout);
    let match_parsed: serde_json::Value = serde_json::from_str(&match_stdout).expect("parse json");
    assert_eq!(match_parsed["ok"], false);
    assert_eq!(match_parsed["error"]["code"], "ambiguous_profile");

    // files inspect must exit 3 and NEVER succeed with generic-table!
    let inspect_output = Command::new(&bin)
        .args([
            "--json",
            "files",
            "inspect",
            "--project",
            root.to_str().unwrap(),
            "--file",
            "data/raw/sample_01.txt",
        ])
        .output()
        .expect("run files inspect");

    assert_eq!(
        inspect_output.status.code(),
        Some(3),
        "inspect on ambiguous must exit code 3"
    );
    let inspect_stdout = String::from_utf8_lossy(&inspect_output.stdout);
    let inspect_parsed: serde_json::Value =
        serde_json::from_str(&inspect_stdout).expect("parse json");
    assert_eq!(inspect_parsed["ok"], false);
    assert_eq!(inspect_parsed["error"]["code"], "ambiguous_profile");
}

#[test]
fn test_skills_repair_dry_run() {
    let bin = cli_bin();
    let output = Command::new(&bin)
        .args(["--json", "skills", "repair", "--dry-run"])
        .output()
        .expect("run skills repair");

    assert_eq!(output.status.code(), Some(0));
    let stdout = String::from_utf8_lossy(&output.stdout);
    let parsed: serde_json::Value = serde_json::from_str(&stdout).expect("parse json");
    assert_eq!(parsed["ok"], true);
    assert_eq!(parsed["command"], "skills.repair");
    assert_eq!(parsed["data"]["dry_run"], true);
}

#[test]
fn test_skills_install_idempotent_and_real_dir_safety() {
    let bin = cli_bin();
    let fake_home = temp_dir("fake_home");

    // Pre-create ~/.agents/skills/set-grammar as a real directory with a sentinel file
    let real_dir = fake_home.join(".agents").join("skills").join("set-grammar");
    fs::create_dir_all(&real_dir).expect("create real dir");
    fs::write(real_dir.join("sentinel.txt"), "untouchable").expect("write sentinel");

    // 1. Run skills install
    let output = Command::new(&bin)
        .env("HOME", &fake_home)
        .env("USERPROFILE", &fake_home)
        .args(["--json", "skills", "install"])
        .output()
        .expect("run skills install");

    assert_eq!(output.status.code(), Some(0));
    let stdout = String::from_utf8_lossy(&output.stdout);
    let parsed: serde_json::Value = serde_json::from_str(&stdout).expect("parse json");
    assert_eq!(parsed["ok"], true);

    // Sentinel file must still exist and directory must remain real
    assert!(real_dir.is_dir());
    assert!(!real_dir.is_symlink());
    assert!(real_dir.join("sentinel.txt").exists());

    // set-profile and setup-rawviewer in .agents/skills must be created as symlink/junction
    let profile_target = fake_home.join(".agents").join("skills").join("set-profile");
    let setup_target = fake_home
        .join(".agents")
        .join("skills")
        .join("setup-rawviewer");
    #[cfg(unix)]
    {
        assert!(profile_target.is_symlink());
        assert!(setup_target.is_symlink());
    }
    #[cfg(windows)]
    {
        assert!(profile_target.exists());
        assert!(setup_target.exists());
    }
    assert!(setup_target.join("SKILL.md").exists());

    // 2. Run skills install again (idempotent)
    let output2 = Command::new(&bin)
        .env("HOME", &fake_home)
        .env("USERPROFILE", &fake_home)
        .args(["--json", "skills", "install"])
        .output()
        .expect("run skills install 2nd time");
    assert_eq!(output2.status.code(), Some(0));

    // 3. Run skills repair
    let output3 = Command::new(&bin)
        .env("HOME", &fake_home)
        .env("USERPROFILE", &fake_home)
        .args(["--json", "skills", "repair"])
        .output()
        .expect("run skills repair");
    assert_eq!(output3.status.code(), Some(0));
}
