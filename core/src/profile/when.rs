//! Unified `when` matching for instrument profile resolution (schema v1–v4).

use std::collections::{BTreeMap, HashMap, HashSet};

/// Case-insensitive content matching applies to the first 64 KiB of the source.
pub const CONTENT_MATCH_BYTE_LIMIT: usize = 64 * 1024;

const TOKEN_DELIMITERS: [char; 4] = ['_', '.', '-', ' '];

#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct WhenClause {
    pub grammar_tokens: BTreeMap<String, String>,
    pub content_contains_any: Vec<String>,
    pub content_starts_with: Vec<String>,
    pub filename_tokens: Vec<String>,
}

impl WhenClause {
    pub fn is_content_only(&self) -> bool {
        self.grammar_tokens.is_empty()
            && self.filename_tokens.is_empty()
            && (!self.content_contains_any.is_empty() || !self.content_starts_with.is_empty())
    }

    pub fn has_selectors(&self) -> bool {
        !self.grammar_tokens.is_empty()
            || !self.filename_tokens.is_empty()
            || !self.content_contains_any.is_empty()
            || !self.content_starts_with.is_empty()
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct GrammarMatchContext {
    pub catalog_loaded: bool,
    pub matched_fields: Option<HashMap<String, String>>,
}

impl GrammarMatchContext {
    pub fn grammar_matched(&self) -> bool {
        self.matched_fields.is_some()
    }

    pub fn without_catalog() -> Self {
        Self {
            catalog_loaded: false,
            matched_fields: None,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ProfileResolveCode {
    AmbiguousProfile,
    GrammarMatchedNoProfile,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ProfileResolution {
    Matched(Box<super::ProfileMatch>),
    Failed(String),
    AmbiguousProfile { candidate_ids: Vec<String> },
    GrammarMatchedNoProfile,
}

impl ProfileResolution {
    pub fn code(&self) -> Option<ProfileResolveCode> {
        match self {
            Self::AmbiguousProfile { .. } => Some(ProfileResolveCode::AmbiguousProfile),
            Self::GrammarMatchedNoProfile => Some(ProfileResolveCode::GrammarMatchedNoProfile),
            _ => None,
        }
    }

    pub fn into_failed_message(self) -> Result<Box<super::ProfileMatch>, String> {
        match self {
            Self::Matched(m) => Ok(m),
            Self::AmbiguousProfile { candidate_ids } => Err(format_ambiguous(&candidate_ids)),
            Self::GrammarMatchedNoProfile => Err(
                "Filename matched the project grammar but no instrument profile mode matched this source."
                    .into(),
            ),
            Self::Failed(message) => Err(message),
        }
    }
}

pub fn format_ambiguous(candidate_ids: &[String]) -> String {
    format!(
        "ambiguous_profile: {} candidate(s): {}.",
        candidate_ids.len(),
        candidate_ids.join(", ")
    )
}

pub fn ambiguous_candidate_labels(matches: &[super::ProfileMatch]) -> Vec<String> {
    use std::collections::HashMap;
    let mut per_profile: HashMap<String, usize> = HashMap::new();
    for m in matches {
        *per_profile
            .entry(candidate_profile_id(&m.profile))
            .or_default() += 1;
    }
    let mut labels: Vec<String> = matches
        .iter()
        .map(|m| {
            let profile_id = candidate_profile_id(&m.profile);
            if per_profile.get(&profile_id).copied().unwrap_or(0) > 1 {
                format!("{profile_id} mode {}", m.mode.id)
            } else {
                profile_id
            }
        })
        .collect();
    labels.sort();
    labels.dedup();
    labels
}

pub fn split_legacy_filename_tokens(entries: &[String]) -> Vec<String> {
    let mut out = Vec::new();
    for entry in entries {
        out.extend(tokenize_fragment(entry));
    }
    out
}

pub fn tokenize_basename(basename: &str) -> Vec<String> {
    let stem = basename
        .rsplit_once('.')
        .map(|(s, _)| s)
        .unwrap_or(basename);
    tokenize_fragment(stem)
}

fn tokenize_fragment(text: &str) -> Vec<String> {
    let mut tokens = Vec::new();
    let mut current = String::new();
    for ch in text.chars() {
        if TOKEN_DELIMITERS.contains(&ch) {
            if !current.is_empty() {
                tokens.push(current.clone());
                current.clear();
            }
        } else if !ch.is_whitespace() {
            current.push(ch);
        } else if !current.is_empty() {
            tokens.push(current.clone());
            current.clear();
        }
    }
    if !current.is_empty() {
        tokens.push(current);
    }
    tokens
}

pub fn merge_when(profile: Option<&WhenClause>, variant: Option<&WhenClause>) -> WhenClause {
    let mut merged = WhenClause::default();
    if let Some(p) = profile {
        merged.grammar_tokens.extend(p.grammar_tokens.clone());
        merged
            .content_contains_any
            .extend(p.content_contains_any.clone());
        merged
            .content_starts_with
            .extend(p.content_starts_with.clone());
        merged.filename_tokens.extend(p.filename_tokens.clone());
    }
    if let Some(v) = variant {
        merged.grammar_tokens.extend(v.grammar_tokens.clone());
        merged
            .content_contains_any
            .extend(v.content_contains_any.clone());
        merged
            .content_starts_with
            .extend(v.content_starts_with.clone());
        merged.filename_tokens.extend(v.filename_tokens.clone());
    }
    merged
}

pub fn when_from_legacy(detect: &[String], filename_contains_all: Option<&[String]>) -> WhenClause {
    WhenClause {
        grammar_tokens: BTreeMap::new(),
        content_contains_any: detect.to_vec(),
        content_starts_with: Vec::new(),
        filename_tokens: filename_contains_all
            .map(split_legacy_filename_tokens)
            .unwrap_or_default(),
    }
}

pub fn when_from_v4_clause(clause: &super::WhenClauseV4) -> WhenClause {
    WhenClause {
        grammar_tokens: clause.tokens.clone(),
        content_contains_any: clause.content_contains_any.clone().unwrap_or_default(),
        content_starts_with: clause.content_starts_with.clone().unwrap_or_default(),
        filename_tokens: clause
            .filename_contains_all
            .as_ref()
            .map(|v| split_legacy_filename_tokens(v))
            .unwrap_or_default(),
    }
}

pub fn grammar_context_from_catalog(
    catalog: Option<&crate::grammar::FilenameGrammarCatalog>,
    basename: &str,
) -> GrammarMatchContext {
    let Some(catalog) = catalog else {
        return GrammarMatchContext::without_catalog();
    };
    for grammar in &catalog.grammars {
        let facts = crate::grammar::extract(basename, grammar);
        if facts.is_matched {
            return GrammarMatchContext {
                catalog_loaded: true,
                matched_fields: Some(facts.extracted_fields),
            };
        }
    }
    GrammarMatchContext {
        catalog_loaded: true,
        matched_fields: None,
    }
}

pub fn mode_is_candidate(merged: &WhenClause, grammar: &GrammarMatchContext) -> bool {
    if !grammar.catalog_loaded {
        return true;
    }
    if grammar.grammar_matched() {
        return true;
    }
    merged.is_content_only()
}

pub fn matches_when(
    merged: &WhenClause,
    grammar_fields: Option<&HashMap<String, String>>,
    basename_tokens: &[String],
    header_sample: &str,
    basename_for_content: &str,
) -> bool {
    if !merged.has_selectors() {
        return false;
    }
    let token_set: HashSet<&str> = basename_tokens.iter().map(String::as_str).collect();
    for required in &merged.filename_tokens {
        if !token_set.contains(required.as_str()) {
            return false;
        }
    }
    for (key, expected) in &merged.grammar_tokens {
        let Some(actual) = grammar_fields.and_then(|f| f.get(key)) else {
            return false;
        };
        if actual != expected {
            return false;
        }
    }
    let sample = truncate_for_content(header_sample);
    let sample_lower = sample.to_lowercase();
    let basename_lower = basename_for_content.to_lowercase();
    let content_any_ok = merged.content_contains_any.is_empty()
        || merged.content_contains_any.iter().any(|sig| {
            let needle = sig.to_lowercase();
            sample_lower.contains(&needle) || basename_lower.contains(&needle)
        });
    if !content_any_ok {
        return false;
    }
    let content_starts_ok = merged.content_starts_with.is_empty()
        || merged.content_starts_with.iter().any(|sig| {
            let needle = sig.to_lowercase();
            sample_lower.starts_with(&needle) || basename_lower.starts_with(&needle)
        });
    content_starts_ok
}

fn truncate_for_content(header_sample: &str) -> &str {
    if header_sample.len() <= CONTENT_MATCH_BYTE_LIMIT {
        return header_sample;
    }
    &header_sample[..CONTENT_MATCH_BYTE_LIMIT]
}

pub fn describe_filename_miss(tokens: &[String], basename: &str) -> String {
    let have = tokenize_basename(basename);
    let set: HashSet<_> = have.iter().collect();
    let missing: Vec<_> = tokens
        .iter()
        .filter(|t| !set.contains(t))
        .cloned()
        .collect();
    if missing.is_empty() {
        format!("filename_contains_all matched basename \"{basename}\"")
    } else {
        format!(
            "filename_contains_all tokens {} not in basename \"{basename}\"",
            missing
                .iter()
                .map(|t| format!("\"{t}\""))
                .collect::<Vec<_>>()
                .join(", ")
        )
    }
}

pub fn describe_content_miss(when: &WhenClause, sample: &str) -> String {
    let sample_lower = sample.to_lowercase();
    if when
        .content_contains_any
        .iter()
        .any(|sig| sample_lower.contains(&sig.to_lowercase()))
    {
        return "detect matched header sample".into();
    }
    format!(
        "detect {} not in header sample",
        when.content_contains_any
            .iter()
            .map(|s| format!("\"{s}\""))
            .collect::<Vec<_>>()
            .join(", ")
    )
}

pub fn when_from_application_mode_id(
    mode_id: &str,
    detect_signatures: &[String],
    filename_contains_all: Option<&[String]>,
) -> WhenClause {
    let mut grammar_tokens = BTreeMap::new();
    grammar_tokens.insert("mode".into(), mode_id.into());
    WhenClause {
        grammar_tokens,
        content_contains_any: detect_signatures.to_vec(),
        content_starts_with: Vec::new(),
        filename_tokens: filename_contains_all
            .map(split_legacy_filename_tokens)
            .unwrap_or_default(),
    }
}

pub fn when_from_header_signature(mode_id: &str, signature: &str) -> WhenClause {
    WhenClause {
        grammar_tokens: BTreeMap::from([(mode_id.into(), mode_id.into())]),
        content_contains_any: vec![signature.into()],
        ..Default::default()
    }
}

pub fn candidate_profile_id(profile: &super::InstrumentProfile) -> String {
    if profile.profile_id.is_empty() {
        profile.relative_path.clone()
    } else {
        profile.profile_id.clone()
    }
}
