use crate::envelope::CliResult;
use raw_viewer_core::explorer::Explorer;
use raw_viewer_core::grammar::{
    default_grammar, extract, parse_single_grammar_node, FilenameGrammar,
};
use raw_viewer_core::paths;
use raw_viewer_core::yaml::parse;
use serde_json::json;
use std::fs;
use std::path::{Path, PathBuf};

fn resolve_grammar(
    global: bool,
    project: Option<&Path>,
) -> Result<(FilenameGrammar, String), CliResult> {
    if let Some(p) = project {
        if !p.exists() {
            return Err(CliResult::not_found(format!(
                "project path does not exist: {}",
                p.display().to_string().replace('\\', "/")
            )));
        }
        let explorer = Explorer::open(p).map_err(|e| {
            CliResult::validation(format!("failed to open project at {}: {}", p.display(), e))
        })?;
        let eff = explorer.effective_grammar();
        let src = match eff.source {
            raw_viewer_core::explorer::GrammarSource::Project => "project",
            raw_viewer_core::explorer::GrammarSource::Global => "global",
            raw_viewer_core::explorer::GrammarSource::Builtin => "built-in",
        };
        Ok((eff.grammar.clone(), src.to_string()))
    } else if global {
        let resolved = paths::resolve_global_paths_from_env().map_err(|e| {
            CliResult::io(format!("failed to resolve global config directory: {e}"))
        })?;
        let global_dir = Path::new(&resolved.global_config_dir);
        let grammar_file = global_dir.join("grammar.yaml");
        if grammar_file.is_file() {
            if let Ok(catalog) = raw_viewer_core::grammar::load_file(&grammar_file) {
                if let Some(first) = catalog.grammars.first() {
                    return Ok((first.clone(), "global".to_string()));
                }
            }
        }
        let cfg_path = global_dir.join("config.yaml");
        if cfg_path.exists() {
            if let Ok(text) = fs::read_to_string(&cfg_path) {
                if let Ok(root) = parse(&text, false) {
                    if let Some(node) = root.value_for_key("grammar") {
                        if let Ok(g) = parse_single_grammar_node(node) {
                            return Ok((g, "global".to_string()));
                        }
                    }
                }
            }
        }
        Ok((default_grammar(), "built-in".to_string()))
    } else {
        Ok((default_grammar(), "built-in".to_string()))
    }
}

fn indent_yaml_sequences(input: &str) -> String {
    let mut out = Vec::new();
    let lines: Vec<&str> = input.lines().collect();
    let mut i = 0;
    while i < lines.len() {
        let line = lines[i];
        let trimmed = line.trim_start();
        let indent = line.len() - trimmed.len();
        out.push(line.to_string());
        if trimmed.ends_with(':') && !trimmed.starts_with('#') {
            let parent_indent = indent;
            let mut j = i + 1;
            let mut in_indentless_seq = false;
            while j < lines.len() {
                let next_line = lines[j];
                let next_trimmed = next_line.trim_start();
                if next_trimmed.is_empty() || next_trimmed.starts_with('#') {
                    j += 1;
                    continue;
                }
                let next_indent = next_line.len() - next_trimmed.len();
                if next_indent == parent_indent && next_trimmed.starts_with("- ") {
                    in_indentless_seq = true;
                    break;
                } else {
                    break;
                }
            }
            if in_indentless_seq {
                i += 1;
                while i < lines.len() {
                    let cur_line = lines[i];
                    let cur_trimmed = cur_line.trim_start();
                    if cur_trimmed.is_empty() {
                        out.push(String::new());
                        i += 1;
                        continue;
                    }
                    if cur_trimmed.starts_with('#') {
                        out.push(cur_line.to_string());
                        i += 1;
                        continue;
                    }
                    let cur_indent = cur_line.len() - cur_trimmed.len();
                    if cur_indent < parent_indent
                        || (cur_indent == parent_indent && !cur_trimmed.starts_with("- "))
                    {
                        break;
                    } else {
                        out.push(format!("  {cur_line}"));
                        i += 1;
                    }
                }
                continue;
            }
        }
        i += 1;
    }
    let mut result = out.join("\n");
    if input.ends_with('\n') {
        result.push('\n');
    }
    result
}

