//! Real-data usth-lab workspace fixture checks (issue #27).
//!
//! Active tests verify committed bytes, row counts, profile axes, Keithley metadata
//! (date/time only), and three resolved Keithley columns. Discovery ignore rules and
//! header-only dispositions stay `#[ignore]` until the shared discovery port lands.

use raw_viewer_core::reader::{load_measurement, ReaderError};
use raw_viewer_core::yaml::{parse, YamlNode};
use sha2::{Digest, Sha256};
use std::fs;
use std::path::{Path, PathBuf};

const EXPECTED_YAML: &str = include_str!("../../fixtures/workspaces/usth-lab/expected.yaml");

fn repo_fixtures_root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../fixtures/workspaces/usth-lab")
}

fn legacy_root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../fixtures/legacy/usth-lab")
}

fn workspace_root() -> PathBuf {
    repo_fixtures_root()
}

fn sha256_file(path: &Path) -> String {
    let bytes = fs::read(path).unwrap_or_else(|err| panic!("read {}: {err}", path.display()));
    let digest = Sha256::digest(bytes);
    format!("{:x}", digest)
}

fn scalar(node: &YamlNode) -> &str {
    match node {
        YamlNode::Scalar(s) => s.as_str(),
        other => panic!("expected scalar, got {other:?}"),
    }
}

fn map_get<'a>(map: &'a [(String, YamlNode)], key: &str) -> &'a YamlNode {
    map.iter()
        .find(|(k, _)| k == key)
        .map(|(_, v)| v)
        .unwrap_or_else(|| panic!("missing map key {key}"))
}

fn optional_bool(map: &[(String, YamlNode)], key: &str) -> bool {
    match map_get(map, key) {
        YamlNode::Scalar(s) => match s.as_str() {
            "true" => true,
            "false" => false,
            other => panic!("{key}: not a bool: {other}"),
        },
        other => panic!("{key}: expected scalar bool, got {other:?}"),
    }
}

fn optional_usize(map: &[(String, YamlNode)], key: &str) -> usize {
    scalar(map_get(map, key)).parse().unwrap_or_else(|err| {
        panic!("{key}: {err}");
    })
}

fn parse_expected() -> YamlNode {
    parse(EXPECTED_YAML, false).expect("parse fixtures/workspaces/usth-lab/expected.yaml")
}

fn entries(doc: &YamlNode) -> Vec<&[(String, YamlNode)]> {
    let root = doc.map_entries().expect("expected root map");
    let list = map_get(root, "entries").list_items().expect("entries list");
    list.iter()
        .map(|item| item.map_entries().expect("entry map"))
        .collect()
}

fn count_keithley_data_rows(text: &str) -> usize {
    let lines: Vec<&str> = text.lines().collect();
    let mut end_markers = 0usize;
    let mut idx = 0usize;
    for (i, line) in lines.iter().enumerate() {
        if line.contains("***End_of_Header***") {
            end_markers += 1;
            if end_markers == 2 {
                idx = i;
                break;
            }
        }
    }
    lines
        .iter()
        .skip(idx + 2)
        .filter(|line| !line.trim().is_empty())
        .count()
}

fn count_delimited_data_rows(text: &str, _delimiter: char) -> usize {
    let mut lines = text.lines();
    let _header = lines.next();
    lines.filter(|line| !line.trim().is_empty()).count()
}

fn measured_row_count(relative: &str, text: &str) -> usize {
    if relative.contains("keithley-2400") && text.contains("LabVIEW Measurement") {
        return count_keithley_data_rows(text);
    }
    if relative.contains("autolab-usth") || relative.contains("horiba-labram") {
        return count_delimited_data_rows(text, ';');
    }
    if relative.contains("iop-hanoi") {
        return count_delimited_data_rows(text, ',');
    }
    0
}

#[test]
fn usth_lab_expected_entries_match_committed_files() {
    let root = workspace_root();
    let doc = parse_expected();
    let root_map = doc.map_entries().expect("root map");
    assert_eq!(scalar(map_get(root_map, "workspace_id")), "usth-lab");

    for entry in entries(&doc) {
        let relative = scalar(map_get(entry, "relative_path"));
        let path = root.join(relative);
        assert!(path.is_file(), "missing fixture file {}", path.display());

        let expected_size = optional_usize(entry, "size_bytes");
        let expected_hash = scalar(map_get(entry, "sha256"));
        let actual_size = fs::metadata(&path)
            .unwrap_or_else(|err| panic!("stat {}: {err}", path.display()))
            .len() as usize;
        assert_eq!(
            actual_size, expected_size,
            "{relative}: size_bytes drift (re-measure expected.yaml)"
        );
        assert_eq!(
            sha256_file(&path),
            expected_hash,
            "{relative}: sha256 drift"
        );

        if optional_bool(entry, "plottable") {
            let text = fs::read_to_string(&path)
                .unwrap_or_else(|err| panic!("read {}: {err}", path.display()));
            let expected_rows = optional_usize(entry, "data_row_count");
            let actual_rows = measured_row_count(relative, &text);
            assert_eq!(
                actual_rows, expected_rows,
                "{relative}: data_row_count mismatch (expected.yaml stale?)"
            );
        }
    }
}

