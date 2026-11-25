use crate::envelope::CliResult;
use raw_viewer_core::package::{
    parse_package_manifest, plan_update, profile_revision, render_manifest, select_writes,
    upgraded_manifest, ProfileFile, ProfileUpdateState, UpdatePlan, USTH_LAB_PACKAGE_ID,
    USTH_LAB_PACKAGE_VERSION,
};
use raw_viewer_core::paths;
use raw_viewer_core::profile::{sha256_hex, BUILTIN_PROFILES};
use serde_json::{json, Value};
use std::fs;
use std::path::{Path, PathBuf};

const USTH_DISPLAY_NAME: &str = "USTH Clean Energy Lab Profiles";

/// A profile shipped inside the binary, with its revision and the sha256 of its bytes.
struct BundledProfile {
    id: String,
    filename: String,
    text: &'static str,
    sha256: String,
    revision: u32,
}

fn bundled_profiles() -> Result<Vec<BundledProfile>, String> {
    BUILTIN_PROFILES
        .iter()
        .map(|(rel, text)| {
            let filename = Path::new(rel)
                .file_name()
                .expect("bundled profile path has a file name")
                .to_string_lossy()
                .to_string();
            let stem = filename.trim_end_matches(".yaml");
            let revision = profile_revision(text)
                .ok_or_else(|| format!("bundled profile {rel} has no numeric revision"))?;
            Ok(BundledProfile {
                id: format!("usth/{stem}"),
                filename,
                text,
                sha256: sha256_hex(text.as_bytes()),
                revision,
            })
        })
        .collect()
}

/// The `package.yaml` text for the bundled USTH package.
fn usth_manifest_text(entries: &[(String, String, String)]) -> String {
    let mut out = format!(
        "schema_version: 1\nid: {USTH_LAB_PACKAGE_ID}\nversion: \"{USTH_LAB_PACKAGE_VERSION}\"\ndisplay_name: \"{USTH_DISPLAY_NAME}\"\nprofiles:\n"
    );
    for (id, filename, sha) in entries {
        out.push_str(&format!(
            "  - id: {id}\n    path: profiles/{filename}\n    sha256: {sha}\n"
        ));
    }
    out
}

pub fn list() -> CliResult {
    let resolved = match paths::resolve_global_paths_from_env() {
        Ok(r) => r,
        Err(e) => return CliResult::io(format!("failed to resolve global paths: {e}")),
    };
    let global_dir = Path::new(&resolved.global_config_dir);
    let packages_dir = global_dir.join("packages");

    let mut packages: Vec<serde_json::Value> = Vec::new();
    let mut has_usth = false;

    if packages_dir.is_dir() {
        if let Ok(entries) = fs::read_dir(&packages_dir) {
            for entry in entries.filter_map(Result::ok) {
                let path = entry.path();
                if !path.is_dir() {
                    continue;
                }
                let manifest_file = path.join("manifest.yaml");
                if !manifest_file.is_file() {
                    continue;
                }
                let text = match fs::read_to_string(&manifest_file) {
                    Ok(t) => t,
                    Err(_) => continue,
                };
                if let Ok(manifest) =
                    parse_package_manifest(&text, &manifest_file.display().to_string())
                {
                    let pkg_id = manifest.id.as_str().to_string();
                    if pkg_id == USTH_LAB_PACKAGE_ID {
                        has_usth = true;
                    }
                    let profiles: Vec<_> = manifest
                        .profiles
                        .iter()
                        .map(|p| {
                            json!({
                                "id": p.id.as_str(),
                                "path": p.path.as_str(),
                                "sha256": p.sha256.as_str(),
                            })
                        })
                        .collect();
                    packages.push(json!({
                        "id": pkg_id,
                        "display_name": manifest.display_name,
                        "version": manifest.version,
                        "profiles": profiles,
                        "is_installed": true,
                    }));
                }
            }
        }
    }

    if !has_usth {
        packages.push(json!({
            "id": USTH_LAB_PACKAGE_ID,
            "display_name": USTH_DISPLAY_NAME,
            "version": USTH_LAB_PACKAGE_VERSION,
            "profiles": [
                { "id": "usth/keithley-2400", "path": "profiles/keithley-2400.yaml" },
                { "id": "usth/autolab-usth", "path": "profiles/autolab-usth.yaml" },
                { "id": "usth/horiba-labram", "path": "profiles/horiba-labram.yaml" },
                { "id": "usth/iop-hanoi", "path": "profiles/iop-hanoi.yaml" }
            ],
            "is_installed": false,
        }));
    }

    packages.sort_by(|a, b| {
        a["id"]
            .as_str()
            .unwrap_or("")
            .cmp(b["id"].as_str().unwrap_or(""))
    });

    CliResult::ok(json!({
        "packages": packages
    }))
}

