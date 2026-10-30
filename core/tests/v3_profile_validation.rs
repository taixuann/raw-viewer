//! Schema v3 profile validation (electrochem fixtures + unknown-key diagnostics).

use raw_viewer_core::profile::{parse_profile_v3, validate_document};

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
  - id: "ca"
    name: "CA"
    key_values:
      instrument: "acme"
      mode: "ca"
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
        - id: "elapsed"
          source:
            header: "Secs"
            aliases: []
          label: "Time"
          quantity: "time"
          unit: "s"
          required: true
          role: "channel"
          axes:
            - "x"
        - id: "current"
          source:
            header: "mAmps"
            aliases: []
          label: "Current"
          quantity: "current"
          unit: "mA"
          required: true
          role: "channel"
          axes:
            - "y"
    metadata: []
    metadata_capture:
      - kind: "pre_header_fields"
    default_plot:
      x: "elapsed"
      y:
        - "current"
"#;

#[test]
fn electrochem_v3_yaml_parses_and_loads() {
    let doc = parse_profile_v3(ELECTROCHEM_YAML).expect("parse electrochem v3 profile");
    assert_eq!(doc.profile_id, "acme");
    assert_eq!(doc.grammar_id, "electrochem");
    assert_eq!(doc.variants.len(), 2);
    assert_eq!(doc.variants[0].id, "cv");
    assert_eq!(doc.variants[1].id, "ca");

    let outcome = validate_document(ELECTROCHEM_YAML, "data/instruments/acme.yaml");
    assert!(outcome.profile.is_none());
    let loaded = outcome.v3_document.expect("valid v3 catalog entry");
    assert_eq!(loaded.relative_path, "data/instruments/acme.yaml");
    assert_eq!(loaded.document.profile_id, "acme");
}

#[test]
fn unknown_root_key_reports_schema_v3_field() {
    let yaml = format!("{ELECTROCHEM_YAML}\nbogus_root: 1\n");
    let err = parse_profile_v3(&yaml).unwrap_err();
    assert!(
        err.message().contains("unknown key \"bogus_root\""),
        "{}",
        err.message()
    );
    assert!(err.message().contains("schema v3"), "{}", err.message());

    let outcome = validate_document(&yaml, "data/instruments/acme.yaml");
    assert!(outcome.v3_document.is_none());
    let text = outcome.issues.join("\n");
    assert!(text.contains("data/instruments/acme.yaml"), "{text}");
    assert!(text.contains("bogus_root"), "{text}");
}
