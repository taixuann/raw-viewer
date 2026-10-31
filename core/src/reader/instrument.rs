use super::ReaderError;
use crate::measurement::{
    InstrumentIdentity, JSONValue, MeasurementChannel, MeasurementView, MetadataField,
    MetadataSection, NormalizedMeasurement, SourceIdentity,
};
use crate::profile::{
    ambiguous_candidate_labels, format_ambiguous, grammar_context_from_catalog, load_catalog,
    matches_when, merge_when, mode_is_candidate, GrammarMatchContext, ProfileCatalog,
    ProfileFormat, ProfileMatch, ProfileResolution,
};
use crate::project::ProjectContext;
use crate::reader::comment_tsv::extract_comment_tsv;
use crate::reader::first_row::extract_first_row_header;
use crate::reader::generic_table;
use crate::reader::line_puller::{decode_with_format, TextEncoding};
use crate::reader::tabular::{
    extract_tabular, open_source_at_prefix, read_prefix, TabularExtraction,
};
use crate::reader::v3;
use std::collections::BTreeMap;
use std::fs;
use std::path::Path;

pub const READER_VERSION: &str = super::READER_VERSION;
const HEADER_SAMPLE_BYTES: usize = 64 * 1024;

pub fn load_measurement(
    project_root: &Path,
    source_relative: &Path,
) -> Result<NormalizedMeasurement, ReaderError> {
    let project = ProjectContext::open(project_root).map_err(|_| ReaderError::InvalidProject)?;
    let source_path = project.source_path(source_relative);
    if project.source_relative_path(&source_path).is_none() {
        return Err(ReaderError::SourceOutsideRaw {
            path: source_relative.display().to_string(),
            data_root: project.data_root_relative_path.clone(),
        });
    }
    if is_symlink(&source_path) {
        return Err(ReaderError::InvalidSource(format!(
            "{}: source file is a symlink or was replaced by one during open; symlinks are never followed.",
            source_relative.display()
        )));
    }
    let extension = source_path
        .extension()
        .and_then(|e| e.to_str())
        .map(|e| format!(".{}", e.to_lowercase()))
        .unwrap_or_default();
    if matches!(extension.as_str(), ".spe" | ".affm") {
        return Err(ReaderError::InvalidSource(format!(
            "{}: RawView skips .spe and .affm files.",
            source_relative.display()
        )));
    }
    let basename = source_path
        .file_name()
        .and_then(|n| n.to_str())
        .unwrap_or("")
        .to_string();
    let relative_path = source_relative.to_string_lossy().replace('\\', "/");

    let catalog = load_catalog(project_root);
    let grammar = crate::grammar::grammar_context(project_root);
    let prefix = read_prefix(&source_path, HEADER_SAMPLE_BYTES)?;
    let file_size = fs::metadata(&source_path).map(|m| m.len()).unwrap_or(0);

    if !catalog.v3_documents.is_empty() {
        match v3::resolve(
            &prefix,
            &extension,
            &basename,
            &relative_path,
            file_size,
            &catalog,
            &grammar,
        ) {
            v3::V3Outcome::Unclaimed => {}
            v3::V3Outcome::Failed(message) => {
                return Err(ReaderError::InvalidSource(message));
            }
            v3::V3Outcome::Matched {
                match_info,
                encoding,
                sample,
                pending,
            } => {
                let prefix_consumed = prefix.len() - pending.len();
                let file = open_source_at_prefix(&source_path, prefix_consumed)?;
                let extracted = v3::extract_streaming(
                    &relative_path,
                    &match_info,
                    encoding,
                    &sample,
                    &pending,
                    file,
                    &prefix[..prefix_consumed],
                )?;
                return v3::measurement_from_v3(&relative_path, &basename, &match_info, extracted);
            }
        }
    }

    let encoded = resolve_encoded(
        &prefix,
        &catalog,
        &extension,
        &basename,
        grammar_context_from_catalog(grammar.catalog.as_ref(), &basename),
    );
    let (profile_match, encoding, sample, pending) = match encoded {
        EncodedResolution::Failed(message) => {
            if let Ok(measurement) =
                generic_table::load_measurement_default(&source_path, &relative_path)
            {
                return Ok(measurement);
            }
            return Err(ReaderError::InvalidSource(
                if message.contains("could not be decoded") {
                    format!("{relative_path}: {message}")
                } else {
                    message
                },
            ));
        }
        EncodedResolution::Matched {
            profile_match,
            encoding,
            text,
            pending,
        } => (*profile_match, encoding, text, pending),
    };

    let prefix_consumed = prefix.len() - pending.len();
    let file = open_source_at_prefix(&source_path, prefix_consumed)?;
    let extracted = extract_for_kind(
        &relative_path,
        &profile_match.format,
        &profile_match.mode,
        encoding,
        &sample,
        &pending,
        file,
        &prefix[..prefix_consumed],
    )?;

    measurement_from_extraction(&relative_path, &basename, &profile_match, extracted)
}

