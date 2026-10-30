//! Profile schema validation diagnostics must name the profile path and field.

use raw_viewer_core::profile::validate_document;

fn issues_joined(outcome: &raw_viewer_core::profile::ProfileLoadOutcome) -> String {
    outcome.issues.join("\n")
}

#[test]
fn unversioned_profile_names_path_and_migration_hint() {
    let yaml = r#"instrument:
  id: keysight-b1500a
  name: Keysight B1500A
formats:
  - id: csv
    extensions: [".csv"]
    delimiter: ","
    rows:
      names_prefix: "DataName"
      data_prefix: "DataValue"
    columns:
      voltage:
        header: "V1"
        unit: "V"
      current:
        header: "I1"
        unit: "A"
modes:
  - id: dual-sweep
    format: csv
    detect: ["2-terminal dual Vsweep"]
    extract:
      x: voltage
      y: [current]
"#;
    let outcome = validate_document(yaml, "data/instruments/keysight-b1500a.yaml");
    assert!(outcome.profile.is_none());
    let text = issues_joined(&outcome);
    assert!(
        text.contains("data/instruments/keysight-b1500a.yaml"),
        "{text}"
    );
    assert!(text.contains("unversioned"), "{text}");
    assert!(text.contains("schema_version: 1"), "{text}");
}

#[test]
fn missing_unit_names_profile_and_field() {
    let yaml = include_str!("fixtures/profiles/keysight-b1500a.yaml")
        .replace("unit: \"V\"", "unit_label: \"V\"");
    let outcome = validate_document(&yaml, "data/instruments/missing-unit.yaml");
    assert!(outcome.profile.is_none());
    let text = issues_joined(&outcome);
    assert!(text.contains("missing-unit.yaml"), "{text}");
    assert!(text.contains("columns.voltage.unit"), "{text}");
}

#[test]
fn unsupported_schema_version_is_actionable() {
    let yaml = include_str!("fixtures/profiles/keysight-b1500a.yaml")
        .replace("schema_version: 1", "schema_version: 9");
    let outcome = validate_document(&yaml, "data/instruments/keysight-b1500a.yaml");
    assert!(outcome.profile.is_none());
    let text = issues_joined(&outcome);
    assert!(text.contains("unsupported schema_version 9"), "{text}");
    assert!(text.contains("schema_version 1, 2, and 3"), "{text}");
}

#[test]
fn unknown_top_level_key_names_field() {
    let yaml = format!(
        "{}\ntheme: dark\n",
        include_str!("fixtures/profiles/keysight-b1500a.yaml")
    );
    let outcome = validate_document(&yaml, "data/instruments/keysight-b1500a.yaml");
    assert!(outcome.profile.is_none());
    let text = issues_joined(&outcome);
    assert!(text.contains("unknown key \"theme\""), "{text}");
}
