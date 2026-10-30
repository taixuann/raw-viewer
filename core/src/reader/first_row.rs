use super::ReaderError;
use crate::measurement::GapReason;
use crate::profile::{ProfileFormat, ProfileMode};
use crate::reader::cell::{append_cell, CellLedger};
use crate::reader::line_puller::{LinePuller, TextEncoding};
use crate::reader::tabular::{resolve_columns, split_line, TabularExtraction};
use std::fs::File;

const MAXIMUM_HEADER_BYTES: usize = 1 << 20;

#[allow(clippy::too_many_arguments)]
pub fn extract_first_row_header(
    relative_path: &str,
    format: &ProfileFormat,
    mode: &ProfileMode,
    encoding: TextEncoding,
    initial_text: &str,
    initial_pending: &[u8],
    file: File,
    prefix_hashed: &[u8],
) -> Result<TabularExtraction, ReaderError> {
    let mut puller = LinePuller::new(
        file,
        encoding,
        relative_path.to_string(),
        initial_pending.to_vec(),
        prefix_hashed,
    );
    puller.stage_text(initial_text, false)?;
    let mut headers: Option<Vec<String>> = None;
    let mut skipped_bytes = 0usize;
    let mut line_number = 0usize;
    while let Some(line) = puller.next_line()? {
        line_number += 1;
        if line.trim().is_empty() {
            skipped_bytes += line.len() + 1;
            if skipped_bytes > MAXIMUM_HEADER_BYTES {
                return Err(ReaderError::InvalidSource(format!(
                    "{relative_path}: header section exceeds the 1 MiB header limit."
                )));
            }
            continue;
        }
        headers = Some(split_line(
            &line,
            format.delimiter,
            &format!("{relative_path} line {line_number}"),
        )?);
        break;
    }
    let headers = headers.ok_or_else(|| {
        ReaderError::InvalidSource(format!("{relative_path}: no header row was found."))
    })?;
    let columns = resolve_columns(&headers, format, mode, relative_path, "header row")?;
    let mut ledger = CellLedger::new(columns.len());
    let mut row_count = 0usize;
    while let Some(line) = puller.next_line()? {
        line_number += 1;
        if line.trim().is_empty() {
            continue;
        }
        let fields = split_line(
            &line,
            format.delimiter,
            &format!("{relative_path} line {line_number}"),
        )?;
        for (column_index, column) in columns.iter().enumerate() {
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
            "{relative_path}: no data rows were found after the header."
        )));
    }
    let warnings = ledger.summarize(relative_path);
    Ok(TabularExtraction {
        columns: columns
            .into_iter()
            .enumerate()
            .map(|(offset, (column, _))| (column, ledger.values[offset].clone()))
            .collect(),
        reasons: ledger.reasons,
        warnings,
        header_fields: vec![],
        sha256: puller.digest_hex(),
    })
}