pub fn install(usth: bool, from: Option<&Path>, replace: bool) -> CliResult {
    let resolved = match paths::resolve_global_paths_from_env() {
        Ok(r) => r,
        Err(e) => return CliResult::io(format!("failed to resolve global paths: {e}")),
    };
    let global_dir = Path::new(&resolved.global_config_dir);

    if usth {
        let pkg_dir = global_dir.join("packages").join(USTH_LAB_PACKAGE_ID);
        let manifest_path = pkg_dir.join("manifest.yaml");
        if manifest_path.exists() && !replace {
            return CliResult::validation(
                "package 'usth-lab' is already installed; pass --replace to overwrite",
            );
        }

        let usth_profiles_dir = global_dir.join("profiles").join("usth");
        if let Err(e) = fs::create_dir_all(&usth_profiles_dir) {
            return CliResult::io(format!("failed to create profiles directory: {e}"));
        }
        if let Err(e) = fs::create_dir_all(&pkg_dir) {
            return CliResult::io(format!("failed to create package directory: {e}"));
        }

        let mut entries = Vec::new();

        for (rel, text) in BUILTIN_PROFILES {
            let filename = match Path::new(rel).file_name() {
                Some(name) => name.to_string_lossy().to_string(),
                None => continue,
            };
            let stem = filename.trim_end_matches(".yaml");
            let profile_id = format!("usth/{stem}");
            let target_path = usth_profiles_dir.join(&filename);

            let tmp_path = target_path.with_extension(format!("tmp.{}", std::process::id()));
            if let Err(e) = fs::write(&tmp_path, text) {
                return CliResult::io(format!("failed writing profile '{filename}': {e}"));
            }
            if let Err(e) = fs::rename(&tmp_path, &target_path) {
                let _ = fs::remove_file(&tmp_path);
                return CliResult::io(format!("failed committing profile '{filename}': {e}"));
            }

            let sha = sha256_hex(text.as_bytes());
            entries.push((profile_id, filename, sha));
        }

        let manifest_content = usth_manifest_text(&entries);

        if let Err(diags) = parse_package_manifest(&manifest_content, "usth-manifest") {
            let err_msgs: Vec<_> = diags
                .iter()
                .map(|d| format!("{}: {}", d.field, d.detail))
                .collect();
            return CliResult::validation(format!(
                "generated USTH manifest is invalid: {}",
                err_msgs.join(", ")
            ));
        }

        let tmp_manifest = manifest_path.with_extension(format!("tmp.{}", std::process::id()));
        if let Err(e) = fs::write(&tmp_manifest, &manifest_content) {
            return CliResult::io(format!("failed writing manifest: {e}"));
        }
        if let Err(e) = fs::rename(&tmp_manifest, &manifest_path) {
            let _ = fs::remove_file(&tmp_manifest);
            return CliResult::io(format!("failed committing manifest: {e}"));
        }

        CliResult::ok(json!({
            "action": "packages.install",
            "package_id": USTH_LAB_PACKAGE_ID,
            "status": "installed",
            "profiles_count": entries.len(),
            "manifest_path": manifest_path.display().to_string().replace('\\', "/"),
        }))
    } else if let Some(source_path) = from {
        if !source_path.exists() {
            return CliResult::not_found(format!(
                "source path does not exist: {}",
                source_path.display()
            ));
        }
        let (manifest_file, source_base) = if source_path.is_dir() {
            (source_path.join("manifest.yaml"), source_path.to_path_buf())
        } else {
            (
                source_path.to_path_buf(),
                source_path.parent().unwrap_or(Path::new(".")).to_path_buf(),
            )
        };

        if !manifest_file.is_file() {
            return CliResult::not_found(format!(
                "manifest file not found at {}",
                manifest_file.display()
            ));
        }

        let text = match fs::read_to_string(&manifest_file) {
            Ok(t) => t,
            Err(e) => return CliResult::io(format!("failed to read manifest file: {e}")),
        };

        let manifest = match parse_package_manifest(&text, &manifest_file.display().to_string()) {
            Ok(m) => m,
            Err(diags) => {
                let err_msgs: Vec<_> = diags
                    .iter()
                    .map(|d| format!("{}: {}", d.field, d.detail))
                    .collect();
                return CliResult::validation(format!(
                    "package manifest validation failed: {}",
                    err_msgs.join("; ")
                ));
            }
        };

        let pkg_id = manifest.id.as_str().to_string();
        let target_pkg_dir = global_dir.join("packages").join(&pkg_id);
        let target_manifest = target_pkg_dir.join("manifest.yaml");

        if target_manifest.exists() && !replace {
            return CliResult::validation(format!(
                "package '{pkg_id}' is already installed; pass --replace to overwrite"
            ));
        }

        if let Err(e) = fs::create_dir_all(&target_pkg_dir) {
            return CliResult::io(format!("failed to create package directory: {e}"));
        }

        for prof in &manifest.profiles {
            let src_profile_file = source_base.join(prof.path.as_str());
            if !src_profile_file.is_file() {
                return CliResult::not_found(format!(
                    "profile declared in manifest not found at {}",
                    src_profile_file.display()
                ));
            }
            let content = match fs::read(&src_profile_file) {
                Ok(c) => c,
                Err(e) => {
                    return CliResult::io(format!(
                        "failed to read profile {}: {e}",
                        src_profile_file.display()
                    ))
                }
            };
            let actual_sha = sha256_hex(&content);
            if actual_sha != prof.sha256.as_str() {
                return CliResult::validation(format!(
                    "checksum mismatch for {}: expected {} but got {}",
                    prof.id.as_str(),
                    prof.sha256.as_str(),
                    actual_sha
                ));
            }

            let ns = prof.id.namespace();
            let target_profile_dir = global_dir.join("profiles").join(ns);
            let _ = fs::create_dir_all(&target_profile_dir);
            let filename = Path::new(prof.path.as_str()).file_name().unwrap();
            let target_file = target_profile_dir.join(filename);
            let tmp_file = target_file.with_extension(format!("tmp.{}", std::process::id()));
            if let Err(e) = fs::write(&tmp_file, &content) {
                return CliResult::io(format!(
                    "failed to write profile {}: {e}",
                    target_file.display()
                ));
            }
            if let Err(e) = fs::rename(&tmp_file, &target_file) {
                let _ = fs::remove_file(&tmp_file);
                return CliResult::io(format!(
                    "failed to commit profile {}: {e}",
                    target_file.display()
                ));
            }
        }

        let tmp_manifest = target_manifest.with_extension(format!("tmp.{}", std::process::id()));
        if let Err(e) = fs::write(&tmp_manifest, &text) {
            return CliResult::io(format!("failed writing package manifest: {e}"));
        }
        if let Err(e) = fs::rename(&tmp_manifest, &target_manifest) {
            let _ = fs::remove_file(&tmp_manifest);
            return CliResult::io(format!("failed committing package manifest: {e}"));
        }

        CliResult::ok(json!({
            "action": "packages.install",
            "package_id": pkg_id,
            "status": "installed",
            "profiles_count": manifest.profiles.len(),
            "manifest_path": target_manifest.display().to_string().replace('\\', "/"),
        }))
    } else {
        CliResult::validation("must specify either --usth or --from <PATH>")
    }
}