pub fn show(global: bool, project: Option<&Path>) -> CliResult {
    let (grammar, source) = match resolve_grammar(global, project) {
        Ok(res) => res,
        Err(e) => return e,
    };

    CliResult::ok(json!({
        "source": source,
        "id": grammar.id,
        "name": grammar.name,
        "template": grammar.template,
        "fields": grammar.fields,
    }))
}

pub fn set(global: bool, project: Option<&Path>, file: &Path, dry_run: bool) -> CliResult {
    if !file.exists() {
        return CliResult::not_found(format!(
            "grammar file does not exist: {}",
            file.display().to_string().replace('\\', "/")
        ));
    }

    let text = match fs::read_to_string(file) {
        Ok(t) => t,
        Err(e) => return CliResult::io(format!("failed to read grammar file: {e}")),
    };

    let node = match parse(&text, false) {
        Ok(n) => n,
        Err(e) => return CliResult::validation(format!("malformed YAML in grammar file: {e}")),
    };

    let grammar_node = if let Some(g) = node.value_for_key("grammar") {
        g
    } else {
        &node
    };

    let parsed_grammar = match parse_single_grammar_node(grammar_node) {
        Ok(g) => g,
        Err(e) => return CliResult::validation(format!("invalid grammar structure: {e}")),
    };

    let target_path: PathBuf = if let Some(p) = project {
        if !p.exists() {
            return CliResult::not_found(format!(
                "project path does not exist: {}",
                p.display().to_string().replace('\\', "/")
            ));
        }
        p.join(".raw-viewer").join("config.yaml")
    } else if global {
        let resolved = match paths::resolve_global_paths_from_env() {
            Ok(r) => r,
            Err(e) => return CliResult::io(format!("failed to resolve global paths: {e}")),
        };
        Path::new(&resolved.global_config_dir).join("config.yaml")
    } else {
        return CliResult::validation("must specify either --global or --project <PATH>");
    };

    if dry_run {
        return CliResult::ok(json!({
            "action": "grammar.set",
            "dry_run": true,
            "target_path": target_path.display().to_string().replace('\\', "/"),
            "grammar": parsed_grammar,
        }));
    }

    let parent = match target_path.parent() {
        Some(p) => p,
        None => return CliResult::io("target path has no parent directory".to_string()),
    };
    if !parent.exists() {
        if let Err(e) = fs::create_dir_all(parent) {
            return CliResult::io(format!("failed to create directory: {e}"));
        }
    }

    let mut config_val: serde_yaml::Value = if target_path.exists() {
        let existing = match fs::read_to_string(&target_path) {
            Ok(t) => t,
            Err(e) => return CliResult::io(format!("failed to read config file: {e}")),
        };
        match serde_yaml::from_str(&existing) {
            Ok(v) => v,
            Err(e) => return CliResult::validation(format!("malformed YAML in config file: {e}")),
        }
    } else {
        serde_yaml::Value::Mapping(serde_yaml::Mapping::new())
    };

    let mapping = match config_val.as_mapping_mut() {
        Some(m) => m,
        None => return CliResult::validation("config root must be a YAML mapping".to_string()),
    };

    if !mapping.contains_key("schema_version") {
        mapping.insert(
            serde_yaml::Value::String("schema_version".to_string()),
            serde_yaml::Value::Number(1.into()),
        );
    }
    if !mapping.contains_key("data_root") {
        mapping.insert(
            serde_yaml::Value::String("data_root".to_string()),
            serde_yaml::Value::String("data/raw".to_string()),
        );
    }

    let grammar_yaml_val = match serde_yaml::to_value(&parsed_grammar) {
        Ok(v) => v,
        Err(e) => return CliResult::validation(format!("failed to serialize grammar: {e}")),
    };
    mapping.insert(
        serde_yaml::Value::String("grammar".to_string()),
        grammar_yaml_val,
    );

    let output_yaml = match serde_yaml::to_string(&config_val) {
        Ok(s) => indent_yaml_sequences(&s),
        Err(e) => return CliResult::io(format!("failed to serialize config: {e}")),
    };

    let tmp_path = target_path.with_extension(format!("tmp.{}", std::process::id()));
    if let Err(e) = fs::write(&tmp_path, &output_yaml) {
        return CliResult::io(format!("failed to write config staging file: {e}"));
    }
    if let Err(e) = fs::rename(&tmp_path, &target_path) {
        let _ = fs::remove_file(&tmp_path);
        return CliResult::io(format!("failed to commit config: {e}"));
    }

    // Clean up any legacy loose grammar.yaml in the same directory
    if let Some(parent) = target_path.parent() {
        let old_grammar = parent.join("grammar.yaml");
        if old_grammar.is_file() {
            let _ = fs::remove_file(old_grammar);
        }
    }

    CliResult::ok(json!({
        "action": "grammar.set",
        "dry_run": false,
        "target_path": target_path.display().to_string().replace('\\', "/"),
        "id": parsed_grammar.id,
    }))
}

