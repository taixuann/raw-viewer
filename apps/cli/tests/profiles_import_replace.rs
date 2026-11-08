use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;

fn cli_bin() -> PathBuf {
    let mut path = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    path.pop();
    path.pop();
    path.push("target");
    path.push("debug");
    path.push("raw-viewer");
    path
}

fn keithley_asset() -> PathBuf {
    let mut path = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    path.pop();
    path.pop();
    path.push("assets");
    path.push("profiles");
    path.push("usth");
    path.push("keithley-2400.yaml");
    path
}

fn temp_project(label: &str) -> PathBuf {
    let mut p = std::env::temp_dir();
    p.push(format!(
        "rv_u2_import_{}_{}",
        label,
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos()
    ));
    fs::create_dir_all(&p).expect("create temp project");
    p
}

fn sha256_hex(path: &Path) -> String {
    let output = Command::new("sha256sum")
        .arg(path)
        .output()
        .expect("sha256sum");
    assert!(output.status.success());
    let line = String::from_utf8_lossy(&output.stdout);
    line.split_whitespace().next().unwrap().to_string()
}

fn run_import_with_env(
    home: &Path,
    project: &Path,
    candidate: &Path,
    replace: bool,
    dry_run: bool,
    extra_env: &[(&str, &str)],
) -> (i32, serde_json::Value) {
    let mut args = vec![
        "--json".to_string(),
        "profiles".to_string(),
        "import".to_string(),
        "--project".to_string(),
        project.to_string_lossy().into_owned(),
        "--file".to_string(),
        candidate.to_string_lossy().into_owned(),
    ];
    if replace {
        args.push("--replace".to_string());
    }
    if dry_run {
        args.push("--dry-run".to_string());
    }

    let mut cmd = Command::new(cli_bin());
    cmd.env("HOME", home).env("USERPROFILE", home);
    for (k, v) in extra_env {
        cmd.env(k, v);
    }
    let output = cmd.args(&args).output().expect("run profiles import");

    let code = output.status.code().unwrap_or(-1);
    let stdout = String::from_utf8_lossy(&output.stdout);
    let parsed: serde_json::Value = if stdout.trim().is_empty() {
        serde_json::json!({})
    } else {
        serde_json::from_str(&stdout).expect("parse json envelope")
    };
    (code, parsed)
}

fn run_import(
    home: &Path,
    project: &Path,
    candidate: &Path,
    replace: bool,
    dry_run: bool,
) -> (i32, serde_json::Value) {
    run_import_with_env(home, project, candidate, replace, dry_run, &[])
}

const MARKER_SUFFIX: &str = "# USER EDIT MARKER — keep during import safety tests\n";

fn marked_keithley_text() -> String {
    let base = fs::read_to_string(keithley_asset()).expect("read keithley asset");
    format!("{base}{MARKER_SUFFIX}")
}

fn minimal_v4_profile(id: &str, instrument_id: &str, instrument_name: &str) -> String {
    format!(
        r#"schema_version: 4
id: {id}
revision: 1
instrument:
  id: {instrument_id}
  name: {instrument_name}
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
    plot:
      x: x
      y: [x]
    when:
      content_contains_any: ["unique-token-{instrument_id}"]
"#
    )
}

#[test]
fn acceptance_first_import_succeeds() {
    let home = temp_project("home_first");
    let project = temp_project("first_import");
    let dest = project.join(".raw-viewer/profiles/usth-keithley-2400.yaml");

    let (code, parsed) = run_import(&home, &project, &keithley_asset(), false, false);
    assert_eq!(code, 0, "stdout: {parsed}");
    assert_eq!(parsed["ok"], true);
    assert!(dest.is_file());
}

#[test]
fn acceptance_repeat_without_replace_exits_nonzero_and_preserves_bytes() {
    let home = temp_project("home_repeat");
    let project = temp_project("repeat_no_replace");
    let dest = project.join(".raw-viewer/profiles/usth-keithley-2400.yaml");
    let marked = marked_keithley_text();
    fs::create_dir_all(dest.parent().unwrap()).expect("profiles dir");
    fs::write(&dest, &marked).expect("write marked dest");

    let before_hash = sha256_hex(&dest);

    let (code, parsed) = run_import(&home, &project, &keithley_asset(), false, false);
    assert_eq!(code, 4, "must refuse silent overwrite");
    assert_eq!(parsed["ok"], false);
    assert_eq!(parsed["error"]["code"], "replacement_required");

    let after_hash = sha256_hex(&dest);
    assert_eq!(
        before_hash, after_hash,
        "destination bytes must be unchanged"
    );
    let on_disk = fs::read_to_string(&dest).expect("read dest");
    assert!(on_disk.contains(MARKER_SUFFIX.trim_end()));
}