/// Plans an upgrade of an installed package. Writes only when `dry_run` is false.
/// `only` limits the upgrade to named profiles, and `replace` consents to replacing edited ones.
pub fn upgrade(
    id: &str,
    dry_run: bool,
    only: &[String],
    replace: &[String],
    project: Option<&Path>,
) -> CliResult {
    let resolved = match paths::resolve_global_paths_from_env() {
        Ok(r) => r,
        Err(e) => return CliResult::io(format!("failed to resolve global paths: {e}")),
    };
    upgrade_in(
        Path::new(&resolved.global_config_dir),
        id,
        dry_run,
        only,
        replace,
        project,
    )
}

fn upgrade_in(
    global_dir: &Path,
    id: &str,
    dry_run: bool,
    only: &[String],
    replace: &[String],
    project: Option<&Path>,
) -> CliResult {
    if id != USTH_LAB_PACKAGE_ID {
        return CliResult::not_found(format!("no bundled package '{id}'"));
    }
    let pkg_dir = global_dir.join("packages").join(id);
    let manifest_path = pkg_dir.join("manifest.yaml");
    let installed_text = match fs::read_to_string(&manifest_path) {
        Ok(t) => t,
        Err(_) => {
            return CliResult::not_found(format!(
                "package '{id}' is not installed; run packages install --usth"
            ))
        }
    };
    let installed =
        match parse_package_manifest(&installed_text, &manifest_path.display().to_string()) {
            Ok(m) => m,
            Err(diags) => return validation_from(diags),
        };

    let bundled_list = match bundled_profiles() {
        Ok(list) => list,
        Err(e) => return CliResult::validation(e),
    };
    let bundled_entries: Vec<_> = bundled_list
        .iter()
        .map(|p| (p.id.clone(), p.filename.clone(), p.sha256.clone()))
        .collect();
    let bundled = match parse_package_manifest(
        &usth_manifest_text(&bundled_entries),
        "bundled-usth-manifest",
    ) {
        Ok(m) => m,
        Err(diags) => return validation_from(diags),
    };

    let mut installed_files = Vec::new();
    for p in &bundled_list {
        match read_installed_file(global_dir, p) {
            Ok(file) => installed_files.push(file),
            Err(e) => return CliResult::io(e),
        }
    }

    let mut overrides = Vec::new();
    if let Some(project) = project {
        if !project.is_dir() {
            return CliResult::not_found(format!(
                "project path does not exist: {}",
                project.display()
            ));
        }
        for p in &bundled_list {
            if project_has_profile(project, &p.id) {
                overrides.push(p.id.clone());
            }
        }
    }

    let revisions: Vec<(String, u32)> = bundled_list
        .iter()
        .map(|p| (p.id.clone(), p.revision))
        .collect();
    let plan = plan_update(
        &installed,
        &installed_files,
        &bundled,
        &revisions,
        &overrides,
    );
    let writes = match select_writes(&plan, only, replace) {
        Ok(w) => w,
        Err(e) => return CliResult::validation(e),
    };

    let kept: Vec<String> = plan
        .profiles
        .iter()
        .filter(|p| p.state == ProfileUpdateState::LocallyEdited)
        .filter(|p| !writes.contains(&p.id))
        .filter(|p| only.is_empty() || only.contains(&p.id))
        .map(|p| p.id.clone())
        .collect();

    // A single-profile upgrade leaves the package version alone, because other profiles stay old.
    let mut next = upgraded_manifest(&installed, &bundled, &writes);
    if !only.is_empty() {
        next.version = installed.version.clone();
    }

    let mut written = Vec::new();
    let mut staged = Vec::new();
    if !dry_run {
        for p in bundled_list.iter().filter(|p| writes.contains(&p.id)) {
            let target = profile_target(global_dir, p);
            if let Err(e) = write_atomic(&target, p.text.as_bytes()) {
                return CliResult::io(e);
            }
            written.push(p.id.clone());
        }
        // Keep-both: an edited profile stays in place and the bundled copy is staged beside it.
        for p in bundled_list.iter().filter(|p| kept.contains(&p.id)) {
            let target = pkg_dir.join("staged").join(&p.filename);
            if let Err(e) = write_atomic(&target, p.text.as_bytes()) {
                return CliResult::io(e);
            }
            staged.push(target.display().to_string().replace('\\', "/"));
        }
        if let Err(e) = write_atomic(&manifest_path, render_manifest(&next).as_bytes()) {
            return CliResult::io(e);
        }
    }

    CliResult::ok(json!({
        "action": "packages.upgrade",
        "package_id": id,
        "dry_run": dry_run,
        "plan": plan_json(&plan),
        "would_write": writes,
        "written": written,
        "kept": kept,
        "staged": staged,
        "manifest_path": manifest_path.display().to_string().replace('\\', "/"),
    }))
}

