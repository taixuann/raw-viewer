use raw_viewer_core::config::load_project_config_with_fallback;
use raw_viewer_core::grammar::grammar_context;
use raw_viewer_core::profile::load_catalog;
use raw_viewer_core::reader::load_measurement;
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};

static NEXT_ID: AtomicU64 = AtomicU64::new(0);

fn temp_project() -> PathBuf {
    let dir = std::env::temp_dir().join(format!(
        "rawview-builtin-assets-{}-{}-{}",
        std::process::id(),
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap_or_default()
            .as_nanos(),
        NEXT_ID.fetch_add(1, Ordering::Relaxed)
    ));
    let _ = fs::remove_dir_all(&dir);
    fs::create_dir_all(&dir).unwrap();
    dir
}

const STANDARD_KEITHLEY_SOURCE: &str = include_str!(
    "../../fixtures/workspaces/usth-lab/data/raw/2026-10-07/071026-143703_keithley-2400.dual-sweep_[cu-ec-pda.q14-ito.2_r2-c6]_iv.dual-sweep_r.[reproducible]_010.txt"
);

#[test]
fn fresh_project_loads_builtins_and_resolves_standard_and_non_standard_files() {
    let tmp = temp_project();
    // No .raw-viewer/ created; completely fresh project
    let grammar_ctx = grammar_context(&tmp);
    let catalog = grammar_ctx.catalog.expect("bundled grammar catalog loads");
    assert_eq!(catalog.grammars.len(), 1);
    assert_eq!(catalog.grammars[0].id, "standard-scientific");

    let profile_cat = load_catalog(&tmp);
    assert!(profile_cat.issues.is_empty(), "issues: {:?}", profile_cat.issues);
    assert!(profile_cat.profiles.len() >= 4);
    assert!(profile_cat.profiles.iter().any(|p| p.profile_id == "usth/keithley-2400"));
    assert!(profile_cat.profiles.iter().any(|p| p.profile_id == "usth/autolab-usth"));
    assert!(profile_cat.profiles.iter().any(|p| p.profile_id == "usth/horiba-labram"));
    assert!(profile_cat.profiles.iter().any(|p| p.profile_id == "usth/iop-hanoi"));

    // 1. Standard-named Keithley file
    let standard_rel = Path::new("data/raw/071026-143703_keithley-2400.dual-sweep_[cu-ec-pda.q14-ito.2_r2-c6]_iv.dual-sweep_r.[reproducible]_010.txt");
    fs::create_dir_all(tmp.join("data/raw")).unwrap();
    fs::write(tmp.join(standard_rel), STANDARD_KEITHLEY_SOURCE).unwrap();

    let measurement = load_measurement(&tmp, standard_rel).expect("loads via built-in profile + grammar");
    assert_eq!(measurement.instrument.id, "keithley-2400");
    assert_eq!(measurement.application_mode.as_deref(), Some("dual-sweep"));
    assert_eq!(measurement.channels.len(), 3);
    assert_eq!(measurement.channels[0].name, "voltage");
    assert_eq!(measurement.channels[0].values.len(), 121);

    // 2. Non-standard named Keithley file selects by content
    let non_standard_rel = Path::new("data/raw/custom_name_sweep.txt");
    fs::write(tmp.join(non_standard_rel), STANDARD_KEITHLEY_SOURCE).unwrap();
    let sweep_measurement = load_measurement(&tmp, non_standard_rel).expect("loads by content when");
    assert_eq!(sweep_measurement.instrument.id, "keithley-2400");
    assert_eq!(sweep_measurement.channels[0].values.len(), 121);

    // 3. Generic table fallback for unmatched content
    let generic_rel = Path::new("data/raw/table.csv");
    fs::write(tmp.join(generic_rel), "a,b\n1,2\n3,4\n").unwrap();
    let generic_m = load_measurement(&tmp, generic_rel).expect("generic table fallback");
    assert_eq!(generic_m.instrument.id, "generic-table");

    let _ = fs::remove_dir_all(&tmp);
}

#[test]
fn disabling_profile_in_config_stops_it_matching() {
    let tmp = temp_project();
    fs::create_dir_all(tmp.join(".raw-viewer")).unwrap();
    fs::write(
        tmp.join(".raw-viewer/config.yaml"),
        "schema_version: 1\nprofiles:\n  disabled:\n    - usth/keithley-2400\n",
    )
    .unwrap();

    let cat = load_catalog(&tmp);
    assert!(cat.issues.is_empty(), "issues: {:?}", cat.issues);
    assert!(!cat.profiles.iter().any(|p| p.profile_id == "usth/keithley-2400"));
    assert!(cat.profiles.iter().any(|p| p.profile_id == "usth/autolab-usth"));

    let non_standard_rel = Path::new("data/raw/custom_name_sweep.txt");
    fs::create_dir_all(tmp.join("data/raw")).unwrap();
    fs::write(tmp.join(non_standard_rel), STANDARD_KEITHLEY_SOURCE).unwrap();

    let m = load_measurement(&tmp, non_standard_rel).expect("fallback when keithley is disabled");
    assert_eq!(m.instrument.id, "generic-table");

    let _ = fs::remove_dir_all(&tmp);
}

