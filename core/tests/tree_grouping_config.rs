//! Issue #112: a tree_grouping level holds '+'-joined grammar tokens.
//! Plain one-token levels keep loading; an empty token is rejected.

use raw_viewer_core::config::{load_project_config, ConfigError};
use std::fs;
use std::path::{Path, PathBuf};

fn temp_config_dir(label: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!("rv-tree-grouping-{label}-{}", std::process::id()));
    let _ = fs::remove_dir_all(&dir);
    fs::create_dir_all(&dir).unwrap();
    dir
}

fn load_with(label: &str, yaml: &str) -> Result<Option<Vec<String>>, ConfigError> {
    let dir = temp_config_dir(label);
    fs::write(dir.join("config.yaml"), yaml).unwrap();
    load_project_config(&dir).map(|config| config.tree_grouping)
}

fn assert_rejected(error: &ConfigError, field: &str, path: &Path) {
    assert_eq!(error.field(), Some(field), "{error}");
    assert_eq!(error.path(), path, "{error}");
    assert!(error.to_string().contains("empty token"), "{error}");
}

#[test]
fn combined_level_loads_as_one_string_per_level() {
    let tree_grouping = load_with(
        "combined",
        "schema_version: 1\ntree_grouping: [\"instrument+application-mode\", device-id, date]\n",
    )
    .unwrap();
    assert_eq!(
        tree_grouping,
        Some(vec![
            "instrument+application-mode".to_string(),
            "device-id".to_string(),
            "date".to_string(),
        ])
    );
}

#[test]
fn plain_string_levels_load_unchanged() {
    let tree_grouping = load_with(
        "legacy",
        "schema_version: 1\ntree_grouping: [instrument, mode]\n",
    )
    .unwrap();
    assert_eq!(
        tree_grouping,
        Some(vec!["instrument".to_string(), "mode".to_string()])
    );
}

#[test]
fn empty_token_in_tree_grouping_is_rejected() {
    for level in ["\"+mode\"", "\"instrument+\"", "\"a++b\"", "\"+\""] {
        let dir = temp_config_dir("empty-token");
        let file = dir.join("config.yaml");
        fs::write(
            &file,
            format!("schema_version: 1\ntree_grouping: [{level}]\n"),
        )
        .unwrap();
        let error = load_project_config(&dir).unwrap_err();
        assert_rejected(&error, "tree_grouping", &file);
    }
}

#[test]
fn empty_level_string_is_rejected_for_tree_grouping() {
    let dir = temp_config_dir("empty-level");
    let file = dir.join("config.yaml");
    fs::write(&file, "schema_version: 1\ntree_grouping: [\"\"]\n").unwrap();
    let error = load_project_config(&dir).unwrap_err();
    assert_eq!(error.field(), Some("tree_grouping"), "{error}");
    assert_eq!(error.path(), file.as_path(), "{error}");
}

#[test]
fn empty_token_in_explorer_grouping_fields_is_rejected() {
    let dir = temp_config_dir("explorer-empty-token");
    let file = dir.join("config.yaml");
    fs::write(
        &file,
        "schema_version: 1\nexplorer:\n  grouping_fields: [\"instrument+\"]\n",
    )
    .unwrap();
    let error = load_project_config(&dir).unwrap_err();
    assert_rejected(&error, "explorer.grouping_fields", &file);
}
