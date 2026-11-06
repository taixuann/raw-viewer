use crate::envelope::CliResult;
use raw_viewer_core::explorer::Explorer;
use raw_viewer_core::profile::{
    builtin_catalog, parse_profile_v3, parse_profile_v4, BUILTIN_PROFILES,
};
use serde_json::json;
use std::fs;
use std::path::Path;

pub fn list(global: bool, project: Option<&Path>) -> CliResult {
    if let Some(p) = project {
        if !p.exists() {
            return CliResult::not_found(format!(
                "project path does not exist: {}",
                p.display().to_string().replace('\\', "/")
            ));
        }
        let explorer = match Explorer::open(p) {
            Ok(exp) => exp,
            Err(e) => return CliResult::validation(format!("failed to open project: {e}")),
        };
        let profiles = explorer.list_profiles();
        CliResult::ok(json!({
            "source": "project",
            "profiles": profiles
        }))
    } else {
        let catalog = builtin_catalog();
        let profiles: Vec<_> = catalog
            .profiles
            .into_iter()
            .map(|p| {
                json!({
                    "id": p.profile_id,
                    "instrument_id": p.instrument_id,
                    "instrument_name": p.instrument_name,
                    "enabled": true,
                    "source": "builtin",
                    "variants": p.modes.into_iter().map(|m| m.id).collect::<Vec<_>>()
                })
            })
            .collect();
        CliResult::ok(json!({
            "source": if global { "global" } else { "builtin" },
            "profiles": profiles
        }))
    }
}

pub fn enable(project: &Path, id: &str, dry_run: bool) -> CliResult {
    crate::commands::config::set(false, Some(project), "profiles.enabled", id, dry_run)
}

pub fn disable(project: &Path, id: &str, dry_run: bool) -> CliResult {
    crate::commands::config::set(false, Some(project), "profiles.disabled", id, dry_run)
}

pub fn import_profile(project: &Path, file: &Path, dry_run: bool) -> CliResult {
    if !project.exists() {
        return CliResult::not_found(format!(
            "project path does not exist: {}",
            project.display().to_string().replace('\\', "/")
        ));
    }
    if !file.exists() {
        return CliResult::not_found(format!(
            "profile file does not exist: {}",
            file.display().to_string().replace('\\', "/")
        ));
    }

    let text = match fs::read_to_string(file) {
        Ok(t) => t,
        Err(e) => return CliResult::io(format!("failed to read profile file: {e}")),
    };

    let (id, instrument_name) = if let Ok(v4) = parse_profile_v4(&text) {
        (v4.profile_id, v4.instrument_name)
    } else if let Ok(v3) = parse_profile_v3(&text) {
        (v3.profile_id, v3.instrument_name)
    } else {
        return CliResult::validation("file does not conform to profile schema v3 or v4");
    };

    let safe_id = id.replace('/', "-");
    let dest_filename = format!("{}.yaml", safe_id);
    let dest_path = project
        .join(".raw-viewer")
        .join("profiles")
        .join(&dest_filename);

    if dry_run {
        return CliResult::ok(json!({
            "action": "profiles.import",
            "dry_run": true,
            "id": id,
            "instrument_name": instrument_name,
            "destination_path": dest_path.display().to_string().replace('\\', "/"),
        }));
    }

    if let Some(parent) = dest_path.parent() {
        if !parent.exists() {
            if let Err(e) = fs::create_dir_all(parent) {
                return CliResult::io(format!("failed to create directory: {e}"));
            }
        }
    }

    if let Err(e) = fs::write(&dest_path, &text) {
        return CliResult::io(format!("failed to write profile file: {e}"));
    }

    CliResult::ok(json!({
        "action": "profiles.import",
        "dry_run": false,
        "id": id,
        "destination_path": dest_path.display().to_string().replace('\\', "/"),
    }))
}

pub fn export_profile(_global: bool, project: Option<&Path>, id: &str, out: &str) -> CliResult {
    let catalog = if let Some(p) = project {
        if !p.exists() {
            return CliResult::not_found(format!(
                "project path does not exist: {}",
                p.display().to_string().replace('\\', "/")
            ));
        }
        let explorer = match Explorer::open(p) {
            Ok(exp) => exp,
            Err(e) => return CliResult::validation(format!("failed to open project: {e}")),
        };
        explorer.catalog.clone()
    } else {
        builtin_catalog()
    };

    let found = catalog.profiles.iter().find(|p| p.profile_id == id);
    let profile = match found {
        Some(p) => p,
        None => {
            return CliResult::not_found(format!("profile with id \"{id}\" not found"));
        }
    };

    // Find the text of the profile: either from BUILTIN_PROFILES or from file on disk
    let yaml_repr = if let Some((_, text)) = BUILTIN_PROFILES.iter().find(|(rel, _)| {
        *rel == profile.relative_path
            || rel.ends_with(&format!("{}.yaml", id.split('/').next_back().unwrap_or(id)))
    }) {
        text.to_string()
    } else if let Some(p) = project {
        let file_path = p.join(&profile.relative_path);
        match fs::read_to_string(&file_path) {
            Ok(t) => t,
            Err(_) => format!(
                "# Exported profile {}\nprofile_id: {}\ninstrument_name: {}\n",
                profile.profile_id, profile.profile_id, profile.instrument_name
            ),
        }
    } else {
        format!(
            "# Exported profile {}\nprofile_id: {}\ninstrument_name: {}\n",
            profile.profile_id, profile.profile_id, profile.instrument_name
        )
    };

    if out == "-" {
        println!("{yaml_repr}");
    } else {
        let out_path = Path::new(out);
        if let Some(parent) = out_path.parent() {
            if !parent.as_os_str().is_empty() && !parent.exists() {
                let _ = fs::create_dir_all(parent);
            }
        }
        if let Err(e) = fs::write(out_path, &yaml_repr) {
            return CliResult::io(format!(
                "failed to write export to {}: {}",
                out_path.display(),
                e
            ));
        }
    }

    CliResult::ok(json!({
        "action": "profiles.export",
        "id": id,
        "output": out,
    }))
}
