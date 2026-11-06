use crate::envelope::CliResult;
use raw_viewer_core::explorer::Explorer;
use serde_json::json;
use std::path::Path;

pub fn resolve(path: &Path) -> CliResult {
    if !path.exists() {
        return CliResult::not_found(format!(
            "path does not exist: {}",
            path.display().to_string().replace('\\', "/")
        ));
    }

    match Explorer::open(path) {
        Ok(explorer) => {
            let summary = explorer.summary();
            let grammar_source = match summary.grammar_source {
                raw_viewer_core::explorer::GrammarSource::Project => "project",
                raw_viewer_core::explorer::GrammarSource::Global => "global",
                raw_viewer_core::explorer::GrammarSource::Builtin => "built-in",
            };
            CliResult::ok(json!({
                "root": summary.root.replace('\\', "/"),
                "data_root": summary.data_root.replace('\\', "/"),
                "grammar_source": grammar_source,
                "grammar_id": summary.grammar_id,
                "total_profiles": summary.total_profiles,
                "enabled_profiles": summary.enabled_profiles,
                "disabled_profiles": summary.disabled_profiles,
            }))
        }
        Err(e) => CliResult::validation(format!(
            "failed to open project at {}: {}",
            path.display(),
            e
        )),
    }
}