fn validation_from(diags: Vec<raw_viewer_core::package::ManifestDiagnostic>) -> CliResult {
    let msgs: Vec<_> = diags
        .iter()
        .map(|d| format!("{}: {}", d.field, d.detail))
        .collect();
    CliResult::validation(format!("package manifest is invalid: {}", msgs.join("; ")))
}

fn profile_target(global_dir: &Path, p: &BundledProfile) -> PathBuf {
    let ns = p.id.split_once('/').map(|(ns, _)| ns).unwrap_or("");
    global_dir.join("profiles").join(ns).join(&p.filename)
}

fn read_installed_file(global_dir: &Path, p: &BundledProfile) -> Result<ProfileFile, String> {
    let path = profile_target(global_dir, p);
    if !path.is_file() {
        return Ok(ProfileFile {
            id: p.id.clone(),
            revision: None,
            sha256: None,
        });
    }
    let bytes = fs::read(&path).map_err(|e| format!("failed to read {}: {e}", path.display()))?;
    Ok(ProfileFile {
        id: p.id.clone(),
        revision: profile_revision(&String::from_utf8_lossy(&bytes)),
        sha256: Some(sha256_hex(&bytes)),
    })
}

fn project_has_profile(project: &Path, id: &str) -> bool {
    [".raw-viewer/profiles", ".rawviewer/profiles"]
        .iter()
        .any(|dir| project.join(dir).join(format!("{id}.yaml")).is_file())
}