#[test]
fn usth_lab_discovery_ignore_placeholders_exist() {
    let root = workspace_root();
    let doc = parse_expected();
    let root_map = doc.map_entries().expect("root map");
    let ignored = map_get(root_map, "discovery_ignored")
        .list_items()
        .expect("discovery_ignored list");
    assert_eq!(ignored.len(), 2, "intake log and quarantine placeholders");
    for item in ignored {
        let rel = scalar(item);
        let path = root.join(rel.trim_end_matches('/'));
        assert!(
            path.exists(),
            "discovery ignore placeholder missing: {}",
            path.display()
        );
    }
}

#[test]
fn usth_lab_legacy_migration_yaml_bundle_is_complete() {
    let legacy = legacy_root();
    let instruments: Vec<_> = fs::read_dir(legacy.join("instruments"))
        .expect("instruments dir")
        .filter_map(Result::ok)
        .filter(|e| e.path().extension().is_some_and(|ext| ext == "yaml"))
        .collect();
    assert_eq!(
        instruments.len(),
        6,
        "legacy instruments/*.yaml count for #24"
    );
    let rawview: Vec<_> = fs::read_dir(legacy.join("rawview/instrument"))
        .expect("rawview/instrument dir")
        .filter_map(Result::ok)
        .filter(|e| e.path().extension().is_some_and(|ext| ext == "yaml"))
        .collect();
    assert_eq!(
        rawview.len(),
        4,
        "legacy rawview/instrument/*.yaml count for #24"
    );
}

#[test]
fn usth_lab_spe_is_rejected_by_rust_reader() {
    let root = workspace_root();
    let relative = Path::new(
        "data/raw/2026-06-26/260626-000000_gtiit-xps.survey_[pda.q3-ito.3]_xps.characterization.spe",
    );
    let err = load_measurement(&root, relative).expect_err(".spe must not parse for plotting");
    match err {
        ReaderError::InvalidSource(message) => {
            assert!(message.contains(".spe"), "unexpected message: {message}");
        }
        other => panic!("expected InvalidSource for .spe, got {other:?}"),
    }
}

fn optional_string_list(map: &[(String, YamlNode)], key: &str) -> Vec<String> {
    match map_get(map, key) {
        YamlNode::List(items) => items.iter().map(|n| scalar(n).to_string()).collect(),
        YamlNode::Scalar(s) if s == "null" || s.is_empty() => vec![],
        other => panic!("{key}: expected list, got {other:?}"),
    }
}

fn channel_quantity<'a>(
    measurement: &'a raw_viewer_core::measurement::NormalizedMeasurement,
    axis_key: &str,
) -> (&'a str, &'a str) {
    let channel = measurement
        .channels
        .iter()
        .find(|c| c.name == axis_key)
        .unwrap_or_else(|| panic!("missing channel {axis_key}"));
    (
        channel.quantity.as_deref().unwrap_or(""),
        channel.unit.as_str(),
    )
}

fn metadata_keys(measurement: &raw_viewer_core::measurement::NormalizedMeasurement) -> Vec<String> {
    let mut keys: Vec<String> = measurement
        .metadata_sections
        .iter()
        .filter(|section| section.title == "Acquisition")
        .flat_map(|section| section.fields.iter().map(|f| f.key.clone()))
        .collect();
    keys.sort();
    keys.dedup();
    keys
}

/// Recorded in PR #18c-2: generic LVM `header_metadata` pulls second-block noise; v4 row metadata keeps first-block date/time only.
pub const KEITHLEY_LVM_PROBE_SUFFICIENT: bool = false;

#[test]
fn usth_lab_plottable_files_match_profile_axes() {
    let root = workspace_root();
    let doc = parse_expected();
    for entry in entries(&doc) {
        if !optional_bool(entry, "plottable") {
            continue;
        }
        let relative = scalar(map_get(entry, "relative_path"));
        let expected_profile = scalar(map_get(entry, "profile_id"));
        let expected_variant = scalar(map_get(entry, "variant"));
        let expected_x_q = scalar(map_get(entry, "x_quantity"));
        let expected_x_u = scalar(map_get(entry, "x_unit"));
        let expected_y_q = scalar(map_get(entry, "y_quantity"));
        let expected_y_u = scalar(map_get(entry, "y_unit"));
        let measurement = load_measurement(&root, Path::new(relative))
            .unwrap_or_else(|err| panic!("{relative}: load failed: {err}"));
        assert_eq!(
            measurement.provenance.get("profile_id").map(String::as_str),
            Some(expected_profile),
            "{relative}: profile_id"
        );
        assert_eq!(
            measurement.provenance.get("mode").map(String::as_str),
            Some(expected_variant),
            "{relative}: mode"
        );
        let x_key = measurement.view.x.as_deref().expect("view.x");
        let y_keys = measurement.view.y.as_ref().expect("view.y");
        let (x_q, x_u) = channel_quantity(&measurement, x_key);
        let (y_q, y_u) = channel_quantity(&measurement, &y_keys[0]);
        assert_eq!(x_q, expected_x_q, "{relative}: x quantity");
        assert_eq!(x_u, expected_x_u, "{relative}: x unit");
        assert_eq!(y_q, expected_y_q, "{relative}: y quantity");
        assert_eq!(y_u, expected_y_u, "{relative}: y unit");
    }
}

