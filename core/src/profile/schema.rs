use super::types::{
    humanized, unique_sorted, BrokenModeSelectors, InstrumentProfile, ProfileCatalog,
    ProfileColumn, ProfileFormat, ProfileLoadOutcome, ProfileMode,
};
use crate::yaml::{parse, YamlNode};

struct Selectors {
    extensions: Vec<String>,
    mode_selectors: Vec<BrokenModeSelectors>,
}

pub fn load_document(text: &str, relative_path: &str, sha256: &str) -> ProfileLoadOutcome {
    let root = match parse(text, false) {
        Ok(node) => node,
        Err(err) => {
            return empty_outcome(vec![format!("{relative_path}: YAML parse error {err}")]);
        }
    };
    if root.map_entries().is_none() {
        return empty_outcome(vec![format!(
            "{relative_path}: the profile document must be a mapping."
        )]);
    }
    let declared_version = root
        .value_for_key("schema_version")
        .and_then(|n| n.scalar_value())
        .and_then(|s| s.parse::<i32>().ok());
    let selectors = lenient_selectors(&root, declared_version == Some(2));
    if root.value_for_key("raw_viewer").is_some() {
        return ProfileLoadOutcome {
            profile: None,
            issues: vec![format!(
                "{relative_path}: raw_viewer profile blocks are not supported; move the versioned profile to a standalone top-level document (companion profiles live in data/instruments/rawview/) (see CONTRACT.md)."
            )],
            extensions: selectors.extensions,
            mode_selectors: selectors.mode_selectors,
        };
    }
    let version_text = match root
        .value_for_key("schema_version")
        .and_then(|n| n.scalar_value())
    {
        Some(v) => v,
        None => {
            return broken(
                &selectors,
                vec![format!(
                    "{relative_path}: profile is unversioned. Add \"schema_version: 1\" and migrate this profile to schema version 1 (see CONTRACT.md). RawView does not rewrite profiles."
                )],
            );
        }
    };
    let version: i32 = match version_text.parse() {
        Ok(v) => v,
        Err(_) => {
            return broken(
                &selectors,
                vec![format!(
                    "{relative_path}: schema_version must be an integer; found \"{version_text}\"."
                )],
            );
        }
    };
    if !ProfileCatalog::SUPPORTED_SCHEMA_VERSIONS.contains(&version) {
        if version == 3 {
            return ProfileLoadOutcome {
                profile: None,
                issues: vec![format!(
                    "{relative_path}: schema_version 3 is not supported in the Rust core yet."
                )],
                extensions: selectors.extensions,
                mode_selectors: selectors.mode_selectors,
            };
        }
        return broken(
            &selectors,
            vec![format!(
                "{relative_path}: unsupported schema_version {version}; this viewer supports schema_version 1, 2, and 3."
            )],
        );
    }
    validate(&root, relative_path, sha256, &selectors, version)
}

fn empty_outcome(issues: Vec<String>) -> ProfileLoadOutcome {
    ProfileLoadOutcome {
        profile: None,
        issues,
        extensions: vec![],
        mode_selectors: vec![],
    }
}

fn broken(selectors: &Selectors, issues: Vec<String>) -> ProfileLoadOutcome {
    ProfileLoadOutcome {
        profile: None,
        issues,
        extensions: selectors.extensions.clone(),
        mode_selectors: selectors.mode_selectors.clone(),
    }
}

fn lenient_selectors(root: &YamlNode, filename_trusted: bool) -> Selectors {
    let mut extensions = Vec::new();
    if let Some(format_nodes) = root.value_for_key("formats").and_then(|n| n.list_items()) {
        for node in format_nodes {
            if let Some(ext_nodes) = node
                .value_for_key("extensions")
                .and_then(|n| n.list_items())
            {
                for item in ext_nodes {
                    if let Some(value) = item.scalar_value() {
                        let lower = value.to_lowercase();
                        if lower.starts_with('.') {
                            extensions.push(lower);
                        }
                    }
                }
            }
        }
    }
    let mut mode_selectors = Vec::new();
    if let Some(mode_nodes) = root.value_for_key("modes").and_then(|n| n.list_items()) {
        for mode in mode_nodes {
            let sigs = trustworthy_signatures(mode.value_for_key("detect"));
            let filenames = if filename_trusted {
                filename_token_list(mode.value_for_key("filename_contains_all"))
            } else {
                None
            };
            mode_selectors.push(BrokenModeSelectors {
                filenames,
                signatures: sigs,
            });
        }
    }
    if let Some(mode_nodes) = root
        .value_for_key("application_modes")
        .and_then(|n| n.list_items())
    {
        for mode in mode_nodes {
            let sigs = trustworthy_signatures(
                mode.value_for_key("detect")
                    .and_then(|d| d.value_for_key("signatures")),
            );
            mode_selectors.push(BrokenModeSelectors {
                filenames: None,
                signatures: sigs,
            });
        }
    }
    Selectors {
        extensions: unique_sorted(extensions),
        mode_selectors,
    }
}

