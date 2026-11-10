//! Typed project settings stored in `.raw-viewer/config.yaml`.
//!
//! A missing file loads defaults. A present file must declare `schema_version: 1`.
//! Loading does not create directories or write files.

use crate::yaml::{parse, YamlNode};
use std::fmt;
use std::fs;
use std::io;
use std::path::{Path, PathBuf};

use crate::paths::{
    LEGACY_SETTING_DIRECTORY_NAME, LEGACY_SETTING_FILE, PROJECT_CONFIG_DIRECTORY_NAME,
    PROJECT_CONFIG_FILE, VIEWER_METADATA_NAMESPACES,
};

use serde::{Deserialize, Serialize};

/// Settings for enabled/disabled built-in profiles.
#[derive(Debug, Clone, PartialEq, Eq, Default, Serialize, Deserialize)]
pub struct ProfilesConfig {
    pub enabled: Option<Vec<String>>,
    pub disabled: Vec<String>,
}

/// Settings from a project's `.raw-viewer` directory.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ProjectConfig {
    /// Present when loaded from a file (`1` only). Absent when defaults apply.
    pub schema_version: Option<u32>,
    pub data_root: String,
    pub default_view: String,
    pub default_preset: String,
    pub explorer_views: Vec<String>,
    pub source_labels: Vec<String>,
    pub profiles: ProfilesConfig,
    pub recent_projects: Vec<String>,
    pub tree_grouping: Option<Vec<String>>,
    pub grammar: Option<crate::grammar::FilenameGrammar>,
}

impl ProjectConfig {
    pub const DEFAULT_DATA_ROOT: &'static str = "data/raw";
    pub const DEFAULT_VIEW: &'static str = "tree";
    pub const DEFAULT_PRESET: &'static str = "nature-single";
    pub const REQUIRED_SCHEMA_VERSION: u32 = 1;
}

impl Default for ProjectConfig {
    fn default() -> Self {
        Self {
            schema_version: None,
            data_root: Self::DEFAULT_DATA_ROOT.to_string(),
            default_view: Self::DEFAULT_VIEW.to_string(),
            default_preset: Self::DEFAULT_PRESET.to_string(),
            explorer_views: Vec::new(),
            source_labels: Vec::new(),
            profiles: ProfilesConfig::default(),
            recent_projects: Vec::new(),
            tree_grouping: None,
            grammar: None,
        }
    }
}

/// Failure to load a config file.
#[derive(Debug)]
pub enum ConfigError {
    Read {
        path: PathBuf,
        source: io::Error,
    },
    Malformed {
        path: PathBuf,
        field: Option<String>,
        detail: String,
    },
}

