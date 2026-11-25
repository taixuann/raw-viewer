//! In-memory package manifest validation and update planning (no install or filesystem I/O).

pub mod manifest;

use crate::profile::sha256_hex;
use crate::yaml::{parse, YamlNode};

pub use manifest::{
    parse_package_manifest, render_manifest, CanonicalProfileId, ManifestDiagnostic,
    ManifestErrorKind, ManifestPath, PackageId, PackageManifest, PackageProfileEntry, Sha256Hex,
    PACKAGE_MANIFEST_SCHEMA_VERSION,
};

pub const USTH_LAB_PACKAGE_ID: &str = "usth-lab";
pub const USTH_LAB_PACKAGE_VERSION: &str = "0.1.1";

/// One row of the committed table that pins each bundled profile to its revision and sha256.
#[derive(Debug, Clone, PartialEq, Eq, serde::Deserialize)]
pub struct ProfileRevisionRecord {
    pub id: String,
    pub revision: u32,
    pub sha256: String,
}

#[derive(Debug, Clone, PartialEq, Eq, serde::Deserialize)]
pub struct BundledTable {
    pub package_id: String,
    pub version: String,
    pub profiles: Vec<ProfileRevisionRecord>,
}

/// Top-level `revision:` value of a profile document, if present and numeric.
pub fn profile_revision(text: &str) -> Option<u32> {
    let root = parse(text, false).ok()?;
    let node = root.value_for_key("revision")?;
    match node {
        YamlNode::Scalar(s) => s.parse().ok(),
        _ => None,
    }
}

/// Compares bundled profile texts against the committed table. A changed text with an
/// unchanged revision is reported as a missing revision bump.
pub fn profile_bump_violations(
    table: &[ProfileRevisionRecord],
    bundled: &[(&str, &str)],
) -> Vec<String> {
    let mut violations = Vec::new();
    for record in table {
        let Some((_, text)) = bundled.iter().find(|(id, _)| *id == record.id) else {
            violations.push(format!("{}: no bundled profile text", record.id));
            continue;
        };
        let sha = sha256_hex(text.as_bytes());
        let revision = profile_revision(text);
        if sha == record.sha256 && revision == Some(record.revision) {
            continue;
        }
        if sha != record.sha256 && revision == Some(record.revision) {
            violations.push(format!(
                "{}: changed without a revision bump (revision {} still in file; bump it and update the table)",
                record.id, record.revision
            ));
        } else {
            violations.push(format!(
                "{}: committed table has revision {} sha256 {}; bundled file has revision {:?} sha256 {}",
                record.id, record.revision, record.sha256, revision, sha
            ));
        }
    }
    violations
}

/// What is on disk for one profile id. `None` fields mean the file is absent.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ProfileFile {
    pub id: String,
    pub revision: Option<u32>,
    pub sha256: Option<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ProfileUpdateState {
    UpdateAvailable,
    LocallyEdited,
    ProjectOverride,
}