fn trustworthy_signatures(node: Option<&YamlNode>) -> Vec<String> {
    let Some(items) = node.and_then(|n| n.list_items()) else {
        return vec![];
    };
    let mut kept = Vec::new();
    for item in items {
        let YamlNode::Scalar(text) = item else {
            return vec![];
        };
        if !text.is_empty() {
            kept.push(text.clone());
        }
    }
    kept
}

fn filename_token_list(node: Option<&YamlNode>) -> Option<Vec<String>> {
    let items = node.and_then(|n| n.list_items())?;
    if items.is_empty() {
        return None;
    }
    let mut tokens = Vec::new();
    for item in items {
        let YamlNode::Scalar(text) = item else {
            return None;
        };
        if text.is_empty() {
            return None;
        }
        tokens.push(text.clone());
    }
    Some(tokens)
}

fn validate(
    root: &YamlNode,
    relative_path: &str,
    sha256: &str,
    selectors: &Selectors,
    version: i32,
) -> ProfileLoadOutcome {
    let extensions = selectors.extensions.clone();
    let mut errors: Vec<String> = Vec::new();
    let mut fail = |message: String| errors.push(format!("{relative_path}: {message}"));

    if root.value_for_key("transforms").is_some() {
        fail(format!(
            "transforms are not part of schema v{version}; remove the transforms field or migrate the profile (see CONTRACT.md)."
        ));
    }
    reject_unknown(
        root,
        &["schema_version", "instrument", "formats", "modes"],
        "",
        &mut fail,
        version,
    );

    let instrument_node = root.value_for_key("instrument");
    if instrument_node.is_none() || instrument_node.and_then(|n| n.map_entries()).is_none() {
        fail("instrument mapping is required.".into());
        return ProfileLoadOutcome {
            profile: None,
            issues: errors,
            extensions,
            mode_selectors: selectors.mode_selectors.clone(),
        };
    }
    let instrument_node = instrument_node.unwrap();
    reject_unknown(
        instrument_node,
        &["id", "name", "vendor", "model"],
        "instrument",
        &mut fail,
        version,
    );
    let instrument_id = string(
        instrument_node.value_for_key("id"),
        "instrument.id",
        &mut fail,
    );
    let instrument_name = string(
        instrument_node.value_for_key("name"),
        "instrument.name",
        &mut fail,
    );
    let vendor = instrument_node
        .value_for_key("vendor")
        .and_then(|n| n.scalar_value())
        .map(str::to_string);
    let model = instrument_node
        .value_for_key("model")
        .and_then(|n| n.scalar_value())
        .map(str::to_string);

    let mut formats = Vec::new();
    let mut format_ids = std::collections::HashSet::new();
    let format_nodes = root
        .value_for_key("formats")
        .and_then(|n| n.list_items())
        .unwrap_or(&[]);
    if format_nodes.is_empty() {
        fail("formats must contain at least one format.".into());
    }
    for (index, node) in format_nodes.iter().enumerate() {
        let field = format!("formats[{index}]");
        if node.map_entries().is_none() {
            fail(format!("{field} must be a mapping."));
            continue;
        }
        let Some(id) = string(node.value_for_key("id"), &format!("{field}.id"), &mut fail) else {
            continue;
        };
        if !format_ids.insert(id.clone()) {
            fail(format!("{field}.id \"{id}\" is duplicated."));
        }
        if node.value_for_key("transforms").is_some() {
            fail(format!(
                "{field}.transforms are not part of schema v{version}; remove the field (see CONTRACT.md)."
            ));
        }
        let supported_kinds: &[&str] = if version >= 2 {
            &["tabular", "comment-tsv", "first-row-header"]
        } else {
            &["tabular"]
        };
        let kind = match node.value_for_key("kind").and_then(|n| n.scalar_value()) {
            Some(k) if supported_kinds.contains(&k) => k.to_string(),
            Some(k) => {
                fail(format!(
                    "{field}.kind \"{k}\" is not supported; this viewer supports {}.",
                    supported_kinds
                        .iter()
                        .map(|s| format!("\"{s}\""))
                        .collect::<Vec<_>>()
                        .join(", ")
                ));
                continue;
            }
            None => {
                fail(format!(
                    "{field}.kind is required and must be {}.",
                    supported_kinds
                        .iter()
                        .map(|s| format!("\"{s}\""))
                        .collect::<Vec<_>>()
                        .join(", ")
                ));
                continue;
            }
        };
        let allowed_keys: Vec<&str> = if kind == "tabular" {
            vec![
                "id",
                "kind",
                "extensions",
                "delimiter",
                "encoding",
                "rows",
                "columns",
                "decimal",
            ]
        } else {
            vec![
                "id",
                "kind",
                "extensions",
                "delimiter",
                "encoding",
                "columns",
                "decimal",
            ]
        };
        reject_unknown(node, &allowed_keys, &field, &mut fail, version);
        let extension_values = match string_list(
            node.value_for_key("extensions"),
            &format!("{field}.extensions"),
            &mut fail,
        ) {
            Some(v) => v,
            None => {
                if node.value_for_key("extensions").is_none() {
                    fail(format!(
                        "{field}.extensions must list at least one file extension such as \".csv\"."
                    ));
                }
                continue;
            }
        };
        if extension_values.is_empty() {
            fail(format!(
                "{field}.extensions must list at least one file extension such as \".csv\"."
            ));
        }
        for value in &extension_values {
            if !value.starts_with('.') {
                fail(format!(
                    "{field}.extensions entry \"{value}\" must start with \".\"."
                ));
            }
        }
        let delimiter_text = match string(
            node.value_for_key("delimiter"),
            &format!("{field}.delimiter"),
            &mut fail,
        ) {
            Some(d) if d.chars().count() == 1 => d,
            Some(_) => {
                fail(format!("{field}.delimiter must be a single character."));
                continue;
            }
            None => continue,
        };
        let delimiter = delimiter_text.chars().next().unwrap();
        let mut decimal_separator = '.';
        if let Some(decimal_node) = node.value_for_key("decimal") {
            if version < 2 {
                fail(format!(
                    "{field}.decimal is not part of schema v1 (no decimal mechanism; see CONTRACT.md)."
                ));
                continue;
            }
            match decimal_node.scalar_value() {
                Some(text) if text.len() == 1 && (text == "." || text == ",") => {
                    decimal_separator = text.chars().next().unwrap();
                }
                _ => {
                    fail(format!("{field}.decimal must be \".\" or \",\"."));
                    continue;
                }
            }
        }
        if delimiter == ',' && decimal_separator == ',' {
            fail(format!(
                "{field}.decimal \",\" conflicts with delimiter \",\"; European decimals require a non-comma delimiter."
            ));
            continue;
        }
        let encoding_names = if let Some(encoding_node) = node.value_for_key("encoding") {
            match string_list(Some(encoding_node), &format!("{field}.encoding"), &mut fail) {
                Some(v) => v,
                None => continue,
            }
        } else {
            vec!["utf-8".to_string()]
        };
        for name in &encoding_names {
            if encoding_named(name).is_none() {
                fail(format!(
                    "{field}.encoding entry \"{name}\" is not supported; use utf-8, windows-1252, iso-8859-1, or ascii."
                ));
            }
        }
        let (names_prefix, data_prefix) = if kind == "comment-tsv" || kind == "first-row-header" {
            if node.value_for_key("rows").is_some() {
                let reason = if kind == "comment-tsv" {
                    "headerless positional layout"
                } else {
                    "first row is the header by definition"
                };
                fail(format!(
                    "{field}.rows is not part of kind \"{kind}\" ({reason}); remove the rows mapping."
                ));
                continue;
            }
            (None, None)
        } else {
            let Some(rows) = node.value_for_key("rows") else {
                fail(format!("{field}.rows mapping is required."));
                continue;
            };
            if rows.map_entries().is_none() {
                fail(format!("{field}.rows mapping is required."));
                continue;
            }
            reject_unknown(
                rows,
                &["names_prefix", "data_prefix"],
                &format!("{field}.rows"),
                &mut fail,
                version,
            );
            let names_prefix = string(
                rows.value_for_key("names_prefix"),
                &format!("{field}.rows.names_prefix"),
                &mut fail,
            );
            let data_prefix = if version >= 2 {
                match rows.value_for_key("data_prefix") {
                    Some(YamlNode::Scalar(text)) => Some(text.clone()),
                    Some(_) => {
                        fail(format!("{field}.rows.data_prefix must be a string."));
                        continue;
                    }
                    None => {
                        fail(format!("{field}.rows.data_prefix is required."));
                        continue;
                    }
                }
            } else {
                string(
                    rows.value_for_key("data_prefix"),
                    &format!("{field}.rows.data_prefix"),
                    &mut fail,
                )
            };
            (names_prefix, data_prefix)
        };
        let mut columns = Vec::new();
        let mut column_keys = std::collections::HashSet::new();
        let mut index_owners: std::collections::HashMap<usize, String> =
            std::collections::HashMap::new();
        let column_entries = node
            .value_for_key("columns")
            .and_then(|n| n.map_entries())
            .unwrap_or(&[]);
        if column_entries.is_empty() {
            fail(format!("{field}.columns must declare at least one column."));
        }
        for (key, entry) in column_entries {
            let column_field = format!("{field}.columns.{key}");
            if entry.map_entries().is_none() {
                fail(format!("{column_field} must be a mapping."));
                continue;
            }
            if kind == "comment-tsv" {
                reject_unknown(
                    entry,
                    &["column_index", "quantity", "unit", "label"],
                    &column_field,
                    &mut fail,
                    version,
                );
                if !column_keys.insert(key.clone()) {
                    fail(format!("{column_field} is duplicated."));
                }
                let index_text = entry
                    .value_for_key("column_index")
                    .and_then(|n| n.scalar_value());
                let column_index: usize = match index_text.and_then(|t| t.parse().ok()) {
                    Some(i) => i,
                    None => {
                        fail(format!(
                            "{column_field}.column_index must be a non-negative integer."
                        ));
                        continue;
                    }
                };
                if let Some(owner) = index_owners.insert(column_index, key.clone()) {
                    fail(format!(
                        "{field}.columns.{owner} and {column_field} resolve to the same source column {}.",
                        column_index + 1
                    ));
                    continue;
                }
                let quantity = match string(
                    entry.value_for_key("quantity"),
                    &format!("{column_field}.quantity"),
                    &mut fail,
                ) {
                    Some(q) => q,
                    None => continue,
                };
                let unit = match string(
                    entry.value_for_key("unit"),
                    &format!("{column_field}.unit"),
                    &mut fail,
                ) {
                    Some(u) => u,
                    None => continue,
                };
                let label = entry
                    .value_for_key("label")
                    .and_then(|n| n.scalar_value())
                    .map(str::to_string)
                    .unwrap_or_else(|| humanized(key));
                columns.push(ProfileColumn {
                    key: key.clone(),
                    header: None,
                    aliases: vec![],
                    quantity,
                    unit,
                    label,
                    index: Some(column_index),
                    required: true,
                });
                continue;
            }
            let mut column_allowed = vec!["header", "aliases", "quantity", "unit", "label"];
            if version >= 2 {
                column_allowed.push("required");
            }
            reject_unknown(entry, &column_allowed, &column_field, &mut fail, version);
            if !column_keys.insert(key.clone()) {
                fail(format!("{column_field} is duplicated."));
            }
            let header = match string(
                entry.value_for_key("header"),
                &format!("{column_field}.header"),
                &mut fail,
            ) {
                Some(h) => h,
                None => continue,
            };
            let quantity = match string(
                entry.value_for_key("quantity"),
                &format!("{column_field}.quantity"),
                &mut fail,
            ) {
                Some(q) => q,
                None => continue,
            };
            let unit = match string(
                entry.value_for_key("unit"),
                &format!("{column_field}.unit"),
                &mut fail,
            ) {
                Some(u) => u,
                None => continue,
            };
            let label = entry
                .value_for_key("label")
                .and_then(|n| n.scalar_value())
                .map(str::to_string)
                .unwrap_or_else(|| humanized(key));
            let aliases = if let Some(aliases_node) = entry.value_for_key("aliases") {
                match string_list(
                    Some(aliases_node),
                    &format!("{column_field}.aliases"),
                    &mut fail,
                ) {
                    Some(a) => a,
                    None => continue,
                }
            } else {
                vec![]
            };
            let mut is_required = true;
            if version >= 2 {
                if let Some(required_node) = entry.value_for_key("required") {
                    match required_node.scalar_value() {
                        Some("true") => is_required = true,
                        Some("false") => is_required = false,
                        _ => {
                            fail(format!(
                                "{column_field}.required must be \"true\" or \"false\"."
                            ));
                            continue;
                        }
                    }
                }
            }
            columns.push(ProfileColumn {
                key: key.clone(),
                header: Some(header),
                aliases,
                quantity,
                unit,
                label,
                index: None,
                required: is_required,
            });
        }
        if kind == "tabular" && (names_prefix.is_none() || data_prefix.is_none()) {
            continue;
        }
        formats.push(ProfileFormat {
            id,
            kind,
            extensions: extension_values.iter().map(|e| e.to_lowercase()).collect(),
            delimiter,
            encoding_names,
            decimal_separator,
            names_prefix,
            data_prefix,
            columns,
        });
    }

    let mut modes = Vec::new();
    let mut mode_ids = std::collections::HashSet::new();
    let mode_nodes = root
        .value_for_key("modes")
        .and_then(|n| n.list_items())
        .unwrap_or(&[]);
    if mode_nodes.is_empty() {
        fail("modes must contain at least one application mode.".into());
    }
    for (index, node) in mode_nodes.iter().enumerate() {
        let field = format!("modes[{index}]");
        if node.map_entries().is_none() {
            fail(format!("{field} must be a mapping."));
            continue;
        }
        let Some(id) = string(node.value_for_key("id"), &format!("{field}.id"), &mut fail) else {
            continue;
        };
        if !mode_ids.insert(id.clone()) {
            fail(format!("{field}.id \"{id}\" is duplicated."));
        }
        let Some(format_id) = string(
            node.value_for_key("format"),
            &format!("{field}.format"),
            &mut fail,
        ) else {
            continue;
        };
        let format = formats.iter().find(|f| f.id == format_id);
        if format.is_none() {
            fail(format!(
                "{field}.format \"{format_id}\" does not match any format id."
            ));
        }
        if node.value_for_key("transforms").is_some() {
            fail(format!(
                "{field}.transforms are not part of schema v{version}; remove the field (see CONTRACT.md)."
            ));
        }
        let mut mode_allowed = vec!["id", "format", "detect", "extract"];
        if version >= 2 {
            mode_allowed.push("filename_contains_all");
        }
        reject_unknown(node, &mode_allowed, &field, &mut fail, version);
        let detect = if let Some(detect_node) = node.value_for_key("detect") {
            match string_list(Some(detect_node), &format!("{field}.detect"), &mut fail) {
                Some(mut parsed) => {
                    parsed.retain(|s| !s.is_empty());
                    parsed
                }
                None => continue,
            }
        } else {
            vec![]
        };
        if detect.is_empty() {
            fail(format!(
                "{field}.detect must list at least one header signature string."
            ));
        }
        let filename_tokens = if version >= 2 {
            if let Some(filename_node) = node.value_for_key("filename_contains_all") {
                match filename_token_list(Some(filename_node)) {
                    Some(tokens) => Some(tokens),
                    None => {
                        fail(format!(
                            "{field}.filename_contains_all must be a non-empty list of non-empty strings."
                        ));
                        continue;
                    }
                }
            } else {
                None
            }
        } else {
            None
        };
        let Some(extract) = node.value_for_key("extract") else {
            fail(format!("{field}.extract mapping with x and y is required."));
            continue;
        };
        let Some(extract_entries) = extract.map_entries() else {
            fail(format!("{field}.extract mapping with x and y is required."));
            continue;
        };
        for (key, _) in extract_entries {
            if key != "x" && key != "y" {
                fail(format!(
                    "{field}.extract.{key} is not part of schema v{version}; only x and y are supported (see CONTRACT.md)."
                ));
            }
        }
        let Some(x) = string(
            extract.value_for_key("x"),
            &format!("{field}.extract.x"),
            &mut fail,
        ) else {
            continue;
        };
        let y = if let Some(y_node) = extract.value_for_key("y") {
            match string_list(Some(y_node), &format!("{field}.extract.y"), &mut fail) {
                Some(parsed) => parsed,
                None => continue,
            }
        } else {
            vec![]
        };
        if y.is_empty() {
            fail(format!("{field}.extract.y must name at least one column."));
        }
        if y.len() != y.iter().collect::<std::collections::HashSet<_>>().len() {
            fail(format!("{field}.extract.y contains duplicated columns."));
        }
        if let Some(format) = format {
            if format.column(&x).is_none() {
                fail(format!(
                    "{field}.extract.x \"{x}\" is not a column of format \"{}\".",
                    format.id
                ));
            }
            for key in &y {
                if format.column(key).is_none() {
                    fail(format!(
                        "{field}.extract.y \"{key}\" is not a column of format \"{}\".",
                        format.id
                    ));
                }
            }
            if let Some(x_column) = format.column(&x) {
                if !x_column.required {
                    fail(format!(
                        "{field}.extract.x \"{x}\" is an optional column; plot axes must reference required columns."
                    ));
                }
            }
            for key in &y {
                if let Some(y_column) = format.column(key) {
                    if !y_column.required {
                        fail(format!(
                            "{field}.extract.y \"{key}\" is an optional column; plot axes must reference required columns."
                        ));
                    }
                }
            }
        }
        if y.contains(&x) {
            fail(format!(
                "{field}.extract.x \"{x}\" must not also appear in extract.y."
            ));
        }
        modes.push(ProfileMode {
            id,
            format_id,
            detect,
            filename_contains_all: filename_tokens,
            x,
            y,
        });
    }

    if !errors.is_empty() || instrument_id.is_none() || instrument_name.is_none() {
        let issues = if errors.is_empty() {
            vec![format!("{relative_path}: profile is incomplete.")]
        } else {
            errors
        };
        return ProfileLoadOutcome {
            profile: None,
            issues,
            extensions,
            mode_selectors: selectors.mode_selectors.clone(),
        };
    }

    ProfileLoadOutcome {
        profile: Some(InstrumentProfile {
            instrument_id: instrument_id.unwrap(),
            instrument_name: instrument_name.unwrap(),
            vendor,
            model,
            formats,
            modes,
            relative_path: relative_path.to_string(),
            sha256: sha256.to_string(),
            schema_version: version,
        }),
        issues: vec![],
        extensions,
        mode_selectors: vec![],
    }
}

