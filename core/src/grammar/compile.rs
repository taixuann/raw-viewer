use super::{GrammarField, GrammarFieldType};
use regex::Regex;

/// Suffixes stripped before matching when absent from the template.
const DATA_EXTENSIONS: &[&str] = &[
    "csv", "txt", "tsv", "dat", "asc", "log", "json", "yaml", "yml", "xlsx", "xls",
];

pub fn strip_data_extension(filename: &str, template: &str) -> String {
    let lower = filename.to_ascii_lowercase();
    for ext in DATA_EXTENSIONS {
        let suffix = format!(".{ext}");
        if lower.ends_with(&suffix) {
            if template.ends_with(&suffix) {
                return filename.to_string();
            }
            let cut = filename.len().saturating_sub(suffix.len());
            return filename[..cut].to_string();
        }
    }
    filename.to_string()
}

fn capture_for_field(
    field: Option<&GrammarField>,
    bracketed: bool,
    next_leading: &str,
    category_style: bool,
) -> Result<String, String> {
    if bracketed {
        return Ok("([^]]+)".into());
    }
    let Some(field) = field else {
        return Ok(fallback_capture(next_leading));
    };
    match field.field_type {
        GrammarFieldType::Number => Ok(number_pattern(&field.format_hint)),
        GrammarFieldType::DateTime => Ok(datetime_pattern(&field.format_hint, next_leading)),
        GrammarFieldType::String => Ok(string_pattern(next_leading, category_style)),
    }
}

fn fallback_capture(next_leading: &str) -> String {
    if next_leading.is_empty() {
        "(.+)".into()
    } else {
        "(.+?)".into()
    }
}

fn number_pattern(format_hint: &str) -> String {
    let fmt = format_hint.trim();
    if fmt == "01" || fmt.to_ascii_lowercase().contains("2-digit") {
        "(\\d{2})".into()
    } else if fmt == "001" || fmt.to_ascii_lowercase().contains("3-digit") {
        "(\\d{3})".into()
    } else if fmt == "0.0" || fmt.eq_ignore_ascii_case("decimal") {
        "(\\d+(?:\\.\\d+)?)".into()
    } else {
        "(\\d+)".into()
    }
}

fn datetime_pattern(format_hint: &str, next_leading: &str) -> String {
    let fmt = format_hint.trim();
    if fmt == "yyyyMMdd" {
        "(\\d{8})".into()
    } else if fmt == "yyMMdd" {
        "(\\d{6})".into()
    } else if fmt == "yyyy-MM-dd" {
        "(\\d{4}-\\d{2}-\\d{2})".into()
    } else if fmt == "HHmmss" {
        "(\\d{6})".into()
    } else if fmt == "HHmm" {
        "(\\d{4})".into()
    } else if fmt == "DDMMYY-HHmmSS" || fmt.eq_ignore_ascii_case("yyMMdd-HHmmss") {
        "(\\d{6}-\\d{6})".into()
    } else {
        fallback_capture(next_leading)
    }
}

fn string_pattern(next_leading: &str, category_style: bool) -> String {
    if category_style {
        return "([^_]+(?:\\.[^_]+)*)".into();
    }
    if next_leading.is_empty() {
        "(.+)".into()
    } else if next_leading.chars().count() == 1 {
        let ch = next_leading.chars().next().unwrap();
        if ch == '.' || ch == '_' {
            "([^._]+)".into()
        } else {
            format!("([^{}]+?)", regex::escape(&ch.to_string()))
        }
    } else {
        "(.+?)".into()
    }
}

fn tail_is_optional_only(template: &str, after_var: usize, fields: &[GrammarField]) -> bool {
    let mut scan = after_var;
    let bytes = template.as_bytes();
    while scan < template.len() {
        if let Some(open_rel) = template[scan..].find('{') {
            let open = scan + open_rel;
            let close = template[open..]
                .find('}')
                .map(|rel| open + rel)
                .unwrap_or(template.len());
            let name = template[open + 1..close].trim();
            let optional = fields
                .iter()
                .find(|f| f.name == name)
                .map(|f| f.is_optional)
                .unwrap_or(false);
            if !optional {
                return false;
            }
            scan = close + 1;
            if scan < template.len() && bytes[scan] == b']' {
                scan += 1;
            }
        } else {
            break;
        }
    }
    true
}

