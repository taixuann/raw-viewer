use super::ReaderError;
use crate::measurement::GapReason;
use crate::profile::{ProfileColumn, ProfileFormat, ProfileMode};
use crate::reader::cell::{append_cell, CellLedger};
use crate::reader::line_puller::{LinePuller, TextEncoding};
use std::fs::File;
use std::io::{Read, Seek, SeekFrom};

pub struct TabularExtraction {
    pub columns: Vec<(ProfileColumn, Vec<Option<f64>>)>,
    pub reasons: Vec<Vec<Option<GapReason>>>,
    pub warnings: Vec<String>,
    pub header_fields: Vec<(String, String)>,
    pub sha256: String,
}

pub fn gap_reason(raw: &str) -> Option<GapReason> {
    if raw.is_empty() {
        return Some(GapReason::Blank);
    }
    match raw.to_lowercase().as_str() {
        "nan" | "+nan" | "-nan" => Some(GapReason::Nan),
        "inf" | "+inf" | "-inf" | "infinity" | "+infinity" | "-infinity" => {
            Some(GapReason::Infinite)
        }
        _ => None,
    }
}

pub fn decimal_number(raw: &str, decimal: char) -> String {
    if decimal == ',' {
        raw.replace(',', ".")
    } else {
        raw.to_string()
    }
}

pub fn is_valid_decimal(text: &str) -> bool {
    if text.is_empty() {
        return false;
    }
    let bytes = text.as_bytes();
    let mut index = 0usize;
    if bytes[index] == b'+' || bytes[index] == b'-' {
        index += 1;
        if index >= bytes.len() {
            return false;
        }
    }
    let mut int_digits = 0usize;
    while index < bytes.len() && bytes[index].is_ascii_digit() {
        int_digits += 1;
        index += 1;
    }
    let mut frac_digits = 0usize;
    if index < bytes.len() && bytes[index] == b'.' {
        index += 1;
        while index < bytes.len() && bytes[index].is_ascii_digit() {
            frac_digits += 1;
            index += 1;
        }
    }
    if int_digits == 0 && frac_digits == 0 {
        return false;
    }
    if index < bytes.len() && (bytes[index] == b'e' || bytes[index] == b'E') {
        index += 1;
        if index >= bytes.len() {
            return false;
        }
        if bytes[index] == b'+' || bytes[index] == b'-' {
            index += 1;
            if index >= bytes.len() {
                return false;
            }
        }
        let mut exp_digits = 0usize;
        while index < bytes.len() && bytes[index].is_ascii_digit() {
            exp_digits += 1;
            index += 1;
        }
        if exp_digits == 0 {
            return false;
        }
    }
    index == bytes.len()
}

pub fn split_line(line: &str, delimiter: char, context: &str) -> Result<Vec<String>, ReaderError> {
    let mut raw_cells = Vec::new();
    let mut current = String::new();
    let mut in_quotes = false;
    let mut chars = line.chars().peekable();
    while let Some(character) = chars.next() {
        if character == '"' {
            if in_quotes && chars.peek() == Some(&'"') {
                chars.next();
                current.push_str("\"\"");
                continue;
            }
            in_quotes = !in_quotes;
            current.push(character);
        } else if character == delimiter && !in_quotes {
            raw_cells.push(current);
            current = String::new();
        } else {
            current.push(character);
        }
    }
    if in_quotes {
        return Err(ReaderError::InvalidSource(format!(
            "{context}: malformed quoted field (unterminated quote)."
        )));
    }
    raw_cells.push(current);
    let mut cells = Vec::new();
    for cell in raw_cells {
        let trimmed = cell.trim();
        if trimmed.starts_with('"') {
            if trimmed.len() < 2 || !trimmed.ends_with('"') {
                return Err(ReaderError::InvalidSource(format!(
                    "{context}: malformed quoted field {trimmed}."
                )));
            }
            let inner = &trimmed[1..trimmed.len() - 1];
            cells.push(inner.replace("\"\"", "\""));
        } else if trimmed.contains('"') {
            return Err(ReaderError::InvalidSource(format!(
                "{context}: malformed quoted field {trimmed}."
            )));
        } else {
            cells.push(trimmed.to_string());
        }
    }
    Ok(cells)
}

