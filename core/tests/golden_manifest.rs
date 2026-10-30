//! Compare Rust reader output to committed Swift golden JSON for each manifest case.

use raw_viewer_core::measurement::NormalizedMeasurement;
use raw_viewer_core::reader::load_measurement;
use serde_json::Value;
use std::fs;
use std::path::{Path, PathBuf};

const MANIFEST: &str = include_str!("fixtures/manifest.json");

#[derive(serde::Deserialize)]
struct Manifest {
    cases: Vec<Case>,
}

#[derive(serde::Deserialize)]
struct Case {
    id: String,
    #[serde(default)]
    grammar_file: Option<String>,
    #[serde(default)]
    profile_files: std::collections::BTreeMap<String, String>,
    source_files: std::collections::BTreeMap<String, String>,
    source_to_load: String,
}

fn fixtures_root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures")
}

fn golden_path(id: &str) -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("tests/golden")
        .join(format!("{id}.json"))
}

fn write_case_project(root: &Path, case: &Case) {
    let base = fixtures_root();
    if let Some(grammar_rel) = &case.grammar_file {
        let src = base.join(grammar_rel);
        let dest = root.join(".rawviewer/grammar.yaml");
        fs::create_dir_all(dest.parent().unwrap()).unwrap();
        fs::copy(&src, &dest).unwrap_or_else(|err| {
            panic!(
                "copy grammar {} -> {}: {err}",
                src.display(),
                dest.display()
            )
        });
    }
    for (dest, src_rel) in &case.profile_files {
        let src = base.join(src_rel);
        let dest_path = root.join("data/instruments").join(dest);
        fs::create_dir_all(dest_path.parent().unwrap()).unwrap();
        fs::copy(&src, &dest_path).unwrap_or_else(|err| {
            panic!(
                "copy profile {} -> {}: {err}",
                src.display(),
                dest_path.display()
            )
        });
    }
    for (dest, src_rel) in &case.source_files {
        let src = base.join(src_rel);
        let dest_path = root.join(dest);
        fs::create_dir_all(dest_path.parent().unwrap()).unwrap();
        fs::copy(&src, &dest_path).unwrap_or_else(|err| {
            panic!(
                "copy source {} -> {}: {err}",
                src.display(),
                dest_path.display()
            )
        });
    }
}

fn load_expected_golden(id: &str) -> Value {
    let text = fs::read_to_string(golden_path(id))
        .unwrap_or_else(|err| panic!("read golden {}: {err}", golden_path(id).display()));
    serde_json::from_str(&text).unwrap_or_else(|err| panic!("parse golden {id}: {err}"))
}

fn write_golden(id: &str, value: &Value) {
    let path = golden_path(id);
    let text = serde_json::to_string(value).expect("serialize golden");
    fs::write(&path, text).unwrap_or_else(|err| panic!("write {}: {err}", path.display()));
}

#[test]
fn manifest_cases_match_swift_golden_json() {
    let write_mode = std::env::var("RAWVIEW_WRITE_RUST_GOLDENS").ok().as_deref() == Some("1");
    let manifest: Manifest = serde_json::from_str(MANIFEST).expect("parse manifest");
    assert!(
        !manifest.cases.is_empty(),
        "manifest must list at least one case"
    );

    let mut fixture_count = 0usize;
    let mut point_count = 0usize;

    for case in &manifest.cases {
        let root = std::env::temp_dir().join(format!(
            "rawview-golden-{}-{}-{}",
            case.id,
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        let _ = fs::remove_dir_all(&root);
        write_case_project(&root, case);

        let measurement = load_measurement(&root, Path::new(&case.source_to_load))
            .unwrap_or_else(|err| panic!("{} load {}: {err}", case.id, case.source_to_load));

        let actual = measurement.to_golden_json();
        if write_mode {
            write_golden(&case.id, &actual);
            continue;
        }
        let expected = load_expected_golden(&case.id);
        assert_eq!(
            actual,
            expected,
            "{}: Rust golden JSON differs from {}",
            case.id,
            golden_path(&case.id).display()
        );

        fixture_count += 1;
        if let Some(rows) = measurement.channels.first() {
            point_count += rows.values.len();
        }

        let round_trip =
            NormalizedMeasurement::from_golden_json(&actual).expect("round-trip golden json");
        assert_eq!(
            round_trip.to_golden_json(),
            actual,
            "{}: golden round-trip must be stable",
            case.id
        );

        let _ = fs::remove_dir_all(&root);
    }

    eprintln!("golden manifest: compared {fixture_count} fixtures, {point_count} acquisition rows");
}