/// A profile that needs attention. Profiles already at the bundled revision are not listed.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ProfileUpdate {
    pub id: String,
    pub installed_revision: Option<u32>,
    pub bundled_revision: u32,
    pub state: ProfileUpdateState,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct VersionChange {
    pub installed: String,
    pub bundled: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct UpdatePlan {
    pub package_id: String,
    pub package_update: Option<VersionChange>,
    pub profiles: Vec<ProfileUpdate>,
}

/// Compares the installed state with the bundled state. Profiles absent from `bundled_revisions`
/// are skipped. An installed file whose sha256 differs from the recorded sha256 counts as edited.
pub fn plan_update(
    installed: &PackageManifest,
    installed_files: &[ProfileFile],
    bundled: &PackageManifest,
    bundled_revisions: &[(String, u32)],
    project_overrides: &[String],
) -> UpdatePlan {
    let package_update = (installed.version != bundled.version
        && version_is_newer(&bundled.version, &installed.version))
    .then(|| VersionChange {
        installed: installed.version.clone(),
        bundled: bundled.version.clone(),
    });

    let mut profiles = Vec::new();
    for entry in &bundled.profiles {
        let id = entry.id.as_str();
        let Some(bundled_revision) = bundled_revisions
            .iter()
            .find(|(b, _)| b == id)
            .map(|(_, r)| *r)
        else {
            continue;
        };
        let file = installed_files.iter().find(|f| f.id == id);
        let installed_revision = file.and_then(|f| f.revision);
        let on_disk = file.and_then(|f| f.sha256.as_deref());
        let recorded = installed
            .profiles
            .iter()
            .find(|p| p.id.as_str() == id)
            .map(|p| p.sha256.as_str());
        // A deleted file is also treated as edited, so replacing it still needs consent.
        let edited = match recorded {
            Some(sha) => on_disk != Some(sha),
            None => on_disk.is_some(),
        };
        let state = if project_overrides.iter().any(|o| o == id) {
            ProfileUpdateState::ProjectOverride
        } else if edited {
            ProfileUpdateState::LocallyEdited
        } else if bundled_revision > installed_revision.unwrap_or(0) {
            ProfileUpdateState::UpdateAvailable
        } else {
            continue;
        };
        profiles.push(ProfileUpdate {
            id: id.to_string(),
            installed_revision,
            bundled_revision,
            state,
        });
    }

    UpdatePlan {
        package_id: bundled.id.as_str().to_string(),
        package_update,
        profiles,
    }
}

/// Profile ids to write. `only` limits the scope, and an empty `only` means the whole package.
/// A named profile that cannot be written is an error, so no partial write happens.
pub fn select_writes(
    plan: &UpdatePlan,
    only: &[String],
    replace: &[String],
) -> Result<Vec<String>, String> {
    for id in only {
        let Some(update) = plan.profiles.iter().find(|p| &p.id == id) else {
            continue;
        };
        match update.state {
            ProfileUpdateState::ProjectOverride => {
                return Err(format!(
                    "{id} is overridden by a project-local profile and is not changed"
                ))
            }
            ProfileUpdateState::LocallyEdited if !replace.contains(id) => {
                return Err(format!(
                    "{id} was edited locally; pass --replace {id} to replace it"
                ))
            }
            _ => {}
        }
    }

    Ok(plan
        .profiles
        .iter()
        .filter(|p| only.is_empty() || only.contains(&p.id))
        .filter(|p| match p.state {
            ProfileUpdateState::UpdateAvailable => true,
            ProfileUpdateState::LocallyEdited => replace.contains(&p.id),
            ProfileUpdateState::ProjectOverride => false,
        })
        .map(|p| p.id.clone())
        .collect())
}

/// The manifest after an upgrade. Written profiles take their bundled sha256, and every other
/// profile keeps the sha256 of the file still on disk.
pub fn upgraded_manifest(
    installed: &PackageManifest,
    bundled: &PackageManifest,
    written: &[String],
) -> PackageManifest {
    let profiles = bundled
        .profiles
        .iter()
        .filter_map(|entry| {
            if written.iter().any(|w| w == entry.id.as_str()) {
                return Some(entry.clone());
            }
            installed
                .profiles
                .iter()
                .find(|p| p.id == entry.id)
                .cloned()
        })
        .collect();
    PackageManifest {
        schema_version: bundled.schema_version,
        id: bundled.id.clone(),
        version: bundled.version.clone(),
        display_name: bundled.display_name.clone(),
        profiles,
    }
}

/// Numeric comparison of dotted versions. Versions with a non-numeric part compare as text.
fn version_is_newer(candidate: &str, current: &str) -> bool {
    let parse = |v: &str| -> Option<Vec<u64>> { v.split('.').map(|p| p.parse().ok()).collect() };
    match (parse(candidate), parse(current)) {
        (Some(mut a), Some(mut b)) => {
            let len = a.len().max(b.len());
            a.resize(len, 0);
            b.resize(len, 0);
            a > b
        }
        _ => candidate != current,
    }
}
