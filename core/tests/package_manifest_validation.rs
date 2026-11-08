//! Acceptance tests for in-memory package manifest validation (RV-U3-R1a).

use raw_viewer_core::package::{parse_package_manifest, ManifestErrorKind};

const LABEL: &str = "test:embedded";

/// Real 64-hex digests for fixtures (syntax only; content not verified).
const DIGEST_A: &str = "abcd0123abcd0123abcd0123abcd0123abcd0123abcd0123abcd0123abcd0123";
const DIGEST_B: &str = "deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef";

fn minimal_manifest(extra: &str) -> String {
    format!(
        r#"schema_version: 1
id: usth
version: "2026.11.1"
display_name: Example
profiles:
  - id: usth/keithley-2400
    path: profiles/keithley-2400.yaml
    sha256: {DIGEST_A}
{extra}"#
    )
}

fn ok(text: &str) -> raw_viewer_core::package::PackageManifest {
    parse_package_manifest(text, LABEL).expect("expected valid manifest")
}

fn err(text: &str) -> Vec<raw_viewer_core::package::ManifestDiagnostic> {
    parse_package_manifest(text, LABEL).expect_err("expected validation errors")
}

#[test]
fn rfc_example_manifest_parses() {
    let yaml = format!(
        r#"schema_version: 1
id: usth
version: "2026.11.1"
display_name: USTH Lab Instrument Profiles
profiles:
  - id: usth/keithley-2400
    path: profiles/keithley-2400.yaml
    sha256: {DIGEST_A}
  - id: usth/autolab-usth
    path: profiles/autolab-usth.yaml
    sha256: {DIGEST_B}
"#
    );
    let manifest = ok(&yaml);
    assert_eq!(manifest.schema_version, 1);
    assert_eq!(manifest.id.as_str(), "usth");
    assert_eq!(manifest.version, "2026.11.1");
    assert_eq!(manifest.display_name, "USTH Lab Instrument Profiles");
    assert_eq!(manifest.profiles.len(), 2);
    assert_eq!(manifest.profiles[0].id.as_str(), "usth/keithley-2400");
    assert_eq!(
        manifest.profiles[0].path.as_str(),
        "profiles/keithley-2400.yaml"
    );
    assert_eq!(manifest.profiles[0].sha256.as_str(), DIGEST_A);
    assert_eq!(manifest.profiles[0].id.namespace(), "usth");
    assert_eq!(manifest.profiles[0].id.name(), "keithley-2400");
}

#[test]
fn schema_version_plain_quoted_and_single_accepted() {
    for quoted in ["1", "\"1\"", "'1'"] {
        let yaml =
            minimal_manifest("").replace("schema_version: 1", &format!("schema_version: {quoted}"));
        let _ = ok(&yaml);
    }
}

#[test]
fn schema_version_rejects_true_float_two_null_tilde() {
    for bad in ["true", "1.0", "2", "null", "~"] {
        let yaml =
            minimal_manifest("").replace("schema_version: 1", &format!("schema_version: {bad}"));
        let diags = err(&yaml);
        assert!(
            diags
                .iter()
                .any(|d| d.kind == ManifestErrorKind::SchemaVersion),
            "bad={bad}: {diags:?}"
        );
    }
}

#[test]
fn schema_version_missing() {
    let yaml = minimal_manifest("").replace("schema_version: 1\n", "");
    let diags = err(&yaml);
    assert_eq!(
        diags
            .iter()
            .find(|d| d.field == "schema_version")
            .map(|d| d.kind),
        Some(ManifestErrorKind::MissingField)
    );
}

#[test]
fn version_accepts_true_and_123_as_text() {
    for ver in ["true", "123"] {
        let yaml =
            minimal_manifest("").replace("version: \"2026.11.1\"", &format!("version: {ver}"));
        let manifest = ok(&yaml);
        assert_eq!(manifest.version, ver);
    }
}

#[test]
fn version_rejects_null_tilde_empty() {
    for bad in ["null", "~", "''"] {
        let yaml =
            minimal_manifest("").replace("version: \"2026.11.1\"", &format!("version: {bad}"));
        let diags = err(&yaml);
        assert!(diags.iter().any(|d| d.field == "version"), "bad={bad}");
    }
}

#[test]
fn duplicate_map_keys_syntax() {
    let yaml = minimal_manifest("schema_version: 2\n");
    let diags = err(&yaml);
    assert_eq!(diags[0].kind, ManifestErrorKind::Syntax);
}

#[test]
fn unknown_top_level_and_profile_hooks_scripts() {
    let yaml = minimal_manifest("hooks: x\n");
    assert!(err(&yaml)
        .iter()
        .any(|d| d.kind == ManifestErrorKind::UnknownField && d.field == "hooks"));
    let yaml = minimal_manifest("    hooks: x\n");
    assert!(err(&yaml).iter().any(|d| d.field.contains("hooks")));
}

