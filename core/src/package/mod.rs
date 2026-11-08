//! In-memory package manifest validation (no install or filesystem I/O).

pub mod manifest;

pub use manifest::{
    parse_package_manifest, CanonicalProfileId, ManifestDiagnostic, ManifestErrorKind,
    ManifestPath, PackageId, PackageManifest, PackageProfileEntry, Sha256Hex,
    PACKAGE_MANIFEST_SCHEMA_VERSION,
};