fn write_atomic(path: &Path, bytes: &[u8]) -> Result<(), String> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)
            .map_err(|e| format!("failed to create {}: {e}", parent.display()))?;
    }
    let tmp = path.with_extension(format!("tmp.{}", std::process::id()));
    fs::write(&tmp, bytes).map_err(|e| format!("failed writing {}: {e}", path.display()))?;
    fs::rename(&tmp, path).map_err(|e| {
        let _ = fs::remove_file(&tmp);
        format!("failed committing {}: {e}", path.display())
    })
}

fn plan_json(plan: &UpdatePlan) -> Value {
    let package_update = plan.package_update.as_ref().map(|change| {
        json!({
            "installed_version": change.installed,
            "bundled_version": change.bundled,
        })
    });
    let profiles: Vec<Value> = plan
        .profiles
        .iter()
        .map(|p| {
            let state = match p.state {
                ProfileUpdateState::UpdateAvailable => "update_available",
                ProfileUpdateState::LocallyEdited => "locally_edited",
                ProfileUpdateState::ProjectOverride => "project_override",
            };
            json!({
                "id": p.id,
                "installed_revision": p.installed_revision,
                "bundled_revision": p.bundled_revision,
                "state": state,
            })
        })
        .collect();
    json!({
        "package_update": package_update,
        "profiles": profiles,
    })
}

