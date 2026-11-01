//! V4 variant `metadata` scalar lists drive tabular Acquisition header filtering.

use raw_viewer_core::reader::load_measurement;
use std::fs;
use std::path::{Path, PathBuf};

fn temp_project() -> PathBuf {
    static NEXT: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
    let dir = std::env::temp_dir().join(format!(
        "rawview-v4-meta-{}-{}",
        std::process::id(),
        NEXT.fetch_add(1, std::sync::atomic::Ordering::Relaxed)
    ));
    let _ = fs::remove_dir_all(&dir);
    fs::create_dir_all(dir.join("data/raw")).unwrap();
    fs::create_dir_all(dir.join(".rawviewer")).unwrap();
    fs::write(
        dir.join(".rawviewer/setting.yaml"),
        "schema_version: 1\ndata_root: data/raw\ndefault_view: tree\ndefault_preset: nature-single\n",
    )
    .unwrap();
    dir
}

const FILTERED_PROFILE: &str = r#"schema_version: 4
id: test/acquisition-filter
instrument:
  id: demo
  name: Demo
variants:
  sweep:
    when:
      content_contains_any: [ACQ-META-MARKER]
    format:
      kind: tabular
      extensions: [".txt"]
      delimiter: "\t"
      encoding: [utf-8]
    rows:
      names_prefix: DataName
      data_prefix: DataValue
    metadata:
      - Alpha
      - Beta
    columns:
      voltage:
        role: channel
        header: voltage
        quantity: voltage
        unit: V
        label: Voltage
      current:
        role: channel
        header: current
        quantity: current
        unit: A
        label: Current
    plot:
      x: voltage
      y: [current]
"#;

const PLAIN_PROFILE: &str = r#"schema_version: 4
id: test/acquisition-plain
instrument:
  id: demo
  name: Demo
variants:
  sweep:
    when:
      content_contains_any: [ACQ-META-MARKER]
    format:
      kind: tabular
      extensions: [".txt"]
      delimiter: "\t"
      encoding: [utf-8]
    rows:
      names_prefix: DataName
      data_prefix: DataValue
    metadata: []
    columns:
      voltage:
        role: channel
        header: voltage
        quantity: voltage
        unit: V
        label: Voltage
      current:
        role: channel
        header: current
        quantity: current
        unit: A
        label: Current
    plot:
      x: voltage
      y: [current]
"#;

const SAMPLE: &str = "ACQ-META-MARKER\t\nAlpha\tfirst\nExtra\tignored\nBeta\tsecond\nDataName\tvoltage\tcurrent\nDataValue\t0\t1.0e-9\n";

fn acquisition_keys(
    measurement: &raw_viewer_core::measurement::NormalizedMeasurement,
) -> Vec<String> {
    measurement
        .metadata_sections
        .iter()
        .filter(|s| s.title == "Acquisition")
        .flat_map(|s| s.fields.iter().map(|f| f.key.clone()))
        .collect()
}

#[test]
fn v4_profile_metadata_scalars_filter_acquisition_headers() {
    let root = temp_project();
    fs::create_dir_all(root.join(".raw-viewer/profiles")).unwrap();
    fs::write(
        root.join(".raw-viewer/profiles/filter.yaml"),
        FILTERED_PROFILE,
    )
    .unwrap();
    fs::write(root.join("data/raw/sample.txt"), SAMPLE).unwrap();
    let measurement =
        load_measurement(&root, Path::new("data/raw/sample.txt")).expect("load filtered");
    assert_eq!(acquisition_keys(&measurement), vec!["Alpha", "Beta"]);
    let alpha = measurement
        .metadata_sections
        .iter()
        .flat_map(|s| s.fields.iter())
        .find(|f| f.key == "Alpha")
        .expect("Alpha field");
    assert_eq!(
        alpha.value,
        raw_viewer_core::measurement::JSONValue::String("first".into())
    );
}

#[test]
fn v4_profile_without_metadata_scalars_leaves_headers_unchanged() {
    let root = temp_project();
    fs::create_dir_all(root.join(".raw-viewer/profiles")).unwrap();
    fs::write(root.join(".raw-viewer/profiles/plain.yaml"), PLAIN_PROFILE).unwrap();
    fs::write(root.join("data/raw/sample.txt"), SAMPLE).unwrap();
    let measurement =
        load_measurement(&root, Path::new("data/raw/sample.txt")).expect("load plain");
    let keys = acquisition_keys(&measurement);
    assert!(
        keys.iter().any(|k| k == "Extra"),
        "expected unfiltered Extra, got {keys:?}"
    );
    assert!(keys.iter().any(|k| k == "Alpha"));
}
