use std::collections::BTreeSet;

use super::v3::ProfileDocumentV3;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ProfileColumn {
    pub key: String,
    pub header: Option<String>,
    pub aliases: Vec<String>,
    pub quantity: String,
    pub unit: String,
    pub label: String,
    pub index: Option<usize>,
    pub required: bool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ProfileFormat {
    pub id: String,
    pub kind: String,
    pub extensions: Vec<String>,
    pub delimiter: char,
    pub encoding_names: Vec<String>,
    pub decimal_separator: char,
    pub names_prefix: Option<String>,
    pub data_prefix: Option<String>,
    pub columns: Vec<ProfileColumn>,
}

impl ProfileFormat {
    pub fn column(&self, key: &str) -> Option<&ProfileColumn> {
        self.columns.iter().find(|c| c.key == key)
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ProfileMode {
    pub id: String,
    pub format_id: String,
    pub detect: Vec<String>,
    pub filename_contains_all: Option<Vec<String>>,
    pub x: String,
    pub y: Vec<String>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct InstrumentProfile {
    /// Catalog profile identifier (`namespace/id` for v4 and namespaced v1/v2).
    pub profile_id: String,
    pub instrument_id: String,
    pub instrument_name: String,
    pub vendor: Option<String>,
    pub model: Option<String>,
    pub formats: Vec<ProfileFormat>,
    pub modes: Vec<ProfileMode>,
    pub relative_path: String,
    pub sha256: String,
    pub schema_version: i32,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ProfileMatch {
    pub profile: InstrumentProfile,
    pub format: ProfileFormat,
    pub mode: ProfileMode,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ProfileResolution {
    Matched(Box<ProfileMatch>),
    Failed(String),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BrokenModeSelectors {
    pub filenames: Option<Vec<String>>,
    pub signatures: Vec<String>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BrokenClaim {
    pub relative_path: String,
    pub extensions: Vec<String>,
    pub issues: Vec<String>,
    pub mode_selectors: Vec<BrokenModeSelectors>,
    pub content_sha256: String,
}

impl BrokenClaim {
    pub fn blocks(&self, sample: &str, basename: &str) -> bool {
        if self.mode_selectors.is_empty() {
            return true;
        }
        let sample = sample.to_lowercase();
        let base = basename.to_lowercase();
        for mode in &self.mode_selectors {
            let filename_mismatch = mode
                .filenames
                .as_ref()
                .map(|tokens| !tokens.iter().all(|t| base.contains(&t.to_lowercase())))
                .unwrap_or(false);
            let header_mismatch = !mode.signatures.is_empty()
                && !mode
                    .signatures
                    .iter()
                    .any(|sig| sample.contains(&sig.to_lowercase()));
            if !filename_mismatch && !header_mismatch {
                return true;
            }
        }
        false
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LoadedV3Document {
    pub document: ProfileDocumentV3,
    pub relative_path: String,
    pub sha256: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ProfileLoadOutcome {
    pub profile: Option<InstrumentProfile>,
    pub issues: Vec<String>,
    pub extensions: Vec<String>,
    pub mode_selectors: Vec<BrokenModeSelectors>,
    pub v3_document: Option<LoadedV3Document>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ProfileCatalog {
    pub profiles: Vec<InstrumentProfile>,
    pub issues: Vec<String>,
    pub broken_claims: Vec<BrokenClaim>,
    pub v3_documents: Vec<LoadedV3Document>,
}

impl ProfileCatalog {
    pub const SUPPORTED_SCHEMA_VERSIONS: [i32; 2] = [1, 2];
    pub const MAXIMUM_PROFILE_BYTES: usize = 1 << 20;

    pub fn has_broken_claim(&self, file_extension: &str) -> bool {
        self.broken_claims
            .iter()
            .any(|c| c.extensions.contains(&file_extension.to_string()))
    }

    pub fn has_valid_claim(&self, file_extension: &str) -> bool {
        self.profiles.iter().any(|profile| {
            profile
                .formats
                .iter()
                .any(|f| f.extensions.iter().any(|e| e == file_extension))
        })
    }
}

pub fn humanized(key: &str) -> String {
    key.replace('_', " ")
        .split_whitespace()
        .map(|word| {
            let mut chars = word.chars();
            match chars.next() {
                None => String::new(),
                Some(first) => first.to_uppercase().chain(chars).collect(),
            }
        })
        .collect::<Vec<_>>()
        .join(" ")
}

pub fn unique_sorted(mut values: Vec<String>) -> Vec<String> {
    let set: BTreeSet<_> = values.drain(..).collect();
    set.into_iter().collect()
}
