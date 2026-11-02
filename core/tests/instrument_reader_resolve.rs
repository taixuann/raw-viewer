//! Reader-level typed resolve codes (parity with Swift InstrumentReaderTests).

use raw_viewer_core::profile::{profile_inspection_resolve_code, ProfileResolveCode};
use raw_viewer_core::reader::{load_measurement, ReaderError};
use std::fs;
use std::path::{Path, PathBuf};

const SYNTH_GRAMMAR_YAML: &str = r#"schema_version: 1
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

const SYNTH_V2: &str = r#"schema_version: 2
instrument:
  id: synth
  name: Synth
formats:
  - id: csv
    kind: tabular
    extensions: [".csv"]
    delimiter: ","
    encoding: [utf-8]
    rows:
      names_prefix: DataName
      data_prefix: DataValue
    columns:
      voltage:
        header: V1
        quantity: voltage
        unit: V
      current:
        header: I1
        quantity: current
        unit: A
modes:
  - id: dual-sweep
    format: csv
    detect: [SYNTH-SPECIFIC-HEADER]
    filename_contains_all: [synth-token, dual-sweep]
    extract:
      x: voltage
      y: [current]
"#;

const SYNTH_CSV: &str = "SetupTitle, SYNTH-SPECIFIC-HEADER\nDataName, V1, I1\n";

const SYNTH_FILENAME_AMBIGUOUS: &str = r#"schema_version: 2
instrument:
  id: synth
  name: Synth
formats:
  - id: csv
    kind: tabular
    extensions: [".csv"]
    delimiter: ","
    encoding: [utf-8]
    rows:
      names_prefix: DataName
      data_prefix: DataValue
    columns:
      voltage:
        header: V1
        quantity: voltage
        unit: V
      current:
        header: I1
        quantity: current
        unit: A
modes:
  - id: dual-sweep
    format: csv
    detect: [SYNTH-SPECIFIC-HEADER]
    filename_contains_all: [synth-token, dual-sweep]
    extract:
      x: voltage
      y: [current]
"#;

const GRAMMAR_MISS_V4: &str = r#"schema_version: 4
id: test/grammar-miss
instrument:
  id: synth
  name: Synth
when:
  mode: list-sweep
variants:
  dual-sweep:
    when:
      content_contains_any: [SYNTH-SPECIFIC-HEADER]
    format:
      kind: tabular
      extensions: [".txt"]
      delimiter: ","
      encoding: [utf-8]
    rows:
      names_prefix: DataName
      data_prefix: DataValue
    metadata: []
    columns:
      voltage:
        role: channel
        header: V1
        quantity: voltage
        unit: V
      current:
        role: channel
        header: I1
        quantity: current
        unit: A
    plot:
      x: voltage
      y: [current]
"#;

const V3_AMBIGUOUS: &str = r#"schema_version: 3
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
      extensions: [".txt"]
      encoding: [utf-8]
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
          axes: [x]
        - id: current
          source:
            header: Amps
            aliases: []
          label: Current
          quantity: current
          unit: A
          required: true
          role: channel
          axes: [y]
    metadata: []
    metadata_capture:
      - kind: pre_header_fields
    default_plot:
      x: potential
      y: [current]
  - id: cv-b
    name: CV B
    key_values:
      instrument: acme
      mode: cv
    raw_stream:
      extensions: [".txt"]
      encoding: [utf-8]
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
          axes: [x]
        - id: current
          source:
            header: Amps
            aliases: []
          label: Current
          quantity: current
          unit: A
          required: true
          role: channel
          axes: [y]
    metadata: []
    metadata_capture:
      - kind: pre_header_fields
    default_plot:
      x: potential
      y: [current]
"#;

const V3_CV_CSV: &str = "Run, acme-cv-1\nVolts, Amps\n1.0, 10.0\n2.0, 20.0\n";

fn temp_project() -> PathBuf {
    static NEXT: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
    let dir = std::env::temp_dir().join(format!(
        "rawview-reader-resolve-{}-{}",
        std::process::id(),
        NEXT.fetch_add(1, std::sync::atomic::Ordering::Relaxed)
    ));
    let _ = fs::remove_dir_all(&dir);
    fs::create_dir_all(dir.join("data/raw")).unwrap();
    fs::create_dir_all(dir.join(".raw-viewer")).unwrap();
    fs::write(
        dir.join(".raw-viewer/config.yaml"),
        "schema_version: 1\ndata_root: data/raw\ndefault_view: tree\ndefault_preset: nature-single\n",
    )
    .unwrap();
    dir
}

