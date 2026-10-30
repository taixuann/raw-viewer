//! Shared RawView core.
//!
//! [`paths`] and [`config`] resolve global and project settings directories.
//! [`profile`] loads and validates instrument profile YAML (schema v1/v2).
//! [`reader`] extracts normalized measurements from raw sources using those
//! profiles. [`measurement`] defines the v1 contract and golden JSON codec.
//! [`yaml`] is the profile YAML subset parser shared with the Swift app.

pub mod config;
pub mod grammar;
pub mod measurement;
pub mod paths;
pub mod profile;
pub mod project;
pub mod reader;
pub mod yaml;

/// Placeholder identity for the shared core.
/// The Tauri shell still calls this.
pub fn core_placeholder() -> &'static str {
    "raw-viewer-core"
}

#[cfg(test)]
mod tests {
    use super::core_placeholder;

    #[test]
    fn placeholder_names_the_crate() {
        assert_eq!(core_placeholder(), "raw-viewer-core");
    }
}