pub fn compile(template: &str, fields: &[GrammarField]) -> Result<(Regex, Vec<String>), String> {
    let trimmed = template.trim();
    if trimmed.is_empty() {
        return Err("Grammar template cannot be empty".into());
    }
    let mut pattern = String::from("^");
    let mut field_names = Vec::new();
    let mut scan_index = 0usize;
    let bytes = trimmed.as_bytes();
    while scan_index < trimmed.len() {
        let Some(open_rel) = trimmed[scan_index..].find('{') else {
            pattern.push_str(&regex::escape(&trimmed[scan_index..]));
            break;
        };
        let open = scan_index + open_rel;
        let mut leading = if open > scan_index {
            trimmed[scan_index..open].to_string()
        } else {
            String::new()
        };
        let bracketed = leading.ends_with('[');
        if bracketed {
            leading.pop();
        }
        let close_rel = trimmed[open..]
            .find('}')
            .ok_or_else(|| format!("Unclosed token near '{}'", &trimmed[open..]))?;
        let close = open + close_rel;
        let var_name = trimmed[open + 1..close].trim().to_string();
        field_names.push(var_name.clone());
        let field_config = fields.iter().find(|f| f.name == var_name);
        let is_optional = field_config.map(|f| f.is_optional).unwrap_or(false);
        let mut after_var = close + 1;
        if bracketed {
            if after_var >= trimmed.len() || bytes[after_var] != b']' {
                return Err(format!(
                    "Bracketed variable '{var_name}' must close with ']'"
                ));
            }
            after_var += 1;
        }
        let next_leading_raw = if let Some(next_open) = trimmed[after_var..].find('{') {
            trimmed[after_var..after_var + next_open].to_string()
        } else {
            String::new()
        };
        let mut next_leading = next_leading_raw.clone();
        if next_leading.ends_with('[') {
            next_leading.pop();
        }
        let category_style = field_config.map(|f| f.field_type) == Some(GrammarFieldType::String)
            && tail_is_optional_only(trimmed, after_var, fields)
            && (next_leading.is_empty() || next_leading.starts_with("_r."));
        let capture_group =
            capture_for_field(field_config, bracketed, &next_leading, category_style)?;
        let mut body = String::new();
        if !leading.is_empty() {
            body.push_str(&regex::escape(&leading));
        }
        if bracketed {
            body.push_str("\\[");
            body.push_str(&capture_group);
            body.push_str("\\]");
        } else {
            body.push_str(&capture_group);
        }
        if is_optional {
            pattern.push_str(&format!("(?:{body})?"));
        } else {
            pattern.push_str(&body);
        }
        scan_index = after_var;
    }
    pattern.push('$');
    Regex::new(&pattern)
        .map_err(|e| format!("Invalid regular expression: {e}"))
        .map(|regex| (regex, field_names))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::grammar::{GrammarField, GrammarFieldType};

    fn field(name: &str, ty: GrammarFieldType, format: &str, optional: bool) -> GrammarField {
        GrammarField {
            name: name.into(),
            role: None,
            field_type: ty,
            format_hint: format.into(),
            is_optional: optional,
        }
    }

    #[test]
    fn counter_width_requires_three_digits() {
        let fields = standard_fields();
        let template = standard_template();
        let (re, _) = compile(template, &fields).expect("compile");
        let f =
            "201226-154955_keithley-2400.dual-sweep_[cu-ec-pda]_iv.dual-sweep_r.[300K]_f.[x]_01";
        assert!(!re.is_match(f));
    }

    #[test]
    fn dotted_instrument_token_does_not_full_match() {
        let fields = standard_fields();
        let template = standard_template();
        let (re, _) = compile(template, &fields).expect("compile");
        let f =
            "201226-154955_keithley.2400.dual-sweep_[cu-ec-pda]_iv.dual-sweep_r.[300K]_f.[x]_001";
        assert!(!re.is_match(f));
    }

    #[test]
    fn standard_acceptance_filename_compiles_and_matches() {
        let fields = standard_fields();
        let template = standard_template();
        let (re, _) = compile(template, &fields).expect("compile");
        let name = "201226-154955_keithley-2400.dual-sweep_[cu-ec-pda.c1-ito.2_r1-c4]_iv.dual-sweep_r.[300K]_f.[x]_001";
        assert!(re.is_match(name));
    }

    fn standard_fields() -> Vec<GrammarField> {
        vec![
            field("date", GrammarFieldType::DateTime, "DDMMYY-HHmmSS", false),
            field("instrument", GrammarFieldType::String, "", false),
            field("mode", GrammarFieldType::String, "", false),
            field("device-id", GrammarFieldType::String, "", false),
            field("study", GrammarFieldType::String, "", false),
            field("remarks", GrammarFieldType::String, "", true),
            field("flags", GrammarFieldType::String, "", true),
            field("batch", GrammarFieldType::Number, "001", true),
        ]
    }

    fn standard_template() -> &'static str {
        "{date}_{instrument}.{mode}_[{device-id}]_{study}_r.[{remarks}]_f.[{flags}]_{batch}"
    }
}
