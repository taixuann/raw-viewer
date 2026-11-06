use crate::config::ConfigError;
use crate::grammar::{default_grammar, FilenameGrammar};
use crate::measurement::NormalizedMeasurement;
use crate::paths::{cache_dir, ResolveError};
use crate::profile::{
    ambiguous_candidate_labels, load_catalog, matches_when, merge_when, mode_is_candidate,
    GrammarMatchContext, InstrumentProfile, ProfileCatalog, ProfileMatch,
};
use crate::project::{ProjectContext, ProjectError};
use crate::reader::{
    decode_with_format, inspect as inspect_generic_table, load_measurement, ReaderError,
};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::collections::BTreeMap;
use std::fs;
use std::path::{Path, PathBuf};

fn sha256_hex(bytes: &[u8]) -> String {
    let mut hasher = Sha256::new();
    hasher.update(bytes);
    format!("{:x}", hasher.finalize())
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum GrammarSource {
    Project,
    Global,
    Builtin,
}

impl std::fmt::Display for GrammarSource {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            GrammarSource::Project => write!(f, "project"),
            GrammarSource::Global => write!(f, "global"),
            GrammarSource::Builtin => write!(f, "built-in"),
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct EffectiveGrammar {
    pub grammar: FilenameGrammar,
    pub source: GrammarSource,
    pub sha256: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ProfileSource {
    Project,
    Builtin,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ProfileSummary {
    pub id: String,
    pub instrument_id: String,
    pub instrument_name: String,
    pub revision: Option<String>,
    pub enabled: bool,
    pub source: ProfileSource,
    pub variants: Vec<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SourceItem {
    pub relative_path: String,
    pub file_name: String,
    pub byte_size: u64,
    pub extension: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct InventoryReport {
    pub sources: Vec<SourceItem>,
    pub directories: Vec<String>,
    pub total_files: usize,
    pub ignored: Vec<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "status", rename_all = "snake_case")]
pub enum MatchOutcome {
    Matched {
        profile_id: String,
        instrument_id: String,
        instrument_name: String,
        variant: String,
        tokens: BTreeMap<String, String>,
    },
    AmbiguousProfile {
        candidate_ids: Vec<String>,
    },
    GrammarMatchedNoProfile {
        tokens: BTreeMap<String, String>,
    },
    NoMatch {
        reason: String,
    },
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ProfileCandidateTrace {
    pub profile_id: String,
    pub instrument_name: String,
    pub variant: String,
    pub hit: bool,
    pub reason: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MatchTrace {
    pub grammar_source: String,
    pub tokens: BTreeMap<String, String>,
    pub candidates: Vec<ProfileCandidateTrace>,
    pub outcome: MatchOutcome,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ColumnSummary {
    pub name: String,
    pub role: String,
    pub quantity: Option<String>,
    pub unit: Option<String>,
    pub label: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct InspectionReport {
    pub relative_path: String,
    pub size_bytes: u64,
    pub sha256: String,
    pub profile_id: String,
    pub instrument_id: String,
    pub instrument_name: String,
    pub variant: String,
    pub tokens: BTreeMap<String, String>,
    pub columns: Vec<ColumnSummary>,
    pub x_quantity: Option<String>,
    pub x_unit: Option<String>,
    pub y_quantity: Option<String>,
    pub y_unit: Option<String>,
    pub data_row_count: usize,
    pub metadata: BTreeMap<String, String>,
    pub disposition: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ProjectSummary {
    pub root: String,
    pub data_root: String,
    pub grammar_source: GrammarSource,
    pub grammar_id: String,
    pub enabled_profiles: Vec<String>,
    pub disabled_profiles: Vec<String>,
    pub total_profiles: usize,
}

#[derive(Debug)]
pub enum ExplorerError {
    Project(ProjectError),
    Io(std::io::Error),
    Reader(ReaderError),
    Config(ConfigError),
    Paths(ResolveError),
    AmbiguousProfile { candidate_ids: Vec<String> },
    InvalidSource(String),
}

impl std::fmt::Display for ExplorerError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            ExplorerError::Project(e) => write!(f, "{e}"),
            ExplorerError::Io(e) => write!(f, "{e}"),
            ExplorerError::Reader(e) => write!(f, "{e}"),
            ExplorerError::Config(e) => write!(f, "{e}"),
            ExplorerError::Paths(e) => write!(f, "{e}"),
            ExplorerError::AmbiguousProfile { candidate_ids } => {
                write!(
                    f,
                    "ambiguous_profile: {} candidate(s): {}",
                    candidate_ids.len(),
                    candidate_ids.join(", ")
                )
            }
            ExplorerError::InvalidSource(s) => write!(f, "{s}"),
        }
    }
}

impl std::error::Error for ExplorerError {}

impl From<ProjectError> for ExplorerError {
    fn from(e: ProjectError) -> Self {
        ExplorerError::Project(e)
    }
}

impl From<std::io::Error> for ExplorerError {
    fn from(e: std::io::Error) -> Self {
        ExplorerError::Io(e)
    }
}

impl From<ReaderError> for ExplorerError {
    fn from(e: ReaderError) -> Self {
        ExplorerError::Reader(e)
    }
}

impl From<ConfigError> for ExplorerError {
    fn from(e: ConfigError) -> Self {
        ExplorerError::Config(e)
    }
}

impl From<ResolveError> for ExplorerError {
    fn from(e: ResolveError) -> Self {
        ExplorerError::Paths(e)
    }
}

pub struct Explorer {
    pub project: ProjectContext,
    pub effective_grammar: EffectiveGrammar,
    pub catalog: ProfileCatalog,
}

impl Explorer {
    pub fn open(project_root: &Path) -> Result<Self, ExplorerError> {
        let project = ProjectContext::open(project_root)?;
        let effective_grammar = resolve_effective_grammar(&project)?;
        let catalog = load_catalog(&project.root);
        Ok(Self {
            project,
            effective_grammar,
            catalog,
        })
    }

    pub fn summary(&self) -> ProjectSummary {
        let profiles = self.list_profiles();
        let enabled: Vec<String> = profiles
            .iter()
            .filter(|p| p.enabled)
            .map(|p| p.id.clone())
            .collect();
        let disabled: Vec<String> = profiles
            .iter()
            .filter(|p| !p.enabled)
            .map(|p| p.id.clone())
            .collect();
        ProjectSummary {
            root: self.project.root.display().to_string(),
            data_root: self.project.data_root_relative_path.clone(),
            grammar_source: self.effective_grammar.source.clone(),
            grammar_id: self.effective_grammar.grammar.id.clone(),
            enabled_profiles: enabled,
            disabled_profiles: disabled,
            total_profiles: profiles.len(),
        }
    }

    pub fn effective_grammar(&self) -> &EffectiveGrammar {
        &self.effective_grammar
    }

    pub fn list_profiles(&self) -> Vec<ProfileSummary> {
        let mut summaries = Vec::new();
        let disabled_set = &self.project.config.profiles.disabled;
        let enabled_set = &self.project.config.profiles.enabled;

        for profile in &self.catalog.profiles {
            let id = &profile.profile_id;
            let enabled = if disabled_set.iter().any(|d| d == id) {
                false
            } else if let Some(ref list) = enabled_set {
                list.iter().any(|e| e == id)
            } else {
                true
            };

            let source = if profile.relative_path.starts_with(".raw-viewer/profiles")
                || profile.relative_path.starts_with(".rawviewer/instrument")
                || profile.relative_path.starts_with("data/instruments")
            {
                ProfileSource::Project
            } else {
                ProfileSource::Builtin
            };

            let variants: Vec<String> = profile.modes.iter().map(|m| m.id.clone()).collect();

            summaries.push(ProfileSummary {
                id: id.clone(),
                instrument_id: profile.instrument_id.clone(),
                instrument_name: profile.instrument_name.clone(),
                revision: profile.revision.clone(),
                enabled,
                source,
                variants,
            });
        }
        summaries.sort_by(|a, b| a.id.cmp(&b.id));
        summaries
    }

    pub fn inventory(&self) -> Result<InventoryReport, ExplorerError> {
        let raw_root = &self.project.raw_root;
        if !raw_root.is_dir() {
            return Ok(InventoryReport {
                sources: Vec::new(),
                directories: Vec::new(),
                total_files: 0,
                ignored: Vec::new(),
            });
        }

        let mut sources = Vec::new();
        let mut directories = Vec::new();
        let mut ignored = Vec::new();

        self.walk_inventory(raw_root, &mut sources, &mut directories, &mut ignored)?;

        sources.sort_by(|a, b| a.relative_path.cmp(&b.relative_path));
        directories.sort();
        ignored.sort();

        let total_files = sources.len();
        Ok(InventoryReport {
            sources,
            directories,
            total_files,
            ignored,
        })
    }

    fn walk_inventory(
        &self,
        dir: &Path,
        sources: &mut Vec<SourceItem>,
        directories: &mut Vec<String>,
        ignored: &mut Vec<String>,
    ) -> Result<(), ExplorerError> {
        let entries = match fs::read_dir(dir) {
            Ok(e) => e,
            Err(_) => return Ok(()),
        };

        if let Some(rel) = self.project.relative_path_of(dir) {
            if !rel.is_empty() {
                directories.push(rel);
            }
        }

        for entry in entries.flatten() {
            let path = entry.path();
            let file_name = entry.file_name().to_string_lossy().to_string();

            if file_name == ".DS_Store" {
                continue;
            }

            // Hidden files/directories starting with '.' (.quarantine, .intake.log, etc.) are ignored
            if file_name.starts_with('.') {
                let mut rel = self
                    .project
                    .relative_path_of(&path)
                    .unwrap_or_else(|| file_name.clone());
                if path.is_dir() && !rel.ends_with('/') {
                    rel.push('/');
                }
                ignored.push(rel);
                continue;
            }

            // Check symlink: do not follow
            if let Ok(meta) = fs::symlink_metadata(&path) {
                if meta.file_type().is_symlink() {
                    let rel = self
                        .project
                        .relative_path_of(&path)
                        .unwrap_or_else(|| file_name.clone());
                    ignored.push(format!("{rel} (symlink)"));
                    continue;
                }
            }

            if path.is_dir() {
                self.walk_inventory(&path, sources, directories, ignored)?;
                continue;
            }

            let ext = path
                .extension()
                .and_then(|e| e.to_str())
                .map(|e| format!(".{}", e.to_lowercase()))
                .unwrap_or_default();

            // Excluded suffixes
            if matches!(ext.as_str(), ".spe" | ".affm") {
                let rel = self
                    .project
                    .relative_path_of(&path)
                    .unwrap_or_else(|| file_name.clone());
                ignored.push(rel);
                continue;
            }

            // Supported measurement extensions: .csv, .txt, .lvm
            if matches!(ext.as_str(), ".csv" | ".txt" | ".lvm") {
                let byte_size = fs::metadata(&path).map(|m| m.len()).unwrap_or(0);
                let relative_path = self
                    .project
                    .relative_path_of(&path)
                    .unwrap_or_else(|| file_name.clone());
                sources.push(SourceItem {
                    relative_path,
                    file_name,
                    byte_size,
                    extension: ext,
                });
            } else {
                let rel = self
                    .project
                    .relative_path_of(&path)
                    .unwrap_or_else(|| file_name.clone());
                ignored.push(rel);
            }
        }

        Ok(())
    }

    pub fn match_file(&self, relative_path: &Path) -> Result<MatchOutcome, ExplorerError> {
        self.match_trace(relative_path).map(|t| t.outcome)
    }

    pub fn match_trace(&self, relative_path: &Path) -> Result<MatchTrace, ExplorerError> {
        let full_path = self.project.source_path(relative_path);
        if !full_path.exists() {
            return Err(ExplorerError::InvalidSource(format!(
                "{}: source file does not exist",
                relative_path.display()
            )));
        }
        if self.project.source_relative_path(&full_path).is_none() {
            return Err(ExplorerError::InvalidSource(format!(
                "{}: source file resolves outside data root \"{}\"",
                relative_path.display(),
                self.project.data_root_relative_path
            )));
        }

        let basename = full_path
            .file_name()
            .and_then(|n| n.to_str())
            .unwrap_or("")
            .to_string();

        let ext = full_path
            .extension()
            .and_then(|e| e.to_str())
            .map(|e| format!(".{}", e.to_lowercase()))
            .unwrap_or_default();

        let prefix = read_file_prefix(&full_path, 64 * 1024)?;

        // Extract tokens using effective grammar
        let facts = crate::grammar::extract(&basename, &self.effective_grammar.grammar);
        let grammar_matched = facts.is_matched;
        let mut tokens = BTreeMap::new();
        for (k, v) in &facts.extracted_fields {
            tokens.insert(k.clone(), v.clone());
        }

        let grammar_source = match self.effective_grammar.source {
            GrammarSource::Project => "project".to_string(),
            GrammarSource::Global => "global".to_string(),
            GrammarSource::Builtin => "built-in".to_string(),
        };

        let match_ctx = GrammarMatchContext {
            catalog_loaded: grammar_matched,
            matched_fields: if grammar_matched {
                Some(facts.extracted_fields.clone())
            } else {
                None
            },
        };

        // Filter enabled profiles that support this extension
        let disabled_set = &self.project.config.profiles.disabled;
        let enabled_set = &self.project.config.profiles.enabled;

        let enabled_profiles: Vec<&InstrumentProfile> = self
            .catalog
            .profiles
            .iter()
            .filter(|p| {
                if disabled_set.iter().any(|d| d == &p.profile_id) {
                    false
                } else if let Some(ref list) = enabled_set {
                    list.iter().any(|e| e == &p.profile_id)
                } else {
                    true
                }
            })
            .collect();

        let candidates: Vec<(&InstrumentProfile, &crate::profile::ProfileFormat)> =
            enabled_profiles
                .iter()
                .flat_map(|p| {
                    p.formats
                        .iter()
                        .filter(|f| f.extensions.iter().any(|e| e.eq_ignore_ascii_case(&ext)))
                        .map(move |f| (*p, f))
                })
                .collect();

        if candidates.is_empty() {
            let outcome = if grammar_matched {
                MatchOutcome::GrammarMatchedNoProfile {
                    tokens: tokens.clone(),
                }
            } else {
                MatchOutcome::NoMatch {
                    reason: format!("no profile claims extension \"{ext}\""),
                }
            };
            return Ok(MatchTrace {
                grammar_source,
                tokens,
                candidates: Vec::new(),
                outcome,
            });
        }

        let mut hits: Vec<ProfileMatch> = Vec::new();
        let mut trace_candidates: Vec<ProfileCandidateTrace> = Vec::new();
        let basename_tokens = crate::profile::tokenize_basename(&basename);

        for (profile, format) in candidates {
            let decoded = match decode_with_format(&prefix, &format.encoding_names) {
                Some(d) => d,
                None => {
                    for mode in profile.modes.iter().filter(|m| m.format_id == format.id) {
                        trace_candidates.push(ProfileCandidateTrace {
                            profile_id: profile.profile_id.clone(),
                            instrument_name: profile.instrument_name.clone(),
                            variant: mode.id.clone(),
                            hit: false,
                            reason: "failed to decode with format encodings".to_string(),
                        });
                    }
                    continue;
                }
            };

            for mode in profile.modes.iter().filter(|m| m.format_id == format.id) {
                let merged = merge_when(profile.profile_when.as_ref(), Some(&mode.when));
                if !mode_is_candidate(&merged, &match_ctx) {
                    trace_candidates.push(ProfileCandidateTrace {
                        profile_id: profile.profile_id.clone(),
                        instrument_name: profile.instrument_name.clone(),
                        variant: mode.id.clone(),
                        hit: false,
                        reason: "filename tokens do not satisfy when conditions".to_string(),
                    });
                    continue;
                }
                if matches_when(
                    &merged,
                    match_ctx.matched_fields.as_ref(),
                    &basename_tokens,
                    &decoded.1,
                    &basename,
                ) {
                    trace_candidates.push(ProfileCandidateTrace {
                        profile_id: profile.profile_id.clone(),
                        instrument_name: profile.instrument_name.clone(),
                        variant: mode.id.clone(),
                        hit: true,
                        reason: "matched".to_string(),
                    });
                    hits.push(ProfileMatch {
                        profile: (*profile).clone(),
                        format: (*format).clone(),
                        mode: mode.clone(),
                    });
                } else {
                    trace_candidates.push(ProfileCandidateTrace {
                        profile_id: profile.profile_id.clone(),
                        instrument_name: profile.instrument_name.clone(),
                        variant: mode.id.clone(),
                        hit: false,
                        reason: "content signatures or parameters do not match".to_string(),
                    });
                }
            }
        }

        let outcome = if hits.len() >= 2 {
            let candidate_ids = ambiguous_candidate_labels(&hits);
            MatchOutcome::AmbiguousProfile { candidate_ids }
        } else if hits.len() == 1 {
            let m = hits.remove(0);
            MatchOutcome::Matched {
                profile_id: m.profile.profile_id,
                instrument_id: m.profile.instrument_id,
                instrument_name: m.profile.instrument_name,
                variant: m.mode.id,
                tokens: tokens.clone(),
            }
        } else if grammar_matched {
            MatchOutcome::GrammarMatchedNoProfile {
                tokens: tokens.clone(),
            }
        } else {
            MatchOutcome::NoMatch {
                reason: format!("no profile mode matched this source (basename \"{basename}\")"),
            }
        };

        Ok(MatchTrace {
            grammar_source,
            tokens,
            candidates: trace_candidates,
            outcome,
        })
    }

    pub fn inspect(&self, relative_path: &Path) -> Result<InspectionReport, ExplorerError> {
        let full_path = self.project.source_path(relative_path);
        let meta = fs::metadata(&full_path).map_err(|e| {
            ExplorerError::InvalidSource(format!("{}: {}", relative_path.display(), e))
        })?;
        let size_bytes = meta.len();
        let prefix = read_file_prefix(&full_path, 64 * 1024)?;
        let sha256 = sha256_hex(&fs::read(&full_path)?);

        let outcome = self.match_file(relative_path)?;
        match outcome {
            MatchOutcome::AmbiguousProfile { candidate_ids } => {
                Err(ExplorerError::AmbiguousProfile { candidate_ids })
            }
            MatchOutcome::Matched {
                profile_id,
                instrument_id,
                instrument_name,
                variant,
                tokens,
            } => {
                let measurement_result = self.load_measurement(relative_path);
                match measurement_result {
                    Ok(measurement) => {
                        let columns: Vec<ColumnSummary> = measurement
                            .channels
                            .iter()
                            .map(|c| ColumnSummary {
                                name: c.name.clone(),
                                role: "channel".to_string(),
                                quantity: c.quantity.clone(),
                                unit: if c.unit.is_empty() {
                                    None
                                } else {
                                    Some(c.unit.clone())
                                },
                                label: Some(c.label.clone()),
                            })
                            .collect();

                        let (x_quantity, x_unit) = measurement
                            .view
                            .x
                            .as_deref()
                            .and_then(|x_name| measurement.channel(x_name))
                            .map(|c| (c.quantity.clone(), Some(c.unit.clone())))
                            .unwrap_or((None, None));

                        let (y_quantity, y_unit) = measurement
                            .view
                            .y
                            .as_deref()
                            .and_then(|ys| ys.first())
                            .and_then(|y_name| measurement.channel(y_name))
                            .map(|c| (c.quantity.clone(), Some(c.unit.clone())))
                            .unwrap_or((None, None));

                        let mut metadata = BTreeMap::new();
                        for sec in &measurement.metadata_sections {
                            for field in &sec.fields {
                                let val_str = match &field.value {
                                    crate::measurement::JSONValue::String(s) => s.clone(),
                                    crate::measurement::JSONValue::Number(n) => n.to_string(),
                                    crate::measurement::JSONValue::Boolean(b) => b.to_string(),
                                    crate::measurement::JSONValue::Null => "".to_string(),
                                };
                                metadata.insert(field.key.clone(), val_str);
                            }
                        }

                        let row_count = measurement.row_count();
                        let disposition = if row_count > 0 {
                            "profile_matched".to_string()
                        } else {
                            "no_data_rows".to_string()
                        };

                        Ok(InspectionReport {
                            relative_path: relative_path.display().to_string().replace('\\', "/"),
                            size_bytes,
                            sha256,
                            profile_id,
                            instrument_id,
                            instrument_name,
                            variant,
                            tokens,
                            columns,
                            x_quantity,
                            x_unit,
                            y_quantity,
                            y_unit,
                            data_row_count: row_count,
                            metadata,
                            disposition,
                        })
                    }
                    Err(ExplorerError::Reader(ReaderError::InvalidSource(ref msg)))
                    | Err(ExplorerError::InvalidSource(ref msg))
                        if msg.contains("no data rows were found after the header") =>
                    {
                        Ok(InspectionReport {
                            relative_path: relative_path.display().to_string().replace('\\', "/"),
                            size_bytes,
                            sha256,
                            profile_id,
                            instrument_id,
                            instrument_name,
                            variant,
                            tokens,
                            columns: Vec::new(),
                            x_quantity: None,
                            x_unit: None,
                            y_quantity: None,
                            y_unit: None,
                            data_row_count: 0,
                            metadata: BTreeMap::new(),
                            disposition: "no_data_rows".to_string(),
                        })
                    }
                    Err(e) => Err(e),
                }
            }
            MatchOutcome::GrammarMatchedNoProfile { tokens } => {
                if let Ok(generic) = inspect_generic_table(&prefix, 50) {
                    let delim_name = match generic.delimiter {
                        '\t' => "TSV",
                        ',' => "CSV",
                        ';' => "Semicolon",
                        _ => "Table",
                    };
                    let measurement = self.load_measurement(relative_path)?;
                    let columns: Vec<ColumnSummary> = measurement
                        .channels
                        .iter()
                        .map(|c| ColumnSummary {
                            name: c.name.clone(),
                            role: "channel".to_string(),
                            quantity: None,
                            unit: None,
                            label: Some(c.label.clone()),
                        })
                        .collect();

                    Ok(InspectionReport {
                        relative_path: relative_path.display().to_string().replace('\\', "/"),
                        size_bytes,
                        sha256,
                        profile_id: "generic-table".to_string(),
                        instrument_id: "generic-table".to_string(),
                        instrument_name: format!("Generic Table ({delim_name})"),
                        variant: "table-view".to_string(),
                        tokens,
                        columns,
                        x_quantity: None,
                        x_unit: None,
                        y_quantity: None,
                        y_unit: None,
                        data_row_count: measurement.row_count(),
                        metadata: BTreeMap::new(),
                        disposition: "generic_table".to_string(),
                    })
                } else {
                    Err(ExplorerError::InvalidSource(format!(
                        "{}: no instrument profile mode matched this source and not a valid table",
                        relative_path.display()
                    )))
                }
            }
            MatchOutcome::NoMatch { .. } => {
                if let Ok(generic) = inspect_generic_table(&prefix, 50) {
                    let delim_name = match generic.delimiter {
                        '\t' => "TSV",
                        ',' => "CSV",
                        ';' => "Semicolon",
                        _ => "Table",
                    };
                    let measurement = self.load_measurement(relative_path)?;
                    let columns: Vec<ColumnSummary> = measurement
                        .channels
                        .iter()
                        .map(|c| ColumnSummary {
                            name: c.name.clone(),
                            role: "channel".to_string(),
                            quantity: None,
                            unit: None,
                            label: Some(c.label.clone()),
                        })
                        .collect();

                    Ok(InspectionReport {
                        relative_path: relative_path.display().to_string().replace('\\', "/"),
                        size_bytes,
                        sha256,
                        profile_id: "generic-table".to_string(),
                        instrument_id: "generic-table".to_string(),
                        instrument_name: format!("Generic Table ({delim_name})"),
                        variant: "table-view".to_string(),
                        tokens: BTreeMap::new(),
                        columns,
                        x_quantity: None,
                        x_unit: None,
                        y_quantity: None,
                        y_unit: None,
                        data_row_count: measurement.row_count(),
                        metadata: BTreeMap::new(),
                        disposition: "generic_table".to_string(),
                    })
                } else {
                    Err(ExplorerError::InvalidSource(format!(
                        "{}: no instrument profile mode matched this source and not a valid table",
                        relative_path.display()
                    )))
                }
            }
        }
    }

    pub fn load_measurement(
        &self,
        relative_path: &Path,
    ) -> Result<NormalizedMeasurement, ExplorerError> {
        let full_path = self.project.source_path(relative_path);
        let meta = fs::metadata(&full_path).map_err(|e| {
            ExplorerError::InvalidSource(format!("{}: {}", relative_path.display(), e))
        })?;
        let size = meta.len();
        let mtime = meta
            .modified()
            .ok()
            .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
            .map(|d| d.as_nanos())
            .unwrap_or(0);

        let prefix = read_file_prefix(&full_path, 64 * 1024)?;
        let prefix_hash = sha256_hex(&prefix);

        // Measurement cache fingerprint includes:
        // 1. Effective grammar SHA256
        // 2. Profiles enabled/disabled digest
        let grammar_sha = &self.effective_grammar.sha256;
        let mut enabled_sorted = self
            .project
            .config
            .profiles
            .enabled
            .clone()
            .unwrap_or_default();
        enabled_sorted.sort();
        let mut disabled_sorted = self.project.config.profiles.disabled.clone();
        disabled_sorted.sort();
        let config_digest =
            sha256_hex(format!("{:?}:{:?}", enabled_sorted, disabled_sorted).as_bytes());
        let env_fingerprint = sha256_hex(format!("{grammar_sha}:{config_digest}").as_bytes());

        // Cache location lives strictly outside the project in platform cache dir
        let cache_base = cache_dir(&self.project.root).ok();
        let cache_file = cache_base.map(|base| {
            let rel_str = relative_path.to_string_lossy();
            let file_key = sha256_hex(format!("{rel_str}:{size}:{mtime}:{prefix_hash}").as_bytes());
            base.join("measurements")
                .join(&env_fingerprint)
                .join(format!("{file_key}.json"))
        });

        // 1. Check cache hit
        if let Some(ref cf) = cache_file {
            if cf.is_file() {
                if let Ok(bytes) = fs::read(cf) {
                    if let Ok(m) = NormalizedMeasurement::decode(&bytes) {
                        return Ok(m);
                    }
                }
            }
        }

        // 2. Cache miss: load from reader
        let measurement = load_measurement(&self.project.root, relative_path)?;

        // 3. Store into cache
        if let Some(ref cf) = cache_file {
            if let Some(parent) = cf.parent() {
                let _ = fs::create_dir_all(parent);
                let json_val = measurement.to_golden_json();
                if let Ok(json_str) = serde_json::to_string(&json_val) {
                    let _ = fs::write(cf, json_str);
                }
            }
        }

        Ok(measurement)
    }
}

fn read_file_prefix(path: &Path, count: usize) -> Result<Vec<u8>, ExplorerError> {
    use std::io::Read;
    let mut file = fs::File::open(path)?;
    let mut buf = vec![0u8; count];
    let n = file.read(&mut buf)?;
    buf.truncate(n);
    Ok(buf)
}

fn resolve_effective_grammar(project: &ProjectContext) -> Result<EffectiveGrammar, ExplorerError> {
    // 1. Project config grammar:
    if let Some(ref grammar) = project.config.grammar {
        let text = serde_json::to_string(grammar).unwrap_or_default();
        let digest = sha256_hex(text.as_bytes());
        return Ok(EffectiveGrammar {
            grammar: grammar.clone(),
            source: GrammarSource::Project,
            sha256: digest,
        });
    }

    // 2. Project dedicated grammar file:
    let grammar_candidates = [
        project.root.join(".raw-viewer/grammar.yaml"),
        project.root.join(".rawviewer/grammar.yaml"),
        project.root.join("data/.rawview/grammar.yaml"),
        project.root.join("data/grammar/view/grammar.yaml"),
    ];
    for cand in &grammar_candidates {
        if cand.is_file() {
            if let Ok(catalog) = crate::grammar::load_file(cand) {
                if let Some(first) = catalog.grammars.first() {
                    let text = fs::read_to_string(cand).unwrap_or_default();
                    let digest = sha256_hex(text.as_bytes());
                    return Ok(EffectiveGrammar {
                        grammar: first.clone(),
                        source: GrammarSource::Project,
                        sha256: digest,
                    });
                }
            }
        }
    }

    // 3. Global config grammar:
    if let Ok(resolved) = crate::paths::resolve_paths_from_env(&project.root) {
        let global_config_dir = PathBuf::from(&resolved.global_config_dir);
        if let Ok(config) = crate::config::load_project_config(&global_config_dir) {
            if let Some(grammar) = config.grammar {
                let text = serde_json::to_string(&grammar).unwrap_or_default();
                let digest = sha256_hex(text.as_bytes());
                return Ok(EffectiveGrammar {
                    grammar,
                    source: GrammarSource::Global,
                    sha256: digest,
                });
            }
        }
    }

    // 4. Built-in default grammar:
    let builtin = default_grammar();
    let digest = sha256_hex(crate::grammar::DEFAULT_CONFIG_YAML.as_bytes());
    Ok(EffectiveGrammar {
        grammar: builtin,
        source: GrammarSource::Builtin,
        sha256: digest,
    })
}