enum EncodedResolution {
    Failed(String),
    Matched {
        profile_match: Box<ProfileMatch>,
        encoding: TextEncoding,
        text: String,
        pending: Vec<u8>,
    },
}

fn profile_resolution_error(resolution: ProfileResolution) -> String {
    match resolution {
        ProfileResolution::Failed(message) => message,
        ProfileResolution::AmbiguousProfile { candidate_ids } => format_ambiguous(&candidate_ids),
        ProfileResolution::GrammarMatchedNoProfile => {
            "Filename matched the project grammar but no instrument profile mode matched this source."
                .into()
        }
        ProfileResolution::Matched(_) => "internal profile resolution error".into(),
    }
}

fn resolve_encoded(
    prefix: &[u8],
    catalog: &ProfileCatalog,
    file_extension: &str,
    basename: &str,
    grammar: GrammarMatchContext,
) -> EncodedResolution {
    let mut candidates: Vec<(&crate::profile::InstrumentProfile, &ProfileFormat)> = Vec::new();
    for profile in &catalog.profiles {
        for format in &profile.formats {
            if format.extensions.iter().any(|e| e == file_extension) {
                candidates.push((profile, format));
            }
        }
    }
    if candidates.is_empty() {
        let resolution = catalog.resolve(file_extension, "", basename, grammar.clone());
        return EncodedResolution::Failed(profile_resolution_error(resolution));
    }
    struct CandidateHit {
        profile_match: ProfileMatch,
        encoding: TextEncoding,
        text: String,
        pending: Vec<u8>,
    }
    let mut hits: Vec<CandidateHit> = Vec::new();
    let mut decoded_any = false;
    let mut first_sample = String::new();
    let mut first_decoded = false;
    for (profile, format) in candidates {
        let Some((encoding, text, pending)) = decode_with_format(prefix, &format.encoding_names)
        else {
            continue;
        };
        if !first_decoded {
            first_sample = text.clone();
            first_decoded = true;
        }
        decoded_any = true;
        let basename_tokens = crate::profile::tokenize_basename(basename);
        let grammar_fields = grammar.matched_fields.as_ref();
        let profile_when = profile.profile_when.as_ref();
        for mode in profile.modes.iter().filter(|m| m.format_id == format.id) {
            let merged = merge_when(profile_when, Some(&mode.when));
            if !mode_is_candidate(&merged, &grammar) {
                continue;
            }
            if matches_when(&merged, grammar_fields, &basename_tokens, &text, basename) {
                hits.push(CandidateHit {
                    profile_match: ProfileMatch {
                        profile: (*profile).clone(),
                        format: (*format).clone(),
                        mode: mode.clone(),
                    },
                    encoding,
                    text: text.clone(),
                    pending: pending.clone(),
                });
            }
        }
    }
    if hits.len() == 1 {
        let unique = hits.swap_remove(0);
        let blocking: Vec<_> = catalog
            .broken_claims
            .iter()
            .filter(|c| c.blocks(&unique.text.to_lowercase(), basename))
            .collect();
        if blocking.is_empty() {
            return EncodedResolution::Matched {
                profile_match: Box::new(unique.profile_match),
                encoding: unique.encoding,
                text: unique.text,
                pending: unique.pending,
            };
        }
        let note = format!(
            "A valid profile ({} mode {}) also matches this source; the source stays blocked until the invalid profile is fixed or removed.",
            unique.profile_match.profile.relative_path, unique.profile_match.mode.id
        );
        let mut messages: Vec<String> = blocking.iter().flat_map(|c| c.issues.clone()).collect();
        messages.push(note);
        return EncodedResolution::Failed(messages.join("\n"));
    }
    if hits.len() > 1 {
        let matches: Vec<_> = hits.iter().map(|hit| hit.profile_match.clone()).collect();
        let candidate_ids = ambiguous_candidate_labels(&matches);
        return EncodedResolution::Failed(format_ambiguous(&candidate_ids));
    }
    if !decoded_any {
        if catalog.has_broken_claim(file_extension) {
            let resolution = catalog.resolve(file_extension, "", basename, grammar.clone());
            if !matches!(resolution, ProfileResolution::Matched(_)) {
                return EncodedResolution::Failed(profile_resolution_error(resolution));
            }
        }
        return EncodedResolution::Failed(
            "the file header could not be decoded with any accepted profile encoding.".into(),
        );
    }
    let fallback = catalog.resolve(file_extension, &first_sample, basename, grammar);
    match fallback {
        ProfileResolution::Failed(message) => EncodedResolution::Failed(message),
        ProfileResolution::AmbiguousProfile { candidate_ids } => {
            EncodedResolution::Failed(format_ambiguous(&candidate_ids))
        }
        ProfileResolution::GrammarMatchedNoProfile => EncodedResolution::Failed(
            profile_resolution_error(ProfileResolution::GrammarMatchedNoProfile),
        ),
        ProfileResolution::Matched(foreign) => EncodedResolution::Failed(format!(
            "No profile mode matched this source using its own declared encoding (basename \"{basename}\"). A mode ({} mode {}) matches only in another candidate's decoded text and cannot decode this source.",
            foreign.profile.relative_path, foreign.mode.id
        )),
    }
}

