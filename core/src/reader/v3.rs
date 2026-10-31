use super::ReaderError;
use super::READER_VERSION;
use crate::grammar::{extract as extract_grammar, FilenameGrammar, GrammarContext, RELATIVE_PATH};
use crate::measurement::{
    InstrumentIdentity, JSONValue, MeasurementChannel, MeasurementView, MetadataField,
    MetadataSection, NormalizedMeasurement, SourceIdentity,
};
use crate::profile::{
    AxisV3, ColumnRoleV3, DataStartLocatorV3, HeaderLocatorV3, ProfileCatalog, ProfileColumn,
    ProfileColumnV3, ProfileDocumentV3, ProfileResolution, ProfileVariantV3,
};
use crate::reader::cell::{append_cell, CellLedger};
use crate::reader::line_puller::{decode_with_format, LinePuller, TextEncoding};
use crate::reader::tabular::{header_metadata, split_line, TabularExtraction};
use std::collections::{BTreeMap, HashMap};
use std::fs::File;

const MAXIMUM_HEADER_BYTES: usize = 1 << 20;

#[derive(Debug, Clone)]
pub struct V3Match {
    pub document: ProfileDocumentV3,
    pub variant: ProfileVariantV3,
    #[allow(dead_code)]
    pub grammar: FilenameGrammar,
    pub facts: crate::grammar::ExtractedGrammarFacts,
    pub grammar_sha256: String,
    pub document_path: String,
    pub document_sha256: String,
}

#[allow(clippy::large_enum_variant)]
pub enum V3Outcome {
    Unclaimed,
    Matched {
        match_info: V3Match,
        encoding: TextEncoding,
        sample: String,
        pending: Vec<u8>,
    },
    Failed(String),
}

struct V3DeferHeader {
    message: String,
}