#[test]
fn acceptance_replace_same_id_succeeds_with_new_bytes() {
    let home = temp_project("home_replace");
    let project = temp_project("replace_same");
    let dest = project.join(".raw-viewer/profiles/usth-keithley-2400.yaml");
    let marked = marked_keithley_text();
    fs::create_dir_all(dest.parent().unwrap()).expect("profiles dir");
    fs::write(&dest, &marked).expect("write marked dest");

    let (code, parsed) = run_import(&home, &project, &keithley_asset(), true, false);
    assert_eq!(code, 0, "parsed: {parsed}");
    assert_eq!(parsed["data"]["replaced"], true);

    let on_disk = fs::read_to_string(&dest).expect("read dest");
    assert!(
        !on_disk.contains(MARKER_SUFFIX.trim_end()),
        "replace must install candidate bytes"
    );
    assert!(on_disk.contains("schema_version: 4"));
}

#[test]
fn acceptance_invalid_candidate_leaves_destination_unchanged_with_and_without_replace() {
    let home = temp_project("home_invalid");
    let project = temp_project("invalid_candidate");
    let dest = project.join(".raw-viewer/profiles/usth-keithley-2400.yaml");
    let marked = marked_keithley_text();
    fs::create_dir_all(dest.parent().unwrap()).expect("profiles dir");
    fs::write(&dest, &marked).expect("write marked dest");
    let before_hash = sha256_hex(&dest);

    let invalid = project.join("invalid-candidate.yaml");
    fs::write(&invalid, "schema_version: 4\nid: not-a-valid-profile\n").expect("write invalid");

    for replace in [false, true] {
        let (code, parsed) = run_import(&home, &project, &invalid, replace, false);
        assert_eq!(code, 4, "invalid candidate must fail validation");
        assert_eq!(parsed["error"]["code"], "validation_error");
        assert_eq!(sha256_hex(&dest), before_hash);
    }
}

#[test]
fn acceptance_dry_run_writes_nothing_including_missing_profiles_dir() {
    let home = temp_project("home_dry");
    let project = temp_project("dry_run_no_writes");
    let profiles_dir = project.join(".raw-viewer/profiles");
    let config_path = project.join(".raw-viewer/config.yaml");
    assert!(!profiles_dir.exists());

    let (code, parsed) = run_import(&home, &project, &keithley_asset(), false, true);
    assert_eq!(code, 0, "parsed: {parsed}");
    assert_eq!(parsed["data"]["dry_run"], true);
    assert_eq!(parsed["data"]["validated_candidate"], true);
    let note = parsed["data"]["note"].as_str().unwrap_or("");
    assert!(
        note.contains("does not install") && note.contains("activate"),
        "dry-run must not imply activation"
    );

    assert!(
        !profiles_dir.exists(),
        "dry-run must not create profiles dir"
    );
    assert!(!config_path.exists(), "dry-run must not touch config");
}

#[test]
fn acceptance_dry_run_on_existing_reports_would_require_replace_without_writing() {
    let home = temp_project("home_dry_exist");
    let project = temp_project("dry_run_existing");
    let dest = project.join(".raw-viewer/profiles/usth-keithley-2400.yaml");
    fs::create_dir_all(dest.parent().unwrap()).expect("profiles dir");
    fs::write(&dest, marked_keithley_text()).expect("seed dest");
    let before_hash = sha256_hex(&dest);

    let (code, parsed) = run_import(&home, &project, &keithley_asset(), false, true);
    assert_eq!(code, 0);
    assert_eq!(parsed["data"]["would_require_replace"], true);
    assert_eq!(sha256_hex(&dest), before_hash);
}