#[allow(clippy::too_many_arguments)]
fn extract_for_kind(
    relative_path: &str,
    format: &ProfileFormat,
    mode: &crate::profile::ProfileMode,
    encoding: TextEncoding,
    initial_text: &str,
    initial_pending: &[u8],
    file: std::fs::File,
    prefix_hashed: &[u8],
) -> Result<TabularExtraction, ReaderError> {
    match format.kind.as_str() {
        "comment-tsv" => extract_comment_tsv(
            relative_path,
            format,
            mode,
            encoding,
            initial_text,
            initial_pending,
            file,
            prefix_hashed,
        ),
        "first-row-header" => extract_first_row_header(
            relative_path,
            format,
            mode,
            encoding,
            initial_text,
            initial_pending,
            file,
            prefix_hashed,
        ),
        _ => extract_tabular(
            relative_path,
            format,
            mode,
            encoding,
            initial_text,
            initial_pending,
            file,
            prefix_hashed,
        ),
    }
}

fn measurement_from_extraction(
    relative_path: &str,
    basename: &str,
    profile_match: &ProfileMatch,
    extracted: TabularExtraction,
) -> Result<NormalizedMeasurement, ReaderError> {
    let channels: Vec<MeasurementChannel> = extracted
        .columns
        .iter()
        .zip(extracted.reasons.iter())
        .map(|((column, values), reasons)| MeasurementChannel {
            name: column.key.clone(),
            label: column.label.clone(),
            unit: column.unit.clone(),
            quantity: if column.quantity.is_empty() {
                None
            } else {
                Some(column.quantity.clone())
            },
            values: values.clone(),
            gap_reasons: reasons.clone(),
        })
        .collect();
    let row_count = extracted.columns.first().map(|(_, v)| v.len()).unwrap_or(0);
    let gap_count: usize = extracted
        .columns
        .iter()
        .map(|(_, values)| values.iter().filter(|v| v.is_none()).count())
        .sum();
    let facts = parse_filename(basename);
    Ok(NormalizedMeasurement {
        source: SourceIdentity {
            path: relative_path.to_string(),
            sha256: extracted.sha256,
        },
        instrument: InstrumentIdentity {
            id: profile_match.profile.instrument_id.clone(),
            name: profile_match.profile.instrument_name.clone(),
            vendor: profile_match.profile.vendor.clone(),
            model: profile_match.profile.model.clone(),
        },
        application_mode: Some(profile_match.mode.id.clone()),
        view: MeasurementView {
            kind: "xy".into(),
            x: Some(profile_match.mode.x.clone()),
            y: Some(profile_match.mode.y.clone()),
            preserve_order: true,
        },
        channels,
        metadata_sections: metadata_sections(
            &extracted.header_fields,
            basename,
            facts,
            extracted.columns.len(),
            row_count,
            gap_count,
        ),
        warnings: extracted.warnings,
        support_status: "supported".into(),
        provenance: BTreeMap::from([
            ("reader_version".into(), READER_VERSION.into()),
            (
                "profile_id".into(),
                profile_match.profile.profile_id.clone(),
            ),
            ("profile_hash".into(), profile_match.profile.sha256.clone()),
            (
                "profile_schema_version".into(),
                profile_match.profile.schema_version.to_string(),
            ),
            ("mode".into(), profile_match.mode.id.clone()),
        ]),
    })
}

