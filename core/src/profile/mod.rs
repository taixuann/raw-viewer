//! Instrument profile catalog and schema validation (v1/v2).

mod catalog;
mod schema;
mod types;

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
