//! Rust project write-ban acceptance (contract 24a-1).

use raw_viewer_core::grammar::grammar_context;
use raw_viewer_core::profile::load_catalog;
use raw_viewer_core::project::ProjectContext;
use raw_viewer_core::reader::load_measurement;
use std::collections::BTreeMap;
use std::fs;
use std::path::{Path, PathBuf};
use std::time::SystemTime;

#[derive(Debug, Clone, PartialEq, Eq)]
struct EntrySnapshot {
    len: u64,
    modified: SystemTime,
    is_dir: bool,
}

fn repo_root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("..")
}

fn snapshot_project_tree(root: &Path) -> BTreeMap<PathBuf, EntrySnapshot> {
    let mut out = BTreeMap::new();
    walk(root, root, &mut out);
    out
}

fn walk(root: &Path, here: &Path, out: &mut BTreeMap<PathBuf, EntrySnapshot>) {
    for entry in fs::read_dir(here).unwrap_or_else(|err| {
        panic!("read_dir {}: {err}", here.display());
    }) {
        let entry = entry.expect("dir entry");
        let path = entry.path();
        let rel = path.strip_prefix(root).expect("under root").to_path_buf();
        let meta = entry.metadata().expect("metadata");
        out.insert(
            rel,
            EntrySnapshot {
                len: meta.len(),
                modified: meta.modified().expect("modified time"),
                is_dir: meta.is_dir(),
            },
        );
        if meta.is_dir() {
            walk(root, &path, out);
        }
    }
}

fn assert_project_tree_unchanged(
    root: &Path,
    before: &BTreeMap<PathBuf, EntrySnapshot>,
) -> Result<(), String> {
    let after = snapshot_project_tree(root);
    if before == &after {
        return Ok(());
    }
    for (path, snap) in before {
        match after.get(path) {
            None => return Err(format!("removed project entry: {}", path.display())),
            Some(next) if next != snap => {
                return Err(format!("modified project entry: {}", path.display()));
            }
            _ => {}
        }
    }
    for path in after.keys() {
        if !before.contains_key(path) {
            return Err(format!("created project entry: {}", path.display()));
        }
    }
    Ok(())
}

fn exercise_read_only_open(root: &Path) {
    let ctx = ProjectContext::open(root).expect("open project");
    let _catalog = load_catalog(root);
    let _grammar = grammar_context(root);
    if root
        .to_string_lossy()
        .contains("fixtures/workspaces/usth-lab")
    {
        let rel = Path::new(
            "data/raw/2025-11-27/271125-000000_autolab-usth.cv_[au-pda]_cv.deposition_r.[20mv-ph-8.4].txt",
        );
        let _ = load_measurement(root, rel).expect("sample measurement");
    }
    assert!(!ctx.root.join("index.db").exists());
    assert!(!ctx.root.join(".raw-viewer/index.db").exists());
}

#[test]
fn write_ban_opening_fixtures_leaves_project_tree_unchanged() {
    for rel in [
        "fixtures/workspaces/usth-lab",
        "fixtures/legacy/project-settings",
    ] {
        let root = repo_root().join(rel);
        let before = snapshot_project_tree(&root);
        exercise_read_only_open(&root);
        assert_project_tree_unchanged(&root, &before).expect("write ban");
    }
}

#[test]
fn write_ban_detects_injected_project_write() {
    let root = std::env::temp_dir().join(format!(
        "rawview-write-ban-inject-{}-{}",
        std::process::id(),
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos()
    ));
    fs::create_dir_all(root.join(".raw-viewer")).unwrap();
    fs::write(
        root.join(".raw-viewer/config.yaml"),
        "schema_version: 1\ndata_root: data/raw\n",
    )
    .unwrap();
    fs::create_dir_all(root.join("data/raw")).unwrap();
    let before = snapshot_project_tree(&root);
    fs::write(root.join(".raw-viewer/injected.txt"), "probe").unwrap();
    let err = assert_project_tree_unchanged(&root, &before).expect_err("must detect injection");
    assert!(
        err.contains("created project entry") || err.contains("modified project entry"),
        "{err}"
    );
    let _ = fs::remove_dir_all(&root);
}