pub fn resolve(
    prefix: &[u8],
    file_extension: &str,
    basename: &str,
    relative_path: &str,
    descriptor_size: u64,
    catalog: &ProfileCatalog,
    grammar: &GrammarContext,
) -> V3Outcome {
    let ext = file_extension.to_lowercase();
    let claiming: Vec<_> = catalog
        .v3_documents
        .iter()
        .filter(|loaded| {
            loaded.document.variants.iter().any(|variant| {
                variant
                    .raw_stream
                    .extensions
                    .iter()
                    .any(|e| e.to_lowercase() == ext)
            })
        })
        .collect();
    if claiming.is_empty() {
        return V3Outcome::Unclaimed;
    }
    let Some(grammar_catalog) = grammar.catalog.as_ref() else {
        return V3Outcome::Failed(format!(
            "{relative_path}: schema-v3 profiles claim \"{ext}\" but the grammar catalog cannot be used ({}); fix {RELATIVE_PATH} or remove the v3 profiles.",
            grammar.error.as_deref().unwrap_or("missing")
        ));
    };
    let truncated = descriptor_size > prefix.len() as u64;
    struct Candidate {
        match_info: V3Match,
        encoding: TextEncoding,
        text: String,
        pending: Vec<u8>,
    }
    let mut candidates: Vec<Candidate> = Vec::new();
    let mut blocking_notes: Vec<String> = Vec::new();
    let mut match_notes: Vec<String> = Vec::new();
    let mut saw_full_match = false;
    let mut decoded_cache: HashMap<String, (TextEncoding, String, Vec<u8>)> = HashMap::new();
    for loaded in &claiming {
        let document = &loaded.document;
        let Some(grammar_def) = grammar_catalog
            .grammars
            .iter()
            .find(|g| g.id == document.grammar_id)
        else {
            blocking_notes.push(format!(
                "{}: filename.grammar_id \"{}\" is not in the grammar catalog.",
                loaded.relative_path, document.grammar_id
            ));
            continue;
        };
        let facts = extract_grammar(basename, grammar_def);
        if !facts.is_matched {
            continue;
        }
        saw_full_match = true;
        let mut tuple_complete = true;
        for key in &document.variant_keys {
            if !facts.extracted_fields.contains_key(key) {
                tuple_complete = false;
                break;
            }
        }
        if !tuple_complete {
            continue;
        }
        for variant in document.variants.iter().filter(|v| {
            v.raw_stream
                .extensions
                .iter()
                .any(|e| e.to_lowercase() == ext)
        }) {
            if !document.variant_keys.iter().all(|key| {
                variant.key_value(key) == facts.extracted_fields.get(key).map(String::as_str)
            }) {
                continue;
            }
            let cache_key = variant.raw_stream.encodings.join("\0");
            let decoded = if let Some(hit) = decoded_cache.get(&cache_key) {
                Some(hit.clone())
            } else if let Some(hit) = decode_with_format(prefix, &variant.raw_stream.encodings) {
                decoded_cache.insert(cache_key, hit.clone());
                Some(hit)
            } else {
                None
            };
            let Some((encoding, text, pending)) = decoded else {
                match_notes.push(format!(
                    "{} variant \"{}\": the file header could not be decoded with declared encodings [{}].",
                    loaded.relative_path,
                    variant.id,
                    variant.raw_stream.encodings.join(", ")
                ));
                continue;
            };
            if let Some(required) = variant
                .match_selectors
                .as_ref()
                .and_then(|m| m.filename_contains_all.as_ref())
            {
                let base_lower = basename.to_lowercase();
                if !required
                    .iter()
                    .all(|token| base_lower.contains(&token.to_lowercase()))
                {
                    continue;
                }
            }
            if let Some(any) = variant
                .match_selectors
                .as_ref()
                .and_then(|m| m.content_contains_any.as_ref())
            {
                let sample_lower = text.to_lowercase();
                if !any
                    .iter()
                    .any(|token| sample_lower.contains(&token.to_lowercase()))
                {
                    continue;
                }
            }
            match check_header(&text, variant, relative_path, !truncated) {
                Ok(()) => candidates.push(Candidate {
                    match_info: V3Match {
                        document: document.clone(),
                        variant: variant.clone(),
                        grammar: grammar_def.clone(),
                        facts: facts.clone(),
                        grammar_sha256: grammar.sha256.clone().unwrap_or_else(|| "absent".into()),
                        document_path: loaded.relative_path.clone(),
                        document_sha256: loaded.sha256.clone(),
                    },
                    encoding,
                    text,
                    pending,
                }),
                Err(V3DeferHeader { .. }) if !truncated => candidates.push(Candidate {
                    match_info: V3Match {
                        document: document.clone(),
                        variant: variant.clone(),
                        grammar: grammar_def.clone(),
                        facts: facts.clone(),
                        grammar_sha256: grammar.sha256.clone().unwrap_or_else(|| "absent".into()),
                        document_path: loaded.relative_path.clone(),
                        document_sha256: loaded.sha256.clone(),
                    },
                    encoding,
                    text,
                    pending,
                }),
                Err(err) => {
                    match_notes.push(format!(
                        "{} variant \"{}\": {}.",
                        loaded.relative_path, variant.id, err.message
                    ));
                }
            }
        }
    }
    if candidates.len() > 1 {
        let described = candidates
            .iter()
            .map(|c| {
                format!(
                    "{} variant {}",
                    c.match_info.document_path, c.match_info.variant.id
                )
            })
            .collect::<Vec<_>>()
            .join(", ");
        return V3Outcome::Failed(format!(
            "{relative_path}: Ambiguous profile match: {described}. Keep one variant per source: refine variant keys, compatibility selectors, or stream headers."
        ));
    }
    if let Some(unique) = candidates.into_iter().next() {
        if !blocking_notes.is_empty() {
            return V3Outcome::Failed(format!(
                "{relative_path}: variant \"{}\" matches, but another claiming profile cannot route ({}). Resolve every claiming variant before loading.",
                unique.match_info.variant.id,
                blocking_notes.join(" ")
            ));
        }
        if let ProfileResolution::Matched(foreign) =
            catalog.resolve(file_extension, &unique.text, basename)
        {
            return V3Outcome::Failed(format!(
                "{relative_path}: Ambiguous profile match: schema-v3 {} variant {} and legacy {} mode {} both match. Keep one profile per source.",
                unique.match_info.document_path,
                unique.match_info.variant.id,
                foreign.profile.relative_path,
                foreign.mode.id
            ));
        }
        let blocking: Vec<_> = catalog
            .broken_claims
            .iter()
            .filter(|c| c.blocks(&unique.text.to_lowercase(), basename))
            .collect();
        if !blocking.is_empty() {
            let note = format!(
                "A valid v3 profile ({} variant {}) also matches this source; the source stays blocked until the invalid profile is fixed or removed.",
                unique.match_info.document_path, unique.match_info.variant.id
            );
            let mut messages: Vec<String> =
                blocking.iter().flat_map(|c| c.issues.clone()).collect();
            messages.push(note);
            return V3Outcome::Failed(messages.join("\n"));
        }
        return V3Outcome::Matched {
            match_info: unique.match_info,
            encoding: unique.encoding,
            sample: unique.text,
            pending: unique.pending,
        };
    }
    if saw_full_match {
        let detail = if match_notes.is_empty() {
            format!(
                "no variant of {} declares those key values",
                claiming
                    .iter()
                    .map(|l| l.relative_path.as_str())
                    .collect::<Vec<_>>()
                    .join(", ")
            )
        } else {
            match_notes.join(" ")
        };
        return V3Outcome::Failed(format!(
            "{relative_path}: the filename matches a schema-v3 grammar but {detail}."
        ));
    }
    V3Outcome::Unclaimed
}