#[test]
fn overriding_one_builtin_keeps_the_rest() {
    let tmp = temp_project();
    fs::create_dir_all(tmp.join(".raw-viewer/profiles")).unwrap();
    let custom_keithley = r#"schema_version: 4
id: usth/keithley-2400
revision: 2
instrument:
  id: keithley-2400-custom
  name: Custom Keithley 2400
variants:
  dual-sweep:
    when:
      content_contains_any:
        - LabVIEW Measurement
    format:
      kind: tabular
      extensions: [".txt"]
      delimiter: "\t"
    rows:
      names_prefix: X_Value
      data_prefix: ""
    metadata: []
    columns:
      voltage:
        role: channel
        header: Untitled
        quantity: voltage
        unit: V
      current:
        role: channel
        header: Untitled 1
        quantity: current
        unit: A
    plot:
      x: voltage
      y: [current]
"#;
    fs::write(tmp.join(".raw-viewer/profiles/my-keithley.yaml"), custom_keithley).unwrap();

    let cat = load_catalog(&tmp);
    assert!(cat.issues.is_empty(), "issues: {:?}", cat.issues);
    let keithley = cat.profiles.iter().find(|p| p.profile_id == "usth/keithley-2400").expect("keithley profile loaded");
    assert_eq!(keithley.instrument_id, "keithley-2400-custom");
    // Other built-ins still loaded
    assert!(cat.profiles.iter().any(|p| p.profile_id == "usth/autolab-usth"));
    assert!(cat.profiles.iter().any(|p| p.profile_id == "usth/horiba-labram"));
    assert!(cat.profiles.iter().any(|p| p.profile_id == "usth/iop-hanoi"));

    let _ = fs::remove_dir_all(&tmp);
}

#[test]
fn older_revision_warning_when_project_revision_less_than_builtin() {
    let tmp = temp_project();
    fs::create_dir_all(tmp.join(".raw-viewer/profiles")).unwrap();
    let old_keithley = r#"schema_version: 4
id: usth/keithley-2400
revision: 0
instrument:
  id: keithley-2400-old
  name: Old Keithley 2400
variants:
  dual-sweep:
    when:
      content_contains_any:
        - LabVIEW Measurement
    format:
      kind: tabular
      extensions: [".txt"]
      delimiter: "\t"
    rows:
      names_prefix: X_Value
      data_prefix: ""
    metadata: []
    columns:
      voltage:
        role: channel
        header: Untitled
        quantity: voltage
        unit: V
      current:
        role: channel
        header: Untitled 1
        quantity: current
        unit: A
    plot:
      x: voltage
      y: [current]
"#;
    fs::write(tmp.join(".raw-viewer/profiles/old-keithley.yaml"), old_keithley).unwrap();

    let cat = load_catalog(&tmp);
    assert!(
        cat.issues.iter().any(|issue| {
            issue.contains("usth/keithley-2400") && issue.contains("older than built-in revision")
        }),
        "expected revision warning in issues: {:?}",
        cat.issues
    );

    let _ = fs::remove_dir_all(&tmp);
}

#[test]
fn duplicate_in_enabled_and_disabled_errors() {
    let tmp = temp_project();
    fs::create_dir_all(tmp.join(".raw-viewer")).unwrap();
    fs::write(
        tmp.join(".raw-viewer/config.yaml"),
        "schema_version: 1\nprofiles:\n  enabled:\n    - usth/keithley-2400\n  disabled:\n    - usth/keithley-2400\n",
    )
    .unwrap();

    let err = load_project_config_with_fallback(&tmp).expect_err("duplicate enabled and disabled must fail");
    let msg = err.to_string();
    assert!(msg.contains("usth/keithley-2400"), "message was: {msg}");
    assert!(msg.contains("both profiles.enabled and profiles.disabled"), "message was: {msg}");

    let _ = fs::remove_dir_all(&tmp);
}

#[test]
fn unknown_keys_in_profiles_config_errors() {
    let tmp = temp_project();
    fs::create_dir_all(tmp.join(".raw-viewer")).unwrap();
    fs::write(
        tmp.join(".raw-viewer/config.yaml"),
        "schema_version: 1\nprofiles:\n  unknown_field: true\n",
    )
    .unwrap();

    let err = load_project_config_with_fallback(&tmp).expect_err("unknown key must fail");
    let msg = err.to_string();
    assert!(msg.contains("unknown_field"), "message was: {msg}");

    let _ = fs::remove_dir_all(&tmp);
}

#[test]
fn two_matching_profiles_yields_ambiguous_profile() {
    let tmp = temp_project();
    fs::create_dir_all(tmp.join(".raw-viewer/profiles")).unwrap();
    // Add a second profile that also matches "LabVIEW Measurement"
    let competing_profile = r#"schema_version: 4
id: other/competing-keithley
revision: 1
instrument:
  id: competing-keithley
  name: Competing Keithley
variants:
  dual-sweep:
    when:
      content_contains_any:
        - LabVIEW Measurement
    format:
      kind: tabular
      extensions: [".txt"]
      delimiter: "\t"
    rows:
      names_prefix: X_Value
      data_prefix: ""
    metadata: []
    columns:
      voltage:
        role: channel
        header: Untitled
        quantity: voltage
        unit: V
      current:
        role: channel
        header: Untitled 1
        quantity: current
        unit: A
    plot:
      x: voltage
      y: [current]
"#;
    fs::write(tmp.join(".raw-viewer/profiles/competing.yaml"), competing_profile).unwrap();

    let file_rel = Path::new("data/raw/sample.txt");
    fs::create_dir_all(tmp.join("data/raw")).unwrap();
    fs::write(tmp.join(file_rel), STANDARD_KEITHLEY_SOURCE).unwrap();

    let err = load_measurement(&tmp, file_rel).expect_err("two hits must produce ambiguous_profile");
    let msg = err.to_string();
    assert!(msg.contains("ambiguous_profile"), "message was: {msg}");
    assert!(msg.contains("2 candidate(s)"), "message was: {msg}");

    let _ = fs::remove_dir_all(&tmp);
}
