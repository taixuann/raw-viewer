//! Shared RawView core.
//!
//! [`paths`] resolves the global config directory, the project config directory,
//! and the cache directory. [`config`] loads typed TOML settings from those
//! directories. Readers and measurements arrive in a later step.

pub mod config;
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