#[test]
fn acceptance_slash_vs_hyphen_id_collision_never_clobbers_with_replace() {
    let home = temp_project("home_collision");
    let project = temp_project("slash_hyphen_collision");
    let dest = project.join(".raw-viewer/profiles/a-b.yaml");
    let slash_candidate = project.join("slash.yaml");
    let hyphen_candidate = project.join("hyphen.yaml");

    fs::create_dir_all(dest.parent().unwrap()).expect("profiles dir");
    fs::write(&dest, minimal_v4_profile("a-b", "hyphen-inst", "Hyphen Id"))
        .expect("write hyphen dest");
    let hyphen_hash = sha256_hex(&dest);

    fs::write(
        &slash_candidate,
        minimal_v4_profile("a/b", "slash-inst", "Slash Id"),
    )
    .expect("write slash candidate");

    for replace in [false, true] {
        let (code, parsed) = run_import(&home, &project, &slash_candidate, replace, false);
        assert_eq!(code, 4, "collision must fail for replace={replace}");
        assert_eq!(parsed["error"]["code"], "profile_id_collision");
        assert_eq!(sha256_hex(&dest), hyphen_hash, "hyphen profile preserved");
    }

    fs::write(
        &hyphen_candidate,
        minimal_v4_profile("a-b", "hyphen-inst-2", "Hyphen Id 2"),
    )
    .expect("write second hyphen candidate");

    let slash_dest = project.join(".raw-viewer/profiles/a-b.yaml");
    fs::write(
        &slash_dest,
        minimal_v4_profile("a/b", "slash-inst", "Slash Id"),
    )
    .expect("write slash dest");
    let slash_hash = sha256_hex(&slash_dest);

    let (code, parsed) = run_import(&home, &project, &hyphen_candidate, true, false);
    assert_eq!(code, 4);
    assert_eq!(parsed["error"]["code"], "profile_id_collision");
    assert_eq!(sha256_hex(&slash_dest), slash_hash);
}

#[test]
fn acceptance_post_staging_replace_failure_leaves_destination_unchanged() {
    let home = temp_project("home_atomic_fail");
    let project = temp_project("atomic_fail");
    let profiles_dir = project.join(".raw-viewer/profiles");
    let dest = profiles_dir.join("usth-keithley-2400.yaml");
    fs::create_dir_all(&profiles_dir).expect("profiles dir");
    let marked = marked_keithley_text();
    fs::write(&dest, &marked).expect("write dest");
    let before_hash = sha256_hex(&dest);
    let parent = dest.parent().unwrap();
    assert!(
        fs::read_dir(parent)
            .expect("list profiles dir")
            .filter_map(Result::ok)
            .all(|e| !e.file_name().to_string_lossy().contains(".import-tmp")),
        "staging must not leave temp files before import"
    );

    let (code, parsed) = run_import_with_env(
        &home,
        &project,
        &keithley_asset(),
        true,
        false,
        &[("RAW_VIEWER_TEST_COMMIT_REPLACE_FAIL", "1")],
    );
    assert_eq!(code, 5, "commit failure after staging must be I/O class");
    assert_eq!(parsed["error"]["code"], "io_error");
    assert_eq!(
        sha256_hex(&dest),
        before_hash,
        "failed replace must not mutate destination"
    );
    assert!(
        fs::read_dir(parent)
            .expect("list after")
            .filter_map(Result::ok)
            .all(|e| !e.file_name().to_string_lossy().contains(".import-tmp")),
        "failed commit must remove staging temp file"
    );
}

#[test]
fn acceptance_destination_appears_after_staging_without_replace_preserves_bytes() {
    let home = temp_project("home_race");
    let project = temp_project("race_dest");
    let dest = project.join(".raw-viewer/profiles/usth-keithley-2400.yaml");
    let inject_body = marked_keithley_text();

    let (code, parsed) = run_import_with_env(
        &home,
        &project,
        &keithley_asset(),
        false,
        false,
        &[
            ("RAW_VIEWER_TEST_IMPORT_INJECT", "post_stage"),
            ("RAW_VIEWER_TEST_INJECT_KIND", "create_dest"),
            ("RAW_VIEWER_TEST_INJECT_CONTENT", &inject_body),
        ],
    );
    assert_eq!(code, 4, "must refuse when destination appears at commit");
    assert!(
        matches!(
            parsed["error"]["code"].as_str(),
            Some("replacement_required") | Some("profile_id_collision")
        ),
        "unexpected error: {parsed}"
    );
    assert!(dest.is_file(), "adversarial destination must remain");
    assert_eq!(
        sha256_hex(&dest),
        sha256_hex_from_bytes(inject_body.as_bytes())
    );
}