pub fn test(global: bool, project: Option<&Path>, filenames: &[String]) -> CliResult {
    let (grammar, source) = match resolve_grammar(global, project) {
        Ok(res) => res,
        Err(e) => return e,
    };

    let mut results = Vec::new();
    let mut all_matched = true;

    for name in filenames {
        let facts = extract(name, &grammar);
        if !facts.is_matched {
            all_matched = false;
        }
        results.push(json!({
            "filename": name,
            "matched": facts.is_matched,
            "tokens": facts.extracted_fields,
            "unmatched_reason": facts.unmatched_reason,
        }));
    }

    let data = json!({
        "grammar_source": source,
        "grammar_id": grammar.id,
        "grammar_template": grammar.template,
        "all_matched": all_matched,
        "results": results,
    });

    if all_matched {
        CliResult::ok(data)
    } else {
        CliResult {
            exit_code: crate::envelope::EXIT_VALIDATION,
            output: Err((
                "grammar_test_failed".to_string(),
                "one or more filenames failed to match grammar".to_string(),
                data,
            )),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_yaml_formatting_and_parsing() {
        let grammar_text = r#"
grammar:
  id: custom-lab-grammar
  name: Custom Lab Grammar
  template: "{sample}_{run}"
  fields:
    - name: sample
      type: string
    - name: run
      type: string
"#;
        let root = parse(grammar_text, false).unwrap();
        let parsed_grammar =
            parse_single_grammar_node(root.value_for_key("grammar").unwrap()).unwrap();

        let mut config_val = serde_yaml::Value::Mapping(serde_yaml::Mapping::new());
        let mapping = config_val.as_mapping_mut().unwrap();
        mapping.insert(
            serde_yaml::Value::String("schema_version".to_string()),
            serde_yaml::Value::Number(1.into()),
        );
        mapping.insert(
            serde_yaml::Value::String("data_root".to_string()),
            serde_yaml::Value::String("data/raw".to_string()),
        );
        let g_val = serde_yaml::to_value(&parsed_grammar).unwrap();
        mapping.insert(serde_yaml::Value::String("grammar".to_string()), g_val);

        let raw_yaml = serde_yaml::to_string(&config_val).unwrap();
        println!("RAW YAML:\n{}", raw_yaml);
        let indented = indent_yaml_sequences(&raw_yaml);
        println!("INDENTED YAML:\n{}", indented);
        let parsed_back = parse(&indented, false);
        println!("PARSED BACK: {:?}", parsed_back);
        assert!(parsed_back.is_ok());
    }
}