fn invalid_message(err: ReaderError) -> String {
    match err {
        ReaderError::InvalidSource(message) => message,
        other => panic!("expected InvalidSource, got {other:?}"),
    }
}

#[test]
fn reader_ambiguous_profile_exposes_typed_code() {
    let root = temp_project();
    fs::create_dir_all(root.join("data/instruments")).unwrap();
    fs::write(root.join("data/instruments/a.yaml"), SYNTH_V2).unwrap();
    fs::write(
        root.join("data/instruments/b.yaml"),
        SYNTH_V2.replace(
            "id: synth\n  name: Synth",
            "id: synth-alt\n  name: Synth Alt",
        ),
    )
    .unwrap();
    fs::write(
        root.join("data/raw/run_synth-token_dual-sweep.csv"),
        SYNTH_CSV,
    )
    .unwrap();
    let err = load_measurement(&root, Path::new("data/raw/run_synth-token_dual-sweep.csv"))
        .expect_err("ambiguous");
    let message = invalid_message(err);
    assert_eq!(
        profile_inspection_resolve_code(&message),
        Some(ProfileResolveCode::AmbiguousProfile)
    );
    assert!(message.contains("synth"));
}

#[test]
fn reader_filename_selector_ambiguity_exposes_typed_code() {
    let root = temp_project();
    fs::create_dir_all(root.join("data/instruments")).unwrap();
    fs::write(
        root.join("data/instruments/a.yaml"),
        SYNTH_FILENAME_AMBIGUOUS,
    )
    .unwrap();
    fs::write(
        root.join("data/instruments/b.yaml"),
        SYNTH_FILENAME_AMBIGUOUS.replace(
            "id: synth\n  name: Synth",
            "id: synth-copy\n  name: Synth Copy",
        ),
    )
    .unwrap();
    fs::write(
        root.join("data/raw/run_synth-token_dual-sweep.csv"),
        "SetupTitle, SYNTH-SPECIFIC-HEADER\nDataName, V1, I1\nDataValue, 0, 1E-12\n",
    )
    .unwrap();
    let err = load_measurement(&root, Path::new("data/raw/run_synth-token_dual-sweep.csv"))
        .expect_err("ambiguous filename selector");
    let message = invalid_message(err);
    assert_eq!(
        profile_inspection_resolve_code(&message),
        Some(ProfileResolveCode::AmbiguousProfile)
    );
    assert!(message.contains("synth-copy"));
}

#[test]
fn reader_grammar_matched_no_profile_exposes_typed_code() {
    let root = temp_project();
    fs::create_dir_all(root.join(".rawviewer")).unwrap();
    fs::write(root.join(".rawviewer/grammar.yaml"), SYNTH_GRAMMAR_YAML).unwrap();
    fs::create_dir_all(root.join("data/instruments")).unwrap();
    fs::write(root.join("data/instruments/x.yaml"), GRAMMAR_MISS_V4).unwrap();
    fs::write(root.join("data/raw/acme.cv_run1.txt"), SYNTH_CSV).unwrap();
    let err = load_measurement(&root, Path::new("data/raw/acme.cv_run1.txt"))
        .expect_err("grammar matched but profile when.mode mismatch");
    let message = invalid_message(err);
    assert_eq!(
        profile_inspection_resolve_code(&message),
        Some(ProfileResolveCode::GrammarMatchedNoProfile)
    );
}

#[test]
fn reader_v3_ambiguous_profile_exposes_typed_code() {
    let root = temp_project();
    fs::create_dir_all(root.join(".rawviewer")).unwrap();
    fs::write(root.join(".rawviewer/grammar.yaml"), SYNTH_GRAMMAR_YAML).unwrap();
    fs::create_dir_all(root.join(".rawviewer/instrument")).unwrap();
    fs::write(root.join(".rawviewer/instrument/acme.yaml"), V3_AMBIGUOUS).unwrap();
    fs::write(root.join("data/raw/acme.cv_run1.txt"), V3_CV_CSV).unwrap();
    let err =
        load_measurement(&root, Path::new("data/raw/acme.cv_run1.txt")).expect_err("v3 ambiguous");
    let message = invalid_message(err);
    assert_eq!(
        profile_inspection_resolve_code(&message),
        Some(ProfileResolveCode::SchemaV3AmbiguousProfile)
    );
    assert!(message.contains("cv-b"));
}
