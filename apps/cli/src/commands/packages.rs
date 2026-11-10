use crate::envelope::CliResult;
use raw_viewer_core::package::parse_package_manifest;
use raw_viewer_core::paths;
use raw_viewer_core::profile::{sha256_hex, BUILTIN_PROFILES};
use serde_json::json;
use std::fs;
use std::path::Path;

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
                    if pkg_id == "usth-lab" {
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
            "id": "usth-lab",
            "display_name": "USTH Clean Energy Lab Profiles",
            "version": "0.1.0",
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
        let pkg_dir = global_dir.join("packages").join("usth-lab");
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

        let mut manifest_lines = vec![
            "schema_version: 1".to_string(),
            "id: usth-lab".to_string(),
            "version: \"0.1.0\"".to_string(),
            "display_name: \"USTH Clean Energy Lab Profiles\"".to_string(),
            "profiles:".to_string(),
        ];
        for (id, filename, sha) in &entries {
            manifest_lines.push(format!("  - id: {id}"));
            manifest_lines.push(format!("    path: profiles/{filename}"));
            manifest_lines.push(format!("    sha256: {sha}"));
        }
        let manifest_content = manifest_lines.join("\n") + "\n";

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
            "package_id": "usth-lab",
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

    if id == "usth-lab" {
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