pub fn parse_filename(filename: &str) -> (Option<String>, Option<String>, Option<String>) {
    let timestamp = regex_timestamp(filename);
    let mut device_id = None;
    let mut category = None;
    if let Some(open) = filename.find('[') {
        if let Some(close) = filename[open..].find(']') {
            let close = open + close;
            if open < close {
                device_id = Some(filename[open + 1..close].to_string());
                let after = &filename[close + 1..];
                if let Some(cap) = regex_category_suffix(after) {
                    category = Some(cap);
                }
            }
        }
    }
    if category.is_none() {
        let parts: Vec<&str> = filename.split('_').collect();
        if parts.len() >= 4 {
            category = parts
                .last()
                .and_then(|last| last.split('.').next())
                .map(str::to_string);
        }
    }
    (timestamp, device_id, category)
}

fn regex_timestamp(filename: &str) -> Option<String> {
    let bytes = filename.as_bytes();
    if bytes.len() >= 6 && bytes[..6].iter().all(|b| b.is_ascii_digit()) {
        let token = if bytes.len() >= 13
            && bytes[6] == b'-'
            && bytes[7..13].iter().all(|b| b.is_ascii_digit())
        {
            &filename[..13]
        } else {
            &filename[..6]
        };
        if is_valid_filename_timestamp(token) {
            return Some(token.to_string());
        }
    }
    None
}

fn regex_category_suffix(after: &str) -> Option<String> {
    if !after.starts_with('_') {
        return None;
    }
    let rest = &after[1..];
    let dot = rest.find('.')?;
    let stem = &rest[..dot];
    if stem.is_empty() {
        return None;
    }
    if stem
        .chars()
        .all(|c| c.is_ascii_alphanumeric() || c == '.' || c == '-' || c == '_')
    {
        Some(stem.to_string())
    } else {
        None
    }
}

fn is_valid_filename_timestamp(token: &str) -> bool {
    let bytes = token.as_bytes();
    if bytes.len() != 6 && bytes.len() != 13 {
        return false;
    }
    if bytes.len() == 13 && bytes[6] != b'-' {
        return false;
    }
    let number = |from: usize, to: usize| -> Option<u32> { token.get(from..to)?.parse().ok() };
    let Some(day) = number(0, 2) else {
        return false;
    };
    let Some(month) = number(2, 4) else {
        return false;
    };
    let Some(year_suffix) = number(4, 6) else {
        return false;
    };
    if !(1..=12).contains(&month) {
        return false;
    }
    let year = 2000 + year_suffix;
    let leap = year % 4 == 0 && (year % 100 != 0 || year % 400 == 0);
    let month_lengths = [
        31,
        if leap { 29 } else { 28 },
        31,
        30,
        31,
        30,
        31,
        31,
        30,
        31,
        30,
        31,
    ];
    if day < 1 || day > month_lengths[(month - 1) as usize] {
        return false;
    }
    if bytes.len() == 13 {
        let Some(hour) = number(7, 9) else {
            return false;
        };
        let Some(minute) = number(9, 11) else {
            return false;
        };
        let Some(second) = number(11, 13) else {
            return false;
        };
        if hour > 23 || minute > 59 || second > 59 {
            return false;
        }
    }
    true
}

