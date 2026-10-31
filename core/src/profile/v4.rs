//! Schema-v4 flat instrument profiles (decode, validate, compile to v1/v2 reader shape).

use crate::profile::types::{
    humanized, InstrumentProfile, ProfileColumn, ProfileFormat, ProfileMode,
};
use crate::yaml::YamlNode;
use std::collections::{BTreeMap, HashSet};

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ProfileDocumentV4 {
    pub profile_id: String,
    pub revision: Option<String>,
    pub instrument_id: String,
    pub instrument_name: String,
    pub vendor: Option<String>,
    pub model: Option<String>,
    pub when: Option<WhenClauseV4>,
    pub variants: BTreeMap<String, ProfileVariantV4>,
}

#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct WhenClauseV4 {
    pub tokens: BTreeMap<String, String>,
    pub content_contains_any: Option<Vec<String>>,
    pub content_starts_with: Option<Vec<String>>,
    pub filename_contains_all: Option<Vec<String>>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ProfileVariantV4 {
    pub when: Option<WhenClauseV4>,
    pub format: StreamFormatV4,
    pub rows: RowsBlockV4,
    pub metadata: Vec<MetadataEntryV4>,
    pub columns: BTreeMap<String, ColumnDefinitionV4>,
    pub plot: PlotSpecV4,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct StreamFormatV4 {
    pub kind: String,
    pub extensions: Vec<String>,
    pub delimiter: char,
    pub encoding_names: Vec<String>,
    pub decimal_separator: char,
}

#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct RowsBlockV4 {
    pub metadata_rows: Vec<RowSpanV4>,
    pub skip_rows: Vec<RowSpanV4>,
    pub header_row: Option<i32>,
    pub data_start_row: Option<i32>,
    pub names_prefix: Option<String>,
    pub data_prefix: Option<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct RowSpanV4 {
    pub start: i32,
    pub end: i32,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum MetadataEntryV4 {
    RowKeyValue {
        row: i32,
        key: String,
        value_type: String,
        format: Option<String>,
    },
    CellKey {
        column: i32,
        row: i32,
        key: String,
    },
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ColumnRoleV4 {
    Channel,
    Progression,
    Skip,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ColumnProgressionV4 {
    pub progression_type: String,
    pub behavior: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ColumnDefinitionV4 {
    pub role: ColumnRoleV4,
    pub label: Option<String>,
    pub quantity: Option<String>,
    pub unit: Option<String>,
    pub header: Option<String>,
    pub aliases: Vec<String>,
    pub required: bool,
    pub progression: Option<ColumnProgressionV4>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PlotSpecV4 {
    pub x: String,
    pub y: Vec<String>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ProfileV4Error {
    Invalid(String),
}

impl ProfileV4Error {
    pub fn message(&self) -> &str {
        match self {
            Self::Invalid(reason) => reason,
        }
    }
}

impl std::fmt::Display for ProfileV4Error {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(self.message())
    }
}

impl std::error::Error for ProfileV4Error {}

fn invalid(reason: impl Into<String>) -> ProfileV4Error {
    ProfileV4Error::Invalid(reason.into())
}

pub fn parse(text: &str) -> Result<ProfileDocumentV4, ProfileV4Error> {
    let root = crate::yaml::parse(text, false)
        .map_err(|err| invalid(format!("Profile YAML parse error {err}")))?;
    if root.map_entries().is_none() {
        return Err(invalid("The profile document must be a mapping."));
    }
    let doc = decode_v4(&root)?;
    validate_structure(&doc)?;
    Ok(doc)
}

pub fn decode_v4(root: &YamlNode) -> Result<ProfileDocumentV4, ProfileV4Error> {
    reject_unknown(
        root,
        &[
            "schema_version",
            "id",
            "revision",
            "instrument",
            "when",
            "variants",
        ],
        "",
    )?;
    let version = root
        .value_for_key("schema_version")
        .and_then(|n| n.scalar_value())
        .ok_or_else(|| invalid("schema_version must be 4 for a flat profile document."))?;
    if version != "4" {
        return Err(invalid(
            "schema_version must be 4 for a flat profile document.",
        ));
    }
    let profile_id = scalar_required(root, "id", "id")?;
    let instrument = root
        .value_for_key("instrument")
        .filter(|n| n.map_entries().is_some())
        .ok_or_else(|| invalid("instrument mapping is required."))?;
    reject_unknown(instrument, &["id", "name", "vendor", "model"], "instrument")?;
    let instrument_id = scalar_required(instrument, "id", "instrument.id")?;
    let instrument_name = scalar_required(instrument, "name", "instrument.name")?;
    let variants_node = root
        .value_for_key("variants")
        .filter(|n| n.map_entries().is_some())
        .ok_or_else(|| invalid("variants must be a mapping keyed by application-mode."))?;
    let mut variants = BTreeMap::new();
    for (key, node) in variants_node.map_entries().unwrap_or(&[]) {
        let field = format!("variants.{key}");
        variants.insert(key.clone(), decode_variant(node, &field)?);
    }
    Ok(ProfileDocumentV4 {
        profile_id,
        revision: optional_scalar(root, "revision"),
        instrument_id,
        instrument_name,
        vendor: optional_scalar(instrument, "vendor"),
        model: optional_scalar(instrument, "model"),
        when: decode_when(root.value_for_key("when"), "when")?,
        variants,
    })
}

pub fn validate_structure(doc: &ProfileDocumentV4) -> Result<(), ProfileV4Error> {
    non_empty(&doc.profile_id, "id")?;
    non_empty(&doc.instrument_id, "instrument.id")?;
    non_empty(&doc.instrument_name, "instrument.name")?;
    if doc.variants.is_empty() {
        return Err(invalid(
            "variants must contain at least one application-mode.",
        ));
    }
    for (key, variant) in &doc.variants {
        validate_variant(key, variant)?;
    }
    Ok(())
}

pub fn compile_instrument_profile(
    doc: &ProfileDocumentV4,
    relative_path: &str,
    sha256: &str,
) -> Result<InstrumentProfile, ProfileV4Error> {
    let mut formats = Vec::new();
    let mut modes = Vec::new();
    for (mode_id, variant) in &doc.variants {
        let format_id = mode_id.clone();
        formats.push(compile_format(format_id.clone(), variant)?);
        modes.push(compile_mode(mode_id, variant)?);
    }
    let profile_when = doc.when.as_ref().map(super::when::when_from_v4_clause);
    Ok(InstrumentProfile {
        profile_id: doc.profile_id.clone(),
        instrument_id: doc.instrument_id.clone(),
        instrument_name: doc.instrument_name.clone(),
        vendor: doc.vendor.clone(),
        model: doc.model.clone(),
        formats,
        modes,
        relative_path: relative_path.to_string(),
        sha256: sha256.to_string(),
        schema_version: 4,
        profile_when,
    })
}

pub fn lenient_v4_extensions(root: &YamlNode) -> Vec<String> {
    let mut extensions = Vec::new();
    let Some(variants) = root.value_for_key("variants").and_then(|n| n.map_entries()) else {
        return extensions;
    };
    for (_, variant) in variants {
        let Some(ext_nodes) = variant
            .value_for_key("format")
            .and_then(|f| f.value_for_key("extensions"))
            .and_then(|n| n.list_items())
        else {
            continue;
        };
        for node in ext_nodes {
            if let Some(value) = node.scalar_value() {
                let lower = value.to_lowercase();
                if lower.starts_with('.') {
                    extensions.push(lower);
                }
            }
        }
    }
    super::types::unique_sorted(extensions)
}

fn column_sort_key<'a>(key: &'a str, plot: &PlotSpecV4) -> (u8, usize, &'a str) {
    if key == plot.x {
        (0, 0, key)
    } else if let Some(index) = plot.y.iter().position(|y| y == key) {
        (1, index, key)
    } else {
        (2, 0, key)
    }
}

fn compile_format(
    format_id: String,
    variant: &ProfileVariantV4,
) -> Result<ProfileFormat, ProfileV4Error> {
    let mut columns = Vec::new();
    let mut ordered_keys: Vec<String> = variant.columns.keys().cloned().collect();
    ordered_keys
        .sort_by(|a, b| column_sort_key(a, &variant.plot).cmp(&column_sort_key(b, &variant.plot)));
    for key in ordered_keys {
        let col = &variant.columns[&key];
        if matches!(col.role, ColumnRoleV4::Skip) {
            continue;
        }
        let quantity = col.quantity.clone().unwrap_or_else(|| "unknown".into());
        let unit = col.unit.clone().unwrap_or_else(|| "unspecified".into());
        let label = col.label.clone().unwrap_or_else(|| humanized(&key));
        let header = col.header.clone().ok_or_else(|| {
            invalid(format!(
                "variants.{format_id}.columns.{key} must declare header for reader compilation."
            ))
        })?;
        columns.push(ProfileColumn {
            key: key.clone(),
            header: Some(header),
            aliases: col.aliases.clone(),
            quantity,
            unit,
            label,
            index: None,
            required: col.required,
        });
    }
    Ok(ProfileFormat {
        id: format_id,
        kind: variant.format.kind.clone(),
        extensions: variant
            .format
            .extensions
            .iter()
            .map(|e| e.to_lowercase())
            .collect(),
        delimiter: variant.format.delimiter,
        encoding_names: variant.format.encoding_names.clone(),
        decimal_separator: variant.format.decimal_separator,
        names_prefix: variant.rows.names_prefix.clone(),
        data_prefix: variant.rows.data_prefix.clone(),
        columns,
    })
}

fn compile_mode(mode_id: &str, variant: &ProfileVariantV4) -> Result<ProfileMode, ProfileV4Error> {
    let when_v4 = variant.when.as_ref();
    let when = when_v4
        .map(super::when::when_from_v4_clause)
        .unwrap_or_default();
    if !when.has_selectors() {
        return Err(invalid(format!(
            "variants.{mode_id}.when must declare at least one selector for reader compilation."
        )));
    }
    let detect = when.content_contains_any.clone();
    let filename_contains_all = when_v4
        .and_then(|w| w.filename_contains_all.clone())
        .filter(|v| !v.is_empty());
    Ok(ProfileMode {
        id: mode_id.to_string(),
        format_id: mode_id.to_string(),
        detect,
        filename_contains_all,
        when,
        x: variant.plot.x.clone(),
        y: variant.plot.y.clone(),
    })
}

fn validate_variant(mode_key: &str, variant: &ProfileVariantV4) -> Result<(), ProfileV4Error> {
    let field = format!("variants.{mode_key}");
    non_empty(&variant.format.kind, &format!("{field}.format.kind"))?;
    if variant.format.extensions.is_empty() {
        return Err(invalid(format!(
            "{field}.format.extensions must not be empty."
        )));
    }
    validate_rows(&variant.rows, &format!("{field}.rows"))?;
    if variant.columns.is_empty() {
        return Err(invalid(format!(
            "{field}.columns must declare at least one column."
        )));
    }
    validate_plot(&variant.plot, &field, &variant.columns)?;
    for (col_key, col) in &variant.columns {
        validate_column(col, &format!("{field}.columns.{col_key}"))?;
    }
    Ok(())
}

fn validate_rows(rows: &RowsBlockV4, field: &str) -> Result<(), ProfileV4Error> {
    let mut occupied: Vec<RowSpanV4> = Vec::new();
    for span in rows.metadata_rows.iter().chain(rows.skip_rows.iter()) {
        push_span(span, field, &mut occupied)?;
    }
    if let Some(header) = rows.header_row {
        push_span(
            &RowSpanV4 {
                start: header,
                end: header,
            },
            field,
            &mut occupied,
        )?;
    }
    if let Some(data_start) = rows.data_start_row {
        push_span(
            &RowSpanV4 {
                start: data_start,
                end: data_start,
            },
            field,
            &mut occupied,
        )?;
    }
    Ok(())
}

fn push_span(
    span: &RowSpanV4,
    field: &str,
    occupied: &mut Vec<RowSpanV4>,
) -> Result<(), ProfileV4Error> {
    if span.start < 1 || span.end < span.start {
        return Err(invalid(format!(
            "{field} row span must be 1-based with end >= start."
        )));
    }
    for other in occupied.iter() {
        if spans_overlap(span, other) {
            return Err(invalid(format!(
                "{field} row assignments overlap between rows {}-{} and {}-{}.",
                span.start, span.end, other.start, other.end
            )));
        }
    }
    occupied.push(*span);
    Ok(())
}

fn spans_overlap(a: &RowSpanV4, b: &RowSpanV4) -> bool {
    a.start <= b.end && b.start <= a.end
}

fn validate_column(col: &ColumnDefinitionV4, field: &str) -> Result<(), ProfileV4Error> {
    match col.role {
        ColumnRoleV4::Channel => {
            non_empty(
                col.quantity.as_deref().unwrap_or(""),
                &format!("{field}.quantity"),
            )?;
            non_empty(col.unit.as_deref().unwrap_or(""), &format!("{field}.unit"))?;
        }
        ColumnRoleV4::Progression => {
            let Some(prog) = &col.progression else {
                return Err(invalid(format!(
                    "{field}.progression is required when role is progression."
                )));
            };
            if !matches!(prog.progression_type.as_str(), "time" | "index" | "custom") {
                return Err(invalid(format!(
                    "{field}.progression.type must be time, index, or custom."
                )));
            }
            if let Some(behavior) = &prog.behavior {
                if behavior != "continuous" && behavior != "discrete" {
                    return Err(invalid(format!(
                        "{field}.progression.behavior must be continuous or discrete."
                    )));
                }
            }
        }
        ColumnRoleV4::Skip => {}
    }
    Ok(())
}

fn validate_plot(
    plot: &PlotSpecV4,
    field: &str,
    columns: &BTreeMap<String, ColumnDefinitionV4>,
) -> Result<(), ProfileV4Error> {
    if plot.y.is_empty() {
        return Err(invalid(format!(
            "{field}.plot.y must name at least one column."
        )));
    }
    let keys: HashSet<_> = columns.keys().cloned().collect();
    if !keys.contains(&plot.x) {
        return Err(invalid(format!(
            "{field}.plot.x \"{}\" is not a declared column.",
            plot.x
        )));
    }
    for y in &plot.y {
        if !keys.contains(y) {
            return Err(invalid(format!(
                "{field}.plot.y \"{y}\" is not a declared column."
            )));
        }
    }
    Ok(())
}

fn decode_variant(node: &YamlNode, field: &str) -> Result<ProfileVariantV4, ProfileV4Error> {
    if node.map_entries().is_none() {
        return Err(invalid(format!("{field} must be a mapping.")));
    }
    reject_unknown(
        node,
        &["when", "format", "rows", "metadata", "columns", "plot"],
        field,
    )?;
    let format_node = node
        .value_for_key("format")
        .filter(|n| n.map_entries().is_some())
        .ok_or_else(|| invalid(format!("{field}.format mapping is required.")))?;
    let rows_node = node
        .value_for_key("rows")
        .filter(|n| n.map_entries().is_some())
        .ok_or_else(|| invalid(format!("{field}.rows mapping is required.")))?;
    let columns_node = node
        .value_for_key("columns")
        .filter(|n| n.map_entries().is_some())
        .ok_or_else(|| invalid(format!("{field}.columns mapping is required.")))?;
    let plot_node = node
        .value_for_key("plot")
        .filter(|n| n.map_entries().is_some())
        .ok_or_else(|| invalid(format!("{field}.plot mapping is required.")))?;
    let mut columns = BTreeMap::new();
    for (key, col_node) in columns_node.map_entries().unwrap_or(&[]) {
        columns.insert(
            key.clone(),
            decode_column(col_node, &format!("{field}.columns.{key}"))?,
        );
    }
    Ok(ProfileVariantV4 {
        when: decode_when(node.value_for_key("when"), &format!("{field}.when"))?,
        format: decode_format(format_node, &format!("{field}.format"))?,
        rows: decode_rows(rows_node, &format!("{field}.rows"))?,
        metadata: decode_metadata(node.value_for_key("metadata"), field)?,
        columns,
        plot: decode_plot(plot_node, field)?,
    })
}

fn decode_format(node: &YamlNode, field: &str) -> Result<StreamFormatV4, ProfileV4Error> {
    reject_unknown(
        node,
        &["kind", "extensions", "delimiter", "encoding", "decimal"],
        field,
    )?;
    let kind = scalar_required(node, "kind", &format!("{field}.kind"))?;
    let extensions = string_list(
        node.value_for_key("extensions"),
        &format!("{field}.extensions"),
        false,
    )?
    .unwrap_or_default();
    let delimiter_text = scalar_required(node, "delimiter", &format!("{field}.delimiter"))?;
    if delimiter_text.chars().count() != 1 {
        return Err(invalid(format!(
            "{field}.delimiter must be a single character."
        )));
    }
    let delimiter = delimiter_text.chars().next().unwrap();
    let encoding_names = if let Some(enc) = node.value_for_key("encoding") {
        string_list(Some(enc), &format!("{field}.encoding"), false)?.unwrap_or_default()
    } else {
        vec!["utf-8".to_string()]
    };
    let decimal_separator = match node.value_for_key("decimal").and_then(|n| n.scalar_value()) {
        Some(text) if text.len() == 1 && (text == "." || text == ",") => {
            text.chars().next().unwrap()
        }
        Some(_) => {
            return Err(invalid(format!("{field}.decimal must be \".\" or \",\".")));
        }
        None => '.',
    };
    if delimiter == ',' && decimal_separator == ',' {
        return Err(invalid(format!(
            "{field}.decimal \",\" conflicts with delimiter \",\"."
        )));
    }
    Ok(StreamFormatV4 {
        kind,
        extensions,
        delimiter,
        encoding_names,
        decimal_separator,
    })
}

fn decode_rows(node: &YamlNode, field: &str) -> Result<RowsBlockV4, ProfileV4Error> {
    reject_unknown(
        node,
        &[
            "metadata",
            "skip",
            "header",
            "data_start",
            "names_prefix",
            "data_prefix",
        ],
        field,
    )?;
    Ok(RowsBlockV4 {
        metadata_rows: decode_row_list(
            node.value_for_key("metadata"),
            &format!("{field}.metadata"),
        )?,
        skip_rows: decode_row_list(node.value_for_key("skip"), &format!("{field}.skip"))?,
        header_row: optional_positive_int(
            node.value_for_key("header"),
            &format!("{field}.header"),
        )?,
        data_start_row: optional_positive_int(
            node.value_for_key("data_start"),
            &format!("{field}.data_start"),
        )?,
        names_prefix: optional_scalar(node, "names_prefix"),
        data_prefix: optional_scalar(node, "data_prefix"),
    })
}

fn decode_row_list(node: Option<&YamlNode>, field: &str) -> Result<Vec<RowSpanV4>, ProfileV4Error> {
    let Some(node) = node else {
        return Ok(Vec::new());
    };
    let items = node
        .list_items()
        .ok_or_else(|| invalid(format!("{field} must be a list of row numbers or ranges.")))?;
    let mut spans = Vec::new();
    for (index, item) in items.iter().enumerate() {
        let text = item
            .scalar_value()
            .ok_or_else(|| invalid(format!("{field}[{index}] must be a string or integer.")))?;
        spans.push(parse_row_span(text, &format!("{field}[{index}]"))?);
    }
    Ok(spans)
}

fn parse_row_span(text: &str, field: &str) -> Result<RowSpanV4, ProfileV4Error> {
    if let Ok(value) = text.parse::<i32>() {
        if value < 1 {
            return Err(invalid(format!("{field} must be a 1-based row number.")));
        }
        return Ok(RowSpanV4 {
            start: value,
            end: value,
        });
    }
    if let Some((start_text, end_text)) = text.split_once('-') {
        let start: i32 = start_text
            .trim()
            .parse()
            .map_err(|_| invalid(format!("{field} range start must be an integer.")))?;
        let end: i32 = end_text
            .trim()
            .parse()
            .map_err(|_| invalid(format!("{field} range end must be an integer.")))?;
        if start < 1 || end < start {
            return Err(invalid(format!("{field} must be a valid 1-based range.")));
        }
        return Ok(RowSpanV4 { start, end });
    }
    Err(invalid(format!(
        "{field} must be a row number or inclusive range such as \"1-9\"."
    )))
}

fn decode_metadata(
    node: Option<&YamlNode>,
    field: &str,
) -> Result<Vec<MetadataEntryV4>, ProfileV4Error> {
    let Some(node) = node else {
        return Ok(Vec::new());
    };
    let items = node
        .list_items()
        .ok_or_else(|| invalid(format!("{field}.metadata must be a list.")))?;
    let mut out = Vec::new();
    for (index, item) in items.iter().enumerate() {
        let meta_field = format!("{field}.metadata[{index}]");
        let entries = item
            .map_entries()
            .ok_or_else(|| invalid(format!("{meta_field} must be a mapping.")))?;
        if entries.iter().any(|(k, _)| k == "column") {
            reject_unknown(item, &["column", "row", "key"], &meta_field)?;
            let column = positive_int(
                item.value_for_key("column"),
                &format!("{meta_field}.column"),
            )?;
            let row = positive_int(item.value_for_key("row"), &format!("{meta_field}.row"))?;
            let key = scalar_required(item, "key", &format!("{meta_field}.key"))?;
            out.push(MetadataEntryV4::CellKey { column, row, key });
        } else {
            reject_unknown(item, &["row", "key", "type", "format"], &meta_field)?;
            let row = positive_int(item.value_for_key("row"), &format!("{meta_field}.row"))?;
            let key = scalar_required(item, "key", &format!("{meta_field}.key"))?;
            let value_type = scalar_required(item, "type", &format!("{meta_field}.type"))?;
            out.push(MetadataEntryV4::RowKeyValue {
                row,
                key,
                value_type,
                format: optional_scalar(item, "format"),
            });
        }
    }
    Ok(out)
}

fn decode_plot(node: &YamlNode, field: &str) -> Result<PlotSpecV4, ProfileV4Error> {
    reject_unknown(node, &["x", "y"], &format!("{field}.plot"))?;
    let x = scalar_required(node, "x", &format!("{field}.plot.x"))?;
    let y = string_list(node.value_for_key("y"), &format!("{field}.plot.y"), false)?
        .filter(|v| !v.is_empty())
        .ok_or_else(|| invalid(format!("{field}.plot.y must be a non-empty list.")))?;
    Ok(PlotSpecV4 { x, y })
}

fn decode_column(node: &YamlNode, field: &str) -> Result<ColumnDefinitionV4, ProfileV4Error> {
    if node.map_entries().is_none() {
        return Err(invalid(format!("{field} must be a mapping.")));
    }
    reject_unknown(
        node,
        &[
            "role",
            "label",
            "quantity",
            "unit",
            "header",
            "aliases",
            "required",
            "progression",
            "type",
            "behavior",
        ],
        field,
    )?;
    let role = match node.value_for_key("role").and_then(|n| n.scalar_value()) {
        Some(text) => match text {
            "channel" => ColumnRoleV4::Channel,
            "progression" => ColumnRoleV4::Progression,
            "skip" => ColumnRoleV4::Skip,
            other => {
                return Err(invalid(format!(
                    "{field}.role \"{other}\" is not channel, progression, or skip."
                )));
            }
        },
        None => ColumnRoleV4::Channel,
    };
    let mut progression = None;
    if let Some(prog_node) = node.value_for_key("progression") {
        progression = Some(decode_progression(
            prog_node,
            &format!("{field}.progression"),
        )?);
    } else if matches!(role, ColumnRoleV4::Progression) {
        let prog_type = node
            .value_for_key("type")
            .and_then(|n| n.scalar_value())
            .ok_or_else(|| invalid(format!("{field}.type is required for progression columns.")))?;
        let behavior = optional_scalar(node, "behavior");
        progression = Some(ColumnProgressionV4 {
            progression_type: prog_type.to_string(),
            behavior,
        });
    }
    Ok(ColumnDefinitionV4 {
        role,
        label: optional_scalar(node, "label"),
        quantity: optional_scalar(node, "quantity"),
        unit: optional_scalar(node, "unit"),
        header: optional_scalar(node, "header"),
        aliases: string_list(
            node.value_for_key("aliases"),
            &format!("{field}.aliases"),
            true,
        )?
        .unwrap_or_default(),
        required: match node
            .value_for_key("required")
            .and_then(|n| n.scalar_value())
        {
            Some("true") => true,
            Some("false") => false,
            Some(_) => {
                return Err(invalid(format!(
                    "{field}.required must be \"true\" or \"false\"."
                )));
            }
            None => true,
        },
        progression,
    })
}

fn decode_progression(node: &YamlNode, field: &str) -> Result<ColumnProgressionV4, ProfileV4Error> {
    if node.map_entries().is_none() {
        return Err(invalid(format!("{field} must be a mapping.")));
    }
    reject_unknown(node, &["type", "behavior"], field)?;
    let progression_type = scalar_required(node, "type", &format!("{field}.type"))?;
    Ok(ColumnProgressionV4 {
        progression_type,
        behavior: optional_scalar(node, "behavior"),
    })
}

fn decode_when(
    node: Option<&YamlNode>,
    field: &str,
) -> Result<Option<WhenClauseV4>, ProfileV4Error> {
    let Some(node) = node else {
        return Ok(None);
    };
    if node.map_entries().is_none() {
        return Err(invalid(format!("{field} must be a mapping.")));
    }
    let mut when = WhenClauseV4::default();
    for (key, value) in node.map_entries().unwrap_or(&[]) {
        match key.as_str() {
            "content_contains_any" => {
                when.content_contains_any = Some(
                    string_list(Some(value), &format!("{field}.content_contains_any"), false)?
                        .unwrap_or_default(),
                );
            }
            "content_starts_with" => {
                when.content_starts_with = Some(
                    string_list(Some(value), &format!("{field}.content_starts_with"), false)?
                        .unwrap_or_default(),
                );
            }
            "filename_contains_all" => {
                when.filename_contains_all = Some(
                    string_list(
                        Some(value),
                        &format!("{field}.filename_contains_all"),
                        false,
                    )?
                    .unwrap_or_default(),
                );
            }
            token => {
                let scalar = value.scalar_value().ok_or_else(|| {
                    invalid(format!("{field}.{token} must be a scalar equality value."))
                })?;
                when.tokens.insert(token.to_string(), scalar.to_string());
            }
        }
    }
    Ok(Some(when))
}

fn reject_unknown(node: &YamlNode, allowed: &[&str], scope: &str) -> Result<(), ProfileV4Error> {
    let Some(entries) = node.map_entries() else {
        return Ok(());
    };
    let allowed_set: HashSet<_> = allowed.iter().copied().collect();
    for (key, _) in entries {
        if !allowed_set.contains(key.as_str()) {
            if scope.is_empty() {
                return Err(invalid(format!(
                    "unknown key \"{key}\" is not part of schema v4."
                )));
            }
            return Err(invalid(format!(
                "{scope}.{key} is not part of schema v4 (unknown key)."
            )));
        }
    }
    Ok(())
}

fn scalar_required(node: &YamlNode, key: &str, field: &str) -> Result<String, ProfileV4Error> {
    optional_scalar(node, key).ok_or_else(|| invalid(format!("{field} is required.")))
}

fn optional_scalar(node: &YamlNode, key: &str) -> Option<String> {
    node.value_for_key(key)
        .and_then(|n| n.scalar_value())
        .map(str::to_string)
        .filter(|s| !s.is_empty())
}

fn string_list(
    node: Option<&YamlNode>,
    field: &str,
    allow_empty: bool,
) -> Result<Option<Vec<String>>, ProfileV4Error> {
    let Some(node) = node else {
        return Ok(None);
    };
    let items = node
        .list_items()
        .ok_or_else(|| invalid(format!("{field} must be a list.")))?;
    if !allow_empty && items.is_empty() {
        return Err(invalid(format!("{field} must not be empty.")));
    }
    let mut out = Vec::new();
    for item in items {
        let value = item
            .scalar_value()
            .ok_or_else(|| invalid(format!("{field} must contain only strings.")))?;
        out.push(value.to_string());
    }
    Ok(Some(out))
}

fn positive_int(node: Option<&YamlNode>, field: &str) -> Result<i32, ProfileV4Error> {
    let Some(node) = node else {
        return Err(invalid(format!("{field} is required.")));
    };
    let text = node
        .scalar_value()
        .ok_or_else(|| invalid(format!("{field} must be an integer.")))?;
    let value: i32 = text
        .parse()
        .map_err(|_| invalid(format!("{field} must be an integer.")))?;
    if value < 1 {
        return Err(invalid(format!("{field} must be a positive integer.")));
    }
    Ok(value)
}

fn optional_positive_int(
    node: Option<&YamlNode>,
    field: &str,
) -> Result<Option<i32>, ProfileV4Error> {
    let Some(node) = node else {
        return Ok(None);
    };
    Ok(Some(positive_int(Some(node), field)?))
}

fn non_empty(value: &str, field: &str) -> Result<(), ProfileV4Error> {
    if value.trim().is_empty() {
        return Err(invalid(format!("{field} must not be empty.")));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn variants_map_is_keyed_by_application_mode() {
        let yaml = r#"schema_version: 4
id: usth/demo
instrument:
  id: demo
  name: Demo
variants:
  cv:
    format:
      kind: tabular
      extensions: [".txt"]
      delimiter: ","
    rows:
      names_prefix: H
      data_prefix: D
    columns:
      x:
        role: channel
        header: X
        quantity: voltage
        unit: V
        label: X
      y:
        role: channel
        header: Y
        quantity: current
        unit: A
        label: Y
    plot:
      x: x
      y: [y]
    when:
      content_contains_any: ["cv"]
"#;
        let doc = parse(yaml).expect("parse");
        assert_eq!(doc.variants.keys().cloned().collect::<Vec<_>>(), vec!["cv"]);
    }

    #[test]
    fn overlapping_rows_fail_validation() {
        let yaml = r#"schema_version: 4
id: usth/demo
instrument:
  id: demo
  name: Demo
variants:
  m:
    format:
      kind: tabular
      extensions: [".txt"]
      delimiter: ","
    rows:
      metadata: [1, "2-4"]
      header: 3
    columns:
      x:
        role: channel
        header: X
        quantity: voltage
        unit: V
        label: X
    plot:
      x: x
      y: [x]
    when:
      content_contains_any: ["x"]
"#;
        let err = parse(yaml).unwrap_err().message().to_string();
        assert!(err.contains("overlap"), "{err}");
    }

    #[test]
    fn progression_columns_round_trip() {
        let yaml = r#"schema_version: 4
id: usth/demo
instrument:
  id: demo
  name: Demo
variants:
  ca:
    format:
      kind: tabular
      extensions: [".txt"]
      delimiter: ","
    rows:
      header: 1
      data_start: 2
    columns:
      t:
        role: progression
        type: time
        behavior: continuous
        label: Time
        quantity: time
        unit: s
        header: Time
      i:
        role: progression
        type: index
        behavior: discrete
        label: Step
        quantity: index
        unit: "1"
        header: Step
      c:
        role: channel
        header: I
        quantity: current
        unit: A
        label: I
    plot:
      x: t
      y: [c]
    when:
      content_contains_any: ["ca"]
"#;
        let doc = parse(yaml).expect("parse");
        let cols = &doc.variants["ca"].columns;
        assert_eq!(
            cols["t"]
                .progression
                .as_ref()
                .map(|p| p.progression_type.as_str()),
            Some("time")
        );
        assert_eq!(
            cols["t"]
                .progression
                .as_ref()
                .and_then(|p| p.behavior.as_deref()),
            Some("continuous")
        );
        assert_eq!(
            cols["i"]
                .progression
                .as_ref()
                .map(|p| p.progression_type.as_str()),
            Some("index")
        );
    }
}
