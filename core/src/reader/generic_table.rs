use super::ReaderError;
use crate::measurement::{
    InstrumentIdentity, JSONValue, MeasurementChannel, MeasurementView, MetadataField,
    MetadataSection, NormalizedMeasurement, SourceIdentity,
};
use crate::profile::sha256_hex;
use crate::reader::tabular;
use std::collections::BTreeMap;
use std::fs;
use std::path::Path;

#[derive(Debug, Clone, PartialEq)]
pub struct GenericTablePreview {
    pub delimiter: char,
    pub decimal_separator: char,
    pub header_line_index: Option<usize>,
    pub data_start_line_index: usize,
    pub column_names: Vec<String>,
    pub column_units: Vec<Option<String>>,
    pub sample_rows: Vec<Vec<f64>>,
}

#[derive(Debug, Clone, PartialEq)]
pub struct GenericTableInspection {
    pub delimiter: char,
    pub decimal_separator: char,
    pub header_line_index: Option<usize>,
    pub data_start_line_index: usize,
    pub column_names: Vec<String>,
    pub column_units: Vec<Option<String>>,
    pub total_rows: usize,
    pub sample_rows: Vec<Vec<f64>>,
}

pub fn inspect(prefix: &[u8], max_sample_lines: usize) -> Result<GenericTablePreview, ReaderError> {
    let content = read_prefix_content(prefix)?;
    let mut lines = split_lines(&content);
    if lines.is_empty() {
        return Err(ReaderError::EmptyFile);
    }
    if !content.ends_with('\n') && !content.ends_with('\r') && lines.len() > 1 {
        lines.pop();
    }
    let sample_limit = lines.len().min(max_sample_lines);
    let sample_lines: Vec<String> = lines.iter().take(sample_limit).cloned().collect();
    let config = detect_config(&sample_lines)?;
    let (column_names, column_units) = parse_column_headers(&lines, &config, true)?;
    let sample_rows = gather_sample_rows(&lines, &config, 5)?;
    Ok(GenericTablePreview {
        delimiter: config.delimiter,
        decimal_separator: config.decimal,
        header_line_index: config.header_idx,
        data_start_line_index: config.data_start,
        column_names,
        column_units,
        sample_rows,
    })
}

pub fn inspect_path(
    path: &Path,
    max_sample_lines: usize,
) -> Result<GenericTableInspection, ReaderError> {
    let content = read_file_content(path)?;
    let lines = split_lines(&content);
    if lines.is_empty() {
        return Err(ReaderError::EmptyFile);
    }
    let sample_limit = lines.len().min(max_sample_lines);
    let sample_lines: Vec<String> = lines.iter().take(sample_limit).cloned().collect();
    let config = detect_config(&sample_lines)?;
    let (column_names, column_units) = parse_column_headers(&lines, &config, false)?;
    let (total_rows, sample_rows) = count_and_sample_rows(&lines, &config, 5)?;
    if total_rows == 0 {
        return Err(ReaderError::NoNumericDataFound);
    }
    Ok(GenericTableInspection {
        delimiter: config.delimiter,
        decimal_separator: config.decimal,
        header_line_index: config.header_idx,
        data_start_line_index: config.data_start,
        column_names,
        column_units,
        total_rows,
        sample_rows,
    })
}

