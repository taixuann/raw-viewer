//! Instrument profile catalog and schema validation (v1/v2).

mod catalog;
mod schema;
mod types;
mod v3;

pub use v3::{
    parse as parse_profile_v3, AxisV3, ColumnRoleV3, DataStartLocatorV3, HeaderLocatorV3,
    MetadataCaptureRuleV3, ProfileColumnV3, ProfileDocumentError, ProfileDocumentV3,
    ProfileVariantV3,
};

pub use v3::MetadataCaptureRuleV3 as MetadataCaptureRule;

pub use catalog::load_catalog;
pub use types::*;

use sha2::{Digest, Sha256};

pub fn validate_document(text: &str, relative_path: &str) -> ProfileLoadOutcome {
    let sha256 = sha256_hex(text.as_bytes());
    schema::load_document(text, relative_path, &sha256)
}

pub fn sha256_hex(data: &[u8]) -> String {
    let digest = Sha256::digest(data);
    digest.iter().map(|b| format!("{b:02x}")).collect()
}
