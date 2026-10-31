//! Typed global and project settings stored in `config.toml`.
//!
//! A missing file loads defaults. A file that parses but has a wrong type or an
//! unknown key is an error that names the file and the field. Loading does not
//! create directories or write files.
//!
//! Each file is a flat table. Top-level keys only. A `[section]` is an unknown
//! field.

use std::fmt;
use std::fs;
use std::io;
use std::path::{Path, PathBuf};

/// File name inside a global or project config directory.
pub const CONFIG_FILE_NAME: &str = "config.toml";

/// Settings from the global config directory.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct GlobalConfig {
    /// Project paths the user opened recently, most recent last.
    pub recent_projects: Vec<String>,
}

/// Settings from a project's `.raw-viewer` directory.
///
/// Defaults match the Swift project settings: data lives in `data/raw`, the
/// view is `tree`, and the preset is `nature-single`. This file does not
/// replace `.rawviewer/setting.yaml`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ProjectConfig {
    /// Project-relative directory that holds raw measurements.
    ///
    /// Allowed values are `.`, or one or more segments separated by `/`.
    /// A segment must not be empty, `.`, or `..`. Absolute paths, values that
    /// start with `~`, backslashes, and control characters are rejected.
    pub data_root: String,
    /// Explorer view opened for the project.
    pub default_view: String,
    /// Plot preset opened for the project.
    pub default_preset: String,
}

impl ProjectConfig {
    /// Default data directory, relative to the project root.
    pub const DEFAULT_DATA_ROOT: &'static str = "data/raw";
    /// Default explorer view.
    pub const DEFAULT_VIEW: &'static str = "tree";
    /// Default plot preset.
    pub const DEFAULT_PRESET: &'static str = "nature-single";
}

impl Default for ProjectConfig {
    fn default() -> Self {
        Self {
            data_root: Self::DEFAULT_DATA_ROOT.to_string(),
            default_view: Self::DEFAULT_VIEW.to_string(),
            default_preset: Self::DEFAULT_PRESET.to_string(),
        }
    }
}

/// Failure to load a config file.
#[derive(Debug)]
pub enum ConfigError {
    /// The file exists but could not be read.
    Read {
        /// Config file path.
        path: PathBuf,
        /// Filesystem error.
        source: io::Error,
    },
    /// The file is not valid settings.
    Malformed {
        /// Config file path.
        path: PathBuf,
        /// Field that failed, when the document identifies one.
        field: Option<String>,
        /// What is wrong with the field or the document.
        detail: String,
    },
}

impl ConfigError {
    /// Path of the config file named by this error.
    pub fn path(&self) -> &Path {
        match self {
            Self::Read { path, .. } | Self::Malformed { path, .. } => path,
        }
    }

    /// Field name when the error is about one key.
    pub fn field(&self) -> Option<&str> {
        match self {
            Self::Malformed { field, .. } => field.as_deref(),
            Self::Read { .. } => None,
        }
    }

    fn malformed(path: &Path, field: Option<String>, detail: String) -> Self {
        Self::Malformed {
            path: path.to_path_buf(),
            field,
            detail,
        }
    }
}

impl fmt::Display for ConfigError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Read { path, source } => {
                write!(f, "failed to read config file {}: {source}", path.display())
            }
            Self::Malformed {
                path,
                field: Some(field),
                detail,
            } => write!(
                f,
                "config file {} is malformed: field `{field}`: {detail}",
                path.display()
            ),
            Self::Malformed {
                path,
                field: None,
                detail,
            } => write!(f, "config file {} is malformed: {detail}", path.display()),
        }
    }
}

impl std::error::Error for ConfigError {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            Self::Read { source, .. } => Some(source),
            Self::Malformed { .. } => None,
        }
    }
}

/// Path of `config.toml` inside `config_dir`.
pub fn config_file(config_dir: &Path) -> PathBuf {
    config_dir.join(CONFIG_FILE_NAME)
}

/// Load global settings from `config_dir/config.toml`.
///
/// A missing file returns [`GlobalConfig::default`]. This function does not
/// create `config_dir` and does not write a file.
///
/// The document must be a flat table. A `[section]` is reported as an unknown
/// field named after that section.
pub fn load_global_config(config_dir: &Path) -> Result<GlobalConfig, ConfigError> {
    let path = config_file(config_dir);
    let Some(table) = read_table(&path)? else {
        return Ok(GlobalConfig::default());
    };
    let mut config = GlobalConfig::default();
    for (key, value) in &table {
        match key.as_str() {
            "recent_projects" => config.recent_projects = expect_string_array(&path, key, value)?,
            _ => {
                return Err(ConfigError::malformed(
                    &path,
                    Some(key.clone()),
                    "unknown field".to_string(),
                ));
            }
        }
    }
    Ok(config)
}