pub fn resolve_columns(
    headers: &[String],
    format: &ProfileFormat,
    mode: &ProfileMode,
    relative_path: &str,
    row_label: &str,
) -> Result<Vec<(ProfileColumn, usize)>, ReaderError> {
    let mut columns = Vec::new();
    for column in &format.columns {
        let want = column.header.as_deref().unwrap_or(&column.key);
        let primary: Vec<usize> = headers
            .iter()
            .enumerate()
            .filter(|(_, h)| h.eq_ignore_ascii_case(want))
            .map(|(i, _)| i)
            .collect();
        if primary.len() > 1 {
            return Err(ReaderError::InvalidSource(format!(
                "{relative_path}: header for column \"{}\" ({want}) matches more than one cell in the {row_label} [{}].",
                column.key,
                headers.join(", ")
            )));
        }
        if let Some(hit) = primary.first().copied() {
            columns.push((column.clone(), hit));
            continue;
        }
        let fallback: Vec<usize> = headers
            .iter()
            .enumerate()
            .filter(|(_, h)| {
                column
                    .aliases
                    .iter()
                    .any(|alias| h.eq_ignore_ascii_case(alias))
            })
            .map(|(i, _)| i)
            .collect();
        if fallback.len() > 1 {
            return Err(ReaderError::InvalidSource(format!(
                "{relative_path}: header for column \"{}\" ({want}) matches more than one cell via aliases [{}] in the {row_label} [{}].",
                column.key,
                column.aliases.join(", "),
                headers.join(", ")
            )));
        }
        if let Some(hit) = fallback.first().copied() {
            columns.push((column.clone(), hit));
            continue;
        }
        if !column.required {
            continue;
        }
        return Err(ReaderError::InvalidSource(format!(
            "{relative_path}: header for column \"{}\" ({want}) was not found in the {row_label} [{}].",
            column.key,
            headers.join(", ")
        )));
    }
    let mut resolved_by_column = std::collections::HashMap::new();
    for (column, index) in &columns {
        if let Some(other) = resolved_by_column.insert(*index, column.key.clone()) {
            return Err(ReaderError::InvalidSource(format!(
                "{relative_path}: columns \"{other}\" and \"{}\" resolve to the same source column {} ({}).",
                column.key,
                index + 1,
                headers[*index]
            )));
        }
    }
    if !columns.iter().any(|(c, _)| c.key == mode.x)
        || !mode
            .y
            .iter()
            .all(|y| columns.iter().any(|(c, _)| c.key == *y))
    {
        return Err(ReaderError::InvalidSource(format!(
            "{relative_path}: profile mode \"{}\" references a column missing from format \"{}\".",
            mode.id, format.id
        )));
    }
    Ok(columns)
}

