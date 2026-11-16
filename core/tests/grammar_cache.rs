//! Grammar extraction cache: behavior on repeated calls and a timing harness.

use raw_viewer_core::grammar::{default_grammar, extract, load_file, FilenameGrammar};
use raw_viewer_core::yaml::parse;
use std::collections::BTreeMap;
use std::path::PathBuf;
use std::time::Instant;

fn grammar_fixtures_dir() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../fixtures/grammar")
}

fn standard_grammar() -> FilenameGrammar {
    load_file(&grammar_fixtures_dir().join("standard-scientific.yaml"))
        .expect("load standard-scientific.yaml")
        .grammars
        .into_iter()
        .next()
        .expect("grammar entry")
}

struct VectorRow {
    id: String,
    filename: String,
    matched: bool,
    tokens: BTreeMap<String, String>,
}

fn load_vector_rows() -> Vec<VectorRow> {
    let text = std::fs::read_to_string(grammar_fixtures_dir().join("vectors.yaml"))
        .expect("read vectors.yaml");
    let root = parse(&text, false).expect("parse vectors.yaml");
    let items = root
        .value_for_key("vectors")
        .and_then(|n| n.list_items())
        .expect("vectors list");
    let mut rows = Vec::new();
    for item in items {
        let mut tokens = BTreeMap::new();
        if let Some(map) = item.value_for_key("tokens").and_then(|n| n.map_entries()) {
            for (key, value) in map {
                if let Some(scalar) = value.scalar_value() {
                    tokens.insert(key.clone(), scalar.to_string());
                }
            }
        }
        rows.push(VectorRow {
            id: item
                .value_for_key("id")
                .and_then(|n| n.scalar_value())
                .expect("vector id")
                .to_string(),
            filename: item
                .value_for_key("filename")
                .and_then(|n| n.scalar_value())
                .expect("filename")
                .to_string(),
            matched: item
                .value_for_key("matched")
                .and_then(|n| n.scalar_value())
                .map(|v| v.eq_ignore_ascii_case("true"))
                .unwrap_or(false),
            tokens,
        });
    }
    rows
}

#[test]
fn extract_facts_match_every_vectors_row_on_repeated_calls() {
    let grammar = standard_grammar();
    let rows = load_vector_rows();
    assert!(!rows.is_empty(), "vectors must not be empty");
    for row in &rows {
        let first = extract(&row.filename, &grammar);
        let second = extract(&row.filename, &grammar);
        assert_eq!(
            first, second,
            "{}: repeated call must return the same facts",
            row.id
        );
        assert_eq!(first.is_matched, row.matched, "{}: is_matched", row.id);
        if row.matched {
            for (key, expected) in &row.tokens {
                assert_eq!(
                    first.extracted_fields.get(key),
                    Some(expected),
                    "{}: token {key}",
                    row.id
                );
            }
        }
    }
}

#[test]
fn changed_template_gives_new_compiled_form() {
    let original = standard_grammar();
    let filename =
        "201226-154955_keithley-2400.dual-sweep_[cu-ec-pda]_iv.dual-sweep_r.[300K]_f.[x]_001";
    let changed_filename =
        "201226-154955_keithley-2400.dual-sweep_[cu-ec-pda]_iv.dual-sweep_r.[300K]_F.[x]_001";
    let changed = FilenameGrammar {
        template: original.template.replace("_f.[", "_F.["),
        ..original.clone()
    };

    let before = extract(filename, &original);
    assert!(before.is_matched, "original template matches");
    assert_eq!(
        before.extracted_fields.get("flags").map(String::as_str),
        Some("x")
    );

    let stale = extract(filename, &changed);
    assert!(
        !stale.is_matched,
        "changed template must not reuse the original pattern"
    );

    let after = extract(changed_filename, &changed);
    assert!(
        after.is_matched,
        "changed template matches its own filename"
    );
    assert_eq!(
        after.extracted_fields.get("flags").map(String::as_str),
        Some("x")
    );
    assert_eq!(
        after.extracted_fields.get("batch").map(String::as_str),
        Some("001")
    );

    let again = extract(filename, &original);
    assert_eq!(
        again, before,
        "original template still returns its own facts"
    );
}

#[test]
fn changed_field_format_gives_new_compiled_form() {
    let original = standard_grammar();
    let mut two_digit = original.clone();
    for field in &mut two_digit.fields {
        if field.name == "batch" {
            field.format_hint = "01".into();
        }
    }
    let two_digit_name =
        "201226-154955_keithley-2400.dual-sweep_[cu-ec-pda]_iv.dual-sweep_r.[300K]_f.[x]_01";
    let three_digit_name =
        "201226-154955_keithley-2400.dual-sweep_[cu-ec-pda]_iv.dual-sweep_r.[300K]_f.[x]_001";

    let short = extract(two_digit_name, &two_digit);
    assert!(
        short.is_matched,
        "two-digit format matches a two-digit counter"
    );
    assert_eq!(short.batch.as_deref(), Some("01"));

    let wide = extract(three_digit_name, &original);
    assert!(
        wide.is_matched,
        "three-digit format matches a three-digit counter"
    );
    assert_eq!(wide.batch.as_deref(), Some("001"));

    let stale = extract(three_digit_name, &two_digit);
    assert!(
        !stale.is_matched,
        "two-digit format must not reuse the three-digit pattern"
    );
    let stale_short = extract(two_digit_name, &original);
    assert!(
        !stale_short.is_matched,
        "three-digit format must not reuse the two-digit pattern"
    );
}

#[test]
fn perf_extract_5000_synthetic_filenames() {
    if std::env::var("RAWVIEW_PERF").as_deref() != Ok("1") {
        return;
    }
    let grammar = default_grammar();
    let names: Vec<String> = (0..5000)
        .map(|i| {
            format!(
                "010526-{i:06}_autolab-usth.ca_[dev-1]_electrochem.study1_r.[clean]_f.[none]_001.txt"
            )
        })
        .collect();
    let start = Instant::now();
    let matched = names
        .iter()
        .filter(|name| extract(name, &grammar).is_matched)
        .count();
    let elapsed = start.elapsed();
    println!(
        "PERF extract 5000 files: {:.1} ms, matched {}",
        elapsed.as_secs_f64() * 1000.0,
        matched
    );
    assert_eq!(matched, names.len(), "every synthetic filename must match");
}
