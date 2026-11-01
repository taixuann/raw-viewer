//! Grammar path precedence for project layout (contract 24a-1).

use raw_viewer_core::grammar::{
    grammar_context, load_file, resolve_grammar_path, GRAMMAR_READ_ORDER,
};
use std::fs;
use std::path::{Path, PathBuf};

const MARKER_NEW: &str = "MARKER-NEW-PATH-GRAMMAR";
const MARKER_LEGACY: &str = "MARKER-LEGACY-GRAMMAR";
const MARKER_VIEW: &str = "MARKER-LEGACY-VIEW-GRAMMAR";

fn grammar_with_marker(marker: &str) -> String {
    format!(
        r#"schema_version: 1
grammars:
  - id: demo
    name: Demo
    template: "{marker}_{{sample}}"
    fields:
      - name: sample
        role: sample
        type: string
        optional: false
"#
    )
}

fn temp_project(label: &str) -> PathBuf {
    static NEXT: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
    let dir = std::env::temp_dir().join(format!(
        "rawview-grammar-{label}-{}-{}",
        std::process::id(),
        NEXT.fetch_add(1, std::sync::atomic::Ordering::Relaxed)
    ));
    fs::create_dir_all(&dir).unwrap();
    dir
}

fn write_grammar(root: &Path, relative: &str, marker: &str) {
    let path = root.join(relative);
    fs::create_dir_all(path.parent().unwrap()).unwrap();
    fs::write(path, grammar_with_marker(marker)).unwrap();
}

fn template_from_context(root: &Path) -> String {
    let ctx = grammar_context(root);
    assert!(ctx.error.is_none(), "{:?}", ctx.error);
    let catalog = ctx.catalog.expect("catalog");
    catalog.grammars[0].template.clone()
}

#[test]
fn grammar_new_path_only_loads_raw_viewer_grammar_yaml() {
    let root = temp_project("new-only");
    write_grammar(&root, GRAMMAR_READ_ORDER[0], MARKER_NEW);
    let (path, relative) = resolve_grammar_path(&root).expect("grammar path");
    assert_eq!(relative, GRAMMAR_READ_ORDER[0]);
    let catalog = load_file(&path).expect("load grammar");
    assert!(catalog.grammars[0].template.contains(MARKER_NEW));
    assert!(template_from_context(&root).contains(MARKER_NEW));
}

#[test]
fn grammar_legacy_only_loads_rawviewer_grammar_yaml() {
    let root = temp_project("legacy-only");
    write_grammar(&root, GRAMMAR_READ_ORDER[1], MARKER_LEGACY);
    let (path, relative) = resolve_grammar_path(&root).expect("grammar path");
    assert_eq!(relative, GRAMMAR_READ_ORDER[1]);
    let catalog = load_file(&path).expect("load grammar");
    assert!(catalog.grammars[0].template.contains(MARKER_LEGACY));
    assert!(template_from_context(&root).contains(MARKER_LEGACY));
}

#[test]
fn grammar_legacy_view_only_loads_view_grammar_yaml() {
    let root = temp_project("legacy-view-only");
    write_grammar(&root, GRAMMAR_READ_ORDER[2], MARKER_VIEW);
    let (path, relative) = resolve_grammar_path(&root).expect("grammar path");
    assert_eq!(relative, GRAMMAR_READ_ORDER[2]);
    let catalog = load_file(&path).expect("load grammar");
    assert!(catalog.grammars[0].template.contains(MARKER_VIEW));
    assert!(template_from_context(&root).contains(MARKER_VIEW));
}

#[test]
fn grammar_new_path_wins_when_all_three_exist() {
    let root = temp_project("all-three");
    write_grammar(&root, GRAMMAR_READ_ORDER[0], MARKER_NEW);
    write_grammar(&root, GRAMMAR_READ_ORDER[1], MARKER_LEGACY);
    write_grammar(&root, GRAMMAR_READ_ORDER[2], MARKER_VIEW);
    let (_, relative) = resolve_grammar_path(&root).expect("grammar path");
    assert_eq!(relative, GRAMMAR_READ_ORDER[0]);
    assert!(template_from_context(&root).contains(MARKER_NEW));
}
