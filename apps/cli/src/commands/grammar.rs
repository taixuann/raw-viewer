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
        let dummy = Path::new("/dummy");
        let resolved = paths::resolve_paths_from_env(dummy).map_err(|e| {
            CliResult::io(format!("failed to resolve global config directory: {e}"))
        })?;
        let cfg_path = Path::new(&resolved.global_config_dir).join("config.yaml");
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
        p.join(".raw-viewer").join("grammar.yaml")
    } else if global {
        let dummy = Path::new("/dummy");
        let resolved = match paths::resolve_paths_from_env(dummy) {
            Ok(r) => r,
            Err(e) => return CliResult::io(format!("failed to resolve global paths: {e}")),
        };
        Path::new(&resolved.global_config_dir).join("grammar.yaml")
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

    if let Some(parent) = target_path.parent() {
        if !parent.exists() {
            if let Err(e) = fs::create_dir_all(parent) {
                return CliResult::io(format!("failed to create directory: {e}"));
            }
        }
    }

    if let Err(e) = fs::write(&target_path, &text) {
        return CliResult::io(format!("failed to write grammar: {e}"));
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
