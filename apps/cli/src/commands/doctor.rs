use crate::envelope::CliResult;
use raw_viewer_core::paths::{self, PROJECT_CONFIG_DIRECTORY_NAME};
use serde_json::json;
use std::env;
use std::path::{Path, PathBuf};

fn find_project_root() -> Option<PathBuf> {
    let mut current = env::current_dir().ok()?;
    loop {
        if current.join(PROJECT_CONFIG_DIRECTORY_NAME).is_dir()
            || current.join(".rawviewer").is_dir()
            || current.join(".view").is_dir()
        {
            return Some(current);
        }
        if !current.pop() {
            break;
        }
    }
    None
}

pub fn run() -> CliResult {
    let resolved = paths::resolve_global_paths_from_env().ok();

    let global_config_path = resolved
        .as_ref()
        .map(|r| {
            Path::new(&r.global_config_dir)
                .join("config.yaml")
                .display()
                .to_string()
        })
        .unwrap_or_default();

    let global_cache_path = resolved
        .as_ref()
        .map(|r| r.cache_dir.clone())
        .unwrap_or_default();

    let project_root = find_project_root();
    let project_path_str = project_root
        .as_ref()
        .map(|p| p.display().to_string().replace('\\', "/"));

    let (grammar_source, enabled_profiles, disabled_profiles) = if let Some(ref root) = project_root
    {
        if let Ok(explorer) = raw_viewer_core::explorer::Explorer::open(root) {
            let sum = explorer.summary();
            let src = match sum.grammar_source {
                raw_viewer_core::explorer::GrammarSource::Project => "project",
                raw_viewer_core::explorer::GrammarSource::Global => "global",
                raw_viewer_core::explorer::GrammarSource::Builtin => "built-in",
            };
            (src, sum.enabled_profiles, sum.disabled_profiles)
        } else {
            ("built-in", Vec::new(), Vec::new())
        }
    } else {
        let catalog = raw_viewer_core::profile::builtin_catalog();
        let enabled = catalog.profiles.into_iter().map(|p| p.profile_id).collect();
        ("built-in", enabled, Vec::new())
    };

    let home = env::var("HOME")
        .or_else(|_| env::var("USERPROFILE"))
        .unwrap_or_default();
    let home_path = Path::new(&home);

    let skill_names = ["rawview-setup-grammar", "rawview-setup-profile"];
    let mut skill_links = Vec::new();

    for name in &skill_names {
        let agent_skill = home_path.join(".agents").join("skills").join(name);
        let status = if agent_skill.is_symlink() {
            if agent_skill.exists() {
                "linked"
            } else {
                "dangling"
            }
        } else if agent_skill.is_dir() {
            "real_directory"
        } else {
            "missing"
        };
        skill_links.push(json!({
            "name": name,
            "path": agent_skill.display().to_string().replace('\\', "/"),
            "status": status,
        }));
    }

    CliResult::ok(json!({
        "version": env!("CARGO_PKG_VERSION"),
        "global_config_path": global_config_path.replace('\\', "/"),
        "global_cache_path": global_cache_path.replace('\\', "/"),
        "project_path": project_path_str,
        "grammar_source": grammar_source,
        "enabled_profiles": enabled_profiles,
        "disabled_profiles": disabled_profiles,
        "skill_links": skill_links,
        "auth": "not_required"
    }))
}
