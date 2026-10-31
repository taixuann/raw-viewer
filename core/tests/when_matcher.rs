//! Acceptance tests for unified `when` profile matching (contract 18c-1).

use raw_viewer_core::profile::{
    load_catalog, matches_when, merge_when, mode_is_candidate, tokenize_basename,
    validate_document, when_from_application_mode_id, when_from_header_signature, when_from_legacy,
    GrammarMatchContext, ProfileCatalog, ProfileResolution, WhenClause,
};
use raw_viewer_core::reader::load_measurement;
use std::collections::HashMap;
use std::path::Path;

const SYNTH_GRAMMAR_YAML: &str = r#"schema_version: 1
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
"#;

fn catalog_with_profiles(project: &Path, yamls: &[(&str, &str)]) -> ProfileCatalog {
    std::fs::create_dir_all(project.join("data/instruments")).unwrap();
    for (name, yaml) in yamls {
        std::fs::write(project.join("data/instruments").join(name), yaml).unwrap();
    }
    load_catalog(project)
}

fn synth_v2_yaml() -> &'static str {
    r#"schema_version: 2
instrument:
  id: synth
  name: Synth
formats:
  - id: csv
    kind: tabular
    extensions: [".csv"]
    delimiter: ","
    encoding: [utf-8]
    rows:
      names_prefix: "DataName"
      data_prefix: "DataValue"
    columns:
      voltage:
        header: "V1"
        quantity: voltage
        unit: "V"
        label: "Voltage"
      current:
        header: "I1"
        quantity: current
        unit: "A"
        label: "Current"
modes:
  - id: dual-sweep
    format: csv
    detect: ["SYNTH-SPECIFIC-HEADER"]
    filename_contains_all: ["synth-token", "dual-sweep"]
    extract:
      x: voltage
      y: [current]
"#
}

#[test]
fn token_exact_match_rejects_near_miss_substring() {
    let merged = when_from_legacy(&["SIG".into()], Some(&["needle".into()]));
    let hit = tokenize_basename("my_needle_extra.csv");
    assert!(matches_when(
        &merged,
        None,
        &hit,
        "SIG",
        "my_needle_extra.csv"
    ));
    let miss = tokenize_basename("my_needlefish.csv");
    assert!(!matches_when(
        &merged,
        None,
        &miss,
        "SIG",
        "my_needlefish.csv"
    ));
}

#[test]
fn content_contains_any_matches_header() {
    let merged = when_from_legacy(&["alpha-header".into(), "beta-header".into()], None);
    assert!(matches_when(
        &merged,
        None,
        &[],
        "prefix alpha-header suffix",
        "file.csv"
    ));
}

#[test]
fn content_and_filename_requires_both() {
    let merged = when_from_legacy(&["HDR".into()], Some(&["tok".into()]));
    let tokens = tokenize_basename("tok.csv");
    assert!(matches_when(&merged, None, &tokens, "HDR", "tok.csv"));
    assert!(!matches_when(
        &merged,
        None,
        &tokens,
        "no-header",
        "tok.csv"
    ));
}

fn write_minimal_project(root: &Path) {
    std::fs::create_dir_all(root.join("data/raw")).unwrap();
    std::fs::create_dir_all(root.join(".rawviewer")).unwrap();
    std::fs::write(
        root.join(".rawviewer/setting.yaml"),
        "schema_version: 1\ndata_root: data/raw\ndefault_view: tree\ndefault_preset: nature-single\n",
    )
    .unwrap();
}

#[test]
fn no_grammar_zero_hits_falls_back_generic() {
    let tmp = temp_project();
    write_minimal_project(&tmp);
    std::fs::write(tmp.join(".rawviewer/grammar.yaml"), SYNTH_GRAMMAR_YAML).unwrap();
    std::fs::create_dir_all(tmp.join("data/instruments")).unwrap();
    std::fs::write(tmp.join("data/instruments/synth.yaml"), synth_v2_yaml()).unwrap();
    std::fs::write(tmp.join("data/raw/table.csv"), b"X,Y\n0,1\n").unwrap();
    let measurement = load_measurement(&tmp, Path::new("data/raw/table.csv"))
        .expect("generic table fallback when grammar unmatched and no profile hit");
    assert_eq!(measurement.instrument.id, "generic-table");
}

#[test]
fn no_grammar_content_only_path() {
    let grammar = GrammarMatchContext {
        catalog_loaded: true,
        matched_fields: None,
    };
    let content_only = when_from_legacy(&["HDR".into()], None);
    let filename_gated = when_from_legacy(&["HDR".into()], Some(&["gate".into()]));
    assert!(mode_is_candidate(&content_only, &grammar));
    assert!(!mode_is_candidate(&filename_gated, &grammar));
}

fn temp_project() -> std::path::PathBuf {
    let dir = std::env::temp_dir().join(format!(
        "rawview-when-{}-{}",
        std::process::id(),
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap_or_default()
            .as_nanos()
    ));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    dir
}