#[allow(clippy::too_many_arguments)]
pub fn load_measurement(
    path: &Path,
    source_id: &str,
    x_column_index: usize,
    y_column_index: usize,
    custom_x_label: Option<&str>,
    custom_y_label: Option<&str>,
) -> Result<NormalizedMeasurement, ReaderError> {
    let inspection = inspect_path(path, 100)?;
    let content = read_file_content(path)?;
    let lines = split_lines(&content);
    let col_count = inspection.column_names.len();
    let mut column_values: Vec<Vec<Option<f64>>> = vec![Vec::new(); col_count];

    for line_ref in lines.iter().skip(inspection.data_start_line_index) {
        let line = clean_line(line_ref);
        if line.is_empty() || is_comment_line(&line) {
            continue;
        }
        let tokens = split_line(&line, inspection.delimiter);
        if tokens.len() < col_count {
            continue;
        }
        let mut parsed_any = false;
        for c in 0..col_count {
            let val = parse_double(&tokens[c], inspection.decimal_separator);
            if val.is_some() {
                parsed_any = true;
            }
            column_values[c].push(val);
        }
        if !parsed_any {
            for column in &mut column_values {
                column.pop();
            }
        }
    }

    let row_count = column_values.first().map(|c| c.len()).unwrap_or(0);
    if row_count == 0 {
        return Err(ReaderError::NoNumericDataFound);
    }

    let x_col = x_column_index.min(col_count.saturating_sub(1));
    let y_col = y_column_index.min(col_count.saturating_sub(1));

    let mut channels = Vec::with_capacity(col_count);
    for (i, original_name) in inspection.column_names.iter().enumerate().take(col_count) {
        let key = format!("col_{i}");
        let label = if i == x_col {
            custom_x_label
                .map(str::to_string)
                .unwrap_or_else(|| original_name.clone())
        } else if i == y_col {
            custom_y_label
                .map(str::to_string)
                .unwrap_or_else(|| original_name.clone())
        } else {
            original_name.clone()
        };
        let unit = inspection.column_units[i].clone().unwrap_or_default();
        let values = column_values[i].clone();
        let gap_reasons: Vec<Option<crate::measurement::GapReason>> = values
            .iter()
            .map(|v| {
                if v.is_none() {
                    Some(crate::measurement::GapReason::Unknown)
                } else {
                    None
                }
            })
            .collect();
        channels.push(MeasurementChannel {
            name: key,
            label,
            unit,
            quantity: Some(original_name.clone()),
            values,
            gap_reasons,
        });
    }

    let x_key = format!("col_{x_col}");
    let y_key = format!("col_{y_col}");
    let file_data = fs::read(path).unwrap_or_default();
    let sha = sha256_hex(&file_data);

    Ok(NormalizedMeasurement {
        source: SourceIdentity {
            path: source_id.to_string(),
            sha256: sha,
        },
        instrument: InstrumentIdentity {
            id: "generic-table".into(),
            name: format!("Generic Table ({})", delimiter_name(inspection.delimiter)),
            vendor: Some("Generic".into()),
            model: Some("Delimited Text".into()),
        },
        application_mode: Some("table-view".into()),
        view: MeasurementView {
            kind: "xy".into(),
            x: Some(x_key),
            y: Some(vec![y_key]),
            preserve_order: true,
        },
        channels,
        metadata_sections: vec![MetadataSection {
            title: "File Format".into(),
            fields: vec![
                MetadataField {
                    key: "delimiter".into(),
                    label: "Delimiter".into(),
                    value: JSONValue::String(delimiter_name(inspection.delimiter).to_string()),
                    unit: None,
                    kind: "string".into(),
                },
                MetadataField {
                    key: "decimal".into(),
                    label: "Decimal Separator".into(),
                    value: JSONValue::String(inspection.decimal_separator.to_string()),
                    unit: None,
                    kind: "string".into(),
                },
                MetadataField {
                    key: "columns".into(),
                    label: "Columns".into(),
                    value: JSONValue::Number(col_count as f64),
                    unit: None,
                    kind: "number".into(),
                },
                MetadataField {
                    key: "rows".into(),
                    label: "Rows".into(),
                    value: JSONValue::Number(row_count as f64),
                    unit: None,
                    kind: "number".into(),
                },
            ],
        }],
        warnings: Vec::new(),
        support_status: "supported".into(),
        provenance: BTreeMap::from([
            ("reader".into(), "GenericTableReader".into()),
            ("delimiter".into(), inspection.delimiter.to_string()),
        ]),
    })
}

pub fn load_measurement_default(
    path: &Path,
    source_id: &str,
) -> Result<NormalizedMeasurement, ReaderError> {
    load_measurement(path, source_id, 0, 1, None, None)
}

struct NumericBlockConfig {
    delimiter: char,
    decimal: char,
    data_start: usize,
    col_count: usize,
    header_idx: Option<usize>,
}

fn detect_config(sample_lines: &[String]) -> Result<NumericBlockConfig, ReaderError> {
    let candidate_delimiters = ['\t', ',', ';'];
    for delim in candidate_delimiters {
        if let Some(config) = find_numeric_block(sample_lines, delim) {
            return Ok(config);
        }
    }
    find_numeric_block(sample_lines, ' ').ok_or(ReaderError::NoNumericDataFound)
}

