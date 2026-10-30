//! Schema-v3 variant profile documents (decode + structural validation).

use crate::yaml::YamlNode;
use std::collections::{BTreeSet, HashSet};

pub type ProfileDocumentError = ProfileV3Error;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ProfileDocumentV3 {
    pub profile_id: String,
    pub profile_name: String,
    pub instrument_id: String,
    pub instrument_name: String,
    pub vendor: Option<String>,
    pub model: Option<String>,
    pub grammar_id: String,
    pub variant_keys: Vec<String>,
    pub variants: Vec<ProfileVariantV3>,
    pub legacy_origin: Option<ProfileLegacyOrigin>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ProfileLegacyOrigin {
    pub path: String,
    pub sha256: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ProfileVariantV3 {
    pub id: String,
    pub name: String,
    pub key_values: Vec<(String, String)>,
    pub match_selectors: Option<VariantMatchV3>,
    pub raw_stream: RawStreamV3,
    pub metadata: Vec<VariantMetadataV3>,
    pub metadata_capture: Vec<MetadataCaptureRuleV3>,
    pub default_plot: Option<DefaultPlotV3>,
}

#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct VariantMatchV3 {
    pub filename_contains_all: Option<Vec<String>>,
    pub content_contains_any: Option<Vec<String>>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RawStreamV3 {
    pub extensions: Vec<String>,
    pub encodings: Vec<String>,
    pub delimiter: String,
    pub decimal_separator: String,
    pub rows: RowLocatorsV3,
    pub columns: Vec<ProfileColumnV3>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RowLocatorsV3 {
    pub header: HeaderLocatorV3,
    pub data_start: DataStartLocatorV3,
    pub data_prefix: Option<String>,
    pub comment_prefix: Option<String>,
    pub excluded_metadata: Vec<i32>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum HeaderLocatorV3 {
    None,
    Row(i32),
    FirstNonBlank,
    Prefix(String),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum DataStartLocatorV3 {
    Row(i32),
    AfterHeader,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum AxisV3 {
    X,
    Y,
}

impl AxisV3 {
    fn parse(raw: &str) -> Option<Self> {
        match raw {
            "x" => Some(Self::X),
            "y" => Some(Self::Y),
            _ => None,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ProfileColumnV3 {
    pub id: String,
    pub source: ColumnSourceV3,
    pub label: String,
    pub quantity: String,
    pub unit: Option<String>,
    pub required: bool,
    pub role: ColumnRoleV3,
    pub axes: Vec<AxisV3>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ColumnRoleV3 {
    Channel,
    Skip,
    Progression,
}

impl ColumnRoleV3 {
    fn parse(raw: &str) -> Option<Self> {
        match raw {
            "channel" => Some(Self::Channel),
            "skip" => Some(Self::Skip),
            "progression" => Some(Self::Progression),
            _ => None,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct ColumnSourceV3 {
    pub column: Option<i32>,
    pub header: Option<String>,
    pub aliases: Vec<String>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct VariantMetadataV3 {
    pub key: String,
    pub role: String,
    pub row: Option<i32>,
    pub column: Option<i32>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum MetadataCaptureRuleV3 {
    PreHeaderFields,
    CommentKeyValue(String),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DefaultPlotV3 {
    pub x: String,
    pub y: Vec<String>,
    pub progression: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ProfileV3Error {
    Invalid(String),
}

impl ProfileV3Error {
    pub fn message(&self) -> &str {
        match self {
            Self::Invalid(reason) => reason,
        }
    }
}

impl std::fmt::Display for ProfileV3Error {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(self.message())
    }
}

impl std::error::Error for ProfileV3Error {}

pub fn parse(text: &str) -> Result<ProfileDocumentV3, ProfileDocumentError> {
    let root = crate::yaml::parse(text, false)
        .map_err(|err| ProfileV3Error::Invalid(format!("Profile YAML parse error {err}")))?;
    if root.map_entries().is_none() {
        return Err(invalid("The profile document must be a mapping."));
    }
    let doc = decode_v3(&root)?;
    validate_structure(&doc)?;
    Ok(doc)
}

pub fn decode_v3(root: &YamlNode) -> Result<ProfileDocumentV3, ProfileV3Error> {
    reject_unknown(
        root,
        &[
            "schema_version",
            "identity",
            "filename",
            "variants",
            "legacy_origin",
        ],
        "",
    )?;
    let version = root
        .value_for_key("schema_version")
        .and_then(|n| n.scalar_value())
        .ok_or_else(|| invalid("schema_version must be 3 for a variant profile document."))?;
    if version != "3" {
        return Err(invalid(
            "schema_version must be 3 for a variant profile document.",
        ));
    }
    let identity = root
        .value_for_key("identity")
        .filter(|n| n.map_entries().is_some())
        .ok_or_else(|| invalid("identity mapping is required."))?;
    reject_unknown(identity, &["id", "name", "instrument"], "identity")?;
    let profile_id = scalar_required(identity, "id", "identity.id")?;
    let profile_name = scalar_required(identity, "name", "identity.name")?;
    let instrument = identity
        .value_for_key("instrument")
        .filter(|n| n.map_entries().is_some())
        .ok_or_else(|| invalid("identity.instrument mapping is required."))?;
    reject_unknown(
        instrument,
        &["id", "name", "vendor", "model"],
        "identity.instrument",
    )?;
    let instrument_id = scalar_required(instrument, "id", "identity.instrument.id")?;
    let instrument_name = scalar_required(instrument, "name", "identity.instrument.name")?;
    let filename = root
        .value_for_key("filename")
        .filter(|n| n.map_entries().is_some())
        .ok_or_else(|| invalid("filename mapping is required."))?;
    reject_unknown(filename, &["grammar_id", "variant_keys"], "filename")?;
    let grammar_id = scalar_required(filename, "grammar_id", "filename.grammar_id")?;
    let variant_keys = string_list(
        filename.value_for_key("variant_keys"),
        "filename.variant_keys",
        true,
    )?
    .unwrap_or_default();
    let variant_nodes = root
        .value_for_key("variants")
        .and_then(|n| n.list_items())
        .ok_or_else(|| invalid("variants must be a list."))?;
    let mut variants = Vec::new();
    for (index, node) in variant_nodes.iter().enumerate() {
        variants.push(decode_variant(node, index)?);
    }
    Ok(ProfileDocumentV3 {
        profile_id,
        profile_name,
        instrument_id,
        instrument_name,
        vendor: optional_scalar(instrument, "vendor"),
        model: optional_scalar(instrument, "model"),
        grammar_id,
        variant_keys,
        variants,
        legacy_origin: decode_legacy_origin(root.value_for_key("legacy_origin"))?,
    })
}

pub fn validate_structure(doc: &ProfileDocumentV3) -> Result<(), ProfileV3Error> {
    safe_id(&doc.profile_id, "identity.id")?;
    non_empty(&doc.profile_name, "identity.name")?;
    safe_id(&doc.instrument_id, "identity.instrument.id")?;
    non_empty(&doc.instrument_name, "identity.instrument.name")?;
    if let Some(vendor) = &doc.vendor {
        non_empty(vendor, "identity.instrument.vendor")?;
    }
    if let Some(model) = &doc.model {
        non_empty(model, "identity.instrument.model")?;
    }
    id_text(&doc.grammar_id, "filename.grammar_id")?;
    let mut seen_keys = BTreeSet::new();
    for key in &doc.variant_keys {
        id_text(key, "filename.variant_keys")?;
        if !seen_keys.insert(key.clone()) {
            return Err(invalid(format!(
                "filename.variant_keys entry \"{key}\" is duplicated."
            )));
        }
    }
    if doc.variants.is_empty() {
        return Err(invalid("variants must contain at least one variant."));
    }
    let mut seen_ids = HashSet::new();
    for (index, variant) in doc.variants.iter().enumerate() {
        validate_variant(variant, index, &doc.variant_keys, &mut seen_ids)?;
    }
    if let Some(origin) = &doc.legacy_origin {
        non_empty(&origin.path, "legacy_origin.path")?;
        single_line(&origin.path, "legacy_origin.path")?;
        if origin.sha256.len() != 64 || !origin.sha256.chars().all(|c| c.is_ascii_hexdigit()) {
            return Err(invalid(
                "legacy_origin.sha256 must be 64 hexadecimal characters.",
            ));
        }
    }
    Ok(())
}

pub fn lenient_v3_extensions(root: &YamlNode) -> Vec<String> {
    let mut extensions = Vec::new();
    let Some(variant_nodes) = root.value_for_key("variants").and_then(|n| n.list_items()) else {
        return extensions;
    };
    for variant in variant_nodes {
        let Some(ext_nodes) = variant
            .value_for_key("raw_stream")
            .and_then(|s| s.value_for_key("extensions"))
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

fn validate_variant(
    variant: &ProfileVariantV3,
    index: usize,
    keys: &[String],
    seen_ids: &mut HashSet<String>,
) -> Result<(), ProfileV3Error> {
    let field = format!("variants[{index}]");
    id_text(&variant.id, &format!("{field}.id"))?;
    if !seen_ids.insert(variant.id.clone()) {
        return Err(invalid(format!(
            "{field}.id \"{}\" is duplicated.",
            variant.id
        )));
    }
    non_empty(&variant.name, &format!("{field}.name"))?;
    let key_set: HashSet<_> = keys.iter().cloned().collect();
    let missing: Vec<_> = keys
        .iter()
        .filter(|key| !variant.key_values.iter().any(|(k, _)| k == *key))
        .collect();
    if !missing.is_empty() {
        let quoted = missing
            .iter()
            .map(|k| format!("\"{k}\""))
            .collect::<Vec<_>>()
            .join(", ");
        return Err(invalid(format!(
            "{field}.key_values is missing keys {quoted}."
        )));
    }
    for (key, value) in &variant.key_values {
        if !key_set.contains(key) {
            return Err(invalid(format!(
                "{field}.key_values has keys outside filename.variant_keys: \"{key}\"."
            )));
        }
        non_empty(value, &format!("{field}.key_values.{key}"))?;
    }
    if let Some(m) = &variant.match_selectors {
        if m.filename_contains_all.is_none() && m.content_contains_any.is_none() {
            return Err(invalid(format!(
                "{field}.match names at least one selector."
            )));
        }
        for list in [&m.filename_contains_all, &m.content_contains_any]
            .into_iter()
            .flatten()
        {
            if list.is_empty() {
                return Err(invalid(format!(
                    "{field}.match selector lists must not be empty."
                )));
            }
            for entry in list {
                non_empty(entry, &format!("{field}.match"))?;
            }
        }
    }
    validate_stream(&variant.raw_stream, &field)?;
    if let Some(plot) = &variant.default_plot {
        validate_plot(plot, &field, &variant.raw_stream.columns)?;
    }
    Ok(())
}

fn validate_stream(stream: &RawStreamV3, field: &str) -> Result<(), ProfileV3Error> {
    let stream_field = format!("{field}.raw_stream");
    if stream.extensions.is_empty() {
        return Err(invalid(format!(
            "{stream_field}.extensions must not be empty."
        )));
    }
    for ext in &stream.extensions {
        non_empty(ext, &format!("{stream_field}.extensions"))?;
        if !ext.starts_with('.') {
            return Err(invalid(format!(
                "{stream_field}.extensions entry \"{ext}\" must start with \".\"."
            )));
        }
    }
    if stream.encodings.is_empty() {
        return Err(invalid(format!(
            "{stream_field}.encoding must not be empty."
        )));
    }
    for name in &stream.encodings {
        non_empty(name, &format!("{stream_field}.encoding"))?;
        if !known_encoding(name) {
            return Err(invalid(format!(
                "{stream_field}.encoding entry \"{name}\" is not supported; use utf-8, windows-1252, iso-8859-1, or ascii."
            )));
        }
    }
    if stream.delimiter.chars().count() != 1 {
        return Err(invalid(format!(
            "{stream_field}.delimiter must be a single character."
        )));
    }
    single_line(&stream.delimiter, &format!("{stream_field}.delimiter"))?;
    if stream.decimal_separator != "." && stream.decimal_separator != "," {
        return Err(invalid(format!(
            "{stream_field}.decimal_separator must be \".\" or \",\"."
        )));
    }
    if stream.delimiter == "," && stream.decimal_separator == "," {
        return Err(invalid(format!(
            "{stream_field}.decimal_separator \",\" conflicts with delimiter \",\"."
        )));
    }
    if stream.columns.is_empty() {
        return Err(invalid(format!(
            "{stream_field}.columns must declare at least one column."
        )));
    }
    let mut seen_ids = HashSet::new();
    for (index, column) in stream.columns.iter().enumerate() {
        validate_column(
            column,
            &format!("{stream_field}.columns[{index}]"),
            &mut seen_ids,
        )?;
    }
    Ok(())
}

fn validate_column(
    column: &ProfileColumnV3,
    field: &str,
    seen_ids: &mut HashSet<String>,
) -> Result<(), ProfileV3Error> {
    id_text(&column.id, &format!("{field}.id"))?;
    if !seen_ids.insert(column.id.clone()) {
        return Err(invalid(format!(
            "{field}.id \"{}\" is duplicated.",
            column.id
        )));
    }
    if let Some(position) = column.source.column {
        if position < 1 {
            return Err(invalid(format!(
                "{field}.source.column must be a positive integer."
            )));
        }
    }
    if let Some(header) = &column.source.header {
        non_empty(header, &format!("{field}.source.header"))?;
    } else if !column.source.aliases.is_empty() {
        return Err(invalid(format!("{field}.source.aliases require a header.")));
    }
    if column.source.column.is_none() && column.source.header.is_none() {
        return Err(invalid(format!(
            "{field}.source requires a column or header."
        )));
    }
    for alias in &column.source.aliases {
        non_empty(alias, &format!("{field}.source.aliases"))?;
    }
    non_empty(&column.label, &format!("{field}.label"))?;
    non_empty(&column.quantity, &format!("{field}.quantity"))?;
    if let Some(unit) = &column.unit {
        non_empty(unit, &format!("{field}.unit"))?;
    }
    if column.axes.len() != column.axes.iter().collect::<HashSet<_>>().len() {
        return Err(invalid(format!("{field}.axes contains duplicated axes.")));
    }
    if column.role == ColumnRoleV3::Skip && !column.axes.is_empty() {
        return Err(invalid(format!(
            "{field} is skipped and must not declare axes."
        )));
    }
    Ok(())
}

fn validate_plot(
    plot: &DefaultPlotV3,
    field: &str,
    columns: &[ProfileColumnV3],
) -> Result<(), ProfileV3Error> {
    let x = find_column(&plot.x, columns).ok_or_else(|| {
        invalid(format!(
            "{field}.default_plot.x \"{}\" is not a declared column.",
            plot.x
        ))
    })?;
    if !x.required || x.role == ColumnRoleV3::Skip || !x.axes.contains(&AxisV3::X) {
        return Err(invalid(format!(
            "{field}.default_plot.x \"{}\" must be a required nonskipped column declaring the x axis.",
            plot.x
        )));
    }
    if plot.y.is_empty() {
        return Err(invalid(format!(
            "{field}.default_plot.y must name at least one column."
        )));
    }
    for id in &plot.y {
        let y = find_column(id, columns).ok_or_else(|| {
            invalid(format!(
                "{field}.default_plot.y \"{id}\" is not a declared column."
            ))
        })?;
        if !y.required || y.role == ColumnRoleV3::Skip || !y.axes.contains(&AxisV3::Y) {
            return Err(invalid(format!(
                "{field}.default_plot.y \"{id}\" must be a required nonskipped column declaring the y axis."
            )));
        }
    }
    Ok(())
}

fn find_column<'a>(id: &str, columns: &'a [ProfileColumnV3]) -> Option<&'a ProfileColumnV3> {
    columns.iter().find(|c| c.id == id)
}

fn decode_variant(node: &YamlNode, index: usize) -> Result<ProfileVariantV3, ProfileV3Error> {
    let field = format!("variants[{index}]");
    if node.map_entries().is_none() {
        return Err(invalid(format!("{field} must be a mapping.")));
    }
    reject_unknown(
        node,
        &[
            "id",
            "name",
            "key_values",
            "match",
            "raw_stream",
            "metadata",
            "metadata_capture",
            "default_plot",
        ],
        &field,
    )?;
    let id = scalar_required(node, "id", &format!("{field}.id"))?;
    let name = scalar_required(node, "name", &format!("{field}.name"))?;
    let key_entries = node
        .value_for_key("key_values")
        .and_then(|n| n.map_entries())
        .ok_or_else(|| invalid(format!("{field}.key_values mapping is required.")))?;
    let mut key_values = Vec::new();
    for (key, value_node) in key_entries {
        let value = value_node
            .scalar_value()
            .ok_or_else(|| invalid(format!("{field}.key_values.{key} must be a string.")))?;
        key_values.push((key.clone(), value.to_string()));
    }
    let stream = node
        .value_for_key("raw_stream")
        .filter(|n| n.map_entries().is_some())
        .ok_or_else(|| invalid(format!("{field}.raw_stream mapping is required.")))?;
    Ok(ProfileVariantV3 {
        id,
        name,
        key_values,
        match_selectors: decode_match(node.value_for_key("match"), &field)?,
        raw_stream: decode_stream(stream, &field)?,
        metadata: decode_metadata_list(node.value_for_key("metadata"), &field)?,
        metadata_capture: decode_capture(node.value_for_key("metadata_capture"), &field)?,
        default_plot: decode_plot(node.value_for_key("default_plot"), &field)?,
    })
}

fn decode_match(
    node: Option<&YamlNode>,
    field: &str,
) -> Result<Option<VariantMatchV3>, ProfileV3Error> {
    let Some(node) = node else {
        return Ok(None);
    };
    if matches!(node, YamlNode::Scalar(text) if text.is_empty()) {
        return Ok(None);
    }
    if node.map_entries().is_none() {
        return Err(invalid(format!("{field}.match must be a mapping.")));
    }
    reject_unknown(
        node,
        &["filename_contains_all", "content_contains_any"],
        &format!("{field}.match"),
    )?;
    let mut m = VariantMatchV3::default();
    if node.value_for_key("filename_contains_all").is_some() {
        m.filename_contains_all = Some(
            string_list(
                node.value_for_key("filename_contains_all"),
                &format!("{field}.match.filename_contains_all"),
                false,
            )?
            .unwrap_or_default(),
        );
    }
    if node.value_for_key("content_contains_any").is_some() {
        m.content_contains_any = Some(
            string_list(
                node.value_for_key("content_contains_any"),
                &format!("{field}.match.content_contains_any"),
                false,
            )?
            .unwrap_or_default(),
        );
    }
    Ok(Some(m))
}

fn decode_stream(node: &YamlNode, field: &str) -> Result<RawStreamV3, ProfileV3Error> {
    let stream_field = format!("{field}.raw_stream");
    reject_unknown(
        node,
        &[
            "extensions",
            "encoding",
            "delimiter",
            "decimal_separator",
            "rows",
            "columns",
        ],
        &stream_field,
    )?;
    let extensions = string_list(
        node.value_for_key("extensions"),
        &format!("{stream_field}.extensions"),
        false,
    )?
    .unwrap_or_default()
    .into_iter()
    .map(|e| e.to_lowercase())
    .collect();
    let encodings = string_list(
        node.value_for_key("encoding"),
        &format!("{stream_field}.encoding"),
        false,
    )?
    .unwrap_or_default();
    let delimiter = scalar_required(node, "delimiter", &format!("{stream_field}.delimiter"))?;
    let decimal_separator = scalar_required(
        node,
        "decimal_separator",
        &format!("{stream_field}.decimal_separator"),
    )?;
    let rows = node
        .value_for_key("rows")
        .filter(|n| n.map_entries().is_some())
        .ok_or_else(|| invalid(format!("{stream_field}.rows mapping is required.")))?;
    let column_nodes = node
        .value_for_key("columns")
        .and_then(|n| n.list_items())
        .ok_or_else(|| invalid(format!("{stream_field}.columns must be a list.")))?;
    let mut columns = Vec::new();
    for (index, item) in column_nodes.iter().enumerate() {
        columns.push(decode_column(
            item,
            &format!("{stream_field}.columns[{index}]"),
        )?);
    }
    Ok(RawStreamV3 {
        extensions,
        encodings,
        delimiter,
        decimal_separator,
        rows: decode_rows(rows, &stream_field)?,
        columns,
    })
}

fn decode_rows(node: &YamlNode, field: &str) -> Result<RowLocatorsV3, ProfileV3Error> {
    let rows_field = format!("{field}.rows");
    reject_unknown(
        node,
        &[
            "header",
            "data_start",
            "data_prefix",
            "comment_prefix",
            "excluded_metadata",
        ],
        &rows_field,
    )?;
    let header = if let Some(header_node) = node.value_for_key("header") {
        decode_header(header_node, &format!("{rows_field}.header"))?
    } else {
        HeaderLocatorV3::None
    };
    let start = node
        .value_for_key("data_start")
        .filter(|n| n.map_entries().is_some())
        .ok_or_else(|| invalid(format!("{rows_field}.data_start mapping is required.")))?;
    reject_unknown(
        start,
        &["row", "after_header"],
        &format!("{rows_field}.data_start"),
    )?;
    let entry_count = start.map_entries().map(|e| e.len()).unwrap_or(0);
    let data_start = if start.value_for_key("row").is_some() {
        if entry_count != 1 {
            return Err(invalid(format!(
                "{rows_field}.data_start names one locator."
            )));
        }
        DataStartLocatorV3::Row(positive_int(
            start.value_for_key("row").unwrap(),
            &format!("{rows_field}.data_start.row"),
        )?)
    } else if start.value_for_key("after_header").is_some() {
        if entry_count != 1 {
            return Err(invalid(format!(
                "{rows_field}.data_start names one locator."
            )));
        }
        if start
            .value_for_key("after_header")
            .and_then(|n| n.scalar_value())
            != Some("true")
        {
            return Err(invalid(format!(
                "{rows_field}.data_start.after_header must be \"true\"."
            )));
        }
        DataStartLocatorV3::AfterHeader
    } else {
        return Err(invalid(format!(
            "{rows_field}.data_start names one locator."
        )));
    };
    Ok(RowLocatorsV3 {
        header,
        data_start,
        data_prefix: scalar_any(node.value_for_key("data_prefix")),
        comment_prefix: optional_scalar(node, "comment_prefix"),
        excluded_metadata: node
            .value_for_key("excluded_metadata")
            .and_then(|n| n.list_items())
            .map(|items| {
                items
                    .iter()
                    .filter_map(|item| {
                        positive_int(item, &format!("{rows_field}.excluded_metadata")).ok()
                    })
                    .collect()
            })
            .unwrap_or_default(),
    })
}

fn decode_header(node: &YamlNode, field: &str) -> Result<HeaderLocatorV3, ProfileV3Error> {
    if matches!(node, YamlNode::Scalar(text) if text.is_empty()) {
        return Ok(HeaderLocatorV3::None);
    }
    let entries = node
        .map_entries()
        .ok_or_else(|| invalid(format!("{field} names one locator.")))?;
    if entries.len() != 1 {
        return Err(invalid(format!("{field} names one locator.")));
    }
    match entries[0].0.as_str() {
        "row" => Ok(HeaderLocatorV3::Row(positive_int(
            &entries[0].1,
            &format!("{field}.row"),
        )?)),
        "first_nonblank" => {
            if entries[0].1.scalar_value() != Some("true") {
                return Err(invalid(format!("{field}.first_nonblank must be \"true\".")));
            }
            Ok(HeaderLocatorV3::FirstNonBlank)
        }
        "prefix" => {
            let text = entries[0]
                .1
                .scalar_value()
                .ok_or_else(|| invalid(format!("{field}.prefix must be a nonempty string.")))?;
            Ok(HeaderLocatorV3::Prefix(text.to_string()))
        }
        key => Err(invalid(format!("{field}.{key} is not a header locator."))),
    }
}

fn decode_column(node: &YamlNode, field: &str) -> Result<ProfileColumnV3, ProfileV3Error> {
    if node.map_entries().is_none() {
        return Err(invalid(format!("{field} must be a mapping.")));
    }
    reject_unknown(
        node,
        &[
            "id",
            "source",
            "label",
            "quantity",
            "unit",
            "required",
            "role",
            "axes",
            "progression",
        ],
        field,
    )?;
    let id = scalar_required(node, "id", &format!("{field}.id"))?;
    let source = node
        .value_for_key("source")
        .filter(|n| n.map_entries().is_some())
        .ok_or_else(|| invalid(format!("{field}.source mapping is required.")))?;
    reject_unknown(
        source,
        &["column", "header", "aliases"],
        &format!("{field}.source"),
    )?;
    let column_source = ColumnSourceV3 {
        column: source
            .value_for_key("column")
            .map(|n| positive_int(n, &format!("{field}.source.column")))
            .transpose()?,
        header: optional_scalar(source, "header"),
        aliases: string_list(
            source.value_for_key("aliases"),
            &format!("{field}.source.aliases"),
            true,
        )?
        .unwrap_or_default(),
    };
    let label = scalar_required(node, "label", &format!("{field}.label"))?;
    let quantity = scalar_required(node, "quantity", &format!("{field}.quantity"))?;
    let role = node
        .value_for_key("role")
        .and_then(|n| n.scalar_value())
        .and_then(ColumnRoleV3::parse)
        .unwrap_or(ColumnRoleV3::Channel);
    let required = match node
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
    };
    let axes = if node.value_for_key("axes").is_some() {
        string_list(node.value_for_key("axes"), &format!("{field}.axes"), true)?
            .unwrap_or_default()
            .into_iter()
            .map(|name| {
                AxisV3::parse(&name)
                    .ok_or_else(|| invalid(format!("{field}.axes entry \"{name}\" is not x or y.")))
            })
            .collect::<Result<Vec<_>, _>>()?
    } else {
        vec![]
    };
    Ok(ProfileColumnV3 {
        id,
        source: column_source,
        label,
        quantity,
        unit: optional_scalar(node, "unit"),
        required,
        role,
        axes,
    })
}

fn decode_metadata_list(
    node: Option<&YamlNode>,
    field: &str,
) -> Result<Vec<VariantMetadataV3>, ProfileV3Error> {
    let Some(node) = node else {
        return Ok(Vec::new());
    };
    if node.list_items().map(|l| l.is_empty()).unwrap_or(true) {
        return Ok(Vec::new());
    }
    let items = node
        .list_items()
        .ok_or_else(|| invalid(format!("{field}.metadata must be a list.")))?;
    let mut out = Vec::new();
    for (index, item) in items.iter().enumerate() {
        let meta_field = format!("{field}.metadata[{index}]");
        reject_unknown(
            item,
            &["key", "role", "source", "format", "parameter"],
            &meta_field,
        )?;
        let key = scalar_required(item, "key", &format!("{meta_field}.key"))?;
        let role = scalar_required(item, "role", &format!("{meta_field}.role"))?;
        let source = item.value_for_key("source");
        let row = source
            .and_then(|s| s.value_for_key("row"))
            .map(|n| positive_int(n, &format!("{meta_field}.source.row")))
            .transpose()?;
        let column = source
            .and_then(|s| s.value_for_key("column"))
            .map(|n| positive_int(n, &format!("{meta_field}.source.column")))
            .transpose()?;
        out.push(VariantMetadataV3 {
            key,
            role,
            row,
            column,
        });
    }
    Ok(out)
}

fn decode_capture(
    node: Option<&YamlNode>,
    field: &str,
) -> Result<Vec<MetadataCaptureRuleV3>, ProfileV3Error> {
    let Some(node) = node else {
        return Ok(Vec::new());
    };
    if node.list_items().map(|l| l.is_empty()).unwrap_or(true) {
        return Ok(Vec::new());
    }
    let items = node
        .list_items()
        .ok_or_else(|| invalid(format!("{field}.metadata_capture must be a list.")))?;
    let mut rules = Vec::new();
    for (index, item) in items.iter().enumerate() {
        let rule_field = format!("{field}.metadata_capture[{index}]");
        reject_unknown(item, &["kind", "prefix"], &rule_field)?;
        let kind = scalar_required(item, "kind", &format!("{rule_field}.kind"))?;
        match kind.as_str() {
            "pre_header_fields" => {
                if item.value_for_key("prefix").is_some() {
                    return Err(invalid(format!(
                        "{rule_field} of kind pre_header_fields takes no prefix."
                    )));
                }
                rules.push(MetadataCaptureRuleV3::PreHeaderFields);
            }
            "comment_key_value" => {
                let prefix = scalar_required(
                    item,
                    "prefix",
                    &format!("{rule_field} of kind comment_key_value requires a nonempty prefix."),
                )?;
                rules.push(MetadataCaptureRuleV3::CommentKeyValue(prefix));
            }
            other => {
                return Err(invalid(format!(
                    "{rule_field}.kind \"{other}\" is not pre_header_fields or comment_key_value."
                )));
            }
        }
    }
    Ok(rules)
}

fn decode_plot(
    node: Option<&YamlNode>,
    field: &str,
) -> Result<Option<DefaultPlotV3>, ProfileV3Error> {
    let Some(node) = node else {
        return Ok(None);
    };
    if matches!(node, YamlNode::Scalar(text) if text.is_empty()) {
        return Ok(None);
    }
    if node.map_entries().is_none() {
        return Err(invalid(format!("{field}.default_plot must be a mapping.")));
    }
    reject_unknown(
        node,
        &["x", "y", "progression"],
        &format!("{field}.default_plot"),
    )?;
    let x = scalar_required(node, "x", &format!("{field}.default_plot.x"))?;
    let y = string_list(
        node.value_for_key("y"),
        &format!("{field}.default_plot.y"),
        false,
    )?
    .unwrap_or_default();
    Ok(Some(DefaultPlotV3 {
        x,
        y,
        progression: optional_scalar(node, "progression"),
    }))
}

fn decode_legacy_origin(
    node: Option<&YamlNode>,
) -> Result<Option<ProfileLegacyOrigin>, ProfileV3Error> {
    let Some(node) = node else {
        return Ok(None);
    };
    if matches!(node, YamlNode::Scalar(text) if text.is_empty()) {
        return Ok(None);
    }
    if node.map_entries().is_none() {
        return Err(invalid("legacy_origin must be a mapping."));
    }
    reject_unknown(node, &["path", "sha256"], "legacy_origin")?;
    Ok(Some(ProfileLegacyOrigin {
        path: scalar_required(node, "path", "legacy_origin.path")?,
        sha256: scalar_required(node, "sha256", "legacy_origin.sha256")?,
    }))
}

fn invalid(reason: impl Into<String>) -> ProfileV3Error {
    ProfileV3Error::Invalid(reason.into())
}

fn scalar_required(node: &YamlNode, key: &str, field: &str) -> Result<String, ProfileV3Error> {
    node.value_for_key(key)
        .and_then(|n| n.scalar_value())
        .map(str::to_string)
        .ok_or_else(|| invalid(format!("{field} is required.")))
}

fn optional_scalar(node: &YamlNode, key: &str) -> Option<String> {
    node.value_for_key(key)
        .and_then(|n| n.scalar_value())
        .map(str::to_string)
}

fn scalar_any(node: Option<&YamlNode>) -> Option<String> {
    match node {
        Some(YamlNode::Scalar(text)) => Some(text.clone()),
        _ => None,
    }
}

fn string_list(
    node: Option<&YamlNode>,
    field: &str,
    allow_empty: bool,
) -> Result<Option<Vec<String>>, ProfileV3Error> {
    let Some(node) = node else {
        return Ok(if allow_empty { Some(vec![]) } else { None });
    };
    let items = node
        .list_items()
        .ok_or_else(|| invalid(format!("{field} must be a list.")))?;
    if items.is_empty() && !allow_empty {
        return Err(invalid(format!("{field} must not be empty.")));
    }
    let mut values = Vec::new();
    for item in items {
        let text = item
            .scalar_value()
            .ok_or_else(|| invalid(format!("{field} must contain only nonempty strings.")))?;
        values.push(text.to_string());
    }
    Ok(Some(values))
}

fn positive_int(node: &YamlNode, field: &str) -> Result<i32, ProfileV3Error> {
    let text = node
        .scalar_value()
        .ok_or_else(|| invalid(format!("{field} must be a positive integer.")))?;
    let value: i32 = text
        .parse()
        .map_err(|_| invalid(format!("{field} must be a positive integer.")))?;
    if value < 1 {
        return Err(invalid(format!("{field} must be a positive integer.")));
    }
    Ok(value)
}

fn reject_unknown(node: &YamlNode, allowed: &[&str], scope: &str) -> Result<(), ProfileV3Error> {
    let Some(entries) = node.map_entries() else {
        return Ok(());
    };
    for (key, _) in entries {
        if !allowed.contains(&key.as_str()) {
            let message = if scope.is_empty() {
                format!("unknown key \"{key}\" is not part of schema v3.")
            } else {
                format!("{scope}.{key} is not part of schema v3 (unknown key).")
            };
            return Err(invalid(message));
        }
    }
    Ok(())
}

fn non_empty(value: &str, field: &str) -> Result<(), ProfileV3Error> {
    if value.trim().is_empty() {
        return Err(invalid(format!("{field} must be nonempty.")));
    }
    single_line(value, field)
}

fn id_text(value: &str, field: &str) -> Result<(), ProfileV3Error> {
    non_empty(value, field)
}

fn single_line(value: &str, field: &str) -> Result<(), ProfileV3Error> {
    if value.contains('\n') || value.contains('\r') {
        return Err(invalid(format!("{field} must be single-line text.")));
    }
    Ok(())
}

fn safe_id(value: &str, field: &str) -> Result<(), ProfileV3Error> {
    id_text(value, field)?;
    if value.contains('/') || value.contains('\\') || value == "." || value == ".." {
        return Err(invalid(format!(
            "{field} \"{value}\" is not a safe profile file name."
        )));
    }
    Ok(())
}

fn known_encoding(name: &str) -> bool {
    matches!(
        name.to_lowercase().as_str(),
        "utf-8"
            | "utf8"
            | "windows-1252"
            | "cp1252"
            | "iso-8859-1"
            | "latin-1"
            | "latin1"
            | "ascii"
            | "us-ascii"
    )
}

impl ProfileVariantV3 {
    pub fn key_value(&self, key: &str) -> Option<&str> {
        self.key_values
            .iter()
            .find(|(k, _)| k == key)
            .map(|(_, v)| v.as_str())
    }
}