/// Matches Swift `String.capitalized` on metadata keys (word boundaries after
/// spaces and non-alphanumeric separators).
pub(crate) fn swift_capitalized_label(key: &str) -> String {
    swift_capitalized_words(&key.replace('_', " "))
}

fn swift_capitalized_words(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    let mut capitalize_next = true;
    for c in text.chars() {
        if c.is_ascii_alphabetic() {
            if capitalize_next {
                out.extend(c.to_uppercase());
                capitalize_next = false;
            } else {
                out.extend(c.to_lowercase());
            }
        } else {
            out.push(c);
            if !c.is_ascii_alphanumeric() {
                capitalize_next = true;
            }
        }
    }
    out
}

fn metadata_sections(
    header_fields: &[(String, String)],
    filename: &str,
    facts: (Option<String>, Option<String>, Option<String>),
    channel_count: usize,
    row_count: usize,
    gap_count: usize,
) -> Vec<MetadataSection> {
    let mut sections = Vec::new();
    if !header_fields.is_empty() {
        let fields = header_fields
            .iter()
            .map(|(key, value)| MetadataField {
                key: key.clone(),
                label: swift_capitalized_label(key),
                value: JSONValue::String(value.clone()),
                unit: None,
                kind: "string".into(),
            })
            .collect();
        sections.push(MetadataSection {
            title: "Acquisition".into(),
            fields,
        });
    }
    let mut id_fields = Vec::new();
    if let Some(device_id) = facts.1 {
        id_fields.push(MetadataField {
            key: "device_id".into(),
            label: "Device id".into(),
            value: JSONValue::String(device_id),
            unit: None,
            kind: "string".into(),
        });
    }
    if let Some(timestamp) = facts.0 {
        id_fields.push(MetadataField {
            key: "timestamp".into(),
            label: "Timestamp".into(),
            value: JSONValue::String(timestamp),
            unit: None,
            kind: "string".into(),
        });
    }
    if let Some(category) = facts.2 {
        id_fields.push(MetadataField {
            key: "category".into(),
            label: "Category".into(),
            value: JSONValue::String(category),
            unit: None,
            kind: "string".into(),
        });
    }
    id_fields.push(MetadataField {
        key: "filename".into(),
        label: "Filename".into(),
        value: JSONValue::String(filename.to_string()),
        unit: None,
        kind: "string".into(),
    });
    sections.push(MetadataSection {
        title: "Identity".into(),
        fields: id_fields,
    });
    sections.push(MetadataSection {
        title: "Data".into(),
        fields: vec![
            MetadataField {
                key: "channel_count".into(),
                label: "Channel count".into(),
                value: JSONValue::Number(channel_count as f64),
                unit: None,
                kind: "number".into(),
            },
            MetadataField {
                key: "point_count".into(),
                label: "Point count".into(),
                value: JSONValue::Number(row_count as f64),
                unit: None,
                kind: "number".into(),
            },
            MetadataField {
                key: "gap_count".into(),
                label: "Gap count".into(),
                value: JSONValue::Number(gap_count as f64),
                unit: None,
                kind: "number".into(),
            },
        ],
    });
    sections
}

fn is_symlink(path: &Path) -> bool {
    std::fs::symlink_metadata(path)
        .map(|m| m.file_type().is_symlink())
        .unwrap_or(false)
}

#[cfg(test)]
mod label_tests {
    use super::swift_capitalized_label;

    #[test]
    fn swift_capitalized_label_matches_word_boundaries() {
        assert_eq!(swift_capitalized_label("SetupTitle"), "Setuptitle");
        assert_eq!(swift_capitalized_label("Writer_Version"), "Writer Version");
        assert_eq!(swift_capitalized_label("Acq. time (s)"), "Acq. Time (S)");
        assert_eq!(
            swift_capitalized_label("***End_of_Header*** "),
            "***End Of Header*** "
        );
    }
}
