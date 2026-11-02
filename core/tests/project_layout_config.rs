//! Project layout config acceptance (contract 24a-1).

const _CONFIG_VECTORS_CONTRACT: &str =
    include_str!("../../fixtures/grammar/cross_language_contract.yaml");

use raw_viewer_core::config::{load_project_config, ConfigError, ProjectConfig};
use raw_viewer_core::project::ProjectContext;
use raw_viewer_core::reader::load_measurement;
use raw_viewer_core::yaml::{parse, YamlNode};
use std::fs;
use std::path::{Path, PathBuf};

fn repo_root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("..")
}

fn config_vectors_path() -> PathBuf {
    repo_root().join("fixtures/config/vectors.yaml")
}

fn load_config_vectors_doc() -> YamlNode {
    let text =
        fs::read_to_string(config_vectors_path()).expect("read fixtures/config/vectors.yaml");
    parse(&text, false).expect("parse config vectors")
}

#[test]
fn usth_fixture_opens_and_reads_schema_version_one() {
    let root = repo_root().join("fixtures/workspaces/usth-lab");
    let ctx = ProjectContext::open(&root).expect("open usth-lab");
    assert_eq!(ctx.config.schema_version, Some(1));
    assert_eq!(ctx.config.data_root, "data/raw");
    assert_eq!(ctx.data_root_relative_path, "data/raw");
}

#[test]
fn missing_schema_version_returns_typed_error() {
    let dir = tempfile_config_dir("missing-schema-version");
    fs::write(dir.join("config.yaml"), "data_root: data/raw\n").unwrap();
    let err = load_project_config(&dir).unwrap_err();
    assert_schema_error(&err, "schema_version", "required");
}

#[test]
fn schema_version_two_returns_typed_error() {
    let dir = tempfile_config_dir("schema-version-two");
    fs::write(
        dir.join("config.yaml"),
        "schema_version: 2\ndata_root: data/raw\n",
    )
    .unwrap();
    let err = load_project_config(&dir).unwrap_err();
    assert_schema_error(&err, "schema_version", "must be 1");
}

#[test]
fn custom_data_root_lists_measurements_via_project_context_and_reader() {
    let root = tempfile_project("custom-data-root");
    fs::create_dir_all(root.join("measurements")).unwrap();
    fs::write(
        root.join(".raw-viewer/config.yaml"),
        "schema_version: 1\ndata_root: measurements\n",
    )
    .unwrap();
    fs::write(
        root.join("measurements/table.csv"),
        "Voltage (V),Current (A)\n0,1\n",
    )
    .unwrap();
    let ctx = ProjectContext::open(&root).expect("open custom data root");
    assert_eq!(ctx.data_root_relative_path, "measurements");
    let measurement = load_measurement(&root, Path::new("measurements/table.csv"))
        .expect("load from custom data root");
    assert_eq!(measurement.instrument.id, "generic-table");
}

#[test]
fn config_parity_vectors_match_rust_loader() {
    let doc = load_config_vectors_doc();
    let vectors = doc
        .value_for_key("vectors")
        .and_then(|n| n.list_items())
        .expect("vectors list");
    for vector in vectors {
        let id = scalar(vector, "id").to_string();
        let yaml_body = vector
            .value_for_key("config_file")
            .and_then(|n| n.scalar_value())
            .map(|rel| {
                fs::read_to_string(repo_root().join("fixtures/config").join(rel))
                    .unwrap_or_else(|err| panic!("read config case {rel}: {err}"))
            });
        let dir = tempfile_config_dir(&id);
        if let Some(body) = yaml_body {
            fs::write(dir.join("config.yaml"), body).unwrap();
        }
        if let Some(expect) = vector.value_for_key("expect") {
            let loaded = load_project_config(&dir).expect("load config");
            assert_expect_config(&id, &loaded, expect);
        } else if let Some(expect_err) = vector.value_for_key("expect_error") {
            let err = load_project_config(&dir).expect_err("expected config error");
            let field = scalar(expect_err, "field");
            let needle = scalar(expect_err, "detail_contains");
            assert_schema_error(&err, &field, &needle);
        } else {
            panic!("vector {id} must declare expect or expect_error");
        }
    }
}

fn assert_expect_config(id: &str, loaded: &ProjectConfig, expect: &YamlNode) {
    let map = expect.map_entries().expect("expect map");
    for (key, node) in map {
        match key.as_str() {
            "schema_version" => {
                let expected: u32 = node
                    .scalar_value()
                    .expect("schema_version scalar")
                    .parse()
                    .expect("schema_version int");
                assert_eq!(loaded.schema_version, Some(expected), "{id}");
            }
            "data_root" => {
                assert_eq!(
                    loaded.data_root,
                    node.scalar_value().expect("data_root"),
                    "{id}"
                );
            }
            "default_view" => {
                assert_eq!(
                    loaded.default_view,
                    node.scalar_value().expect("default_view"),
                    "{id}"
                );
            }
            "default_preset" => {
                assert_eq!(
                    loaded.default_preset,
                    node.scalar_value().expect("default_preset"),
                    "{id}"
                );
            }
            other => panic!("unexpected expect key {other} in vector {id}"),
        }
    }
}

fn assert_schema_error(err: &ConfigError, field: &str, needle: &str) {
    assert_eq!(err.field(), Some(field));
    assert!(
        err.to_string().contains(needle),
        "expected {needle} in {err}"
    );
}

fn scalar(node: &YamlNode, key: &str) -> String {
    if let Some(map) = node.map_entries() {
        return map
            .iter()
            .find(|(k, _)| k == key)
            .map(|(_, v)| v.scalar_value().expect("scalar").to_string())
            .unwrap_or_else(|| panic!("missing {key}"));
    }
    node.scalar_value()
        .map(str::to_string)
        .unwrap_or_else(|| panic!("missing scalar"))
}

fn tempfile_config_dir(label: &str) -> PathBuf {
    static NEXT: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
    let dir = std::env::temp_dir().join(format!(
        "rawview-cfg-{label}-{}-{}",
        std::process::id(),
        NEXT.fetch_add(1, std::sync::atomic::Ordering::Relaxed)
    ));
    fs::create_dir_all(&dir).unwrap();
    dir
}

fn tempfile_project(label: &str) -> PathBuf {
    static NEXT: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
    let dir = std::env::temp_dir().join(format!(
        "rawview-proj-{label}-{}-{}",
        std::process::id(),
        NEXT.fetch_add(1, std::sync::atomic::Ordering::Relaxed)
    ));
    fs::create_dir_all(dir.join(".raw-viewer")).unwrap();
    dir
}
