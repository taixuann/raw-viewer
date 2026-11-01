//! Cross-language grammar vectors shared with Swift via fixtures/grammar/vectors.yaml.

use raw_viewer_core::grammar::{compile, extract, load_file, FilenameGrammar};
use raw_viewer_core::yaml::parse;
use std::collections::BTreeMap;
use std::path::PathBuf;

fn grammar_fixtures_dir() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../fixtures/grammar")
}

fn vectors_path() -> PathBuf {
    grammar_fixtures_dir().join("vectors.yaml")
}

fn cross_language_contract_path() -> PathBuf {
    grammar_fixtures_dir().join("cross_language_contract.yaml")
}

fn load_expected_compile_pattern() -> String {
    let text = std::fs::read_to_string(cross_language_contract_path()).expect("read cross_language_contract.yaml");
    let root = parse(&text, false).expect("parse cross_language_contract.yaml");
    let section = root
        .value_for_key("grammar_compile_pattern")
        .expect("grammar_compile_pattern");
    section
        .value_for_key("expected_pattern")
        .and_then(|n| n.scalar_value())
        .expect("expected_pattern")
        .to_string()
}

fn grammar_path(relative: &str) -> PathBuf {
    grammar_fixtures_dir().join(relative)
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
fn shared_grammar_compile_pattern_matches_rust_reference() {
    let catalog =
        load_file(&grammar_path("standard-scientific.yaml")).expect("load standard-scientific");
    let grammar = catalog.grammars.into_iter().next().expect("grammar entry");
    let (regex, _) = compile(&grammar.template, &grammar.fields).expect("compile");
    // Shared with Swift via fixtures/grammar/cross_language_contract.yaml.
    // NSRegularExpression spells the negated-] class as `[^\]]`; the Rust `regex` crate uses `[^]]`.
    // Those differ only in escaping; normalize before compare.
    let expected = load_expected_compile_pattern();
    let normalize = |s: &str| s.replace("[^\\]]", "[^]]");
    assert_eq!(
        normalize(regex.as_str()),
        normalize(&expected),
        "compiled pattern must match cross_language_contract.yaml expected_pattern"
    );
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
