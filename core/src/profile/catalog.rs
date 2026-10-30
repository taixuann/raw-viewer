use super::schema;
use super::sha256_hex;
use super::types::{
    BrokenClaim, InstrumentProfile, ProfileCatalog, ProfileMatch, ProfileMode, ProfileResolution,
};
use crate::project::ProjectContext;
use std::fs;
use std::io;
use std::path::{Path, PathBuf};

pub fn load_catalog(project_root: &Path) -> ProfileCatalog {
    let project = match ProjectContext::open(project_root) {
        Ok(p) => p,
        Err(err) => {
            return ProfileCatalog {
                profiles: vec![],
                issues: vec![format!("{}: {}", project_root.display(), err)],
                broken_claims: vec![],
            };
        }
    };

    let rawviewer = project.root.join(".rawviewer/instrument");
    if is_directory_with_yamls(&rawviewer, &project.root) {
        return load_profiles(&rawviewer, ".rawviewer/instrument", &project);
    }

    let legacy = project.root.join("data/.rawview/instrument");
    if is_directory_with_yamls(&legacy, &project.root) {
        return load_profiles(&legacy, "data/.rawview/instrument", &project);
    }

    let instruments = project.root.join("data/instruments");
    if !is_inside_project(&instruments, &project.root) {
        return ProfileCatalog {
            profiles: vec![],
            issues: vec![
                "data/instruments resolves outside this project. No profiles were loaded.".into(),
            ],
            broken_claims: vec![],
        };
    }
    if !instruments.is_dir() {
        return ProfileCatalog {
            profiles: vec![],
            issues: vec![],
            broken_claims: vec![],
        };
    }

    let companion = instruments.join("rawview");
    match fs::symlink_metadata(&companion) {
        Ok(meta) => {
            if meta.file_type().is_symlink() {
                return ProfileCatalog {
                    profiles: vec![],
                    issues: vec![
                        "data/instruments/rawview is a symlink; profiles must be regular entries in the companion directory.".into(),
                    ],
                    broken_claims: vec![],
                };
            }
            let companion = fs::canonicalize(&companion).unwrap_or(companion);
            if !is_inside_directory(&companion, &instruments) {
                return ProfileCatalog {
                    profiles: vec![],
                    issues: vec![
                        "data/instruments/rawview resolves outside data/instruments. No profiles were loaded.".into(),
                    ],
                    broken_claims: vec![],
                };
            }
            if !companion.is_dir() {
                return ProfileCatalog {
                    profiles: vec![],
                    issues: vec![
                        "data/instruments/rawview is not a readable directory. No profiles were loaded.".into(),
                    ],
                    broken_claims: vec![],
                };
            }
            load_profiles(&companion, "data/instruments/rawview", &project)
        }
        Err(err) if err.kind() == io::ErrorKind::NotFound => {
            load_profiles(&instruments, "data/instruments", &project)
        }
        Err(err) => ProfileCatalog {
            profiles: vec![],
            issues: vec![format!(
                "data/instruments/rawview could not be examined ({err}); no profiles were loaded."
            )],
            broken_claims: vec![],
        },
    }
}

fn is_directory_with_yamls(path: &Path, project_root: &Path) -> bool {
    let Ok(meta) = fs::symlink_metadata(path) else {
        return false;
    };
    if meta.file_type().is_symlink() {
        return false;
    }
    if !is_inside_project(path, project_root) {
        return false;
    }
    if !path.is_dir() {
        return false;
    }
    has_yaml_profiles(path)
}

fn has_yaml_profiles(root: &Path) -> bool {
    let Ok(entries) = fs::read_dir(root) else {
        return false;
    };
    entries.filter_map(Result::ok).any(|entry| {
        let name = entry.file_name().to_string_lossy().to_lowercase();
        name.ends_with(".yaml") || name.ends_with(".yml")
    })
}

fn is_inside_project(path: &Path, project_root: &Path) -> bool {
    let Ok(canonical_root) = fs::canonicalize(project_root) else {
        return path.starts_with(project_root);
    };
    let canonical_path = fs::canonicalize(path).unwrap_or_else(|_| path.to_path_buf());
    canonical_path.starts_with(&canonical_root) && canonical_path != canonical_root
}

fn is_inside_directory(path: &Path, parent: &Path) -> bool {
    let Ok(parent) = fs::canonicalize(parent) else {
        return path.starts_with(parent);
    };
    let canonical = fs::canonicalize(path).unwrap_or_else(|_| path.to_path_buf());
    canonical.starts_with(&parent) && canonical != parent
}