#[test]
fn acceptance_destination_appears_after_staging_with_replace_refuses_different_identity() {
    let home = temp_project("home_race_diff");
    let project = temp_project("race_diff");
    let dest = project.join(".raw-viewer/profiles/a-b.yaml");
    let hyphen_body = minimal_v4_profile("a-b", "hyphen", "Hyphen");

    let (code, parsed) = run_import_with_env(
        &home,
        &project,
        &{
            let c = project.join("slash.yaml");
            fs::write(&c, minimal_v4_profile("a/b", "slash", "Slash")).expect("slash cand");
            c
        },
        true,
        false,
        &[
            ("RAW_VIEWER_TEST_IMPORT_INJECT", "post_stage"),
            ("RAW_VIEWER_TEST_INJECT_KIND", "create_dest"),
            ("RAW_VIEWER_TEST_INJECT_CONTENT", &hyphen_body),
        ],
    );
    assert_eq!(code, 4);
    assert_eq!(parsed["error"]["code"], "profile_id_collision");
    assert_eq!(
        sha256_hex(&dest),
        sha256_hex_from_bytes(hyphen_body.as_bytes())
    );
}

fn sha256_hex_from_bytes(data: &[u8]) -> String {
    use std::io::Write;
    let mut child = Command::new("sha256sum")
        .stdin(std::process::Stdio::piped())
        .stdout(std::process::Stdio::piped())
        .spawn()
        .expect("sha256sum");
    child
        .stdin
        .take()
        .expect("stdin")
        .write_all(data)
        .expect("write hash stdin");
    let out = child.wait_with_output().expect("hash");
    String::from_utf8_lossy(&out.stdout)
        .split_whitespace()
        .next()
        .unwrap()
        .to_string()
}

fn electrochem_v3_fixture() -> &'static str {
    const ELECTROCHEM_YAML: &str = r#"schema_version: 3
identity:
  id: "acme"
  name: "Acme Lab"
  instrument:
    id: "acme-inst"
    name: "Acme Instrument"
filename:
  grammar_id: "electrochem"
  variant_keys:
    - "instrument"
    - "mode"
variants:
  - id: "cv"
    name: "CV"
    key_values:
      instrument: "acme"
      mode: "cv"
    raw_stream:
      extensions:
        - ".txt"
      encoding:
        - "utf-8"
      delimiter: ","
      decimal_separator: "."
      rows:
        header:
          row: 2
        data_start:
          after_header: true
        excluded_metadata: []
      columns:
        - id: "potential"
          source:
            header: "Volts"
            aliases: []
          label: "Voltage"
          quantity: "voltage"
          unit: "V"
          required: true
          role: "channel"
          axes:
            - "x"
        - id: "current"
          source:
            header: "Amps"
            aliases: []
          label: "Current"
          quantity: "current"
          unit: "A"
          required: true
          role: "channel"
          axes:
            - "y"
    metadata: []
    metadata_capture:
      - kind: "pre_header_fields"
    default_plot:
      x: "potential"
      y:
        - "current"
"#;
    ELECTROCHEM_YAML
}

#[test]
fn acceptance_v3_candidate_import_preserves_guard_behavior() {
    let home = temp_project("home_v3");
    let project = temp_project("v3_import");
    let candidate = project.join("v3.yaml");
    let dest = project.join(".raw-viewer/profiles/acme.yaml");
    let v3 = electrochem_v3_fixture();
    fs::write(&candidate, v3).expect("write v3");

    let (code, _) = run_import(&home, &project, &candidate, false, false);
    assert_eq!(code, 0);
    assert!(dest.is_file());

    let mut on_disk = fs::read_to_string(&dest).expect("read installed v3");
    on_disk.push_str("\n# USER MARKER v3\n");
    fs::write(&dest, &on_disk).expect("mark installed v3");
    let before_hash = sha256_hex(&dest);

    let (code, parsed) = run_import(&home, &project, &candidate, false, false);
    assert_eq!(code, 4);
    assert_eq!(parsed["error"]["code"], "replacement_required");
    assert_eq!(sha256_hex(&dest), before_hash);
}

#[test]
fn regression_base_behavior_overwrites_marked_destination_without_replace() {
    // Documents the pre-U2 bug: without the guard in profiles.rs, a second import would exit 0
    // and remove user edit markers. This test expects the fixed head behavior (nonzero + marker kept).
    let home = temp_project("home_regression");
    let project = temp_project("regression_marker");
    let dest = project.join(".raw-viewer/profiles/usth-keithley-2400.yaml");
    fs::create_dir_all(dest.parent().unwrap()).expect("profiles dir");
    fs::write(&dest, marked_keithley_text()).expect("write marked");

    let (code, _) = run_import(&home, &project, &keithley_asset(), false, false);
    assert_ne!(
        code, 0,
        "at base 64904ee import would have returned 0 and clobbered the marker; head must refuse"
    );
    let on_disk = fs::read_to_string(&dest).expect("read");
    assert!(on_disk.contains(MARKER_SUFFIX.trim_end()));
}
