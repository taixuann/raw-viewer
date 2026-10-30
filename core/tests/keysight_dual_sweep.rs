use raw_viewer_core::reader::load_measurement;
use std::fs;
use std::path::Path;

const KEYSIGHT_PROFILE: &str = r#"schema_version: 1
instrument:
  id: keysight-b1500a
  name: Keysight B1500A Semiconductor Device Parameter Analyzer
  vendor: Keysight Technologies
  model: B1500A
formats:
  - id: csv
    kind: tabular
    extensions: [".csv"]
    delimiter: ","
    encoding: [utf-8, windows-1252, iso-8859-1]
    rows:
      names_prefix: "DataName"
      data_prefix: "DataValue"
    columns:
      voltage:
        header: "V1"
        quantity: voltage
        unit: "V"
        label: "Voltage"
      current:
        header: "I2"
        aliases: ["I1"]
        quantity: current
        unit: "A"
        label: "Current"
modes:
  - id: dual-sweep
    format: csv
    detect: ["2-terminal dual Vsweep", "dual Vsweep"]
    extract:
      x: voltage
      y: [current]
"#;

const DUAL_SWEEP_CSV: &str = "\u{feff}SetupTitle, 2-terminal dual Vsweep
ApplicationTest, 2-terminal dual Vsweep, Public
Dimension1, 5, 5
DataName, V1, I1
DataValue, 0, 1E-12
DataValue, 0.1, 2E-12
DataValue, 0.2, 3E-12
DataValue, 0.1, 4E-12
DataValue, 0, 5E-12
";

fn write_project(root: &Path) {
    fs::create_dir_all(root.join("data/instruments")).unwrap();
    fs::create_dir_all(root.join("data/raw/fixture-run")).unwrap();
    fs::write(
        root.join("data/instruments/keysight-b1500a.yaml"),
        KEYSIGHT_PROFILE,
    )
    .unwrap();
    fs::write(
        root.join("data/raw/fixture-run/dual-sweep.csv"),
        DUAL_SWEEP_CSV,
    )
    .unwrap();
}

#[test]
fn keysight_dual_sweep_loads_voltage_and_current() {
    let root = std::env::temp_dir().join(format!("rawview-keysight-{}", std::process::id()));
    let _ = fs::remove_dir_all(&root);
    write_project(&root);

    let measurement = load_measurement(&root, Path::new("data/raw/fixture-run/dual-sweep.csv"))
        .expect("load measurement");

    let voltage: Vec<Option<f64>> = measurement
        .channel("voltage")
        .expect("voltage channel")
        .values
        .clone();
    let current: Vec<Option<f64>> = measurement
        .channel("current")
        .expect("current channel")
        .values
        .clone();

    assert_eq!(
        voltage,
        vec![Some(0.0), Some(0.1), Some(0.2), Some(0.1), Some(0.0)]
    );
    assert_eq!(
        current,
        vec![
            Some(1e-12),
            Some(2e-12),
            Some(3e-12),
            Some(4e-12),
            Some(5e-12),
        ]
    );
    assert_eq!(measurement.instrument.id, "keysight-b1500a");
    assert_eq!(measurement.application_mode.as_deref(), Some("dual-sweep"));
    assert_eq!(
        measurement.provenance.get("profile_id").map(String::as_str),
        Some("keysight-b1500a")
    );

    let _ = fs::remove_dir_all(root);
}
