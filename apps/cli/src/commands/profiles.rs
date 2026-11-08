use crate::envelope::CliResult;
use raw_viewer_core::explorer::Explorer;
use raw_viewer_core::profile::{
    builtin_catalog, parse_profile_v3, parse_profile_v4, BUILTIN_PROFILES,
};
use serde_json::json;
use std::fs::{self, OpenOptions};
use std::io::Write;
use std::path::{Path, PathBuf};

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

fn destination_path_for_profile_id(project: &Path, id: &str) -> PathBuf {
    let safe_id = id.replace('/', "-");
    let dest_filename = format!("{safe_id}.yaml");
    project
        .join(".raw-viewer")
        .join("profiles")
        .join(dest_filename)
}

fn read_profile_id_from_yaml(text: &str) -> Option<String> {
    if let Ok(v4) = parse_profile_v4(text) {
        return Some(v4.profile_id);
    }
    if let Ok(v3) = parse_profile_v3(text) {
        return Some(v3.profile_id);
    }
    None
}

fn read_installed_profile_id(path: &Path) -> Result<String, String> {
    let text = fs::read_to_string(path)
        .map_err(|e| format!("failed to read existing profile at {}: {e}", path.display()))?;
    read_profile_id_from_yaml(&text).ok_or_else(|| {
        format!(
            "existing destination {} is not a valid schema v3/v4 profile",
            path.display().to_string().replace('\\', "/")
        )
    })
}

enum DestinationGuard {
    Absent,
    SameId { replace_required: bool },
    Collision(CliResult),
}

fn evaluate_destination_guard(
    dest_path: &Path,
    candidate_id: &str,
    replace: bool,
) -> DestinationGuard {
    if !dest_path.exists() {
        return DestinationGuard::Absent;
    }

    let existing_id = match read_installed_profile_id(dest_path) {
        Ok(id) => id,
        Err(message) => {
            return DestinationGuard::Collision(CliResult {
                exit_code: crate::envelope::EXIT_VALIDATION,
                output: Err((
                    "profile_id_collision".to_string(),
                    message,
                    json!({
                        "destination_path": dest_path.display().to_string().replace('\\', "/"),
                        "candidate_id": candidate_id,
                    }),
                )),
            });
        }
    };

    if existing_id != candidate_id {
        return DestinationGuard::Collision(CliResult {
            exit_code: crate::envelope::EXIT_VALIDATION,
            output: Err((
                "profile_id_collision".to_string(),
                format!(
                    "destination path is already used by profile \"{existing_id}\"; \
                     importing \"{candidate_id}\" would collide (slash and hyphen ids map to the same filename). \
                     Use a different profile id or remove the existing file explicitly."
                ),
                json!({
                    "destination_path": dest_path.display().to_string().replace('\\', "/"),
                    "existing_id": existing_id,
                    "candidate_id": candidate_id,
                }),
            )),
        });
    }

    DestinationGuard::SameId {
        replace_required: !replace,
    }
}

fn replacement_required_result(dest_path: &Path, candidate_id: &str) -> CliResult {
    CliResult {
        exit_code: crate::envelope::EXIT_VALIDATION,
        output: Err((
            "replacement_required".to_string(),
            format!(
                "profile \"{candidate_id}\" is already installed at {}; \
                 re-import requires --replace to overwrite existing edits",
                dest_path.display().to_string().replace('\\', "/")
            ),
            json!({
                "destination_path": dest_path.display().to_string().replace('\\', "/"),
                "id": candidate_id,
            }),
        )),
    }
}

fn import_test_adversary_inject(dest_path: &Path) {
    if std::env::var_os("RAW_VIEWER_TEST_IMPORT_INJECT") != Some("post_stage".into()) {
        return;
    }
    let Ok(kind) = std::env::var("RAW_VIEWER_TEST_INJECT_KIND") else {
        return;
    };
    let content = std::env::var("RAW_VIEWER_TEST_INJECT_CONTENT")
        .unwrap_or_else(|_| minimal_test_marker_content());
    match kind.as_str() {
        "create_dest" if !dest_path.exists() => {
            let _ = fs::write(dest_path, content);
        }
        "create_dest_same_id" => {
            let _ = fs::write(dest_path, content);
        }
        _ => {}
    }
}

const MINIMAL_INJECTED_PROFILE: &str = "schema_version: 4\nid: usth/keithley-2400\nrevision: 1\ninstrument:\n  id: k\n  name: K\nvariants:\n  default:\n    format:\n      kind: tabular\n      extensions: [\".txt\"]\n      delimiter: \"\\t\"\n    rows:\n      header: 1\n      data_start: 2\n    columns:\n      x:\n        role: channel\n        header: x\n        quantity: voltage\n        unit: V\n        label: X\n    plot:\n      x: x\n      y: [x]\n# INJECTED MARKER\n";

