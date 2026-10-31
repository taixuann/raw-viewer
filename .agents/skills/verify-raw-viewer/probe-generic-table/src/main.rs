use raw_viewer_core::reader::load_measurement;
use std::fs;
use std::path::Path;

const SIMPLE_CSV: &str = "Voltage (V),Current (A)
0.0,1.0e-9
0.1,2.0e-9
0.2,3.0e-9
";

fn main() {
    let root = std::env::temp_dir().join(format!(
        "rawview-verify-probe-{}",
        std::process::id()
    ));
    let _ = fs::remove_dir_all(&root);
    fs::create_dir_all(root.join("data/raw")).expect("create data/raw");
    fs::write(root.join("data/raw/simple.csv"), SIMPLE_CSV).expect("write csv");

    let measurement =
        load_measurement(&root, Path::new("data/raw/simple.csv")).expect("load_measurement");

    println!("instrument={}", measurement.instrument.id);
    println!(
        "application_mode={}",
        measurement.application_mode.as_deref().unwrap_or("")
    );
    println!("view_x={}", measurement.view.x.as_deref().unwrap_or(""));
    let y = measurement
        .view
        .y
        .as_ref()
        .map(|cols| format!("[{}]", cols.join(", ")))
        .unwrap_or_else(|| "[]".into());
    println!("view_y={y}");

    let _ = fs::remove_dir_all(&root);
}
