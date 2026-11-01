//! Profile catalog discovery precedence (issue #18, contract 18c-2).

use raw_viewer_core::profile::load_catalog;
use raw_viewer_core::reader::load_measurement;
use std::fs;
use std::path::{Path, PathBuf};

fn repo_root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("..")
}

fn temp_project() -> PathBuf {
    static NEXT: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
    let dir = std::env::temp_dir().join(format!(
        "rawview-catalog-{}-{}-{}",
        std::process::id(),
        NEXT.fetch_add(1, std::sync::atomic::Ordering::Relaxed),
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos()
    ));
    fs::create_dir_all(&dir).unwrap();
    fs::create_dir_all(dir.join("data/raw")).unwrap();
    dir
}

fn write_keysight_v4(dir: &Path, relative: &str) {
    let yaml = include_str!("fixtures/profiles/keysight-b1500a.yaml");
    let path = dir.join(relative);
    fs::create_dir_all(path.parent().unwrap()).unwrap();
    fs::write(path, yaml).unwrap();
}

#[test]
fn usth_fixture_profiles_compile_with_tabular_row_markers() {
    let root = repo_root().join("fixtures/workspaces/usth-lab");
    let catalog = load_catalog(&root);
    assert!(catalog.issues.is_empty(), "{}", catalog.issues.join("; "));
    assert_eq!(catalog.profiles.len(), 4, "expected four usth v4 profiles");
    let keithley = catalog
        .profiles
        .iter()
        .find(|p| p.profile_id == "usth/keithley-2400")
        .expect("keithley profile");
    let format = keithley
        .formats
        .iter()
        .find(|f| f.id == "dual-sweep")
        .expect("dual-sweep format");
    assert_eq!(format.names_prefix.as_deref(), Some("X_Value"));
    assert_eq!(format.data_prefix.as_deref(), Some(""));
    assert_eq!(format.acquisition_header_keys.len(), 11);
}

#[test]
fn raw_viewer_profiles_directory_loads_and_takes_precedence() {
    let tmp = temp_project();
    write_keysight_v4(&tmp, ".raw-viewer/profiles/priority.yaml");
    write_keysight_v4(&tmp, "data/instruments/legacy.yaml");
    let catalog = load_catalog(&tmp);
    assert_eq!(catalog.profiles.len(), 1, "{}", catalog.issues.join("; "));
    assert!(
        catalog.profiles[0]
            .relative_path
            .replace('\\', "/")
            .starts_with(".raw-viewer/profiles/"),
        "expected .raw-viewer/profiles precedence, got {}",
        catalog.profiles[0].relative_path
    );
    assert_eq!(catalog.profiles[0].profile_id, "usth/keysight-b1500a");
}

#[test]
fn legacy_profile_directories_still_load_when_raw_viewer_profiles_absent() {
    let tmp = temp_project();
    write_keysight_v4(&tmp, "data/.rawview/instrument/legacy.yaml");
    let catalog = load_catalog(&tmp);
    assert_eq!(catalog.profiles.len(), 1);
    assert!(catalog.profiles[0]
        .relative_path
        .replace('\\', "/")
        .starts_with("data/.rawview/instrument/"));
}

#[test]
fn v3_acme_profile_end_to_end_resolve_from_rawviewer_instrument() {
    let tmp = temp_project();
    fs::create_dir_all(tmp.join(".rawviewer")).unwrap();
    fs::write(
        tmp.join(".rawviewer/grammar.yaml"),
        r#"schema_version: 1
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
"#,
    )
    .unwrap();
    fs::create_dir_all(tmp.join(".rawviewer/instrument")).unwrap();
    fs::copy(
        repo_root().join("core/tests/fixtures/profiles/acme-v3.yaml"),
        tmp.join(".rawviewer/instrument/acme.yaml"),
    )
    .unwrap();
    fs::write(
        tmp.join("data/raw/acme.cv_run1.txt"),
        "Run, acme-cv-1\nVolts, Amps\n1.0, 10.0\n2.0, 20.0\n",
    )
    .unwrap();
    let measurement =
        load_measurement(&tmp, Path::new("data/raw/acme.cv_run1.txt")).expect("v3 load");
    assert_eq!(
        measurement.provenance.get("profile_id").map(String::as_str),
        Some("acme")
    );
    assert_eq!(
        measurement.provenance.get("variant_id").map(String::as_str),
        Some("cv")
    );
}