pub fn remove(id: &str) -> CliResult {
    let resolved = match paths::resolve_global_paths_from_env() {
        Ok(r) => r,
        Err(e) => return CliResult::io(format!("failed to resolve global paths: {e}")),
    };
    let global_dir = Path::new(&resolved.global_config_dir);
    let pkg_dir = global_dir.join("packages").join(id);

    if !pkg_dir.exists() {
        return CliResult::not_found(format!("package '{id}' not found"));
    }

    if id == USTH_LAB_PACKAGE_ID {
        let usth_profiles_dir = global_dir.join("profiles").join("usth");
        if usth_profiles_dir.exists() {
            let _ = fs::remove_dir_all(&usth_profiles_dir);
        }
    } else {
        let manifest_path = pkg_dir.join("manifest.yaml");
        if let Ok(text) = fs::read_to_string(&manifest_path) {
            if let Ok(manifest) =
                parse_package_manifest(&text, &manifest_path.display().to_string())
            {
                for prof in manifest.profiles {
                    let ns = prof.id.namespace();
                    if let Some(filename) = Path::new(prof.path.as_str()).file_name() {
                        let prof_file = global_dir.join("profiles").join(ns).join(filename);
                        let _ = fs::remove_file(prof_file);
                    }
                }
            }
        }
    }

    if let Err(e) = fs::remove_dir_all(&pkg_dir) {
        return CliResult::io(format!("failed to remove package directory: {e}"));
    }

    CliResult::ok(json!({
        "action": "packages.remove",
        "package_id": id,
        "status": "removed"
    }))
}

#[cfg(test)]
mod upgrade_tests {
    use super::*;
    use raw_viewer_core::package::PackageManifest;

