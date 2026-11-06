use crate::envelope::CliResult;
use raw_viewer_core::explorer::{Explorer, ExplorerError, MatchOutcome};
use serde_json::json;
use std::fs;
use std::path::Path;

pub fn inspect(project: &Path, file_rel: &str) -> CliResult {
    if !project.exists() {
        return CliResult::not_found(format!(
            "project path does not exist: {}",
            project.display().to_string().replace('\\', "/")
        ));
    }

    let explorer = match Explorer::open(project) {
        Ok(exp) => exp,
        Err(e) => return CliResult::validation(format!("failed to open project: {e}")),
    };

    let rel_path = Path::new(file_rel);
    match explorer.inspect(rel_path) {
        Ok(report) => CliResult::ok(json!(report)),
        Err(ExplorerError::AmbiguousProfile { candidate_ids }) => CliResult::ambiguous_profile(
            format!(
                "ambiguous profile: {} candidates matched",
                candidate_ids.len()
            ),
            candidate_ids,
        ),
        Err(ExplorerError::InvalidSource(msg)) if msg.contains("does not exist") => {
            CliResult::not_found(msg)
        }
        Err(e) => CliResult::validation(format!("{e}")),
    }
}

pub fn match_file(project: &Path, file_rel: &str) -> CliResult {
    if !project.exists() {
        return CliResult::not_found(format!(
            "project path does not exist: {}",
            project.display().to_string().replace('\\', "/")
        ));
    }

    let explorer = match Explorer::open(project) {
        Ok(exp) => exp,
        Err(e) => return CliResult::validation(format!("failed to open project: {e}")),
    };

    let rel_path = Path::new(file_rel);
    let trace = match explorer.match_trace(rel_path) {
        Ok(t) => t,
        Err(ExplorerError::InvalidSource(msg)) if msg.contains("does not exist") => {
            return CliResult::not_found(msg);
        }
        Err(e) => return CliResult::validation(format!("{e}")),
    };

    // If ambiguous profile -> exit 3
    if let MatchOutcome::AmbiguousProfile { ref candidate_ids } = trace.outcome {
        return CliResult::ambiguous_profile(
            format!(
                "ambiguous profile: {} candidates matched: {}",
                candidate_ids.len(),
                candidate_ids.join(", ")
            ),
            candidate_ids.clone(),
        );
    }

    CliResult::ok(json!({
        "grammar_source": trace.grammar_source,
        "tokens": trace.tokens,
        "candidates": trace.candidates,
        "outcome": trace.outcome,
    }))
}

pub fn export_file(
    project: &Path,
    file_rel: &str,
    format: &str,
    out: &str,
    dry_run: bool,
) -> CliResult {
    if !project.exists() {
        return CliResult::not_found(format!(
            "project path does not exist: {}",
            project.display().to_string().replace('\\', "/")
        ));
    }

    let explorer = match Explorer::open(project) {
        Ok(exp) => exp,
        Err(e) => return CliResult::validation(format!("failed to open project: {e}")),
    };

    let rel_path = Path::new(file_rel);
    let measurement = match explorer.load_measurement(rel_path) {
        Ok(m) => m,
        Err(ExplorerError::AmbiguousProfile { candidate_ids }) => {
            return CliResult::ambiguous_profile(
                format!(
                    "ambiguous profile: {} candidates matched",
                    candidate_ids.len()
                ),
                candidate_ids,
            );
        }
        Err(ExplorerError::InvalidSource(msg)) if msg.contains("does not exist") => {
            return CliResult::not_found(msg);
        }
        Err(e) => return CliResult::validation(format!("{e}")),
    };

    let row_count = measurement.row_count();
    let col_count = measurement.channels.len();

    if dry_run {
        return CliResult::ok(json!({
            "action": "files.export",
            "dry_run": true,
            "format": format,
            "out": out,
            "row_count": row_count,
            "column_count": col_count,
            "channels": measurement.channels.iter().map(|c| &c.name).collect::<Vec<_>>()
        }));
    }

    let content = match format.to_lowercase().as_str() {
        "json" => match serde_json::to_string_pretty(&measurement) {
            Ok(s) => s,
            Err(e) => return CliResult::validation(format!("failed to serialize JSON: {e}")),
        },
        "csv" => {
            let mut csv_out = String::new();
            // Header
            let headers: Vec<&str> = measurement
                .channels
                .iter()
                .map(|c| c.name.as_str())
                .collect();
            csv_out.push_str(&headers.join(","));
            csv_out.push('\n');

            // Data rows
            for row_idx in 0..row_count {
                let mut row_vals = Vec::new();
                for channel in &measurement.channels {
                    if let Some(Some(val)) = channel.values.get(row_idx) {
                        row_vals.push(val.to_string());
                    } else {
                        row_vals.push(String::new());
                    }
                }
                csv_out.push_str(&row_vals.join(","));
                csv_out.push('\n');
            }
            csv_out
        }
        other => {
            return CliResult::validation(format!(
                "unsupported format \"{other}\", expected csv or json"
            ));
        }
    };

    if out == "-" {
        print!("{content}");
    } else {
        let out_path = Path::new(out);
        if let Some(parent) = out_path.parent() {
            if !parent.as_os_str().is_empty() && !parent.exists() {
                let _ = fs::create_dir_all(parent);
            }
        }
        if let Err(e) = fs::write(out_path, &content) {
            return CliResult::io(format!(
                "failed to write export to {}: {}",
                out_path.display(),
                e
            ));
        }
    }

    CliResult::ok(json!({
        "action": "files.export",
        "dry_run": false,
        "format": format,
        "out": out,
        "row_count": row_count,
        "column_count": col_count,
    }))
}