fn check_header(
    sample: &str,
    variant: &ProfileVariantV3,
    relative_path: &str,
    complete_prefix: bool,
) -> Result<(), V3DeferHeader> {
    let lines: Vec<String> = sample
        .replace("\r\n", "\n")
        .replace('\r', "\n")
        .split('\n')
        .map(str::to_string)
        .collect();
    let usable = if complete_prefix {
        lines
    } else {
        lines[..lines.len().saturating_sub(1)].to_vec()
    };
    let numbered: Vec<(usize, String)> = usable
        .into_iter()
        .enumerate()
        .map(|(i, text)| (i + 1, text))
        .collect();
    match resolve_header_row(&numbered, variant, relative_path) {
        Ok(None) => Ok(()),
        Ok(Some((_, headers))) => {
            resolve_data_columns(Some(&headers), variant, relative_path).map_err(|err| {
                if complete_prefix {
                    V3DeferHeader {
                        message: err.to_string(),
                    }
                } else {
                    V3DeferHeader {
                        message: "header row was not found".into(),
                    }
                }
            })?;
            Ok(())
        }
        Err(defer @ V3DeferHeader { .. }) => {
            if complete_prefix {
                Err(V3DeferHeader {
                    message: format!("{relative_path}: {}.", defer.message),
                })
            } else {
                Err(defer)
            }
        }
    }
}

fn resolve_header_row(
    lines: &[(usize, String)],
    variant: &ProfileVariantV3,
    relative_path: &str,
) -> Result<Option<(usize, Vec<String>)>, V3DeferHeader> {
    let stream = &variant.raw_stream;
    let delimiter = stream
        .delimiter
        .chars()
        .next()
        .ok_or_else(|| V3DeferHeader {
            message: format!(
                "{relative_path}: variant \"{}\" declares an unusable delimiter.",
                variant.id
            ),
        })?;
    if stream.delimiter.chars().count() != 1 {
        return Err(V3DeferHeader {
            message: format!(
                "{relative_path}: variant \"{}\" declares an unusable delimiter.",
                variant.id
            ),
        });
    }
    let split_header = |text: &str, number: usize| -> Result<Vec<String>, V3DeferHeader> {
        split_line(text, delimiter, &format!("{relative_path} line {number}")).map_err(|err| {
            V3DeferHeader {
                message: err.to_string(),
            }
        })
    };
    match stream.rows.header {
        HeaderLocatorV3::None => Ok(None),
        HeaderLocatorV3::Row(physical) => {
            if (physical as usize) > lines.len() {
                return Err(V3DeferHeader {
                    message: format!("header row {physical} was not found"),
                });
            }
            let (number, text) = &lines[(physical as usize) - 1];
            Ok(Some((*number, split_header(text, *number)?)))
        }
        HeaderLocatorV3::FirstNonBlank => {
            for (number, text) in lines {
                if !text.trim().is_empty() {
                    return Ok(Some((*number, split_header(text, *number)?)));
                }
            }
            Err(V3DeferHeader {
                message: "no non-blank header row was found".into(),
            })
        }
        HeaderLocatorV3::Prefix(ref marker) => {
            for (number, text) in lines {
                let cells = split_header(text, *number)?;
                if cells.first().map(String::as_str) == Some(marker.as_str()) {
                    return Ok(Some((*number, cells)));
                }
            }
            Err(V3DeferHeader {
                message: format!("no header row starting with \"{marker}\" was found"),
            })
        }
    }
}