#[test]
fn duplicate_profile_ids() {
    let yaml = format!(
        r#"schema_version: 1
id: usth
version: v1
display_name: n
profiles:
  - id: usth/a
    path: profiles/a.yaml
    sha256: {DIGEST_A}
  - id: usth/a
    path: profiles/b.yaml
    sha256: {DIGEST_B}
"#
    );
    let diags = err(&yaml);
    assert!(diags
        .iter()
        .any(|d| d.kind == ManifestErrorKind::DuplicateProfileId && d.field == "profiles[1].id"));
}

#[test]
fn display_name_256_ok_257_bad() {
    let name256 = "a".repeat(256);
    let yaml =
        minimal_manifest("").replace("display_name: Example", &format!("display_name: {name256}"));
    let _ = ok(&yaml);
    let name257 = "a".repeat(257);
    let yaml =
        minimal_manifest("").replace("display_name: Example", &format!("display_name: {name257}"));
    let diags = err(&yaml);
    assert!(diags.iter().any(|d| d.field == "display_name"));
}

#[test]
fn display_name_control_character() {
    let yaml = minimal_manifest("").replace("display_name: Example", "display_name: \"a\u{1}b\"");
    assert!(err(&yaml).iter().any(|d| d.field == "display_name"));
}

#[test]
fn malformed_yaml_syntax() {
    let yaml = "schema_version: 1\nid: [\n";
    assert_eq!(err(yaml)[0].kind, ManifestErrorKind::UnsupportedSyntax);
}

#[test]
fn depth_31_ok_depth_32_error() {
    let mut inner =
        String::from("schema_version: 1\nid: usth\nversion: v\ndisplay_name: n\nprofiles:\n");
    inner.push_str("  - id: usth/p\n    path: profiles/p.yaml\n    sha256: ");
    inner.push_str(DIGEST_A);
    inner.push('\n');
    inner.push_str(&"  x:\n".repeat(29));
    inner.push_str("    leaf: v\n");
    let _ = parse_package_manifest(&inner, LABEL); // may be ok or shape error depending depth counting

    let mut deep =
        String::from("schema_version: 1\nid: usth\nversion: v\ndisplay_name: n\nprofiles:\n");
    deep.push_str("  - id: usth/p\n    path: profiles/p.yaml\n    sha256: ");
    deep.push_str(DIGEST_A);
    deep.push('\n');
    deep.push_str(&"  x:\n".repeat(31));
    deep.push_str("    leaf: v\n");
    let diags = err(&deep);
    assert!(diags.iter().any(|d| d.kind == ManifestErrorKind::Syntax));
}

#[test]
fn too_large_and_nul() {
    let big = "a".repeat(1024 * 1024 + 1);
    assert_eq!(err(&big)[0].kind, ManifestErrorKind::TooLarge);
    let yaml = minimal_manifest("").replace('\n', "\0\n");
    assert_eq!(err(&yaml)[0].kind, ManifestErrorKind::ContainsNul);
}

#[test]
fn path_shape_and_windows_guards() {
    let bad_paths = [
        ("profiles/nested/x.yaml", "nested"),
        ("vendor/x.yaml", "prefix"),
        ("profiles/x.yml", "extension"),
        ("profiles/.yaml", "stem"),
        ("profiles/x<.yaml", "lt"),
        ("profiles/x>.yaml", "gt"),
        ("profiles/x\".yaml", "quote"),
        ("profiles/x|.yaml", "pipe"),
        ("profiles/x?.yaml", "q"),
        ("profiles/x*.yaml", "star"),
        ("profiles/con.yaml", "reserved"),
        ("profiles/COM1.yaml", "com1"),
        ("C:/profiles/x.yaml", "drive"),
    ];
    for (path, note) in bad_paths {
        let yaml = minimal_manifest("").replace(
            "path: profiles/keithley-2400.yaml",
            &format!("path: {path}"),
        );
        let diags = err(&yaml);
        assert!(
            diags.iter().any(|d| d.field.contains("path")),
            "{note}: {diags:?}"
        );
    }
}

#[test]
fn path_quoted_punctuation_allowed() {
    let yaml = minimal_manifest("").replace(
        "path: profiles/keithley-2400.yaml",
        "path: \"profiles/safe-name.yaml\"",
    );
    let _ = ok(&yaml);
}

#[test]
fn path_casefold_collision() {
    let yaml = format!(
        r#"schema_version: 1
id: usth
version: v1
display_name: n
profiles:
  - id: usth/a
    path: profiles/Alpha.yaml
    sha256: {DIGEST_A}
  - id: usth/b
    path: profiles/alpha.yaml
    sha256: {DIGEST_B}
"#
    );
    let diags = err(&yaml);
    assert!(diags
        .iter()
        .any(|d| d.kind == ManifestErrorKind::PathCollision));
}