    fn scratch(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("rv_upgrade_{name}_{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();
        dir
    }

    struct Entry {
        bundled: BundledProfile,
        on_disk: String,
        recorded: String,
    }

    fn default_entries() -> Vec<Entry> {
        bundled_profiles()
            .unwrap()
            .into_iter()
            .map(|bundled| {
                let on_disk = bundled.text.to_string();
                let recorded = on_disk.clone();
                Entry {
                    bundled,
                    on_disk,
                    recorded,
                }
            })
            .collect()
    }

    fn keithley(entries: &[Entry]) -> usize {
        entries
            .iter()
            .position(|e| e.bundled.id == "usth/keithley-2400")
            .unwrap()
    }

    /// Bundled keithley text with `revision: 0`, which is one revision behind the bundled copy.
    fn keithley_rev0() -> String {
        let text = BUILTIN_PROFILES
            .iter()
            .find(|(rel, _)| rel.ends_with("keithley-2400.yaml"))
            .unwrap()
            .1;
        text.replacen("revision: 1", "revision: 0", 1)
    }

    fn write_installed(global: &Path, version: &str, entries: &[Entry]) {
        let mut manifest = usth_manifest_text(
            &entries
                .iter()
                .map(|e| {
                    (
                        e.bundled.id.clone(),
                        e.bundled.filename.clone(),
                        sha256_hex(e.recorded.as_bytes()),
                    )
                })
                .collect::<Vec<_>>(),
        );
        manifest = manifest.replacen(
            &format!("version: \"{USTH_LAB_PACKAGE_VERSION}\""),
            &format!("version: \"{version}\""),
            1,
        );
        let profiles_dir = global.join("profiles").join("usth");
        fs::create_dir_all(&profiles_dir).unwrap();
        for e in entries {
            fs::write(profiles_dir.join(&e.bundled.filename), &e.on_disk).unwrap();
        }
        let pkg_dir = global.join("packages").join(USTH_LAB_PACKAGE_ID);
        fs::create_dir_all(&pkg_dir).unwrap();
        fs::write(pkg_dir.join("manifest.yaml"), manifest).unwrap();
    }

    fn profile_path(global: &Path, filename: &str) -> PathBuf {
        global.join("profiles").join("usth").join(filename)
    }

    fn data(result: CliResult) -> Value {
        result.output.expect("command succeeded")
    }

    fn sha_of_manifest_entry(global: &Path, id: &str) -> String {
        let text = fs::read_to_string(global.join("packages/usth-lab/manifest.yaml")).unwrap();
        let manifest: PackageManifest = parse_package_manifest(&text, "test").unwrap();
        manifest
            .profiles
            .iter()
            .find(|p| p.id.as_str() == id)
            .unwrap()
            .sha256
            .as_str()
            .to_string()
    }

    fn bundled_bytes(id: &str) -> String {
        bundled_profiles()
            .unwrap()
            .into_iter()
            .find(|p| p.id == id)
            .unwrap()
            .text
            .to_string()
    }

    #[test]
    fn case1_same_version_and_revisions_list_no_update() {
        let global = scratch("case1");
        write_installed(&global, USTH_LAB_PACKAGE_VERSION, &default_entries());

        let out = data(upgrade_in(&global, "usth-lab", true, &[], &[], None));

        assert_eq!(out["plan"]["package_update"], Value::Null);
        assert_eq!(out["plan"]["profiles"], json!([]));
        assert_eq!(out["would_write"], json!([]));
    }

    #[test]
    fn case2_newer_bundled_version_lists_package_with_changed_profile() {
        let global = scratch("case2");
        let mut entries = default_entries();
        let k = keithley(&entries);
        entries[k].on_disk = keithley_rev0();
        entries[k].recorded = keithley_rev0();
        write_installed(&global, "0.0.9", &entries);

        let out = data(upgrade_in(&global, "usth-lab", true, &[], &[], None));

        assert_eq!(
            out["plan"]["package_update"],
            json!({"installed_version": "0.0.9", "bundled_version": "0.1.1"})
        );
        assert_eq!(
            out["plan"]["profiles"],
            json!([{
                "id": "usth/keithley-2400",
                "installed_revision": 0,
                "bundled_revision": 1,
                "state": "update_available"
            }])
        );
    }

    #[test]
    fn case3_one_newer_profile_is_written_and_others_stay_byte_identical() {
        let global = scratch("case3");
        let mut entries = default_entries();
        let k = keithley(&entries);
        entries[k].on_disk = keithley_rev0();
        entries[k].recorded = keithley_rev0();
        write_installed(&global, USTH_LAB_PACKAGE_VERSION, &entries);
        let autolab_before = fs::read(profile_path(&global, "autolab-usth.yaml")).unwrap();

        let out = data(upgrade_in(&global, "usth-lab", false, &[], &[], None));

        assert_eq!(out["plan"]["profiles"].as_array().unwrap().len(), 1);
        assert_eq!(out["written"], json!(["usth/keithley-2400"]));
        assert_eq!(
            fs::read_to_string(profile_path(&global, "keithley-2400.yaml")).unwrap(),
            bundled_bytes("usth/keithley-2400")
        );
        assert_eq!(
            fs::read(profile_path(&global, "autolab-usth.yaml")).unwrap(),
            autolab_before
        );
    }

    #[test]
    fn case4_edited_profile_is_kept_and_bundled_copy_is_staged_without_consent() {
        let global = scratch("case4_keep");
        let mut entries = default_entries();
        let k = keithley(&entries);
        entries[k].on_disk = format!("{}# my own edit\n", keithley_rev0());
        entries[k].recorded = keithley_rev0();
        write_installed(&global, USTH_LAB_PACKAGE_VERSION, &entries);

        let out = data(upgrade_in(&global, "usth-lab", false, &[], &[], None));

        assert_eq!(out["plan"]["profiles"][0]["state"], "locally_edited");
        assert_eq!(out["written"], json!([]));
        assert_eq!(out["kept"], json!(["usth/keithley-2400"]));
        assert_eq!(
            fs::read_to_string(profile_path(&global, "keithley-2400.yaml")).unwrap(),
            format!("{}# my own edit\n", keithley_rev0()),
            "the user edit stays in place"
        );
        assert_eq!(
            fs::read_to_string(global.join("packages/usth-lab/staged/keithley-2400.yaml")).unwrap(),
            bundled_bytes("usth/keithley-2400"),
            "the bundled copy is staged beside it"
        );
        assert_eq!(
            sha_of_manifest_entry(&global, "usth/keithley-2400"),
            sha256_hex(keithley_rev0().as_bytes()),
            "the manifest still records the file on disk"
        );
    }

    #[test]
    fn case4_edited_profile_is_replaced_only_with_explicit_consent() {
        let global = scratch("case4_replace");
        let mut entries = default_entries();
        let k = keithley(&entries);
        entries[k].on_disk = format!("{}# my own edit\n", keithley_rev0());
        entries[k].recorded = keithley_rev0();
        write_installed(&global, USTH_LAB_PACKAGE_VERSION, &entries);

        let refused = upgrade_in(
            &global,
            "usth-lab",
            false,
            &["usth/keithley-2400".to_string()],
            &[],
            None,
        );
        assert_eq!(refused.exit_code, 4);
        let (code, message, _) = refused.output.unwrap_err();
        assert_eq!(code, "validation_error");
        assert!(
            message.contains("--replace usth/keithley-2400"),
            "{message}"
        );
        assert_eq!(
            fs::read_to_string(profile_path(&global, "keithley-2400.yaml")).unwrap(),
            format!("{}# my own edit\n", keithley_rev0()),
            "a refused upgrade writes nothing"
        );

        let out = data(upgrade_in(
            &global,
            "usth-lab",
            false,
            &[],
            &["usth/keithley-2400".to_string()],
            None,
        ));

        assert_eq!(out["written"], json!(["usth/keithley-2400"]));
        assert_eq!(
            fs::read_to_string(profile_path(&global, "keithley-2400.yaml")).unwrap(),
            bundled_bytes("usth/keithley-2400")
        );
    }

    #[test]
    fn case5_project_local_override_is_reported_and_never_changed() {
        let global = scratch("case5");
        let project = scratch("case5_project");
        let override_dir = project.join(".raw-viewer/profiles/usth");
        fs::create_dir_all(&override_dir).unwrap();
        fs::write(override_dir.join("keithley-2400.yaml"), "project copy\n").unwrap();
        let mut entries = default_entries();
        let k = keithley(&entries);
        entries[k].on_disk = keithley_rev0();
        entries[k].recorded = keithley_rev0();
        write_installed(&global, USTH_LAB_PACKAGE_VERSION, &entries);

        let out = data(upgrade_in(
            &global,
            "usth-lab",
            false,
            &[],
            &["usth/keithley-2400".to_string()],
            Some(&project),
        ));

        assert_eq!(out["plan"]["profiles"][0]["state"], "project_override");
        assert_eq!(out["written"], json!([]));
        assert_eq!(
            fs::read_to_string(override_dir.join("keithley-2400.yaml")).unwrap(),
            "project copy\n"
        );
        assert_eq!(
            fs::read_to_string(profile_path(&global, "keithley-2400.yaml")).unwrap(),
            keithley_rev0(),
            "the global copy is not written either"
        );
    }

    #[test]
    fn case6_manifest_after_update_has_new_version_and_new_sha256() {
        let global = scratch("case6");
        let mut entries = default_entries();
        let k = keithley(&entries);
        entries[k].on_disk = keithley_rev0();
        entries[k].recorded = keithley_rev0();
        write_installed(&global, "0.0.9", &entries);

        let out = data(upgrade_in(&global, "usth-lab", false, &[], &[], None));

        assert_eq!(out["written"], json!(["usth/keithley-2400"]));
        let text = fs::read_to_string(global.join("packages/usth-lab/manifest.yaml")).unwrap();
        let manifest = parse_package_manifest(&text, "test").unwrap();
        assert_eq!(manifest.version, USTH_LAB_PACKAGE_VERSION);
        assert_eq!(
            sha_of_manifest_entry(&global, "usth/keithley-2400"),
            sha256_hex(bundled_bytes("usth/keithley-2400").as_bytes())
        );
    }

    #[test]
    fn dry_run_writes_nothing() {
        let global = scratch("dry_run");
        let mut entries = default_entries();
        let k = keithley(&entries);
        entries[k].on_disk = keithley_rev0();
        entries[k].recorded = keithley_rev0();
        write_installed(&global, "0.0.9", &entries);
        let before = fs::read(global.join("packages/usth-lab/manifest.yaml")).unwrap();

        let out = data(upgrade_in(&global, "usth-lab", true, &[], &[], None));

        assert_eq!(out["dry_run"], true);
        assert_eq!(out["would_write"], json!(["usth/keithley-2400"]));
        assert_eq!(out["written"], json!([]));
        assert_eq!(
            fs::read(global.join("packages/usth-lab/manifest.yaml")).unwrap(),
            before
        );
        assert_eq!(
            fs::read_to_string(profile_path(&global, "keithley-2400.yaml")).unwrap(),
            keithley_rev0()
        );
    }
}
