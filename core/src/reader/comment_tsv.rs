use crate::profile::{ProfileFormat, ProfileMode};
use crate::reader::cell::{append_cell, CellLedger};
use crate::reader::line_puller::{LinePuller, TextEncoding, MAXIMUM_SOURCE_LINE_BYTES};
use crate::reader::tabular::{split_line, TabularExtraction};
use crate::reader::ReaderError;
use crate::measurement::GapReason;
use std::fs::File;

const MAXIMUM_HEADER_BYTES: usize = 1 << 20;

pub fn extract_comment_tsv(
    relative_path: &str,
    format: &ProfileFormat,
    mode: &ProfileMode,
    encoding: TextEncoding,
    initial_text: &str,
    initial_pending: &[u8],
    file: File,
    prefix_hashed: &[u8],
) -> Result<TabularExtraction, ReaderError> {
    let mut indexed = Vec::new();
    for column in &format.columns {
        let position = column.index.ok_or_else(|| {
            ReaderError::InvalidSource(format!(
                "{relative_path}: column \"{}\" has no column_index for kind \"comment-tsv\".",
                column.key
            ))
        })?;
        indexed.push((column.clone(), position));
    }
    if !indexed.iter().any(|(c, _)| c.key == mode.x)
        || !mode.y.iter().all(|y| indexed.iter().any(|(c, _)| c.key == *y))
    {
        return Err(ReaderError::InvalidSource(format!(
            "{relative_path}: profile mode \"{}\" references a column missing from format \"{}\".",
            mode.id, format.id
        )));
    }
    let mut puller = LinePuller::new(
        file,
        encoding,
        relative_path.to_string(),
        initial_pending.to_vec(),
        prefix_hashed,
    );
    puller.stage_text(initial_text, false)?;
    let mut comments = Vec::new();
    let mut used_keys = std::collections::HashSet::new();
    let mut ledger = CellLedger::new(indexed.len());
    let mut line_number = 0usize;
    let mut row_count = 0usize;
    let mut header_bytes = 0usize;
    while let Some(line) = puller.next_line()? {
        line_number += 1;
        let trimmed = line.trim();
        if trimmed.is_empty() {
            continue;
        }
        if trimmed.starts_with('#') {
            let line_bytes = line.len() + 1;
            if line_bytes > MAXIMUM_HEADER_BYTES.saturating_sub(header_bytes) {
                return Err(ReaderError::InvalidSource(format!(
                    "{relative_path}: comment-tsv header exceeds the 1 MiB limit."
                )));
            }
            header_bytes += line_bytes;
            let body = trimmed.trim_start_matches('#').trim();
            let Some(separator) = body.find('=') else {
                continue;
            };
            let key = body[..separator].trim();
            let value = body[separator + 1..].trim();
            if key.is_empty() || value.is_empty() || comments.len() >= 256 {
                continue;
            }
            let mut unique = key.to_string();
            let mut suffix = 2usize;
            while used_keys.contains(&unique) {
                unique = format!("{key} #{suffix}");
                suffix += 1;
            }
            used_keys.insert(unique.clone());
            let stored = if value.len() > 512 {
                format!("{}...", &value[..509])
            } else {
                value.to_string()
            };
            comments.push((unique, stored));
            continue;
        }
        let fields = split_line(&line, format.delimiter, &format!("{relative_path} line {line_number}"))?;
        for (column_index, column) in indexed.iter().enumerate() {
            if column.1 >= fields.len() {
                ledger.record(
                    column_index,
                    GapReason::Blank,
                    format!(
                        "{relative_path} line {line_number}: column \"{}\" has no cell {} ; shown as a gap.",
                        column.0.key,
                        column.1 + 1
                    ),
                );
            } else {
                append_cell(
                    &fields[column.1],
                    column_index,
                    &column.0.key,
                    line_number,
                    relative_path,
                    format.decimal_separator,
                    &mut ledger,
                )?;
            }
        }
        row_count += 1;
    }
    if row_count == 0 {
        return Err(ReaderError::InvalidSource(format!(
            "{relative_path}: no data rows were found."
        )));
    }
    Ok(TabularExtraction {
        columns: indexed
            .into_iter()
            .enumerate()
            .map(|(offset, (column, _))| (column, ledger.values[offset].clone()))
            .collect(),
        reasons: ledger.reasons,
        warnings: ledger.summarize(relative_path),
        header_fields: comments,
        sha256: puller.digest_hex(),
    })
}