fn metadata_field_value(
    measurement: &raw_viewer_core::measurement::NormalizedMeasurement,
    key: &str,
) -> Option<String> {
    measurement
        .metadata_sections
        .iter()
        .filter(|section| section.title == "Acquisition")
        .flat_map(|section| section.fields.iter())
        .find(|field| field.key == key)
        .and_then(|field| match &field.value {
            raw_viewer_core::measurement::JSONValue::String(text) => Some(text.clone()),
            _ => None,
        })
}

fn channel_by_key<'a>(
    measurement: &'a raw_viewer_core::measurement::NormalizedMeasurement,
    key: &str,
) -> &'a raw_viewer_core::measurement::MeasurementChannel {
    measurement
        .channels
        .iter()
        .find(|c| c.name == key)
        .unwrap_or_else(|| panic!("missing channel {key}"))
}

#[test]
fn usth_lab_keithley_resolves_three_profile_columns() {
    let root = workspace_root();
    let doc = parse_expected();
    let entry = entries(&doc)
        .into_iter()
        .find(|e| scalar(map_get(e, "id")) == "keithley-dual-sweep")
        .expect("keithley entry");
    let relative = scalar(map_get(entry, "relative_path"));
    let measurement = load_measurement(&root, Path::new(relative))
        .unwrap_or_else(|err| panic!("{relative}: load failed: {err}"));
    assert_eq!(measurement.channels.len(), 3, "{relative}: channel count");
    let voltage = channel_by_key(&measurement, "voltage");
    assert_eq!(voltage.quantity.as_deref(), Some("voltage"));
    assert_eq!(voltage.unit, "V");
    let current = channel_by_key(&measurement, "current");
    assert_eq!(current.quantity.as_deref(), Some("current"));
    assert_eq!(current.unit, "A");
    let timestamp = channel_by_key(&measurement, "timestamp");
    assert_eq!(timestamp.quantity.as_deref(), Some("time"));
    assert_eq!(timestamp.unit, "s");
    assert_eq!(voltage.values.len(), 121);
    assert_eq!(current.values.len(), 121);
    assert_eq!(timestamp.values.len(), 121);
}

#[test]
fn usth_lab_metadata_keys_match_profiles() {
    let root = workspace_root();
    let doc = parse_expected();
    for entry in entries(&doc) {
        let relative = scalar(map_get(entry, "relative_path"));
        let expected_keys = optional_string_list(entry, "metadata_keys");
        if expected_keys.is_empty() || !optional_bool(entry, "plottable") {
            continue;
        }
        let measurement = load_measurement(&root, Path::new(relative))
            .unwrap_or_else(|err| panic!("{relative}: load failed: {err}"));
        let actual = metadata_keys(&measurement);
        assert_eq!(
            actual, expected_keys,
            "{relative}: metadata_keys probe output {actual:?}"
        );
        if relative.contains("keithley-2400") {
            assert_eq!(actual.len(), 2, "keithley LVM metadata: {actual:?}");
            assert_eq!(
                metadata_field_value(&measurement, "Date").as_deref(),
                Some("2026/10/07")
            );
            assert_eq!(
                metadata_field_value(&measurement, "Time").as_deref(),
                Some("14:37:03.3081121444702148437")
            );
        }
    }
}

#[test]
#[ignore = "pending discovery indexer port for .intake.log and .quarantine/ (#27 acceptance)"]
fn usth_lab_discovery_skips_intake_log_and_quarantine() {
    panic!("wire when Rust/Swift discovery shares ignore rules on this fixture");
}

#[test]
#[ignore = "pending #18 reader disposition for header-only LabVIEW exports"]
fn usth_lab_header_only_keithley_reports_no_data_rows() {
    let root = workspace_root();
    let relative = Path::new(
        "data/raw/2026-10-07/SYNTHETIC_keithley-2400.dual-sweep_header-only_no-data-rows.txt",
    );
    let _ = load_measurement(&root, relative).expect_err("header-only fixture");
    panic!("assert explicit no-data-rows disposition once #18 profiles ship");
}