fn reject_unknown(
    node: &YamlNode,
    allowed: &[&str],
    scope: &str,
    fail: &mut impl FnMut(String),
    version: i32,
) {
    let Some(entries) = node.map_entries() else {
        return;
    };
    let allowed_set: std::collections::HashSet<_> = allowed.iter().copied().collect();
    for (key, _) in entries {
        if !allowed_set.contains(key.as_str()) {
            if scope.is_empty() {
                fail(format!(
                    "unknown key \"{key}\" is not part of schema v{version}."
                ));
            } else {
                fail(format!(
                    "{scope}.{key} is not part of schema v{version} (unknown key)."
                ));
            }
        }
    }
}

fn string(node: Option<&YamlNode>, field: &str, fail: &mut impl FnMut(String)) -> Option<String> {
    match node.and_then(|n| n.scalar_value()) {
        Some(value) => Some(value.to_string()),
        None => {
            fail(format!("{field} is required."));
            None
        }
    }
}

fn string_list(
    node: Option<&YamlNode>,
    field: &str,
    fail: &mut impl FnMut(String),
) -> Option<Vec<String>> {
    let node = node?;
    let items = match node.list_items() {
        Some(items) => items,
        None => {
            fail(format!("{field} must be a list."));
            return None;
        }
    };
    let mut result = Vec::new();
    for item in items {
        match item.scalar_value() {
            Some(value) => result.push(value.to_string()),
            None => {
                fail(format!(
                    "{field} must contain only strings; found a non-scalar entry."
                ));
                return None;
            }
        }
    }
    Some(result)
}

pub fn encoding_named(name: &str) -> Option<&'static str> {
    match name.to_lowercase().as_str() {
        "utf-8" | "utf8" => Some("utf-8"),
        "windows-1252" | "cp1252" => Some("windows-1252"),
        "iso-8859-1" | "latin-1" | "latin1" => Some("iso-8859-1"),
        "ascii" | "us-ascii" => Some("ascii"),
        _ => None,
    }
}