impl ConfigError {
    pub fn path(&self) -> &Path {
        match self {
            Self::Read { path, .. } | Self::Malformed { path, .. } => path,
        }
    }

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

/// Path of `config.yaml` inside a project's metadata directory.
pub fn project_config_file(project_root: &Path) -> PathBuf {
    project_root
        .join(PROJECT_CONFIG_DIRECTORY_NAME)
        .join(PROJECT_CONFIG_FILE)
}

/// Path of `config.yaml` inside `config_dir` (the `.raw-viewer` directory).
pub fn config_file(config_dir: &Path) -> PathBuf {
    config_dir.join(PROJECT_CONFIG_FILE)
}

/// Load project settings from `<project>/.raw-viewer/config.yaml`.
///
/// The `config_dir` argument is the `.raw-viewer` directory itself.
pub fn load_project_config(config_dir: &Path) -> Result<ProjectConfig, ConfigError> {
    let path = config_file(config_dir);
    let text = match fs::read_to_string(&path) {
        Ok(text) => text,
        Err(source) if source.kind() == io::ErrorKind::NotFound => {
            return Ok(ProjectConfig::default());
        }
        Err(source) => {
            return Err(ConfigError::Read {
                path: path.to_path_buf(),
                source,
            });
        }
    };
    if text.trim().is_empty() {
        return Err(ConfigError::malformed(
            &path,
            Some("schema_version".into()),
            "required".into(),
        ));
    }
    parse_project_yaml(&path, &text, false)
}

/// Load project settings with legacy fallback.
///
/// Tries `<project>/.raw-viewer/config.yaml` first, then falls back to
/// `<project>/.rawviewer/setting.yaml`. Returns defaults only when both are
/// proven absent. A malformed file at either path produces a typed error;
/// fallback does not swallow errors.
pub fn load_project_config_with_fallback(
    project_root: &Path,
) -> Result<ProjectConfig, ConfigError> {
    let config_dir = project_root.join(PROJECT_CONFIG_DIRECTORY_NAME);
    let config_path = config_file(&config_dir);
    let has_config = fs::metadata(&config_path)
        .map(|meta| meta.is_file())
        .unwrap_or(false);
    if has_config {
        return load_project_config(&config_dir);
    }
    load_legacy_setting(project_root)
}

fn load_legacy_setting(project_root: &Path) -> Result<ProjectConfig, ConfigError> {
    let path = project_root
        .join(LEGACY_SETTING_DIRECTORY_NAME)
        .join(LEGACY_SETTING_FILE);
    let text = match fs::read_to_string(&path) {
        Ok(text) => text,
        Err(source) if source.kind() == io::ErrorKind::NotFound => {
            return Ok(ProjectConfig::default());
        }
        Err(source) => {
            return Err(ConfigError::Read {
                path: path.to_path_buf(),
                source,
            });
        }
    };
    if text.trim().is_empty() {
        return Err(ConfigError::malformed(
            &path,
            Some("schema_version".into()),
            "required".into(),
        ));
    }
    parse_project_yaml(&path, &text, true)
}

fn parse_project_yaml(
    path: &Path,
    text: &str,
    is_legacy: bool,
) -> Result<ProjectConfig, ConfigError> {
    let root = parse(text, false)
        .map_err(|error| ConfigError::malformed(path, None, error.to_string()))?;
    let entries = root
        .map_entries()
        .ok_or_else(|| ConfigError::malformed(path, None, "expected a YAML mapping".into()))?;
    let mut config = ProjectConfig::default();
    let mut saw_schema_version = false;
    for (key, value) in entries {
        if key == "developer_mode" {
            continue;
        }
        match key.as_str() {
            "schema_version" => {
                saw_schema_version = true;
                config.schema_version = Some(expect_schema_version(path, value, is_legacy)?);
            }
            "data_root" => config.data_root = expect_data_root(path, value)?,
            "default_view" => config.default_view = expect_string(path, "default_view", value)?,
            "default_preset" => {
                config.default_preset = expect_string(path, "default_preset", value)?;
            }
            "explorer_views" => {
                config.explorer_views = expect_string_array(path, "explorer_views", value)?;
            }
            "source_labels" => {
                config.source_labels = expect_string_array(path, "source_labels", value)?;
            }
            "profiles" => {
                config.profiles = expect_profiles_config(path, value)?;
            }
            "recent_projects" => {
                config.recent_projects = expect_string_array(path, "recent_projects", value)?;
            }
            "tree_grouping" => {
                config.tree_grouping = Some(expect_string_array(path, "tree_grouping", value)?);
            }
            "explorer" => {
                let map = value.map_entries().ok_or_else(|| {
                    ConfigError::malformed(
                        path,
                        Some("explorer".into()),
                        "expected a YAML mapping".into(),
                    )
                })?;
                for (ek, ev) in map {
                    match ek.as_str() {
                        "grouping_mode" => {
                            config.default_view =
                                expect_string(path, "explorer.grouping_mode", ev)?;
                        }
                        "grouping_fields" => {
                            config.tree_grouping =
                                Some(expect_string_array(path, "explorer.grouping_fields", ev)?);
                        }
                        _ => {
                            return Err(ConfigError::malformed(
                                path,
                                Some(format!("explorer.{ek}")),
                                "unknown field".into(),
                            ));
                        }
                    }
                }
            }
            "grammar" => {
                let grammar = crate::grammar::parse_single_grammar_node(value)
                    .map_err(|err| ConfigError::malformed(path, Some("grammar".into()), err))?;
                config.grammar = Some(grammar);
            }
            _ => {
                return Err(ConfigError::malformed(
                    path,
                    Some(key.clone()),
                    "unknown field".into(),
                ));
            }
        }
    }
    if !saw_schema_version {
        return Err(ConfigError::malformed(
            path,
            Some("schema_version".into()),
            "required".into(),
        ));
    }
    Ok(config)
}

fn expect_profiles_config(path: &Path, value: &YamlNode) -> Result<ProfilesConfig, ConfigError> {
    let entries = value.map_entries().ok_or_else(|| {
        ConfigError::malformed(
            path,
            Some("profiles".into()),
            format!("expected a mapping, found {}", yaml_kind(value)),
        )
    })?;
    let mut enabled: Option<Vec<String>> = None;
    let mut disabled: Vec<String> = Vec::new();
    for (key, val) in entries {
        match key.as_str() {
            "enabled" => {
                enabled = Some(expect_string_array(path, "profiles.enabled", val)?);
            }
            "disabled" => {
                disabled = expect_string_array(path, "profiles.disabled", val)?;
            }
            _ => {
                return Err(ConfigError::malformed(
                    path,
                    Some(format!("profiles.{key}")),
                    "unknown field; expected enabled, disabled".into(),
                ));
            }
        }
    }
    if let Some(ref en) = enabled {
        for id in en {
            if disabled.contains(id) {
                return Err(ConfigError::malformed(
                    path,
                    Some("profiles".into()),
                    format!("profile id '{id}' cannot be in both profiles.enabled and profiles.disabled"),
                ));
            }
        }
    }
    Ok(ProfilesConfig { enabled, disabled })
}

fn expect_schema_version(
    path: &Path,
    value: &YamlNode,
    is_legacy: bool,
) -> Result<u32, ConfigError> {
    let text = value.scalar_value().ok_or_else(|| {
        ConfigError::malformed(
            path,
            Some("schema_version".into()),
            format!("expected an integer, found {}", yaml_kind(value)),
        )
    })?;
    let version: u32 = text.parse().map_err(|_| {
        ConfigError::malformed(
            path,
            Some("schema_version".into()),
            format!("expected an integer, found {text:?}"),
        )
    })?;
    if is_legacy {
        if !(1..=3).contains(&version) {
            return Err(ConfigError::malformed(
                path,
                Some("schema_version".into()),
                "must be 1, 2, or 3".into(),
            ));
        }
    } else if version != ProjectConfig::REQUIRED_SCHEMA_VERSION {
        return Err(ConfigError::malformed(
            path,
            Some("schema_version".into()),
            format!("must be {}", ProjectConfig::REQUIRED_SCHEMA_VERSION),
        ));
    }
    Ok(version)
}

fn expect_data_root(path: &Path, value: &YamlNode) -> Result<String, ConfigError> {
    let text = expect_string(path, "data_root", value)?;
    if let Some(detail) = data_root_problem(&text) {
        return Err(ConfigError::malformed(
            path,
            Some("data_root".into()),
            detail,
        ));
    }
    Ok(text)
}

fn data_root_problem(value: &str) -> Option<String> {
    if value.trim().is_empty() {
        return Some("must not be empty".into());
    }
    if value.chars().any(|c| c.is_control() || c == '\\') {
        return Some("must not contain backslashes or control characters".into());
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
    if is_viewer_metadata_namespace(value) {
        return Some(format!(
            "must not be a RawView viewer metadata or snapshot namespace (got {value:?})"
        ));
    }
    None
}

fn is_viewer_metadata_namespace(value: &str) -> bool {
    for ns in VIEWER_METADATA_NAMESPACES {
        if value == ns || value.starts_with(&format!("{ns}/")) {
            return true;
        }
    }
    false
}

fn has_windows_drive_prefix(value: &str) -> bool {
    let mut chars = value.chars();
    matches!(
        (chars.next(), chars.next()),
        (Some(letter), Some(':')) if letter.is_ascii_alphabetic()
    )
}

fn expect_string(path: &Path, field: &str, value: &YamlNode) -> Result<String, ConfigError> {
    match value {
        YamlNode::Scalar(text) => Ok(text.clone()),
        _ => Err(ConfigError::malformed(
            path,
            Some(field.into()),
            format!("expected a string, found {}", yaml_kind(value)),
        )),
    }
}

fn expect_string_array(
    path: &Path,
    field: &str,
    value: &YamlNode,
) -> Result<Vec<String>, ConfigError> {
    let items = value.list_items().ok_or_else(|| {
        ConfigError::malformed(
            path,
            Some(field.into()),
            format!("expected a list of strings, found {}", yaml_kind(value)),
        )
    })?;
    let mut strings = Vec::with_capacity(items.len());
    for (index, item) in items.iter().enumerate() {
        match item.scalar_value() {
            Some(text) => strings.push(text.to_string()),
            None => {
                return Err(ConfigError::malformed(
                    path,
                    Some(field.into()),
                    format!(
                        "expected a string, found {} at index {index}",
                        yaml_kind(item)
                    ),
                ));
            }
        }
    }
    Ok(strings)
}

fn yaml_kind(value: &YamlNode) -> &'static str {
    match value {
        YamlNode::Scalar(_) => "a string",
        YamlNode::List(_) => "a list",
        YamlNode::Map(_) => "a mapping",
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicU64, Ordering};
    use std::time::{SystemTime, UNIX_EPOCH};

    static TEMP_DIR_COUNTER: AtomicU64 = AtomicU64::new(0);

    struct TempDir {
        path: PathBuf,
    }

    impl TempDir {
        fn new() -> Self {
            let unique = TEMP_DIR_COUNTER.fetch_add(1, Ordering::Relaxed);
            let path = std::env::temp_dir().join(format!(
                "raw-viewer-cfg-{}-{}-{}",
                std::process::id(),
                SystemTime::now()
                    .duration_since(UNIX_EPOCH)
                    .expect("clock")
                    .as_nanos(),
                unique
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
            load_project_config(&dir.path).unwrap(),
            ProjectConfig {
                schema_version: None,
                data_root: "data/raw".to_string(),
                default_view: "tree".to_string(),
                default_preset: "nature-single".to_string(),
                explorer_views: Vec::new(),
                source_labels: Vec::new(),
                profiles: ProfilesConfig::default(),
                recent_projects: Vec::new(),
                tree_grouping: None,
                grammar: None,
            }
        );
        assert_eq!(fs::read_dir(&dir.path).unwrap().count(), before);
        assert!(!config_file(&dir.path).exists());
    }

    #[test]
    fn empty_file_requires_schema_version() {
        let dir = TempDir::new();
        let file = config_file(&dir.path);
        fs::write(&file, "   \n\t\n").unwrap();
        let error = load_project_config(&dir.path).unwrap_err();
        assert_names_file_and_field(&error, &file, "schema_version");
        assert!(error.to_string().contains("required"), "{error}");
    }

    #[test]
    fn valid_yaml_loads_typed_values() {
        let dir = TempDir::new();
        let file = config_file(&dir.path);
        fs::write(
            &file,
            "\
schema_version: 1
data_root: measurements
default_view: tree
default_preset: science-single
explorer_views: [tree, plot]
source_labels: [row-a, row-b]
tree_grouping: [instrument, mode]
",
        )
        .unwrap();
        assert_eq!(
            load_project_config(&dir.path).unwrap(),
            ProjectConfig {
                schema_version: Some(1),
                data_root: "measurements".to_string(),
                default_view: "tree".to_string(),
                default_preset: "science-single".to_string(),
                explorer_views: vec!["tree".into(), "plot".into()],
                source_labels: vec!["row-a".into(), "row-b".into()],
                profiles: ProfilesConfig::default(),
                recent_projects: Vec::new(),
                tree_grouping: Some(vec!["instrument".into(), "mode".into()]),
                grammar: None,
            }
        );
    }

    #[test]
    fn omitted_project_fields_keep_defaults() {
        let dir = TempDir::new();
        fs::write(
            config_file(&dir.path),
            "schema_version: 1\ndefault_preset: science-single\n",
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
            ("schema_version: 1\ndata_root: [1]\n", "data_root"),
            ("schema_version: 1\ndefault_view: [tree]\n", "default_view"),
            (
                "schema_version: 1\ndefault_preset: [nature-single]\n",
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
            fs::write(&file, format!("schema_version: 1\ndata_root: {value:?}\n")).unwrap();
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
        ];
        for (value, needle) in rejected {
            let dir = TempDir::new();
            let file = config_file(&dir.path);
            fs::write(&file, format!("schema_version: 1\ndata_root: {value:?}\n")).unwrap();
            let error = load_project_config(&dir.path).unwrap_err();
            assert_names_file_and_field(&error, &file, "data_root");
            assert!(
                error.to_string().contains(needle),
                "value {value:?}: {error}"
            );
        }

        let dir = TempDir::new();
        let file = config_file(&dir.path);
        fs::write(&file, "schema_version: 1\ndata_root: \"\"\n").unwrap();
        let error = load_project_config(&dir.path).unwrap_err();
        assert_names_file_and_field(&error, &file, "data_root");
        assert!(error.to_string().contains("must not be empty"), "{error}");
    }

    #[test]
    fn missing_schema_version_returns_typed_error() {
        let dir = TempDir::new();
        let file = config_file(&dir.path);
        fs::write(&file, "data_root: data/raw\n").unwrap();
        let error = load_project_config(&dir.path).unwrap_err();
        assert_names_file_and_field(&error, &file, "schema_version");
        assert!(error.to_string().contains("required"), "{error}");
    }

    #[test]
    fn schema_version_two_returns_typed_error() {
        let dir = TempDir::new();
        let file = config_file(&dir.path);
        fs::write(&file, "schema_version: 2\ndata_root: data/raw\n").unwrap();
        let error = load_project_config(&dir.path).unwrap_err();
        assert_names_file_and_field(&error, &file, "schema_version");
        assert!(error.to_string().contains("must be 1"), "{error}");
    }

    #[test]
    fn developer_mode_is_ignored_without_error() {
        let dir = TempDir::new();
        fs::write(
            config_file(&dir.path),
            "schema_version: 1\ndeveloper_mode: true\ndata_root: data/raw\n",
        )
        .unwrap();
        let config = load_project_config(&dir.path).unwrap();
        assert_eq!(config.schema_version, Some(1));
        assert_eq!(config.data_root, "data/raw");
    }

    #[test]
    fn unknown_field_names_the_file_and_the_field() {
        let dir = TempDir::new();
        let file = config_file(&dir.path);
        fs::write(&file, "schema_version: 1\ntheme: dark\n").unwrap();
        let error = load_project_config(&dir.path).unwrap_err();
        assert_names_file_and_field(&error, &file, "theme");
        assert!(error.to_string().contains("unknown field"), "{error}");
    }

    #[test]
    fn nested_mapping_is_an_unknown_field() {
        let dir = TempDir::new();
        let file = config_file(&dir.path);
        fs::write(
            &file,
            "schema_version: 1\nproject:\n  data_root: data/raw\n",
        )
        .unwrap();
        let error = load_project_config(&dir.path).unwrap_err();
        assert_names_file_and_field(&error, &file, "project");
        assert!(error.to_string().contains("unknown field"), "{error}");
    }

    #[test]
    fn invalid_yaml_names_the_file() {
        let dir = TempDir::new();
        let file = config_file(&dir.path);
        fs::write(&file, "schema_version: 1\ndata_root: \"unterminated\n").unwrap();
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
        let error = load_project_config(&dir.path).unwrap_err();
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
