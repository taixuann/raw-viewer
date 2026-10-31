//! Schema-v4 profile validation and compatibility with legacy schemas.

use raw_viewer_core::profile::{parse_profile_v4, validate_document};

#[test]
fn v1_v2_v3_fixtures_still_load() {
    for (path, yaml) in [
        (
            "compat/keysight-b1500a-v1.yaml",
            include_str!("fixtures/profiles/compat/keysight-b1500a-v1.yaml"),
        ),
        (
            "compat/keysight-b1500a-v2.yaml",
            include_str!("fixtures/profiles/compat/keysight-b1500a-v2.yaml"),
        ),
        (
            "acme-v3.yaml",
            include_str!("fixtures/profiles/acme-v3.yaml"),
        ),
    ] {
        let outcome = validate_document(yaml, path);
        assert!(
            outcome.issues.is_empty(),
            "{path}: {}",
            outcome.issues.join("\n")
        );
        if path.contains("v3") {
            assert!(outcome.v3_document.is_some(), "{path}");
        } else {
            assert!(outcome.profile.is_some(), "{path}");
        }
    }
}

#[test]
fn unsupported_schema_version_lists_v4() {
    let yaml = include_str!("fixtures/profiles/compat/keysight-b1500a-v1.yaml")
        .replace("schema_version: 1", "schema_version: 9");
    let outcome = validate_document(&yaml, "broken.yaml");
    let text = outcome.issues.join("\n");
    assert!(text.contains("unsupported schema_version 9"), "{text}");
    assert!(text.contains("schema_version 1, 2, 3, and 4"), "{text}");
}

#[test]
fn keysight_v4_profile_loads_and_compiles() {
    let yaml = include_str!("fixtures/profiles/keysight-b1500a.yaml");
    let outcome = validate_document(yaml, "keysight-b1500a.yaml");
    assert!(outcome.issues.is_empty(), "{}", outcome.issues.join("\n"));
    let profile = outcome.profile.expect("compiled profile");
    assert_eq!(profile.profile_id, "usth/keysight-b1500a");
    assert_eq!(profile.schema_version, 4);
    assert_eq!(profile.modes.len(), 7);
}

#[test]
fn progression_round_trip_rust() {
    let yaml = r#"schema_version: 4
id: usth/demo
instrument:
  id: demo
  name: Demo
variants:
  run:
    format:
      kind: tabular
      extensions: [".txt"]
      delimiter: ","
    rows:
      header: 1
      data_start: 2
    columns:
      t:
        role: progression
        type: time
        behavior: continuous
        header: T
        quantity: time
        unit: s
        label: Time
      i:
        role: progression
        type: index
        behavior: discrete
        header: I
        quantity: index
        unit: "1"
        label: Index
      c:
        role: channel
        header: C
        quantity: current
        unit: A
        label: Current
    plot:
      x: t
      y: [c]
    when:
      content_contains_any: ["demo"]
"#;
    let doc = parse_profile_v4(yaml).expect("parse");
    let t = &doc.variants["run"].columns["t"];
    assert_eq!(
        t.progression.as_ref().map(|p| p.progression_type.as_str()),
        Some("time")
    );
    assert_eq!(
        t.progression.as_ref().and_then(|p| p.behavior.as_deref()),
        Some("continuous")
    );
    let i = &doc.variants["run"].columns["i"];
    assert_eq!(
        i.progression.as_ref().map(|p| p.progression_type.as_str()),
        Some("index")
    );
    assert_eq!(
        i.progression.as_ref().and_then(|p| p.behavior.as_deref()),
        Some("discrete")
    );
}