#[test]
fn grammar_match_zero_hits_is_error() {
    let yaml = r#"schema_version: 4
id: test/grammar-miss
instrument:
  id: synth
  name: Synth
when:
  mode: list-sweep
variants:
  dual-sweep:
    when:
      content_contains_any: [SYNTH-SPECIFIC-HEADER]
      filename_contains_all: [synth-token, dual-sweep]
    format:
      kind: tabular
      extensions: [".csv"]
      delimiter: ","
      encoding: [utf-8]
    rows:
      names_prefix: DataName
      data_prefix: DataValue
    metadata: []
    columns:
      voltage:
        role: channel
        header: V1
        quantity: voltage
        unit: V
      current:
        role: channel
        header: I1
        quantity: current
        unit: A
    plot:
      x: voltage
      y: [current]
"#;
    let tmp = temp_project();
    std::fs::create_dir_all(tmp.join("data/instruments")).unwrap();
    std::fs::write(tmp.join("data/instruments/x.yaml"), yaml).unwrap();
    let catalog = load_catalog(&tmp);
    let grammar = GrammarMatchContext {
        catalog_loaded: true,
        matched_fields: Some(HashMap::from([("mode".into(), "cv".into())])),
    };
    assert!(matches!(
        catalog.resolve(
            ".csv",
            "SYNTH-SPECIFIC-HEADER",
            "run_synth-token_dual-sweep.csv",
            grammar
        ),
        ProfileResolution::GrammarMatchedNoProfile
    ));
}

#[test]
fn two_hits_ambiguous_profile_sorted_candidates() {
    let tmp = temp_project();
    let catalog = catalog_with_profiles(
        &tmp,
        &[
            ("a.yaml", synth_v2_yaml()),
            (
                "b.yaml",
                &synth_v2_yaml().replace(
                    "id: synth\n  name: Synth",
                    "id: synth-alt\n  name: Synth Alt",
                ),
            ),
        ],
    );
    let resolution = catalog.resolve(
        ".csv",
        "SYNTH-SPECIFIC-HEADER",
        "run_synth-token_dual-sweep.csv",
        GrammarMatchContext::without_catalog(),
    );
    match resolution {
        ProfileResolution::AmbiguousProfile { candidate_ids } => {
            assert_eq!(candidate_ids.len(), 2);
            assert_eq!(candidate_ids[0], "synth");
            assert_eq!(candidate_ids[1], "synth-alt");
        }
        other => panic!("expected ambiguous_profile, got {other:?}"),
    }
}

#[test]
fn variant_and_profile_when_both_required() {
    let mut profile_when = WhenClause {
        grammar_tokens: [("mode".into(), "cv".into())].into(),
        content_contains_any: vec!["HDR".into()],
        ..Default::default()
    };
    let variant_when = WhenClause {
        grammar_tokens: [("instrument".into(), "autolab".into())].into(),
        ..Default::default()
    };
    let merged = merge_when(Some(&profile_when), Some(&variant_when));
    let fields = HashMap::from([
        ("mode".into(), "cv".into()),
        ("instrument".into(), "autolab".into()),
    ]);
    assert!(matches_when(&merged, Some(&fields), &[], "HDR", "x.csv"));
    profile_when
        .grammar_tokens
        .insert("mode".into(), "wrong".into());
    let merged_bad = merge_when(Some(&profile_when), Some(&variant_when));
    assert!(!matches_when(
        &merged_bad,
        Some(&fields),
        &[],
        "HDR",
        "x.csv"
    ));
}

#[test]
fn variant_when_without_content_compiles() {
    let yaml = r#"schema_version: 4
id: test/token-only
instrument:
  id: synth
  name: Synth
variants:
  token-only:
    when:
      filename_contains_all: ["synth-token"]
    format:
      kind: tabular
      extensions: [".csv"]
      delimiter: ","
      encoding: [utf-8]
    rows:
      names_prefix: DataName
      data_prefix: DataValue
    metadata: []
    columns:
      voltage:
        role: channel
        header: V1
        quantity: voltage
        unit: V
      current:
        role: channel
        header: I1
        quantity: current
        unit: A
    plot:
      x: voltage
      y: [current]
"#;
    let outcome = validate_document(yaml, "data/instruments/token-only.yaml");
    assert!(outcome.profile.is_some(), "{:?}", outcome.issues);
}

#[test]
fn legacy_filename_contains_all_translation() {
    let when = when_from_legacy(&[], Some(&["synth-token".into(), "dual-sweep".into()]));
    assert_eq!(
        when.filename_tokens,
        vec!["synth", "token", "dual", "sweep"]
    );
}

#[test]
fn legacy_header_signatures_translation() {
    let when = when_from_header_signature("cv", "Potential applied (V)");
    assert_eq!(
        when.content_contains_any,
        vec!["Potential applied (V)".to_string()]
    );
    assert_eq!(when.grammar_tokens.get("cv"), Some(&"cv".to_string()));
}

#[test]
fn legacy_detect_signatures_translation() {
    let when = when_from_legacy(&["detect-me".into()], None);
    assert!(matches_when(
        &when,
        None,
        &[],
        "prefix detect-me suffix",
        "f.csv"
    ));
}

#[test]
fn legacy_application_modes_translation() {
    let when = when_from_application_mode_id("dual-sweep", &["dual Vsweep".into()], None);
    assert_eq!(
        when.grammar_tokens.get("mode"),
        Some(&"dual-sweep".to_string())
    );
    assert!(when
        .content_contains_any
        .contains(&"dual Vsweep".to_string()));
}

#[test]
fn v2_optional_id_fallback_direct() {
    let yaml = synth_v2_yaml().replace("dual-sweep", "optional-id");
    let outcome = validate_document(&yaml, "data/instruments/synth.yaml");
    assert!(outcome.profile.is_some());
}
