//! In-memory package manifest validation and update planning (no install or filesystem I/O).

pub mod manifest;

use crate::profile::sha256_hex;
use crate::yaml::{parse, YamlNode};

pub use manifest::{
    parse_package_manifest, CanonicalProfileId, ManifestDiagnostic, ManifestErrorKind,
    ManifestPath, PackageId, PackageManifest, PackageProfileEntry, Sha256Hex,
    PACKAGE_MANIFEST_SCHEMA_VERSION,
};

pub const USTH_LAB_PACKAGE_ID: &str = "usth-lab";
pub const USTH_LAB_PACKAGE_VERSION: &str = "0.1.0";

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