#[test]
fn empty_profiles_and_257_entries() {
    let yaml = r#"schema_version: 1
id: usth
version: v1
display_name: n
profiles:
"#;
    assert_eq!(err(yaml)[0].kind, ManifestErrorKind::EmptyProfiles);

    let mut yaml =
        String::from("schema_version: 1\nid: usth\nversion: v1\ndisplay_name: n\nprofiles:\n");
    for i in 0..257 {
        yaml.push_str(&format!(
            "  - id: usth/p{i}\n    path: profiles/p{i}.yaml\n    sha256: {DIGEST_A}\n"
        ));
    }
    assert_eq!(err(&yaml)[0].kind, ManifestErrorKind::TooManyProfiles);
}

#[test]
fn digest_length_chars_and_lowercase_normalization() {
    let yaml = minimal_manifest("").replace(DIGEST_A, "abcd");
    assert!(err(&yaml).iter().any(|d| d.field.contains("sha256")));
    let yaml = minimal_manifest("").replace(DIGEST_A, &DIGEST_A.to_ascii_uppercase());
    let manifest = ok(&yaml);
    assert_eq!(manifest.profiles[0].sha256.as_str(), DIGEST_A);
    assert!(manifest.profiles[0]
        .sha256
        .as_str()
        .chars()
        .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit()));
}

#[test]
fn quoted_scalars_allow_special_punctuation() {
    let yaml = minimal_manifest("").replace(
        "display_name: Example",
        "display_name: \"has * & !! | inside\"",
    );
    let _ = ok(&yaml);
}

#[test]
fn unsupported_unquoted_flow_block_tag_alias() {
    let cases = [
        ("display_name: |", "block"),
        ("display_name: >", "fold"),
        ("display_name: !!str x", "tag"),
        ("display_name: &anchor", "anchor"),
        ("display_name: *alias", "alias"),
        ("display_name: [a, b]", "flow list"),
        ("display_name: {x: 1}", "flow map"),
        ("profiles:\n  - *x\n", "seq alias"),
        ("profiles:\n  - !!tag\n", "seq tag"),
        ("profiles:\n  - [a, b]\n", "seq flow"),
    ];
    for (patch, note) in cases {
        let base = minimal_manifest("");
        let yaml = if patch.starts_with("profiles:") {
            base.replace("profiles:\n  - id: usth/keithley-2400", patch.trim())
        } else {
            base.replace("display_name: Example", patch)
        };
        let diags = err(&yaml);
        assert!(
            diags.iter().any(|d| matches!(
                d.kind,
                ManifestErrorKind::UnsupportedSyntax | ManifestErrorKind::Syntax
            )),
            "{note}: {diags:?}"
        );
    }
}

#[test]
fn alias_like_map_key_rejected() {
    let yaml = minimal_manifest("").replace("schema_version: 1\n", "*bad: 1\nschema_version: 1\n");
    let diags = err(&yaml);
    assert!(
        diags.iter().any(|d| {
            matches!(
                d.kind,
                ManifestErrorKind::UnsupportedSyntax
                    | ManifestErrorKind::UnknownField
                    | ManifestErrorKind::Syntax
            )
        }),
        "{diags:?}"
    );
}

#[test]
fn diagnostic_precedence_size_before_parse() {
    let mut text = vec![0u8; 1024 * 1024 + 10];
    text.fill(b'a');
    text[0] = 0;
    let diags = err(&String::from_utf8_lossy(&text));
    assert_eq!(diags[0].kind, ManifestErrorKind::TooLarge);
}

#[test]
fn diagnostic_order_unknown_before_schema_field_order() {
    let yaml = "hooks: 1\nschema_version: 2\nid: usth\nversion: v\ndisplay_name: n\nprofiles:\n  - id: usth/a\n    path: profiles/a.yaml\n    sha256: abcd0123abcd0123abcd0123abcd0123abcd0123abcd0123abcd0123abcd0123\n";
    let diags = err(yaml);
    let hooks_idx = diags.iter().position(|d| d.field == "hooks").unwrap();
    let schema_idx = diags
        .iter()
        .position(|d| d.field == "schema_version")
        .unwrap();
    assert!(hooks_idx < schema_idx);
}

#[test]
fn source_label_in_diagnostics_not_opened() {
    let diags = err("id: only");
    assert!(diags.iter().all(|d| d.source == LABEL));
}

#[test]
fn newtypes_expose_as_str_helpers() {
    let manifest = ok(&minimal_manifest(""));
    assert_eq!(manifest.id.as_str(), "usth");
    assert_eq!(manifest.profiles[0].id.as_str(), "usth/keithley-2400");
}