fn load_profiles(root: &Path, display_root: &str, project: &ProjectContext) -> ProfileCatalog {
    let mut profiles: Vec<InstrumentProfile> = Vec::new();
    let mut issues: Vec<String> = Vec::new();
    let mut broken_claims: Vec<BrokenClaim> = Vec::new();
    let profile_root = fs::canonicalize(root).unwrap_or_else(|_| root.to_path_buf());

    let mut entries: Vec<PathBuf> = fs::read_dir(root)
        .map(|read_dir| read_dir.filter_map(Result::ok).map(|e| e.path()).collect())
        .unwrap_or_default();
    entries.sort_by_key(|p| p.file_name().map(|n| n.to_os_string()));

    for entry in entries {
        let ext = entry
            .extension()
            .and_then(|e| e.to_str())
            .map(|e| e.to_lowercase());
        let Some(ext) = ext else { continue };
        if ext != "yaml" && ext != "yml" {
            continue;
        }
        if entry.is_dir() {
            continue;
        }
        if fs::symlink_metadata(&entry)
            .map(|m| m.file_type().is_symlink())
            .unwrap_or(false)
        {
            let name = entry.file_name().unwrap_or_default().to_string_lossy();
            issues.push(format!(
                "{display_root}/{name}: profile is a symlink; symlinks are never followed; skipped."
            ));
            continue;
        }
        let claimed_relative = match project.relative_path_of(&entry) {
            Some(p) => p,
            None => {
                let name = entry.file_name().unwrap_or_default().to_string_lossy();
                issues.push(format!(
                    "{display_root}/{name}: profile is outside this project; skipped."
                ));
                continue;
            }
        };
        let actual_parent = entry
            .parent()
            .and_then(|p| fs::canonicalize(p).ok())
            .or_else(|| entry.parent().map(Path::to_path_buf));
        if actual_parent.as_ref() != Some(&profile_root) {
            issues.push(format!(
                "{claimed_relative}: profile resolves outside {display_root}; skipped."
            ));
            continue;
        }
        let raw = match fs::read(&entry) {
            Ok(bytes) => bytes,
            Err(err) => {
                issues.push(format!(
                    "{claimed_relative}: profile could not be opened: {err}; skipped."
                ));
                continue;
            }
        };
        if raw.len() > ProfileCatalog::MAXIMUM_PROFILE_BYTES {
            issues.push(format!(
                "{claimed_relative}: profile exceeds the 1 MiB profile limit; skipped."
            ));
            continue;
        }
        let text = match std::str::from_utf8(&raw) {
            Ok(t) => t,
            Err(_) => {
                issues.push(format!(
                    "{claimed_relative}: profile is not readable UTF-8 text; skipped."
                ));
                continue;
            }
        };
        let digest = sha256_hex(&raw);
        let outcome = schema::load_document(text, &claimed_relative, &digest);
        if let Some(profile) = outcome.profile {
            profiles.push(profile);
        } else if !outcome.issues.is_empty() {
            issues.extend(outcome.issues.clone());
            if !outcome.extensions.is_empty() {
                broken_claims.push(BrokenClaim {
                    relative_path: claimed_relative,
                    extensions: outcome.extensions,
                    issues: outcome.issues,
                    mode_selectors: outcome.mode_selectors,
                    content_sha256: digest,
                });
            }
        }
    }

    ProfileCatalog {
        profiles,
        issues,
        broken_claims,
    }
}

