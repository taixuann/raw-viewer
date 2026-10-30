use raw_viewer_core::reader::load_measurement;
use std::fs;
use std::path::Path;

const GRAMMAR_YAML: &str = r#"schema_version: 1
grammars:
  - id: electrochem
    name: Electrochem Filenames
    template: "{instrument}.{mode}_{sample}"
    fields:
      - name: instrument
        role: instrument
        type: string
        optional: false
      - name: mode
        role: mode
        type: string
        optional: false
      - name: sample
        role: sample
        type: string
        optional: false
"#;

const ACME_PROFILE: &str = r#"schema_version: 3
identity:
  id: acme
  name: Acme Lab
  instrument:
    id: acme-inst
    name: Acme Instrument
filename:
  grammar_id: electrochem
  variant_keys:
    - instrument
    - mode
variants:
  - id: cv
    name: CV
    key_values:
      instrument: acme
      mode: cv
    raw_stream:
      extensions:
        - ".txt"
      encoding:
        - utf-8
      delimiter: ","
      decimal_separator: "."
      rows:
        header:
          row: 2
        data_start:
          after_header: true
        excluded_metadata: []
      columns:
        - id: potential
          source:
            header: Volts
            aliases: []
          label: Voltage
          quantity: voltage
          unit: V
          required: true
          role: channel
          axes:
            - x
        - id: current
          source:
            header: Amps
            aliases: []
          label: Current
          quantity: current
          unit: A
          required: true
          role: channel
          axes:
            - y
    metadata: []
    metadata_capture:
      - kind: pre_header_fields
    default_plot:
      x: potential
      y:
        - current
  - id: ca
    name: CA
    key_values:
      instrument: acme
      mode: ca
    raw_stream:
      extensions:
        - ".txt"
      encoding:
        - utf-8
      delimiter: ","
      decimal_separator: "."
      rows:
        header:
          row: 2
        data_start:
          after_header: true
        excluded_metadata: []
      columns:
        - id: elapsed
          source:
            header: Secs
            aliases: []
          label: Time
          quantity: time
          unit: s
          required: true
          role: channel
          axes:
            - x
        - id: current
          source:
            header: mAmps
            aliases: []
          label: Current
          quantity: current
          unit: mA
          required: true
          role: channel
          axes:
            - y
    metadata: []
    metadata_capture:
      - kind: pre_header_fields
    default_plot:
      x: elapsed
      y:
        - current
"#;

const CV_CSV: &str = "Run, acme-cv-1
Volts, Amps
1.0, 10.0
2.0, 20.0

";

fn write_project(root: &Path) {
    fs::create_dir_all(root.join(".rawviewer")).unwrap();
    fs::write(root.join(".rawviewer/grammar.yaml"), GRAMMAR_YAML).unwrap();
    fs::create_dir_all(root.join("data/instruments")).unwrap();
    fs::create_dir_all(root.join("data/raw")).unwrap();
    fs::write(root.join("data/instruments/acme.yaml"), ACME_PROFILE).unwrap();
    fs::write(root.join("data/raw/acme.cv_run1.txt"), CV_CSV).unwrap();
}

#[test]
fn acme_profile_loads_as_v3_document() {
    let outcome =
        raw_viewer_core::profile::validate_document(ACME_PROFILE, "data/instruments/acme.yaml");
    assert!(
        outcome.v3_document.is_some(),
        "expected v3 document, issues: {:?}",
        outcome.issues
    );
}

#[test]
fn v3_acme_cv_loads_potential_and_current() {
    let root = std::env::temp_dir().join(format!("rawview-v3-acme-{}", std::process::id()));
    let _ = fs::remove_dir_all(&root);
    write_project(&root);

    let measurement =
        load_measurement(&root, Path::new("data/raw/acme.cv_run1.txt")).expect("load measurement");

    let potential: Vec<Option<f64>> = measurement
        .channel("potential")
        .expect("potential channel")
        .values
        .clone();
    let current: Vec<Option<f64>> = measurement
        .channel("current")
        .expect("current channel")
        .values
        .clone();

    assert_eq!(potential, vec![Some(1.0), Some(2.0)]);
    assert_eq!(current, vec![Some(10.0), Some(20.0)]);
    assert_eq!(measurement.provenance.get("variant_id").map(String::as_str), Some("cv"));
    assert_eq!(
        measurement.provenance.get("profile_schema_version").map(String::as_str),
        Some("3")
    );
    assert_eq!(
        measurement.provenance.get("grammar_id").map(String::as_str),
        Some("electrochem")
    );

    let _ = fs::remove_dir_all(root);
}
