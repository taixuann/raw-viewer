//! Filename grammar catalog (schema v1) for schema-v3 profile routing.

use crate::profile::sha256_hex;
use crate::yaml::parse;
use std::collections::HashMap;

mod compile;

pub use compile::compile;

pub const RELATIVE_PATH: &str = ".rawviewer/grammar.yaml";

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum GrammarFieldType {
    String,
    Number,
    DateTime,
}

impl GrammarFieldType {
    fn parse(raw: &str) -> Option<Self> {
        match raw {
            "string" => Some(Self::String),
            "number" => Some(Self::Number),
            "datetime" => Some(Self::DateTime),
            _ => None,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct GrammarField {
    pub name: String,
    pub role: Option<String>,
    pub field_type: GrammarFieldType,
    pub format_hint: String,
    pub is_optional: bool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FilenameGrammar {
    pub id: String,
    pub name: String,
    pub template: String,
    pub fields: Vec<GrammarField>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FilenameGrammarCatalog {
    pub grammars: Vec<FilenameGrammar>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ExtractedGrammarFacts {
    pub is_matched: bool,
    pub extracted_fields: HashMap<String, String>,
    pub timestamp: Option<String>,
    pub instrument: Option<String>,
    pub mode: Option<String>,
    pub device_id: Option<String>,
    pub category: Option<String>,
    pub batch: Option<String>,
    pub remarks: Vec<String>,
    pub unmatched_reason: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct GrammarContext {
    pub catalog: Option<FilenameGrammarCatalog>,
    pub sha256: Option<String>,
    pub error: Option<String>,
}

pub fn load_file(path: &std::path::Path) -> Result<FilenameGrammarCatalog, String> {
    let text = std::fs::read_to_string(path).map_err(|e| e.to_string())?;
    parse_catalog_text(&text)
}

pub fn grammar_context(project_root: &std::path::Path) -> GrammarContext {
    let path = project_root.join(RELATIVE_PATH);
    if !path.is_file() {
        return GrammarContext {
            catalog: None,
            sha256: None,
            error: Some(format!("grammar catalog {RELATIVE_PATH} not found")),
        };
    }
    let bytes = match std::fs::read(&path) {
        Ok(b) => b,
        Err(_) => {
            return GrammarContext {
                catalog: None,
                sha256: None,
                error: Some(format!("grammar catalog {RELATIVE_PATH} could not be read")),
            };
        }
    };
    let digest = sha256_hex(&bytes);
    match parse_catalog_text(std::str::from_utf8(&bytes).unwrap_or("")) {
        Ok(catalog) => GrammarContext {
            catalog: Some(catalog),
            sha256: Some(digest),
            error: None,
        },
        Err(err) => GrammarContext {
            catalog: None,
            sha256: Some(digest),
            error: Some(err),
        },
    }
}

fn parse_catalog_text(text: &str) -> Result<FilenameGrammarCatalog, String> {
    let root = parse(text, false).map_err(|e| e.to_string())?;
    if root
        .value_for_key("schema_version")
        .and_then(|n| n.scalar_value())
        != Some("1")
    {
        return Err("Unsupported grammar schema_version; expected 1".into());
    }
    let list = root
        .value_for_key("grammars")
        .and_then(|n| n.list_items())
        .ok_or_else(|| "grammars must be a YAML list".to_string())?;
    let mut grammars = Vec::new();
    for item in list {
        let id = item
            .value_for_key("id")
            .and_then(|n| n.scalar_value())
            .ok_or_else(|| "grammar id is required".to_string())?
            .to_string();
        let name = item
            .value_for_key("name")
            .and_then(|n| n.scalar_value())
            .ok_or_else(|| "grammar name is required".to_string())?
            .to_string();
        let template = item
            .value_for_key("template")
            .and_then(|n| n.scalar_value())
            .ok_or_else(|| "grammar template is required".to_string())?
            .to_string();
        let mut fields = Vec::new();
        if let Some(field_list) = item.value_for_key("fields").and_then(|n| n.list_items()) {
            for f_node in field_list {
                let f_name = f_node
                    .value_for_key("name")
                    .and_then(|n| n.scalar_value())
                    .ok_or_else(|| "field name is required".to_string())?
                    .to_string();
                let f_type_raw = f_node
                    .value_for_key("type")
                    .and_then(|n| n.scalar_value())
                    .ok_or_else(|| "field type is required".to_string())?;
                let field_type = GrammarFieldType::parse(f_type_raw)
                    .ok_or_else(|| format!("unknown field type '{f_type_raw}'"))?;
                let format_hint = f_node
                    .value_for_key("format")
                    .and_then(|n| n.scalar_value())
                    .unwrap_or("")
                    .to_string();
                let is_optional = f_node
                    .value_for_key("optional")
                    .and_then(|n| n.scalar_value())
                    .map(|v| v.eq_ignore_ascii_case("true"))
                    .unwrap_or(false);
                fields.push(GrammarField {
                    name: f_name,
                    role: f_node
                        .value_for_key("role")
                        .and_then(|n| n.scalar_value())
                        .map(str::to_string),
                    field_type,
                    format_hint,
                    is_optional,
                });
            }
        }
        grammars.push(FilenameGrammar {
            id,
            name,
            template,
            fields,
        });
    }
    Ok(FilenameGrammarCatalog { grammars })
}

pub fn template_variables(template: &str) -> Vec<String> {
    let mut names = Vec::new();
    let mut scan = 0usize;
    while scan < template.len() {
        if let Some(open_rel) = template[scan..].find('{') {
            let open = scan + open_rel;
            if let Some(close_rel) = template[open..].find('}') {
                let close = open + close_rel;
                let name = template[open + 1..close].trim();
                if !name.is_empty() {
                    names.push(name.to_string());
                }
                scan = close + 1;
                continue;
            }
            break;
        }
        break;
    }
    names
}

fn template_has_bracketed_var(template: &str, var_name: &str) -> bool {
    let needle = format!("[{{{var_name}}}]");
    template.contains(&needle)
}

fn canonical_role_key(role: &str) -> String {
    match role.to_lowercase().as_str() {
        "date & time" | "datetime" => "datetime".into(),
        "instrument" => "instrument".into(),
        "mode" => "mode".into(),
        "study" | "category" => "category".into(),
        "device id" | "device" => "device".into(),
        "remarks" => "remarks".into(),
        "batch" => "batch".into(),
        other => other.to_string(),
    }
}

pub fn extract(filename: &str, grammar: &FilenameGrammar) -> ExtractedGrammarFacts {
    let Ok((regex, field_names)) = compile(&grammar.template, &grammar.fields) else {
        return ExtractedGrammarFacts {
            is_matched: false,
            extracted_fields: HashMap::new(),
            timestamp: None,
            instrument: None,
            mode: None,
            device_id: None,
            category: None,
            batch: None,
            remarks: Vec::new(),
            unmatched_reason: Some("Invalid template syntax".into()),
        };
    };
    let target = compile::strip_data_extension(filename, &grammar.template);
    let Some(caps) = regex.captures(&target) else {
        return ExtractedGrammarFacts {
            is_matched: false,
            extracted_fields: HashMap::new(),
            timestamp: None,
            instrument: None,
            mode: None,
            device_id: None,
            category: None,
            batch: None,
            remarks: Vec::new(),
            unmatched_reason: Some("Filename does not match template pattern".into()),
        };
    };
    let mut extracted = HashMap::new();
    for (idx, name) in field_names.iter().enumerate() {
        if let Some(m) = caps.get(idx + 1) {
            let mut value = m.as_str().to_string();
            if template_has_bracketed_var(&grammar.template, name)
                && value.starts_with('[')
                && value.ends_with(']')
                && value.len() >= 2
            {
                value = value[1..value.len() - 1].to_string();
            }
            extracted.insert(name.clone(), value);
        }
    }
    let mut timestamp = None;
    let mut instrument = None;
    let mut mode = None;
    let mut device_id = None;
    let mut category = None;
    let mut batch = None;
    let mut remarks = Vec::new();
    for name in &field_names {
        let Some(val) = extracted.get(name) else {
            continue;
        };
        let Some(field_config) = grammar.fields.iter().find(|f| f.name == *name) else {
            continue;
        };
        let key = field_config
            .role
            .as_deref()
            .map(canonical_role_key)
            .unwrap_or_else(|| canonical_role_key(name));
        match key.as_str() {
            "datetime" => timestamp = Some(val.clone()),
            "instrument" => instrument = Some(val.clone()),
            "mode" => mode = Some(val.clone()),
            "device" => device_id = Some(val.clone()),
            "study" | "category" => category = Some(val.clone()),
            "batch" => batch = Some(val.clone()),
            "remarks" => remarks.push(val.clone()),
            _ => {}
        }
    }
    ExtractedGrammarFacts {
        is_matched: true,
        extracted_fields: extracted,
        timestamp,
        instrument,
        mode,
        device_id,
        category,
        batch,
        remarks,
        unmatched_reason: None,
    }
}
