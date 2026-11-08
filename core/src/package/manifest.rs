//! In-memory `package.yaml` validation (manifest text only; no install I/O).

use crate::yaml::{parse, YamlNode, YamlParseError};

pub const PACKAGE_MANIFEST_SCHEMA_VERSION: u32 = 1;

const MAX_MANIFEST_BYTES: usize = 1024 * 1024;
const MAX_PROFILES: usize = 256;
const MAX_VERSION_LEN: usize = 128;
const MAX_DISPLAY_NAME_SCALARS: usize = 256;
const MAX_ID_SEGMENT_LEN: usize = 64;
const MAX_PATH_BYTES: usize = 1024;
const MAX_PATH_COMPONENT_BYTES: usize = 255;

const TOP_LEVEL_KEYS: &[&str] = &[
    "schema_version",
    "id",
    "version",
    "display_name",
    "profiles",
];
const PROFILE_KEYS: &[&str] = &["id", "path", "sha256"];

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PackageManifest {
    pub schema_version: u32,
    pub id: PackageId,
    pub version: String,
    pub display_name: String,
    pub profiles: Vec<PackageProfileEntry>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PackageProfileEntry {
    pub id: CanonicalProfileId,
    pub path: ManifestPath,
    pub sha256: Sha256Hex,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PackageId(String);

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CanonicalProfileId(String);

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ManifestPath(String);

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Sha256Hex(String);

impl PackageId {
    pub fn as_str(&self) -> &str {
        &self.0
    }
}

impl CanonicalProfileId {
    pub fn as_str(&self) -> &str {
        &self.0
    }

    pub fn namespace(&self) -> &str {
        self.0.split_once('/').map(|(ns, _)| ns).unwrap_or("")
    }

    pub fn name(&self) -> &str {
        self.0.split_once('/').map(|(_, n)| n).unwrap_or("")
    }
}

impl ManifestPath {
    pub fn as_str(&self) -> &str {
        &self.0
    }
}

impl Sha256Hex {
    pub fn as_str(&self) -> &str {
        &self.0
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ManifestDiagnostic {
    pub source: String,
    pub field: String,
    pub line: Option<usize>,
    pub kind: ManifestErrorKind,
    pub detail: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ManifestErrorKind {
    TooLarge,
    ContainsNul,
    Syntax,
    UnsupportedSyntax,
    SchemaVersion,
    MissingField,
    UnknownField,
    WrongShape,
    InvalidValue,
    DuplicateProfileId,
    PathCollision,
    TooManyProfiles,
    EmptyProfiles,
}

pub fn parse_package_manifest(
    text: &str,
    source_label: &str,
) -> Result<PackageManifest, Vec<ManifestDiagnostic>> {
    let mut diagnostics: Vec<ManifestDiagnostic> = Vec::new();
    let push = |diagnostics: &mut Vec<ManifestDiagnostic>, d: ManifestDiagnostic| {
        diagnostics.push(d);
    };

    if text.len() > MAX_MANIFEST_BYTES {
        push(
            &mut diagnostics,
            diag(
                source_label,
                "",
                None,
                ManifestErrorKind::TooLarge,
                format!("manifest exceeds {} bytes", MAX_MANIFEST_BYTES),
            ),
        );
        return Err(diagnostics);
    }
    if text.bytes().any(|b| b == 0) {
        push(
            &mut diagnostics,
            diag(
                source_label,
                "",
                None,
                ManifestErrorKind::ContainsNul,
                "manifest contains a NUL byte",
            ),
        );
        return Err(diagnostics);
    }

    if let Some((line, detail)) = scan_unsupported_syntax(text) {
        push(
            &mut diagnostics,
            diag(
                source_label,
                "",
                Some(line),
                ManifestErrorKind::UnsupportedSyntax,
                detail,
            ),
        );
        return Err(diagnostics);
    }

    let root = match parse(text, false) {
        Ok(node) => node,
        Err(YamlParseError { line, message }) => {
            push(
                &mut diagnostics,
                diag(
                    source_label,
                    "",
                    Some(line),
                    ManifestErrorKind::Syntax,
                    message,
                ),
            );
            return Err(diagnostics);
        }
    };

    validate_root_map(source_label, &root, &mut diagnostics)
}

fn diag(
    source: &str,
    field: impl Into<String>,
    line: Option<usize>,
    kind: ManifestErrorKind,
    detail: impl Into<String>,
) -> ManifestDiagnostic {
    ManifestDiagnostic {
        source: source.to_string(),
        field: field.into(),
        line,
        kind,
        detail: detail.into(),
    }
}

fn validate_root_map(
    source: &str,
    root: &YamlNode,
    diagnostics: &mut Vec<ManifestDiagnostic>,
) -> Result<PackageManifest, Vec<ManifestDiagnostic>> {
    let entries = match root.map_entries() {
        Some(e) => e,
        None => {
            diagnostics.push(diag(
                source,
                "",
                None,
                ManifestErrorKind::WrongShape,
                "manifest root must be a mapping",
            ));
            return Err(std::mem::take(diagnostics));
        }
    };

    let mut by_key: std::collections::HashMap<&str, &YamlNode> = std::collections::HashMap::new();
    for (key, value) in entries {
        if !TOP_LEVEL_KEYS.contains(&key.as_str()) {
            diagnostics.push(diag(
                source,
                key,
                None,
                ManifestErrorKind::UnknownField,
                format!("unknown field \"{key}\""),
            ));
            continue;
        }
        by_key.entry(key.as_str()).or_insert(value);
    }

    let mut schema_version: Option<u32> = None;
    let mut package_id: Option<PackageId> = None;
    let mut version: Option<String> = None;
    let mut display_name: Option<String> = None;

    match by_key.get("schema_version") {
        Some(value) => match read_schema_version(value) {
            Ok(v) => schema_version = Some(v),
            Err(kind) => diagnostics.push(diag(
                source,
                "schema_version",
                None,
                kind,
                "schema_version must be the scalar text \"1\"",
            )),
        },
        None => diagnostics.push(diag(
            source,
            "schema_version",
            None,
            ManifestErrorKind::MissingField,
            "missing required field \"schema_version\"",
        )),
    }

    if let Some(value) = by_key.get("id") {
        match parse_package_id(value) {
            Ok(id) => package_id = Some(id),
            Err(detail) => diagnostics.push(diag(
                source,
                "id",
                None,
                ManifestErrorKind::InvalidValue,
                detail,
            )),
        }
    } else if !diagnostics.iter().any(|d| d.field == "id") {
        diagnostics.push(diag(
            source,
            "id",
            None,
            ManifestErrorKind::MissingField,
            "missing required field \"id\"",
        ));
    }

    if let Some(value) = by_key.get("version") {
        match parse_version(value) {
            Ok(v) => version = Some(v),
            Err(detail) => diagnostics.push(diag(
                source,
                "version",
                None,
                ManifestErrorKind::InvalidValue,
                detail,
            )),
        }
    } else if !diagnostics.iter().any(|d| d.field == "version") {
        diagnostics.push(diag(
            source,
            "version",
            None,
            ManifestErrorKind::MissingField,
            "missing required field \"version\"",
        ));
    }

    if let Some(value) = by_key.get("display_name") {
        match parse_display_name(value) {
            Ok(v) => display_name = Some(v),
            Err(detail) => diagnostics.push(diag(
                source,
                "display_name",
                None,
                ManifestErrorKind::InvalidValue,
                detail,
            )),
        }
    } else if !diagnostics.iter().any(|d| d.field == "display_name") {
        diagnostics.push(diag(
            source,
            "display_name",
            None,
            ManifestErrorKind::MissingField,
            "missing required field \"display_name\"",
        ));
    }

    let profiles_value = match by_key.get("profiles") {
        Some(v) => *v,
        None => {
            diagnostics.push(diag(
                source,
                "profiles",
                None,
                ManifestErrorKind::MissingField,
                "missing required field \"profiles\"",
            ));
            return Err(std::mem::take(diagnostics));
        }
    };

    if !diagnostics.is_empty() {
        return Err(std::mem::take(diagnostics));
    }

    let profiles_list = match profiles_value.list_items() {
        Some(items) => items,
        None => {
            if matches!(profiles_value, YamlNode::Scalar(s) if s.is_empty()) {
                diagnostics.push(diag(
                    source,
                    "profiles",
                    None,
                    ManifestErrorKind::EmptyProfiles,
                    "profiles must not be empty",
                ));
                return Err(std::mem::take(diagnostics));
            }
            diagnostics.push(diag(
                source,
                "profiles",
                None,
                ManifestErrorKind::WrongShape,
                "profiles must be a sequence",
            ));
            return Err(std::mem::take(diagnostics));
        }
    };

    if profiles_list.is_empty() {
        diagnostics.push(diag(
            source,
            "profiles",
            None,
            ManifestErrorKind::EmptyProfiles,
            "profiles must not be empty",
        ));
        return Err(std::mem::take(diagnostics));
    }
    if profiles_list.len() > MAX_PROFILES {
        diagnostics.push(diag(
            source,
            "profiles",
            None,
            ManifestErrorKind::TooManyProfiles,
            format!("profiles exceeds {} entries", MAX_PROFILES),
        ));
        return Err(std::mem::take(diagnostics));
    }

    let mut profiles: Vec<PackageProfileEntry> = Vec::new();
    let mut seen_ids: Vec<(String, usize)> = Vec::new();
    let mut seen_paths: Vec<(String, usize)> = Vec::new();

    for (index, item) in profiles_list.iter().enumerate() {
        let prefix = format!("profiles[{index}]");
        let entry = match validate_profile_entry(source, item, &prefix, diagnostics) {
            Ok(e) => e,
            Err(()) => {
                if !diagnostics.is_empty() {
                    return Err(std::mem::take(diagnostics));
                }
                continue;
            }
        };

        if let Some((_, prior)) = seen_ids.iter().find(|(id, _)| id == entry.id.as_str()) {
            diagnostics.push(diag(
                source,
                format!("{prefix}.id"),
                None,
                ManifestErrorKind::DuplicateProfileId,
                format!("duplicate profile id \"{}\"", entry.id.as_str()),
            ));
            let _ = prior;
            return Err(std::mem::take(diagnostics));
        }
        seen_ids.push((entry.id.as_str().to_string(), index));

        let folded = ascii_casefold_path(entry.path.as_str());
        if let Some((_, prior)) = seen_paths.iter().find(|(p, _)| p == &folded) {
            diagnostics.push(diag(
                source,
                format!("{prefix}.path"),
                None,
                ManifestErrorKind::PathCollision,
                format!("path collides with profiles[{prior}]"),
            ));
            return Err(std::mem::take(diagnostics));
        }
        seen_paths.push((folded, index));

        profiles.push(entry);
    }

    if !diagnostics.is_empty() {
        return Err(std::mem::take(diagnostics));
    }

    Ok(PackageManifest {
        schema_version: schema_version.unwrap_or(PACKAGE_MANIFEST_SCHEMA_VERSION),
        id: package_id.expect("validated"),
        version: version.expect("validated"),
        display_name: display_name.expect("validated"),
        profiles,
    })
}

fn validate_profile_entry(
    source: &str,
    item: &YamlNode,
    prefix: &str,
    diagnostics: &mut Vec<ManifestDiagnostic>,
) -> Result<PackageProfileEntry, ()> {
    let entries = match item.map_entries() {
        Some(e) => e,
        None => {
            diagnostics.push(diag(
                source,
                prefix,
                None,
                ManifestErrorKind::WrongShape,
                "profile entry must be a mapping",
            ));
            return Err(());
        }
    };

    let mut profile_id: Option<CanonicalProfileId> = None;
    let mut path: Option<ManifestPath> = None;
    let mut sha: Option<Sha256Hex> = None;

    for (key, value) in entries {
        if !PROFILE_KEYS.contains(&key.as_str()) {
            diagnostics.push(diag(
                source,
                format!("{prefix}.{key}"),
                None,
                ManifestErrorKind::UnknownField,
                format!("unknown field \"{key}\""),
            ));
            continue;
        }
        match key.as_str() {
            "id" if profile_id.is_none() => match parse_profile_id(value) {
                Ok(id) => profile_id = Some(id),
                Err(detail) => diagnostics.push(diag(
                    source,
                    format!("{prefix}.id"),
                    None,
                    ManifestErrorKind::InvalidValue,
                    detail,
                )),
            },
            "path" if path.is_none() => match parse_manifest_path(value) {
                Ok(p) => path = Some(p),
                Err(detail) => diagnostics.push(diag(
                    source,
                    format!("{prefix}.path"),
                    None,
                    ManifestErrorKind::InvalidValue,
                    detail,
                )),
            },
            "sha256" if sha.is_none() => match parse_sha256(value) {
                Ok(h) => sha = Some(h),
                Err(detail) => diagnostics.push(diag(
                    source,
                    format!("{prefix}.sha256"),
                    None,
                    ManifestErrorKind::InvalidValue,
                    detail,
                )),
            },
            _ => {}
        }
    }

    if profile_id.is_none() {
        diagnostics.push(diag(
            source,
            format!("{prefix}.id"),
            None,
            ManifestErrorKind::MissingField,
            "missing required field \"id\"",
        ));
    }
    if path.is_none() {
        diagnostics.push(diag(
            source,
            format!("{prefix}.path"),
            None,
            ManifestErrorKind::MissingField,
            "missing required field \"path\"",
        ));
    }
    if sha.is_none() {
        diagnostics.push(diag(
            source,
            format!("{prefix}.sha256"),
            None,
            ManifestErrorKind::MissingField,
            "missing required field \"sha256\"",
        ));
    }

    if !diagnostics.is_empty() {
        return Err(());
    }

    Ok(PackageProfileEntry {
        id: profile_id.expect("validated"),
        path: path.expect("validated"),
        sha256: sha.expect("validated"),
    })
}

fn scalar_text(node: &YamlNode) -> Option<&str> {
    match node {
        YamlNode::Scalar(s) => Some(s.as_str()),
        _ => None,
    }
}

fn read_schema_version(node: &YamlNode) -> Result<u32, ManifestErrorKind> {
    let text = scalar_text(node).ok_or(ManifestErrorKind::WrongShape)?;
    if text == "1" {
        return Ok(1);
    }
    Err(ManifestErrorKind::SchemaVersion)
}

fn parse_version(node: &YamlNode) -> Result<String, String> {
    let text = scalar_text(node).ok_or_else(|| "version must be a scalar".to_string())?;
    if text.is_empty() {
        return Err("version must not be empty".into());
    }
    if text.chars().any(|c| c.is_control()) {
        return Err("version must not contain control characters".into());
    }
    if !text.chars().all(is_visible_ascii) {
        return Err("version must be visible ASCII".into());
    }
    if text.len() > MAX_VERSION_LEN {
        return Err(format!("version exceeds {} characters", MAX_VERSION_LEN));
    }
    Ok(text.to_string())
}

fn parse_display_name(node: &YamlNode) -> Result<String, String> {
    let text = scalar_text(node).ok_or_else(|| "display_name must be a scalar".to_string())?;
    if text.is_empty() {
        return Err("display_name must not be empty".into());
    }
    let scalar_count = text.chars().count();
    if scalar_count > MAX_DISPLAY_NAME_SCALARS {
        return Err(format!(
            "display_name exceeds {} scalar values",
            MAX_DISPLAY_NAME_SCALARS
        ));
    }
    if text.chars().any(|c| c.is_control()) {
        return Err("display_name must not contain control characters".into());
    }
    Ok(text.to_string())
}

fn parse_package_id(node: &YamlNode) -> Result<PackageId, String> {
    let text = scalar_text(node).ok_or_else(|| "id must be a scalar".to_string())?;
    validate_id_segment(text).map(|s| PackageId(s.to_string()))
}

fn parse_profile_id(node: &YamlNode) -> Result<CanonicalProfileId, String> {
    let text = scalar_text(node).ok_or_else(|| "id must be a scalar".to_string())?;
    let Some((ns, name)) = text.split_once('/') else {
        return Err("profile id must be namespace/name".into());
    };
    validate_id_segment(ns)?;
    validate_id_segment(name)?;
    Ok(CanonicalProfileId(text.to_string()))
}

fn validate_id_segment(segment: &str) -> Result<&str, String> {
    if segment.is_empty() {
        return Err("id segment must not be empty".into());
    }
    if segment.len() > MAX_ID_SEGMENT_LEN {
        return Err(format!(
            "id segment exceeds {} characters",
            MAX_ID_SEGMENT_LEN
        ));
    }
    let mut chars = segment.chars();
    let first = chars.next().unwrap();
    if !first.is_ascii_lowercase() && !first.is_ascii_digit() {
        return Err("id segment must start with [a-z0-9]".into());
    }
    if !segment
        .chars()
        .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '_' || c == '-')
    {
        return Err("id segment contains invalid characters".into());
    }
    Ok(segment)
}

fn parse_sha256(node: &YamlNode) -> Result<Sha256Hex, String> {
    let text = scalar_text(node).ok_or_else(|| "sha256 must be a scalar".to_string())?;
    if text.len() != 64 {
        return Err("sha256 must be exactly 64 hex digits".into());
    }
    if !text.chars().all(|c| c.is_ascii_hexdigit()) {
        return Err("sha256 must contain only hex digits".into());
    }
    Ok(Sha256Hex(text.to_ascii_lowercase()))
}

fn parse_manifest_path(node: &YamlNode) -> Result<ManifestPath, String> {
    let text = scalar_text(node).ok_or_else(|| "path must be a scalar".to_string())?;
    validate_manifest_path(text).map(|s| ManifestPath(s.to_string()))
}

fn validate_manifest_path(path: &str) -> Result<&str, String> {
    if path.is_empty() {
        return Err("path must not be empty".into());
    }
    if path.len() > MAX_PATH_BYTES {
        return Err(format!("path exceeds {} bytes", MAX_PATH_BYTES));
    }
    if path.contains('\\') {
        return Err("path must not contain backslash".into());
    }
    if path.contains(':') {
        return Err("path must not contain colon".into());
    }
    if path.starts_with('/') {
        return Err("path must be relative".into());
    }
    if path.chars().any(|c| c.is_control()) {
        return Err("path must not contain control characters".into());
    }
    for forbidden in ['<', '>', '"', '|', '?', '*'] {
        if path.contains(forbidden) {
            return Err(format!("path must not contain '{forbidden}'"));
        }
    }
    if path.contains("..") {
        return Err("path must not contain '..'".into());
    }
    if looks_like_drive_or_unc(path) {
        return Err("path must not use drive or UNC form".into());
    }

    let parts: Vec<&str> = path.split('/').collect();
    if parts.len() != 2 {
        return Err("path must be exactly profiles/<file>.yaml".into());
    }
    if parts[0] != "profiles" {
        return Err("path must start with profiles/".into());
    }
    let filename = parts[1];
    if filename.is_empty() || filename == "." || filename == ".." {
        return Err("invalid profile filename".into());
    }
    if filename.len() > MAX_PATH_COMPONENT_BYTES {
        return Err("path component too long".into());
    }
    if filename.ends_with('.') || filename.ends_with(' ') {
        return Err("path component must not end with dot or space".into());
    }
    if !filename.ends_with(".yaml") {
        return Err("profile file must use .yaml extension".into());
    }
    let stem = &filename[..filename.len() - 5];
    if stem.is_empty() {
        return Err("profile filename stem must not be empty".into());
    }
    if stem.contains('/') {
        return Err("path must not contain nested directories".into());
    }
    if windows_reserved_basename(stem) {
        return Err("path uses a Windows reserved basename".into());
    }
    Ok(path)
}

fn looks_like_drive_or_unc(path: &str) -> bool {
    let bytes = path.as_bytes();
    (bytes.len() >= 2 && bytes[1] == b':' && bytes[0].is_ascii_alphabetic())
        || path.starts_with("//")
        || path.starts_with("\\\\")
}

fn windows_reserved_basename(stem: &str) -> bool {
    let folded = stem.to_ascii_lowercase();
    const RESERVED: &[&str] = &[
        "con", "prn", "aux", "nul", "com1", "com2", "com3", "com4", "com5", "com6", "com7", "com8",
        "com9", "lpt1", "lpt2", "lpt3", "lpt4", "lpt5", "lpt6", "lpt7", "lpt8", "lpt9",
    ];
    RESERVED.contains(&folded.as_str())
}

fn ascii_casefold_path(path: &str) -> String {
    path.chars().flat_map(char::to_lowercase).collect()
}

fn is_visible_ascii(c: char) -> bool {
    c.is_ascii() && !c.is_control()
}

/// Quote-aware pre-parse scan for unsupported scalar forms (mandatory before `yaml::parse`).
fn scan_unsupported_syntax(text: &str) -> Option<(usize, String)> {
    let normalized = text.replace("\r\n", "\n").replace('\r', "\n");
    for (offset, raw) in normalized.split('\n').enumerate() {
        let line_no = offset + 1;
        let body = match strip_comment(raw) {
            Ok(b) => b,
            Err(_) => continue,
        };
        let trimmed = body.trim();
        if trimmed.is_empty() {
            continue;
        }
        let mut indent = 0usize;
        let mut rest = trimmed;
        while rest.starts_with(' ') {
            indent += 1;
            rest = &rest[1..];
        }
        if rest.is_empty() {
            continue;
        }

        if rest == "-" || rest.starts_with("- ") {
            let item = if rest == "-" {
                ""
            } else {
                rest[1..].trim_start()
            };
            if item.is_empty() {
                continue;
            }
            if is_mapping_entry(item) {
                let (key, value) = split_key_value(item)?;
                if let Some(detail) = check_map_key(&key) {
                    return Some((line_no, detail));
                }
                if !value.is_empty() {
                    if let Some(detail) = check_scalar_token(&value, line_no) {
                        return Some((line_no, detail));
                    }
                }
            } else if let Some(detail) = check_scalar_token(item, line_no) {
                return Some((line_no, detail));
            }
            continue;
        }

        if let Some((key, value)) = split_key_value(rest) {
            if let Some(detail) = check_map_key(&key) {
                return Some((line_no, detail));
            }
            if !value.is_empty() {
                if let Some(detail) = check_scalar_token(&value, line_no) {
                    return Some((line_no, detail));
                }
            }
        }
        let _ = indent;
    }
    None
}

fn check_map_key(key: &str) -> Option<String> {
    if key.starts_with('*') || key.starts_with('&') || key.starts_with('!') {
        return Some(format!("unsupported map key \"{key}\""));
    }
    None
}

fn check_scalar_token(token: &str, _line: usize) -> Option<String> {
    if token.starts_with('"') || token.starts_with('\'') {
        return None;
    }
    if token.starts_with('!') || token.starts_with('&') || token.starts_with('*') {
        return Some("unsupported tag, anchor, or alias scalar".into());
    }
    if token == "|" || token == ">" || token.starts_with('|') || token.starts_with('>') {
        return Some("block scalar syntax is not supported".into());
    }
    if token.starts_with('{') {
        return Some("flow mapping is not supported".into());
    }
    if token.starts_with('[') {
        return Some("flow sequence is not supported".into());
    }
    None
}

fn is_mapping_entry(content: &str) -> bool {
    let Some(colon_idx) = content.find(':') else {
        return false;
    };
    let next_idx = colon_idx + 1;
    next_idx >= content.len()
        || content.as_bytes()[next_idx] == b' '
        || content.as_bytes()[next_idx] == b'\t'
}

fn split_key_value(content: &str) -> Option<(String, String)> {
    let colon_idx = content.find(':')?;
    let next_idx = colon_idx + 1;
    if next_idx < content.len() {
        let next = content.as_bytes()[next_idx];
        if next != b' ' && next != b'\t' {
            return None;
        }
    }
    let key = content[..colon_idx].trim();
    if key.is_empty() || key.contains('"') || key.contains('\'') {
        return None;
    }
    let value = if next_idx >= content.len() {
        String::new()
    } else {
        content[next_idx..].trim().to_string()
    };
    Some((key.to_string(), value))
}

fn is_escaped_double_quote(token_with_quote: &str) -> bool {
    let mut backslashes = 0usize;
    for ch in token_with_quote.chars().rev().skip(1) {
        if ch == '\\' {
            backslashes += 1;
        } else {
            break;
        }
    }
    backslashes % 2 == 1
}

fn strip_comment(body: &str) -> Result<String, ()> {
    let mut quote: Option<char> = None;
    let mut previous: char = ' ';
    let mut result = String::new();
    for character in body.chars() {
        if let Some(active) = quote {
            result.push(character);
            if active == '\'' {
                if character == '\'' {
                    quote = None;
                }
            } else if character == '"' && !is_escaped_double_quote(&result) {
                quote = None;
            }
        } else if character == '"' || character == '\'' {
            quote = Some(character);
            result.push(character);
        } else if character == '#' && (previous == ' ' || previous == '\t' || result.is_empty()) {
            break;
        } else {
            result.push(character);
        }
        previous = character;
    }
    Ok(result)
}