#[allow(clippy::too_many_arguments)]
pub fn extract_tabular(
    relative_path: &str,
    format: &ProfileFormat,
    mode: &ProfileMode,
    encoding: TextEncoding,
    initial_text: &str,
    initial_pending: &[u8],
    file: File,
    prefix_hashed: &[u8],
) -> Result<TabularExtraction, ReaderError> {
    let names_prefix = format.names_prefix.as_deref().ok_or_else(|| {
        ReaderError::InvalidSource(format!(
            "{relative_path}: format \"{}\" has no row-block markers for kind \"{}\".",
            format.id, format.kind
        ))
    })?;
    let data_prefix = format.data_prefix.as_deref().ok_or_else(|| {
        ReaderError::InvalidSource(format!(
            "{relative_path}: format \"{}\" has no row-block markers for kind \"{}\".",
            format.id, format.kind
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

    let mut header_line_texts = Vec::new();
    let mut header_bytes = 0usize;
    let mut headers: Option<Vec<String>> = None;
    let mut line_number = 0usize;
    while let Some(line) = puller.next_line()? {
        line_number += 1;
        let fields = split_line(
            &line,
            format.delimiter,
            &format!("{relative_path} line {line_number}"),
        )?;
        if fields.first().map(String::as_str) == Some(names_prefix) {
            headers = Some(fields);
            break;
        }
        header_bytes += line.len() + 1;
        if header_bytes > (1 << 20) {
            return Err(ReaderError::InvalidSource(format!(
                "{relative_path}: header section exceeds the 1 MiB header limit."
            )));
        }
        header_line_texts.push(line);
    }
    let headers = headers.ok_or_else(|| {
        ReaderError::InvalidSource(format!(
            "{relative_path}: no \"{names_prefix}\" header row was found."
        ))
    })?;
    let columns = resolve_columns(
        &headers,
        format,
        mode,
        relative_path,
        &format!("{names_prefix} row"),
    )?;
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
        if !data_prefix.is_empty() && fields.first().map(String::as_str) != Some(data_prefix) {
            continue;
        }
        for (column_index, column) in columns.iter().enumerate() {
            let cell_index = column.1;
            if cell_index >= fields.len() {
                ledger.record(
                    column_index,
                    GapReason::Blank,
                    format!(
                        "{relative_path} line {line_number}: column \"{}\" has no cell {} ; shown as a gap.",
                        column.0.key,
                        cell_index + 1
                    ),
                );
            } else {
                append_cell(
                    &fields[cell_index],
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
        let message = if data_prefix.is_empty() {
            format!("{relative_path}: no data rows were found after the header.")
        } else {
            format!("{relative_path}: no \"{data_prefix}\" data rows were found after the header.")
        };
        return Err(ReaderError::InvalidSource(message));
    }
    let header_fields = header_metadata(&header_line_texts, format.delimiter, relative_path)?;
    let warnings = ledger.summarize(relative_path);
    Ok(TabularExtraction {
        columns: columns
            .into_iter()
            .enumerate()
            .map(|(offset, (column, _))| (column, ledger.values[offset].clone()))
            .collect(),
        reasons: ledger.reasons,
        warnings,
        header_fields,
        sha256: puller.digest_hex(),
    })
}

pub fn header_metadata(
    lines: &[String],
    delimiter: char,
    relative_path: &str,
) -> Result<Vec<(String, String)>, ReaderError> {
    let mut rows = Vec::new();
    let mut first_counts: std::collections::HashMap<String, usize> =
        std::collections::HashMap::new();
    for (index, line) in lines.iter().enumerate() {
        let cells = split_line(
            line,
            delimiter,
            &format!("{relative_path} line {}", index + 1),
        )?;
        let Some(first) = cells.first().filter(|c| !c.is_empty()) else {
            continue;
        };
        let first_key = first.clone();
        rows.push(cells);
        *first_counts.entry(first_key).or_default() += 1;
    }
    let mut result = Vec::new();
    let mut used_keys = std::collections::HashSet::new();
    for cells in rows {
        if result.len() >= 256 {
            break;
        }
        let first = &cells[0];
        let (base_key, value) = if cells.len() == 1 {
            continue;
        } else if cells.len() == 2 {
            (first.clone(), cells[1].clone())
        } else if first_counts.get(first).copied().unwrap_or(0) > 1 {
            (format!("{} {}", first, cells[1]), cells[2..].join(", "))
        } else {
            (first.clone(), cells[1..].join(", "))
        };
        let trimmed = value.trim();
        if trimmed.is_empty() {
            continue;
        }
        let mut key = base_key.clone();
        let mut suffix = 2usize;
        while used_keys.contains(&key) {
            key = format!("{base_key} #{suffix}");
            suffix += 1;
        }
        used_keys.insert(key.clone());
        let stored = if trimmed.len() > 512 {
            format!("{}...", &trimmed[..509])
        } else {
            trimmed.to_string()
        };
        result.push((key, stored));
    }
    Ok(result)
}

/// Re-open helper: seek file to end of prefix already consumed by caller.
pub fn open_source_at_prefix(
    path: &std::path::Path,
    prefix_len: usize,
) -> Result<File, ReaderError> {
    let mut file = File::open(path).map_err(|err| {
        ReaderError::InvalidSource(format!(
            "{}: could not open the source file: {err}",
            path.display()
        ))
    })?;
    file.seek(SeekFrom::Start(prefix_len as u64))
        .map_err(|err| {
            ReaderError::InvalidSource(format!(
                "{}: could not read the source file: {err}",
                path.display()
            ))
        })?;
    Ok(file)
}

pub fn read_prefix(path: &std::path::Path, max_bytes: usize) -> Result<Vec<u8>, ReaderError> {
    let mut file = File::open(path).map_err(|err| {
        ReaderError::InvalidSource(format!(
            "{}: could not open the source file: {err}",
            path.display()
        ))
    })?;
    let mut buffer = vec![0u8; max_bytes];
    let read = file.read(&mut buffer).map_err(|err| {
        ReaderError::InvalidSource(format!(
            "{}: could not read the source file: {err}",
            path.display()
        ))
    })?;
    buffer.truncate(read);
    Ok(buffer)
}