pub fn resolve_data_columns(
    headers: Option<&[String]>,
    variant: &ProfileVariantV3,
    relative_path: &str,
) -> Result<Vec<(ProfileColumnV3, usize)>, ReaderError> {
    let decodable: Vec<_> = variant
        .raw_stream
        .columns
        .iter()
        .filter(|c| c.role != ColumnRoleV3::Skip)
        .cloned()
        .collect();
    if decodable.is_empty() {
        return Err(ReaderError::InvalidSource(format!(
            "{relative_path}: variant \"{}\" declares no decodable columns.",
            variant.id
        )));
    }
    let mut resolved = Vec::new();
    if let Some(headers) = headers {
        for column in &decodable {
            let mut header_index: Option<usize> = None;
            if let Some(want) = &column.source.header {
                let primary: Vec<usize> = headers
                    .iter()
                    .enumerate()
                    .filter(|(_, h)| h.eq_ignore_ascii_case(want))
                    .map(|(i, _)| i)
                    .collect();
                if primary.len() > 1 {
                    return Err(ReaderError::InvalidSource(format!(
                        "{relative_path}: header for column \"{}\" ({want}) matches more than one cell in the header row [{}].",
                        column.id,
                        headers.join(", ")
                    )));
                }
                if let Some(hit) = primary.first().copied() {
                    header_index = Some(hit);
                } else {
                    let fallback: Vec<usize> = headers
                        .iter()
                        .enumerate()
                        .filter(|(_, h)| {
                            column
                                .source
                                .aliases
                                .iter()
                                .any(|alias| h.eq_ignore_ascii_case(alias))
                        })
                        .map(|(i, _)| i)
                        .collect();
                    if fallback.len() > 1 {
                        return Err(ReaderError::InvalidSource(format!(
                            "{relative_path}: header for column \"{}\" ({want}) matches more than one cell via aliases [{}] in the header row [{}].",
                            column.id,
                            column.source.aliases.join(", "),
                            headers.join(", ")
                        )));
                    }
                    header_index = fallback.first().copied();
                }
            }
            if let Some(position) = column.source.column {
                let pos = (position - 1) as usize;
                if let Some(header_index) = header_index {
                    if header_index != pos {
                        return Err(ReaderError::InvalidSource(format!(
                            "{relative_path}: column \"{}\" declares source column {position} but header \"{}\" resolves to source column {}; position and header must agree.",
                            column.id,
                            column.source.header.as_deref().unwrap_or(""),
                            header_index + 1
                        )));
                    }
                } else {
                    header_index = Some(pos);
                }
            }
            let Some(index) = header_index else {
                if !column.required {
                    continue;
                }
                return Err(ReaderError::InvalidSource(format!(
                    "{relative_path}: header for column \"{}\" ({}) was not found in the header row [{}].",
                    column.id,
                    column
                        .source
                        .header
                        .as_deref()
                        .unwrap_or("column"),
                    headers.join(", ")
                )));
            };
            resolved.push((column.clone(), index));
        }
    } else {
        for column in decodable {
            let Some(position) = column.source.column else {
                return Err(ReaderError::InvalidSource(format!(
                    "{relative_path}: column \"{}\" has no header row to resolve against and declares no source column position.",
                    column.id
                )));
            };
            resolved.push((column, (position - 1) as usize));
        }
    }
    let mut seen: HashMap<usize, String> = HashMap::new();
    for (column, index) in &resolved {
        if let Some(other) = seen.insert(*index, column.id.clone()) {
            return Err(ReaderError::InvalidSource(format!(
                "{relative_path}: columns \"{other}\" and \"{}\" resolve to the same source column {}.",
                column.id,
                index + 1
            )));
        }
    }
    Ok(resolved)
}

