use raw_viewer_core::reader::load_measurement;
use std::fs;
use std::path::Path;

const SIMPLE_CSV: &str = "Voltage (V),Current (A)
0.0,1.0e-9
0.1,2.0e-9
0.2,3.0e-9
";

fn write_project(root: &Path) {
    fs::create_dir_all(root.join("data/raw")).unwrap();
    fs::write(root.join("data/raw/simple.csv"), SIMPLE_CSV).unwrap();
}

#[test]
fn generic_table_loads_unprofiled_delimited_csv() {
    let root = std::env::temp_dir().join(format!("rawview-generic-table-{}", std::process::id()));
    let _ = fs::remove_dir_all(&root);
    write_project(&root);

    let measurement = load_measurement(&root, Path::new("data/raw/simple.csv")).expect("load");

    assert_eq!(measurement.instrument.id, "generic-table");
    assert_eq!(measurement.application_mode.as_deref(), Some("table-view"));
    assert_eq!(measurement.view.x.as_deref(), Some("col_0"));
    assert_eq!(
        measurement.view.y.as_deref(),
        Some(&["col_1".to_string()][..])
    );

    let x = measurement
        .channel("col_0")
        .expect("x")
        .values
        .iter()
        .map(|v| v.expect("finite x"))
        .collect::<Vec<_>>();
    let y = measurement
        .channel("col_1")
        .expect("y")
        .values
        .iter()
        .map(|v| v.expect("finite y"))
        .collect::<Vec<_>>();
    assert_eq!(x, vec![0.0, 0.1, 0.2]);
    assert!((y[0] - 1e-9).abs() < 1e-15);
    assert!((y[1] - 2e-9).abs() < 1e-15);
    assert!((y[2] - 3e-9).abs() < 1e-15);

    assert_eq!(
        measurement.provenance.get("reader_version"),
        Some(&raw_viewer_core::reader::READER_VERSION.to_string())
    );
    assert_eq!(
        measurement.provenance.get("reader"),
        Some(&"GenericTableReader".to_string())
    );
}
