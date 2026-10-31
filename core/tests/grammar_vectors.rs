//! Cross-language grammar vectors shared with Swift via fixtures/grammar/vectors.yaml.

use raw_viewer_core::grammar::{extract, load_file, FilenameGrammar};
use raw_viewer_core::yaml::parse;
use std::collections::BTreeMap;
use std::path::PathBuf;

fn vectors_path() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../fixtures/grammar/vectors.yaml")
}

fn grammar_path(relative: &str) -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../fixtures/grammar")
        .join(relative)
}

#[derive(Debug)]
struct VectorCase {
    id: String,
    filename: String,
    matched: bool,
    tokens: BTreeMap<String, String>,
}

fn load_vectors() -> (FilenameGrammar, Vec<VectorCase>) {
    let text = std::fs::read_to_string(vectors_path()).expect("read vectors.yaml");
    let root = parse(&text, false).expect("parse vectors.yaml");
    let grammar_file = root
        .value_for_key("grammar_file")
        .and_then(|n| n.scalar_value())
        .expect("grammar_file");
    let catalog = load_file(&grammar_path(grammar_file)).expect("load grammar");
    let grammar = catalog.grammars.into_iter().next().expect("grammar entry");
    let items = root
        .value_for_key("vectors")
        .and_then(|n| n.list_items())
        .expect("vectors list");
    let mut cases = Vec::new();
    for item in items {
        let id = item
            .value_for_key("id")
            .and_then(|n| n.scalar_value())
            .expect("vector id")
            .to_string();
        let filename = item
            .value_for_key("filename")
            .and_then(|n| n.scalar_value())
            .expect("filename")
            .to_string();
        let matched = item
            .value_for_key("matched")
            .and_then(|n| n.scalar_value())
            .map(|v| v.eq_ignore_ascii_case("true"))
            .unwrap_or(false);
        let mut tokens = BTreeMap::new();
        if let Some(map) = item.value_for_key("tokens").and_then(|n| n.map_entries()) {
            for (key, value) in map {
                if let Some(scalar) = value.scalar_value() {
                    tokens.insert(key.clone(), scalar.to_string());
                }
            }
        }
        cases.push(VectorCase {
            id,
            filename,
            matched,
            tokens,
        });
    }
    (grammar, cases)
}

#[test]
fn shared_grammar_vectors_match_rust_engine() {
    let (grammar, cases) = load_vectors();
    assert!(!cases.is_empty(), "vectors must not be empty");
    for case in cases {
        let facts = extract(&case.filename, &grammar);
        assert_eq!(facts.is_matched, case.matched, "{}: is_matched", case.id);
        if case.matched {
            for (key, expected) in &case.tokens {
                assert_eq!(
                    facts.extracted_fields.get(key),
                    Some(expected),
                    "{}: token {}",
                    case.id,
                    key
                );
            }
        }
    }
}