pub fn extract_streaming(
    relative_path: &str,
    match_info: &V3Match,
    encoding: TextEncoding,
    initial_text: &str,
    initial_pending: &[u8],
    file: File,
    prefix_hashed: &[u8],
) -> Result<TabularExtraction, ReaderError> {
    let variant = &match_info.variant;
    let stream = &variant.raw_stream;
    let delimiter = stream.delimiter.chars().next().ok_or_else(|| {
        ReaderError::InvalidSource(format!(
            "{relative_path}: variant \"{}\" declares an unusable delimiter or decimal separator.",
            variant.id
        ))
    })?;
    let decimal = stream.decimal_separator.chars().next().ok_or_else(|| {
        ReaderError::InvalidSource(format!(
            "{relative_path}: variant \"{}\" declares an unusable delimiter or decimal separator.",
            variant.id
        ))
    })?;
    let mut puller = LinePuller::new(
        file,
        encoding,
        relative_path.to_string(),
        initial_pending.to_vec(),
        prefix_hashed,
    );
    puller.stage_text(initial_text, false)?;
    let wants_pre_header = variant
        .metadata_capture
        .iter()
        .any(|rule| matches!(rule, crate::profile::MetadataCaptureRuleV3::PreHeaderFields));
    let is_headerless = matches!(stream.rows.header, HeaderLocatorV3::None);
    let mut line_number = 0usize;
    let mut header_line: Option<usize> = None;
    let mut header_names: Option<Vec<String>> = None;
    let mut columns: Vec<(ProfileColumnV3, usize)> = Vec::new();
    let mut columns_resolved = false;
    let mut pre_buffer: Vec<(usize, String)> = Vec::new();
    let mut pre_bytes = 0usize;
    let mut ledger = CellLedger::new(0);
    let mut row_count = 0usize;
    if is_headerless {
        columns = resolve_data_columns(None, variant, relative_path)?;
        columns_resolved = true;
        ledger = CellLedger::new(columns.len());
    }
    let data_start_row = match stream.rows.data_start {
        DataStartLocatorV3::Row(row) => Some(row as usize),
        DataStartLocatorV3::AfterHeader => None,
    };
    while let Some(line) = puller.next_line()? {
        line_number += 1;
        let trimmed = line.trim();
        if !is_headerless && header_line.is_none() {
            pre_bytes += line.len() + 1;
            if pre_bytes > MAXIMUM_HEADER_BYTES {
                return Err(ReaderError::InvalidSource(format!(
                    "{relative_path}: header section exceeds the 1 MiB header limit."
                )));
            }
            match stream.rows.header {
                HeaderLocatorV3::None => {}
                HeaderLocatorV3::Row(physical) => {
                    pre_buffer.push((line_number, line.clone()));
                    if line_number == physical as usize {
                        header_line = Some(line_number);
                        header_names = Some(split_line(
                            &line,
                            delimiter,
                            &format!("{relative_path} line {line_number}"),
                        )?);
                    }
                }
                HeaderLocatorV3::FirstNonBlank => {
                    pre_buffer.push((line_number, line.clone()));
                    if !trimmed.is_empty() {
                        header_line = Some(line_number);
                        header_names = Some(split_line(
                            &line,
                            delimiter,
                            &format!("{relative_path} line {line_number}"),
                        )?);
                    }
                }
                HeaderLocatorV3::Prefix(ref marker) => {
                    pre_buffer.push((line_number, line.clone()));
                    let cells = split_line(
                        &line,
                        delimiter,
                        &format!("{relative_path} line {line_number}"),
                    )?;
                    if cells.first().map(String::as_str) == Some(marker.as_str()) {
                        header_line = Some(line_number);
                        header_names = Some(cells);
                    }
                }
            }
            if header_line.is_some() {
                columns = resolve_data_columns(header_names.as_deref(), variant, relative_path)?;
                columns_resolved = true;
                ledger = CellLedger::new(columns.len());
            }
            continue;
        }
        if !columns_resolved {
            return Err(ReaderError::InvalidSource(format!(
                "{relative_path}: no header row was found."
            )));
        }
        if header_line == Some(line_number) {
            continue;
        }
        if trimmed.is_empty() {
            continue;
        }
        let start_line = data_start_row.unwrap_or(header_line.map(|h| h + 1).unwrap_or(1));
        if line_number < start_line {
            continue;
        }
        if let Some(data_prefix) = &stream.rows.data_prefix {
            if !data_prefix.is_empty() {
                let fields = split_line(
                    &line,
                    delimiter,
                    &format!("{relative_path} line {line_number}"),
                )?;
                if fields.first().map(String::as_str) != Some(data_prefix.as_str()) {
                    continue;
                }
            }
        }
        let fields = split_line(
            &line,
            delimiter,
            &format!("{relative_path} line {line_number}"),
        )?;
        for (column_index, column) in columns.iter().enumerate() {
            if column.1 >= fields.len() {
                ledger.record(
                    column_index,
                    crate::measurement::GapReason::Blank,
                    format!(
                        "{relative_path} line {line_number}: column \"{}\" has no cell {}; shown as a gap.",
                        column.0.id,
                        column.1 + 1
                    ),
                );
            } else {
                append_cell(
                    &fields[column.1],
                    column_index,
                    &column.0.id,
                    line_number,
                    relative_path,
                    decimal,
                    &mut ledger,
                )?;
            }
        }
        row_count += 1;
    }
    if !is_headerless && header_line.is_none() {
        return Err(ReaderError::InvalidSource(format!(
            "{relative_path}: no header row was found."
        )));
    }
    if row_count == 0 {
        return Err(ReaderError::InvalidSource(format!(
            "{relative_path}: no data rows were found after the header."
        )));
    }
    let header_limit = header_line.unwrap_or(line_number);
    let pre_header_texts: Vec<String> = pre_buffer
        .iter()
        .filter(|(number, _)| *number < header_limit)
        .map(|(_, text)| text.clone())
        .collect();
    let header_fields = if wants_pre_header {
        header_metadata(&pre_header_texts, delimiter, relative_path)?
    } else {
        Vec::new()
    };
    Ok(TabularExtraction {
        columns: columns
            .iter()
            .enumerate()
            .map(|(index, column)| {
                (
                    ProfileColumn {
                        key: column.0.id.clone(),
                        header: column.0.source.header.clone(),
                        aliases: column.0.source.aliases.clone(),
                        quantity: column.0.quantity.clone(),
                        unit: column.0.unit.clone().unwrap_or_default(),
                        label: column.0.label.clone(),
                        index: None,
                        required: column.0.required,
                    },
                    ledger.values[index].clone(),
                )
            })
            .collect(),
        reasons: ledger.reasons.clone(),
        warnings: ledger.summarize(relative_path),
        header_fields,
        sha256: puller.digest_hex(),
    })
}