fn parse_column_headers(
    lines: &[String],
    config: &NumericBlockConfig,
    strict_header_tokens: bool,
) -> Result<(Vec<String>, Vec<Option<String>>), ReaderError> {
    let mut column_names = Vec::new();
    let mut column_units = Vec::new();
    if let Some(h_idx) = config.header_idx {
        if h_idx < lines.len() {
            let raw_header = clean_line(&lines[h_idx]);
            let tokens = split_line(&raw_header, config.delimiter);
            if strict_header_tokens && tokens.len() != config.col_count {
                return Err(ReaderError::NoNumericDataFound);
            }
            for i in 0..config.col_count {
                if i < tokens.len() {
                    let cleaned = trim_header_token(&tokens[i]);
                    let parsed = parse_header_and_unit(&cleaned);
                    column_names.push(if parsed.0.is_empty() {
                        format!("Column {}", i + 1)
                    } else {
                        parsed.0
                    });
                    column_units.push(parsed.1);
                } else {
                    column_names.push(format!("Column {}", i + 1));
                    column_units.push(None);
                }
            }
            return Ok((column_names, column_units));
        }
    }
    for i in 0..config.col_count {
        column_names.push(format!("Column {}", i + 1));
        column_units.push(None);
    }
    Ok((column_names, column_units))
}

fn gather_sample_rows(
    lines: &[String],
    config: &NumericBlockConfig,
    limit: usize,
) -> Result<Vec<Vec<f64>>, ReaderError> {
    let mut sample_rows = Vec::new();
    for line_ref in lines.iter().skip(config.data_start) {
        let line = clean_line(line_ref);
        if line.is_empty() || is_comment_line(&line) {
            continue;
        }
        let tokens = split_line(&line, config.delimiter);
        if tokens.len() < config.col_count {
            continue;
        }
        if let Some(row_values) = parse_full_row(&tokens, config.col_count, config.decimal) {
            sample_rows.push(row_values);
            if sample_rows.len() >= limit {
                break;
            }
        }
    }
    if sample_rows.is_empty() {
        return Err(ReaderError::NoNumericDataFound);
    }
    Ok(sample_rows)
}

fn count_and_sample_rows(
    lines: &[String],
    config: &NumericBlockConfig,
    sample_limit: usize,
) -> Result<(usize, Vec<Vec<f64>>), ReaderError> {
    let mut total_rows = 0usize;
    let mut sample_rows = Vec::new();
    for line_ref in lines.iter().skip(config.data_start) {
        let line = clean_line(line_ref);
        if line.is_empty() || is_comment_line(&line) {
            continue;
        }
        let tokens = split_line(&line, config.delimiter);
        if tokens.len() < config.col_count {
            continue;
        }
        if let Some(row_values) = parse_full_row(&tokens, config.col_count, config.decimal) {
            total_rows += 1;
            if sample_rows.len() < sample_limit {
                sample_rows.push(row_values);
            }
        }
    }
    Ok((total_rows, sample_rows))
}

fn parse_full_row(tokens: &[String], col_count: usize, decimal: char) -> Option<Vec<f64>> {
    let mut row_values = Vec::with_capacity(col_count);
    for token in tokens.iter().take(col_count) {
        row_values.push(parse_double(token, decimal)?);
    }
    Some(row_values)
}

fn read_prefix_content(prefix: &[u8]) -> Result<String, ReaderError> {
    let mut candidate = prefix.to_vec();
    for _ in 0..4 {
        if let Ok(utf8) = std::str::from_utf8(&candidate) {
            return Ok(strip_bom(utf8).to_string());
        }
        if candidate.is_empty() {
            break;
        }
        candidate.pop();
    }
    decode_latin1(prefix)
        .or_else(|| decode_utf16(prefix))
        .ok_or(ReaderError::UnreadableEncoding)
}

fn read_file_content(path: &Path) -> Result<String, ReaderError> {
    let data = fs::read(path).map_err(|err| {
        ReaderError::InvalidSource(format!(
            "{}: could not read the source file: {err}",
            path.display()
        ))
    })?;
    if let Ok(utf8) = std::str::from_utf8(&data) {
        return Ok(strip_bom(utf8).to_string());
    }
    decode_latin1(&data)
        .or_else(|| decode_utf16(&data))
        .ok_or(ReaderError::UnreadableEncoding)
}

fn strip_bom(text: &str) -> &str {
    text.strip_prefix('\u{feff}').unwrap_or(text)
}

fn decode_latin1(data: &[u8]) -> Option<String> {
    Some(data.iter().map(|&b| b as char).collect())
}

fn decode_utf16(data: &[u8]) -> Option<String> {
    if data.len() < 2 || !data.len().is_multiple_of(2) {
        return None;
    }
    let units: Vec<u16> = data
        .as_chunks::<2>()
        .0
        .iter()
        .map(|chunk| u16::from_le_bytes(*chunk))
        .collect();
    String::from_utf16(&units).ok()
}

fn split_lines(text: &str) -> Vec<String> {
    text.lines().map(str::to_string).collect()
}