fn minimal_test_marker_content() -> String {
    MINIMAL_INJECTED_PROFILE.to_string()
}

fn commit_error_for_existing_destination(
    dest_path: &Path,
    candidate_id: &str,
    replace: bool,
) -> CliResult {
    if !dest_path.exists() {
        return CliResult::validation("internal error: destination classification without file");
    }

    let existing_id = match read_installed_profile_id(dest_path) {
        Ok(id) => id,
        Err(message) => {
            return CliResult {
                exit_code: crate::envelope::EXIT_VALIDATION,
                output: Err((
                    "profile_id_collision".to_string(),
                    message,
                    json!({
                        "destination_path": dest_path.display().to_string().replace('\\', "/"),
                        "candidate_id": candidate_id,
                    }),
                )),
            };
        }
    };

    if existing_id != candidate_id {
        return CliResult {
            exit_code: crate::envelope::EXIT_VALIDATION,
            output: Err((
                "profile_id_collision".to_string(),
                format!(
                    "destination path is already used by profile \"{existing_id}\"; \
                     refusing to overwrite with \"{candidate_id}\""
                ),
                json!({
                    "destination_path": dest_path.display().to_string().replace('\\', "/"),
                    "existing_id": existing_id,
                    "candidate_id": candidate_id,
                }),
            )),
        };
    }

    if !replace {
        return replacement_required_result(dest_path, candidate_id);
    }

    CliResult::validation("internal error: replace commit called without consent resolution")
}

fn commit_staged_import(
    dest_path: &Path,
    tmp_path: &Path,
    text: &str,
    candidate_id: &str,
    replace: bool,
) -> CliResult {
    import_test_adversary_inject(dest_path);

    if dest_path.exists() {
        if !replace {
            let err = commit_error_for_existing_destination(dest_path, candidate_id, replace);
            return err;
        }

        let existing_id = match read_installed_profile_id(dest_path) {
            Ok(id) => id,
            Err(message) => {
                return CliResult {
                    exit_code: crate::envelope::EXIT_VALIDATION,
                    output: Err((
                        "profile_id_collision".to_string(),
                        message,
                        json!({
                            "destination_path": dest_path.display().to_string().replace('\\', "/"),
                            "candidate_id": candidate_id,
                        }),
                    )),
                };
            }
        };
        if existing_id != candidate_id {
            return CliResult {
                exit_code: crate::envelope::EXIT_VALIDATION,
                output: Err((
                    "profile_id_collision".to_string(),
                    format!(
                        "destination path is already used by profile \"{existing_id}\"; \
                         refusing to overwrite with \"{candidate_id}\""
                    ),
                    json!({
                        "destination_path": dest_path.display().to_string().replace('\\', "/"),
                        "existing_id": existing_id,
                        "candidate_id": candidate_id,
                    }),
                )),
            };
        }

        if std::env::var_os("RAW_VIEWER_TEST_COMMIT_REPLACE_FAIL") == Some("1".into()) {
            return CliResult::io(
                "test harness: injected post-staging replace failure before rename",
            );
        }

        if let Err(e) = fs::rename(tmp_path, dest_path) {
            return CliResult::io(format!(
                "failed to replace profile at {}: {e}",
                dest_path.display()
            ));
        }

        return CliResult::ok(json!({
            "action": "profiles.import",
            "dry_run": false,
            "replaced": true,
            "id": candidate_id,
            "destination_path": dest_path.display().to_string().replace('\\', "/"),
        }));
    }

    let mut dest_file = match OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(dest_path)
    {
        Ok(f) => f,
        Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => {
            return commit_error_for_existing_destination(dest_path, candidate_id, replace);
        }
        Err(e) => {
            return CliResult::io(format!(
                "failed to create profile file at {}: {e}",
                dest_path.display()
            ));
        }
    };

    if let Err(e) = dest_file.write_all(text.as_bytes()) {
        let _ = fs::remove_file(dest_path);
        return CliResult::io(format!(
            "failed to write profile file at {}: {e}",
            dest_path.display()
        ));
    }

    if let Err(e) = dest_file.sync_all() {
        let _ = fs::remove_file(dest_path);
        return CliResult::io(format!(
            "failed to flush profile file at {}: {e}",
            dest_path.display()
        ));
    }
    drop(dest_file);
    let _ = fs::remove_file(tmp_path);

    CliResult::ok(json!({
        "action": "profiles.import",
        "dry_run": false,
        "replaced": false,
        "id": candidate_id,
        "destination_path": dest_path.display().to_string().replace('\\', "/"),
    }))
}