impl ProfileCatalog {
    pub fn resolve(
        &self,
        file_extension: &str,
        header_sample: &str,
        basename: &str,
    ) -> ProfileResolution {
        let valid: Vec<_> = self
            .profiles
            .iter()
            .filter(|profile| {
                profile
                    .formats
                    .iter()
                    .any(|format| format.extensions.iter().any(|e| e == file_extension))
            })
            .collect();
        let claims: Vec<_> = self
            .broken_claims
            .iter()
            .filter(|claim| claim.extensions.iter().any(|e| e == file_extension))
            .collect();

        let sample = header_sample.to_lowercase();
        let base = basename.to_lowercase();
        let mut matches: Vec<ProfileMatch> = Vec::new();
        let mut misses: Vec<String> = Vec::new();
        let mut saw_filename_gate = false;

        for profile in &valid {
            for format in &profile.formats {
                if !format.extensions.iter().any(|e| e == file_extension) {
                    continue;
                }
                let modes: Vec<_> = profile
                    .modes
                    .iter()
                    .filter(|m| m.format_id == format.id)
                    .collect();
                let saw_filename_in_modes = modes.iter().any(|m| m.filename_contains_all.is_some());
                let matched: Vec<ProfileMode> = modes
                    .iter()
                    .filter(|mode| {
                        let filename_ok = mode
                            .filename_contains_all
                            .as_ref()
                            .map(|tokens| tokens.iter().all(|t| base.contains(&t.to_lowercase())))
                            .unwrap_or(true);
                        let header_ok = mode
                            .detect
                            .iter()
                            .any(|sig| sample.contains(&sig.to_lowercase()));
                        filename_ok && header_ok
                    })
                    .map(|mode| (*mode).clone())
                    .collect();
                let matched_empty = matched.is_empty();
                for mode in matched {
                    matches.push(ProfileMatch {
                        profile: (*profile).clone(),
                        format: format.clone(),
                        mode,
                    });
                }
                if matched_empty {
                    if saw_filename_in_modes {
                        saw_filename_gate = true;
                    }
                    let declared = if modes.is_empty() {
                        format!("no mode for format {}", format.id)
                    } else {
                        modes
                            .iter()
                            .map(|m| describe_miss(m, basename, &sample))
                            .collect::<Vec<_>>()
                            .join(", ")
                    };
                    misses.push(format!("{}: {declared}", profile.relative_path));
                }
            }
        }

        if matches.len() == 1 {
            let sole = matches.swap_remove(0);
            let blocking: Vec<_> = claims
                .iter()
                .filter(|c| c.blocks(&sample, basename))
                .collect();
            if blocking.is_empty() {
                return ProfileResolution::Matched(Box::new(sole));
            }
            let note = format!(
                "A valid profile ({} mode {}) also matches this source; the source stays blocked until the invalid profile is fixed or removed.",
                sole.profile.relative_path, sole.mode.id
            );
            let mut messages: Vec<String> =
                blocking.iter().flat_map(|c| c.issues.clone()).collect();
            messages.push(note);
            return ProfileResolution::Failed(messages.join("\n"));
        }
        if matches.len() > 1 {
            let described = matches
                .iter()
                .map(|m| format!("{} mode {}", m.profile.relative_path, m.mode.id))
                .collect::<Vec<_>>()
                .join(", ");
            return ProfileResolution::Failed(format!(
                "Ambiguous profile match: {described}. Keep one profile mode per source format."
            ));
        }
        if !claims.is_empty() {
            let conflict = if valid.is_empty() {
                vec![]
            } else {
                vec![format!(
                    "A supported profile also claims \"{file_extension}\"; the source stays blocked until the invalid profile is fixed or removed."
                )]
            };
            let mut messages: Vec<String> = claims.iter().flat_map(|c| c.issues.clone()).collect();
            messages.extend(conflict);
            return ProfileResolution::Failed(messages.join("\n"));
        }
        if valid.is_empty() {
            return ProfileResolution::Failed(format!(
                "No instrument profile supports \"{file_extension}\" files. Add a versioned profile under data/instruments; see CONTRACT.md."
            ));
        }
        let advice = if saw_filename_gate {
            "A v2 mode with filename_contains_all needs every token in the basename and one detect signature in the first 64 KiB."
        } else {
            "Add a detect signature for this file or fix the profile."
        };
        ProfileResolution::Failed(format!(
            "No profile mode matched this source (basename \"{basename}\"). Declared modes: {}. {advice}",
            misses.join("; ")
        ))
    }
}

fn describe_miss(mode: &crate::profile::ProfileMode, basename: &str, sample: &str) -> String {
    let mut parts = Vec::new();
    if let Some(tokens) = &mode.filename_contains_all {
        let missing: Vec<_> = tokens
            .iter()
            .filter(|t| !basename.to_lowercase().contains(&t.to_lowercase()))
            .collect();
        if missing.is_empty() {
            parts.push(format!(
                "filename_contains_all matched basename \"{basename}\""
            ));
        } else {
            parts.push(format!(
                "filename_contains_all tokens {} not in basename \"{basename}\"",
                missing
                    .iter()
                    .map(|t| format!("\"{t}\""))
                    .collect::<Vec<_>>()
                    .join(", ")
            ));
        }
    }
    if mode
        .detect
        .iter()
        .any(|sig| sample.contains(&sig.to_lowercase()))
    {
        parts.push("detect matched header sample".into());
    } else {
        parts.push(format!(
            "detect {} not in header sample",
            mode.detect
                .iter()
                .map(|s| format!("\"{s}\""))
                .collect::<Vec<_>>()
                .join(", ")
        ));
    }
    format!("{} [{}]", mode.id, parts.join("; "))
}
