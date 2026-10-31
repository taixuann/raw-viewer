//! Real-data usth-lab workspace fixture checks (issue #27).
//!
//! Active tests verify committed bytes, measured row counts, and reader guards
//! that exist today. Profile routing, axis metadata, discovery ignore rules, and
//! header-only dispositions stay `#[ignore]` until #18 lands variant profiles.

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

#[test]
#[ignore = "pending #18 variant profiles under .raw-viewer/profiles/"]
fn usth_lab_plottable_files_match_profile_axes() {
    let _root = workspace_root();
    let _doc = parse_expected();
    panic!("implement after #18 lands profiles and grammar routing");
}

#[test]
#[ignore = "pending #18 variant profiles under .raw-viewer/profiles/"]
fn usth_lab_metadata_keys_match_profiles() {
    let _root = workspace_root();
    panic!("implement after #18 lands profiles and metadata extraction");
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