/// Load project settings from `config_dir/config.toml`.
///
/// A missing file returns [`ProjectConfig::default`]. This function does not
/// create `config_dir` and does not write a file.
///
/// The document must be a flat table. A `[section]` is reported as an unknown
/// field named after that section. `data_root`, when present, must be a
/// project-relative path. See [`ProjectConfig::data_root`].
pub fn load_project_config(config_dir: &Path) -> Result<ProjectConfig, ConfigError> {
    let path = config_file(config_dir);
    let Some(table) = read_table(&path)? else {
        return Ok(ProjectConfig::default());
    };
    let mut config = ProjectConfig::default();
    for (key, value) in &table {
        match key.as_str() {
            "data_root" => config.data_root = expect_data_root(&path, value)?,
            "default_view" => config.default_view = expect_string(&path, key, value)?,
            "default_preset" => config.default_preset = expect_string(&path, key, value)?,
            _ => {
                return Err(ConfigError::malformed(
                    &path,
                    Some(key.clone()),
                    "unknown field".to_string(),
                ));
            }
        }
    }
    Ok(config)
}

fn read_table(path: &Path) -> Result<Option<toml::Table>, ConfigError> {
    let text = match fs::read_to_string(path) {
        Ok(text) => text,
        Err(source) if source.kind() == io::ErrorKind::NotFound => return Ok(None),
        Err(source) => {
            return Err(ConfigError::Read {
                path: path.to_path_buf(),
                source,
            });
        }
    };
    if text.trim().is_empty() {
        return Ok(Some(toml::Table::new()));
    }
    match toml::from_str::<toml::Table>(&text) {
        Ok(table) => Ok(Some(table)),
        Err(error) => Err(ConfigError::malformed(path, None, error.to_string())),
    }
}

fn expect_data_root(path: &Path, value: &toml::Value) -> Result<String, ConfigError> {
    let text = expect_string(path, "data_root", value)?;
    if let Some(detail) = data_root_problem(&text) {
        return Err(ConfigError::malformed(
            path,
            Some("data_root".to_string()),
            detail,
        ));
    }
    Ok(text)
}

/// `data_root` is `.`, or slash-separated segments that stay inside the project.
fn data_root_problem(value: &str) -> Option<String> {
    if value.trim().is_empty() {
        return Some("must not be empty".to_string());
    }
    if value.chars().any(|c| c.is_control() || c == '\\') {
        return Some("must not contain backslashes or control characters".to_string());
    }
    if value.starts_with('/') || has_windows_drive_prefix(value) {
        return Some(format!(
            "must be project-relative, not absolute (got {value:?})"
        ));
    }
    if value.starts_with('~') {
        return Some(format!(
            "must be project-relative, not a home path (got {value:?})"
        ));
    }
    if value != "." {
        for component in value.split('/') {
            if component.is_empty() || component == "." || component == ".." {
                return Some(format!(
                    "must not contain empty, '.', or '..' components (got {value:?})"
                ));
            }
        }
    }
    None
}

fn has_windows_drive_prefix(value: &str) -> bool {
    let mut chars = value.chars();
    matches!(
        (chars.next(), chars.next()),
        (Some(letter), Some(':')) if letter.is_ascii_alphabetic()
    )
}

fn expect_string(path: &Path, field: &str, value: &toml::Value) -> Result<String, ConfigError> {
    match value.as_str() {
        Some(text) => Ok(text.to_string()),
        None => Err(ConfigError::malformed(
            path,
            Some(field.to_string()),
            format!("expected a string, found {}", value_kind(value)),
        )),
    }
}

fn expect_string_array(
    path: &Path,
    field: &str,
    value: &toml::Value,
) -> Result<Vec<String>, ConfigError> {
    let Some(items) = value.as_array() else {
        return Err(ConfigError::malformed(
            path,
            Some(field.to_string()),
            format!("expected an array of strings, found {}", value_kind(value)),
        ));
    };
    let mut strings = Vec::with_capacity(items.len());
    for (index, item) in items.iter().enumerate() {
        match item.as_str() {
            Some(text) => strings.push(text.to_string()),
            None => {
                return Err(ConfigError::malformed(
                    path,
                    Some(field.to_string()),
                    format!(
                        "expected a string, found {} at index {index}",
                        value_kind(item)
                    ),
                ));
            }
        }
    }
    Ok(strings)
}