pub fn measurement_from_v3(
    relative_path: &str,
    basename: &str,
    match_info: &V3Match,
    extracted: TabularExtraction,
) -> Result<NormalizedMeasurement, ReaderError> {
    let variant = &match_info.variant;
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
    let channel_names: std::collections::HashSet<_> =
        channels.iter().map(|c| c.name.as_str()).collect();
    let view = if let Some(plot) = &variant.default_plot {
        if !channel_names.contains(plot.x.as_str())
            || !plot.y.iter().all(|y| channel_names.contains(y.as_str()))
        {
            return Err(ReaderError::InvalidSource(format!(
                "{relative_path}: variant \"{}\" default_plot references a column missing from this source.",
                variant.id
            )));
        }
        MeasurementView {
            kind: "xy".into(),
            x: Some(plot.x.clone()),
            y: Some(plot.y.clone()),
            preserve_order: true,
        }
    } else {
        MeasurementView {
            kind: "metadata-only".into(),
            x: None,
            y: None,
            preserve_order: true,
        }
    };
    let mut acquisition = extracted.header_fields.clone();
    let mut filename_fields: Vec<(String, String)> = match_info
        .facts
        .extracted_fields
        .iter()
        .map(|(k, v)| (k.clone(), v.clone()))
        .collect();
    filename_fields.sort_by(|a, b| a.0.cmp(&b.0));
    let mut warnings = extracted.warnings.clone();
    for key in filename_fields
        .iter()
        .map(|(k, _)| k.clone())
        .collect::<Vec<_>>()
    {
        let file_value = filename_fields
            .iter()
            .find(|(k, _)| k == &key)
            .map(|(_, v)| v.clone());
        let stream_value = acquisition
            .iter()
            .find(|(k, _)| k == &key)
            .map(|(_, v)| v.clone());
        if let (Some(file_value), Some(stream_value)) = (file_value, stream_value) {
            if file_value != stream_value {
                acquisition.retain(|(k, _)| k != &key);
                filename_fields.retain(|(k, _)| k != &key);
                acquisition.push((format!("{key} (filename)"), file_value.clone()));
                acquisition.push((format!("{key} (header)"), stream_value.clone()));
                warnings.push(format!(
                    "{relative_path}: metadata \"{key}\" differs between the filename ({file_value}) and the file header ({stream_value}); both are kept with source qualification."
                ));
            } else {
                filename_fields.retain(|(k, _)| k != &key);
            }
        }
    }
    fn field(key: &str, value: &str) -> MetadataField {
        MetadataField {
            key: key.to_string(),
            label: super::instrument::swift_capitalized_label(key),
            value: JSONValue::String(value.to_string()),
            unit: None,
            kind: "string".into(),
        }
    }
    let mut sections = Vec::new();
    if !acquisition.is_empty() {
        sections.push(MetadataSection {
            title: "Acquisition".into(),
            fields: acquisition.iter().map(|(k, v)| field(k, v)).collect(),
        });
    }
    let mut identity = filename_fields;
    identity.push(("filename".into(), basename.to_string()));
    sections.push(MetadataSection {
        title: "Identity".into(),
        fields: identity.iter().map(|(k, v)| field(k, v)).collect(),
    });
    let row_count = channels.first().map(|c| c.values.len()).unwrap_or(0);
    let gap_count: usize = channels
        .iter()
        .map(|c| c.values.iter().filter(|v| v.is_none()).count())
        .sum();
    sections.push(MetadataSection {
        title: "Data".into(),
        fields: vec![
            MetadataField {
                key: "channel_count".into(),
                label: "Channel count".into(),
                value: JSONValue::Number(channels.len() as f64),
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
    let mut eligible_x: Vec<_> = variant
        .raw_stream
        .columns
        .iter()
        .filter(|c| {
            c.role != ColumnRoleV3::Skip
                && c.axes.contains(&AxisV3::X)
                && channel_names.contains(c.id.as_str())
        })
        .map(|c| c.id.clone())
        .collect();
    eligible_x.sort();
    let mut eligible_y: Vec<_> = variant
        .raw_stream
        .columns
        .iter()
        .filter(|c| {
            c.role != ColumnRoleV3::Skip
                && c.axes.contains(&AxisV3::Y)
                && channel_names.contains(c.id.as_str())
        })
        .map(|c| c.id.clone())
        .collect();
    eligible_y.sort();
    Ok(NormalizedMeasurement {
        source: SourceIdentity {
            path: relative_path.to_string(),
            sha256: extracted.sha256,
        },
        instrument: InstrumentIdentity {
            id: match_info.document.instrument_id.clone(),
            name: match_info.document.instrument_name.clone(),
            vendor: match_info.document.vendor.clone(),
            model: match_info.document.model.clone(),
        },
        application_mode: Some(variant.id.clone()),
        view,
        channels,
        metadata_sections: sections,
        warnings,
        support_status: "supported".into(),
        provenance: BTreeMap::from([
            ("reader_version".into(), READER_VERSION.into()),
            ("profile_id".into(), match_info.document.profile_id.clone()),
            ("variant_id".into(), variant.id.clone()),
            ("profile_hash".into(), match_info.document_sha256.clone()),
            ("profile_schema_version".into(), "3".into()),
            (
                "mode".into(),
                match_info
                    .facts
                    .mode
                    .clone()
                    .unwrap_or_else(|| variant.id.clone()),
            ),
            ("grammar_id".into(), match_info.document.grammar_id.clone()),
            ("grammar_sha256".into(), match_info.grammar_sha256.clone()),
            ("eligible_x".into(), eligible_x.join(",")),
            ("eligible_y".into(), eligible_y.join(",")),
            (
                "progression".into(),
                variant
                    .default_plot
                    .as_ref()
                    .and_then(|p| p.progression.clone())
                    .unwrap_or_default(),
            ),
        ]),
    })
}