fn clean_line(line: &str) -> String {
    line.trim().to_string()
}

fn is_comment_line(line: &str) -> bool {
    line.starts_with('#') || line.starts_with(';') || line.starts_with("//")
}

fn split_line(line: &str, delimiter: char) -> Vec<String> {
    if delimiter == ' ' {
        line.split_whitespace().map(str::to_string).collect()
    } else {
        line.split(delimiter).map(str::to_string).collect()
    }
}

fn parse_double(raw: &str, decimal_separator: char) -> Option<f64> {
    let trimmed = raw.trim();
    let stripped = trimmed.trim_matches(|c| c == '"' || c == '\'');
    if tabular::gap_reason(stripped).is_some() {
        return None;
    }
    let normalized = tabular::decimal_number(stripped, decimal_separator);
    if !tabular::is_valid_decimal(&normalized) {
        return None;
    }
    normalized.parse::<f64>().ok().filter(|v| v.is_finite())
}

fn find_numeric_block(lines: &[String], delimiter: char) -> Option<NumericBlockConfig> {
    let decimals: Vec<char> = if delimiter == ',' {
        vec!['.']
    } else {
        vec!['.', ',']
    };
    for dec in decimals {
        for (i, line_ref) in lines.iter().enumerate() {
            let line = clean_line(line_ref);
            if line.is_empty() || is_comment_line(&line) {
                continue;
            }
            let tokens = split_line(&line, delimiter);
            if tokens.len() < 2 {
                continue;
            }
            let numeric_count = tokens
                .iter()
                .filter(|token| parse_double(token, dec).is_some())
                .count();
            if (numeric_count as f64) / (tokens.len() as f64) < 0.75 {
                continue;
            }
            let mut consecutive = 1usize;
            let mut next_idx = i + 1;
            while next_idx < lines.len() && consecutive < 3 {
                let next_line = clean_line(&lines[next_idx]);
                if !next_line.is_empty() && !is_comment_line(&next_line) {
                    let next_tokens = split_line(&next_line, delimiter);
                    if next_tokens.len() == tokens.len() {
                        let next_numeric = next_tokens
                            .iter()
                            .filter(|token| parse_double(token, dec).is_some())
                            .count();
                        if (next_numeric as f64) / (next_tokens.len() as f64) >= 0.75 {
                            consecutive += 1;
                        } else {
                            break;
                        }
                    } else {
                        break;
                    }
                }
                next_idx += 1;
            }
            let required = 3.min(1.max(lines.len().saturating_sub(i)));
            if consecutive >= required {
                let mut header_idx = None;
                for prev in (0..i).rev() {
                    let prev_line = clean_line(&lines[prev]);
                    if !prev_line.is_empty() {
                        header_idx = Some(prev);
                        break;
                    }
                }
                return Some(NumericBlockConfig {
                    delimiter,
                    decimal: dec,
                    data_start: i,
                    col_count: tokens.len(),
                    header_idx,
                });
            }
        }
    }
    None
}

fn trim_header_token(raw: &str) -> String {
    raw.trim()
        .trim_matches(|c| matches!(c, '"' | '\'' | '#' | ';'))
        .to_string()
}

fn parse_header_and_unit(raw: &str) -> (String, Option<String>) {
    let trimmed = raw.trim();
    for (open, close) in [('(', ')'), ('[', ']')] {
        if let Some(open_idx) = trimmed.rfind(open) {
            if trimmed.ends_with(close) && open_idx < trimmed.len() - 1 {
                let name = trimmed[..open_idx].trim();
                let unit = trimmed[open_idx + 1..trimmed.len() - 1].trim();
                if !unit.is_empty() {
                    return (name.to_string(), Some(unit.to_string()));
                }
            }
        }
    }
    (trimmed.to_string(), None)
}

fn delimiter_name(delim: char) -> &'static str {
    match delim {
        '\t' => "TSV",
        ',' => "CSV",
        ';' => "Semicolon",
        ' ' => "Whitespace",
        _ => "Custom",
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn inspect_prefix_sniffs_comma_csv() {
        let prefix = b"Voltage (V),Current (A)\n0.1,1e-6\n0.2,2e-6\n0.3,3e-6\n";
        let preview = inspect(prefix, 100).expect("inspect");
        assert_eq!(preview.delimiter, ',');
        assert_eq!(preview.column_names[0], "Voltage");
        assert_eq!(preview.column_units[0].as_deref(), Some("V"));
        assert_eq!(preview.sample_rows.len(), 3);
    }
}