fn value_kind(value: &toml::Value) -> String {
    match value.type_str() {
        "integer" | "array" => format!("an {}", value.type_str()),
        other => format!("a {other}"),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::{SystemTime, UNIX_EPOCH};

    struct TempDir {
        path: PathBuf,
    }

    impl TempDir {
        fn new() -> Self {
            let path = std::env::temp_dir().join(format!(
                "raw-viewer-cfg-{}-{}",
                std::process::id(),
                SystemTime::now()
                    .duration_since(UNIX_EPOCH)
                    .expect("clock")
                    .as_nanos()
            ));
            fs::create_dir_all(&path).unwrap();
            Self { path }
        }
    }

    impl Drop for TempDir {
        fn drop(&mut self) {
            #[cfg(unix)]
            {
                use std::os::unix::fs::PermissionsExt;
                if let Ok(metadata) = fs::metadata(&self.path) {
                    let mut permissions = metadata.permissions();
                    // Owner write bit, so a read-only test directory can be removed.
                    let mode = permissions.mode() | 0o200;
                    permissions.set_mode(mode);
                    let _ = fs::set_permissions(&self.path, permissions);
                }
            }
            let _ = fs::remove_dir_all(&self.path);
        }
    }

    fn assert_names_file_and_field(error: &ConfigError, file: &Path, field: &str) {
        assert_eq!(error.path(), file);
        assert_eq!(error.field(), Some(field));
        let message = error.to_string();
        assert!(message.contains(&file.display().to_string()), "{message}");
        assert!(message.contains(field), "{message}");
        assert!(message.contains("malformed"), "{message}");
    }

    #[test]
    fn missing_file_returns_defaults_and_creates_nothing() {
        let missing = std::env::temp_dir().join(format!(
            "raw-viewer-missing-cfg-{}-{}",
            std::process::id(),
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .expect("clock")
                .as_nanos()
        ));
        assert!(!missing.exists());
        assert_eq!(
            load_global_config(&missing).unwrap(),
            GlobalConfig::default()
        );
        assert_eq!(
            load_project_config(&missing).unwrap(),
            ProjectConfig::default()
        );
        assert!(!missing.exists());
        assert!(!config_file(&missing).exists());
    }

    #[test]
    fn empty_directory_returns_defaults_and_writes_nothing() {
        let dir = TempDir::new();
        let before = fs::read_dir(&dir.path).unwrap().count();
        assert_eq!(
            load_global_config(&dir.path).unwrap(),
            GlobalConfig {
                recent_projects: Vec::new()
            }
        );
        assert_eq!(
            load_project_config(&dir.path).unwrap(),
            ProjectConfig {
                data_root: "data/raw".to_string(),
                default_view: "tree".to_string(),
                default_preset: "nature-single".to_string(),
            }
        );
        assert_eq!(fs::read_dir(&dir.path).unwrap().count(), before);
        assert!(!config_file(&dir.path).exists());
    }

    #[test]
    fn empty_and_comment_files_return_defaults() {
        let dir = TempDir::new();
        let file = config_file(&dir.path);
        fs::write(&file, "   \n\t\n").unwrap();
        assert_eq!(
            load_project_config(&dir.path).unwrap(),
            ProjectConfig::default()
        );
        fs::write(&file, "# no settings yet\n").unwrap();
        assert_eq!(
            load_global_config(&dir.path).unwrap(),
            GlobalConfig::default()
        );
        let bytes = fs::read(&file).unwrap();
        let _ = load_project_config(&dir.path).unwrap();
        assert_eq!(fs::read(&file).unwrap(), bytes);
    }

    #[test]
    fn valid_files_load_typed_values() {
        let dir = TempDir::new();
        let file = config_file(&dir.path);
        fs::write(
            &file,
            "recent_projects = [\"/lab/one\", \"D:\\\\lab\\\\two\"]\n",
        )
        .unwrap();
        assert_eq!(
            load_global_config(&dir.path).unwrap(),
            GlobalConfig {
                recent_projects: vec!["/lab/one".to_string(), "D:\\lab\\two".to_string()],
            }
        );

        fs::write(
            &file,
            "\
data_root = \"measurements\"
default_view = \"tree\"
default_preset = \"science-single\"
",
        )
        .unwrap();
        assert_eq!(
            load_project_config(&dir.path).unwrap(),
            ProjectConfig {
                data_root: "measurements".to_string(),
                default_view: "tree".to_string(),
                default_preset: "science-single".to_string(),
            }
        );
    }

    #[test]
    fn omitted_project_fields_keep_defaults() {
        let dir = TempDir::new();
        fs::write(
            config_file(&dir.path),
            "default_preset = \"science-single\"\n",
        )
        .unwrap();
        let config = load_project_config(&dir.path).unwrap();
        assert_eq!(config.data_root, ProjectConfig::DEFAULT_DATA_ROOT);
        assert_eq!(config.default_view, ProjectConfig::DEFAULT_VIEW);
        assert_eq!(config.default_preset, "science-single");
    }

    #[test]
    fn wrong_types_name_the_file_and_the_field() {
        let cases = [
            ("data_root = 1\n", "data_root"),
            ("default_view = true\n", "default_view"),
            (
                "default_preset = { name = \"nature-single\" }\n",
                "default_preset",
            ),
        ];
        for (body, field) in cases {
            let dir = TempDir::new();
            let file = config_file(&dir.path);
            fs::write(&file, body).unwrap();
            let error = load_project_config(&dir.path).unwrap_err();
            assert_names_file_and_field(&error, &file, field);
            assert!(error.to_string().contains("expected a string"), "{error}");
        }
    }

    #[test]
    fn data_root_rejects_traversal_and_accepts_project_relative_paths() {
        let accepted = ["data/raw", ".", "measurements", "lab/batch_01"];
        for value in accepted {
            let dir = TempDir::new();
            let file = config_file(&dir.path);
            fs::write(&file, format!("data_root = {value:?}\n")).unwrap();
            let config = load_project_config(&dir.path).unwrap();
            assert_eq!(config.data_root, value);
        }

        let rejected = [
            ("../../../secrets", ".."),
            ("data/../../raw", ".."),
            ("/etc/passwd", "absolute"),
            ("C:/Windows", "absolute"),
            ("~/secrets", "home path"),
            ("data//raw", "empty"),
            ("data/./raw", "'.'"),
            ("data\\raw", "backslash"),
            ("", "empty"),
            ("   ", "empty"),
        ];
        for (value, needle) in rejected {
            let dir = TempDir::new();
            let file = config_file(&dir.path);
            fs::write(&file, format!("data_root = {value:?}\n")).unwrap();
            let error = load_project_config(&dir.path).unwrap_err();
            assert_names_file_and_field(&error, &file, "data_root");
            assert!(
                error.to_string().contains(needle),
                "value {value:?}: {error}"
            );
        }
    }

    #[test]
    fn section_table_is_an_unknown_field() {
        let dir = TempDir::new();
        let file = config_file(&dir.path);
        fs::write(&file, "[project]\ndata_root = \"data/raw\"\n").unwrap();
        let error = load_project_config(&dir.path).unwrap_err();
        assert_names_file_and_field(&error, &file, "project");
        assert!(error.to_string().contains("unknown field"), "{error}");
    }

    #[test]
    fn unknown_field_names_the_file_and_the_field() {
        let dir = TempDir::new();
        let file = config_file(&dir.path);
        fs::write(&file, "theme = \"dark\"\n").unwrap();
        let error = load_project_config(&dir.path).unwrap_err();
        assert_names_file_and_field(&error, &file, "theme");
        assert!(error.to_string().contains("unknown field"), "{error}");

        fs::write(&file, "recent_projects = []\n").unwrap();
        let error = load_project_config(&dir.path).unwrap_err();
        assert_names_file_and_field(&error, &file, "recent_projects");
    }

    #[test]
    fn malformed_recent_projects_names_the_field() {
        let dir = TempDir::new();
        let file = config_file(&dir.path);
        fs::write(&file, "recent_projects = \"/lab\"\n").unwrap();
        let error = load_global_config(&dir.path).unwrap_err();
        assert_names_file_and_field(&error, &file, "recent_projects");
        assert!(error.to_string().contains("array"), "{error}");

        fs::write(&file, "recent_projects = [\"/ok\", 2]\n").unwrap();
        let error = load_global_config(&dir.path).unwrap_err();
        assert_names_file_and_field(&error, &file, "recent_projects");
        let message = error.to_string();
        assert!(message.contains("index 1"), "{message}");
        assert!(message.contains("integer"), "{message}");
    }

    #[test]
    fn invalid_toml_names_the_file() {
        let dir = TempDir::new();
        let file = config_file(&dir.path);
        fs::write(&file, "data_root = \"unterminated\n").unwrap();
        let error = load_project_config(&dir.path).unwrap_err();
        assert_eq!(error.path(), file.as_path());
        assert_eq!(error.field(), None);
        let message = error.to_string();
        assert!(message.contains(&file.display().to_string()), "{message}");
        assert!(message.contains("malformed"), "{message}");
    }

    #[test]
    fn directory_where_a_file_was_expected_names_the_file() {
        let dir = TempDir::new();
        let file = config_file(&dir.path);
        fs::create_dir(&file).unwrap();
        let error = load_global_config(&dir.path).unwrap_err();
        assert_eq!(error.path(), file.as_path());
        assert!(error.to_string().contains("failed to read"), "{error}");
    }

    #[cfg(unix)]
    #[test]
    fn read_only_directory_without_a_file_returns_defaults() {
        let dir = TempDir::new();
        let mut permissions = fs::metadata(&dir.path).unwrap().permissions();
        permissions.set_readonly(true);
        fs::set_permissions(&dir.path, permissions).unwrap();
        assert_eq!(
            load_project_config(&dir.path).unwrap(),
            ProjectConfig::default()
        );
        assert!(!config_file(&dir.path).exists());
    }
}