fn write_profile_atomically(
    dest_path: &Path,
    text: &str,
    candidate_id: &str,
    replace: bool,
) -> CliResult {
    let parent = match dest_path.parent() {
        Some(p) => p,
        None => {
            return CliResult::validation("invalid destination path (no parent directory)");
        }
    };

    if let Err(e) = fs::create_dir_all(parent) {
        return CliResult::io(format!("failed to create directory: {e}"));
    }

    let safe_id = candidate_id.replace('/', "-");
    let tmp_path = parent.join(format!(".{safe_id}.import-tmp"));

    let mut tmp_file = match fs::File::create(&tmp_path) {
        Ok(f) => f,
        Err(e) => {
            return CliResult::io(format!("failed to create temporary profile file: {e}"));
        }
    };

    if let Err(e) = tmp_file.write_all(text.as_bytes()) {
        let _ = fs::remove_file(&tmp_path);
        return CliResult::io(format!("failed to write temporary profile file: {e}"));
    }

    if let Err(e) = tmp_file.sync_all() {
        let _ = fs::remove_file(&tmp_path);
        return CliResult::io(format!("failed to flush temporary profile file: {e}"));
    }
    drop(tmp_file);

    let result = commit_staged_import(dest_path, &tmp_path, text, candidate_id, replace);
    if result.exit_code != crate::envelope::EXIT_OK {
        let _ = fs::remove_file(&tmp_path);
    }
    result
}

pub fn import_profile(project: &Path, file: &Path, dry_run: bool, replace: bool) -> CliResult {
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

    let dest_path = destination_path_for_profile_id(project, &id);
    let destination_exists = dest_path.exists();

    let guard = evaluate_destination_guard(&dest_path, &id, replace);

    let would_require_replace = matches!(
        &guard,
        DestinationGuard::SameId {
            replace_required: true,
            ..
        }
    );

    match guard {
        DestinationGuard::Collision(result) => return result,
        DestinationGuard::SameId {
            replace_required: true,
            ..
        } if !dry_run => return replacement_required_result(&dest_path, &id),
        _ => {}
    }

    if dry_run {
        return CliResult::ok(json!({
            "action": "profiles.import",
            "dry_run": true,
            "id": id,
            "instrument_name": instrument_name,
            "destination_path": dest_path.display().to_string().replace('\\', "/"),
            "destination_exists": destination_exists,
            "replace": replace,
            "would_require_replace": would_require_replace,
            "validated_candidate": true,
            "note": "Dry-run validates the candidate file only; it does not install, activate, or enable the profile.",
        }));
    }

    write_profile_atomically(&dest_path, &text, &id, replace)
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

#[cfg(test)]
mod import_commit_tests {
    use super::*;
    use std::time::{SystemTime, UNIX_EPOCH};

    fn temp_root(label: &str) -> PathBuf {
        let nanos = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let p = std::env::temp_dir().join(format!("rv_import_ut_{label}_{nanos}"));
        fs::create_dir_all(&p).expect("temp");
        p
    }

    #[test]
    fn commit_create_new_refuses_existing_dest_without_replace() {
        let root = temp_root("create_new");
        let parent = root.join(".raw-viewer/profiles");
        fs::create_dir_all(&parent).expect("parent");
        let dest = parent.join("usth-keithley-2400.yaml");
        fs::write(&dest, "# PREEXISTING\n").expect("seed");
        let tmp = parent.join(".usth-keithley-2400.import-tmp");
        fs::write(&tmp, "candidate").expect("stage");

        let result = commit_staged_import(&dest, &tmp, "candidate", "usth/keithley-2400", false);
        assert_eq!(result.exit_code, crate::envelope::EXIT_VALIDATION);
        assert_eq!(fs::read_to_string(&dest).unwrap(), "# PREEXISTING\n");
    }

    #[test]
    fn commit_replace_refuses_different_identity_even_with_replace_flag() {
        let root = temp_root("diff_id");
        let parent = root.join(".raw-viewer/profiles");
        fs::create_dir_all(&parent).expect("parent");
        let dest = parent.join("a-b.yaml");
        fs::write(&dest, minimal_v4_profile_id("a-b")).expect("hyphen profile");
        let tmp = parent.join(".a-b.import-tmp");
        fs::write(&tmp, minimal_v4_profile_id("a/b")).expect("stage slash");

        let result = commit_staged_import(&dest, &tmp, &minimal_v4_profile_id("a/b"), "a/b", true);
        assert_eq!(result.exit_code, crate::envelope::EXIT_VALIDATION);
        let on_disk = fs::read_to_string(&dest).unwrap();
        assert!(on_disk.contains("id: a-b"), "hyphen identity must remain");
    }

    fn minimal_v4_profile_id(id: &str) -> String {
        format!(
            "schema_version: 4\nid: {id}\nrevision: 1\ninstrument:\n  id: x\n  name: X\nvariants:\n  default:\n    format:\n      kind: tabular\n      extensions: [\".txt\"]\n      delimiter: \"\\t\"\n    rows:\n      header: 1\n      data_start: 2\n    columns:\n      x:\n        role: channel\n        header: x\n        quantity: voltage\n        unit: V\n        label: X\n    plot:\n      x: x\n      y: [x]\n"
        )
    }
}
