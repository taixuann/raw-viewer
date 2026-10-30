//! Config and cache locations.
//!
//! [`resolve_paths`] is a pure function of the target operating system, the home
//! directory, environment variables, and a callback that reports which directories
//! exist. [`resolve_paths_from_env`] is the thin wrapper that reads the process
//! environment. The wrapper uses the [`directories`] crate for the home directory
//! and, on Windows, for the roaming and local app-data folders.
//!
//! Reads do not create directories.

use std::env;
use std::fmt;
use std::path::Path;

/// Directory name used for global config and cache locations.
pub const APP_DIRECTORY_NAME: &str = "raw-viewer";

/// Directory name used for project config, directly under the project root.
pub const PROJECT_CONFIG_DIRECTORY_NAME: &str = ".raw-viewer";

/// Operating system whose path rules should be applied.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TargetOs {
    /// Linux and other non-Apple Unix systems. Paths use `/`.
    Linux,
    /// macOS. Paths use `/`.
    MacOs,
    /// Windows. Paths use `\`.
    Windows,
}

impl TargetOs {
    /// Operating system this process was built for.
    pub fn host() -> Self {
        if cfg!(target_os = "windows") {
            Self::Windows
        } else if cfg!(any(target_os = "macos", target_os = "ios")) {
            Self::MacOs
        } else {
            Self::Linux
        }
    }
}

/// Injected inputs for [`resolve_paths`].
///
/// Strings are paths for `os`, not necessarily for the machine running the tests.
/// Empty strings are treated as unset. Relative `XDG_CONFIG_HOME` and
/// `XDG_CACHE_HOME` values are ignored, matching the `directories` crate.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PathInputs {
    /// Target operating system.
    pub os: TargetOs,
    /// Home directory. Required for Linux and macOS platform defaults.
    pub home: Option<String>,
    /// `XDG_CONFIG_HOME`. Used on every operating system when
    /// `$XDG_CONFIG_HOME/raw-viewer` exists.
    pub xdg_config_home: Option<String>,
    /// `XDG_CACHE_HOME`. Honored on Linux when it is absolute.
    pub xdg_cache_home: Option<String>,
    /// Windows roaming app data (`%APPDATA%`). The host wrapper fills this from
    /// `directories::BaseDirs::config_dir`.
    pub app_data: Option<String>,
    /// Windows local app data (`%LOCALAPPDATA%`). The host wrapper fills this from
    /// `directories::BaseDirs::cache_dir`.
    pub local_app_data: Option<String>,
    /// Project root. The project config directory is `<project_root>/.raw-viewer`.
    pub project_root: String,
}

/// Directories selected for one project.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ResolvedPaths {
    /// Global config directory. `config.toml` lives here.
    pub global_config_dir: String,
    /// Project config directory. `config.toml` lives here.
    pub project_config_dir: String,
    /// Cache directory. This is never a path under `.raw-viewer`.
    pub cache_dir: String,
}

/// Failure to resolve a directory from the injected inputs.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ResolveError {
    /// Home is unset and a path needs it.
    MissingHome,
    /// Home is set but is not absolute.
    HomeNotAbsolute,
    /// Windows roaming app data is unset and the platform config directory needs it.
    MissingAppData,
    /// Windows roaming app data is set but is not absolute.
    AppDataNotAbsolute,
    /// Windows local app data is unset and the cache directory needs it.
    MissingLocalAppData,
    /// Windows local app data is set but is not absolute.
    LocalAppDataNotAbsolute,
    /// The project root is empty or only whitespace.
    EmptyProjectRoot,
    /// A filesystem path is not valid UTF-8.
    PathNotUtf8 {
        /// What the path was for, such as "home directory".
        what: &'static str,
    },
    /// An environment variable is not valid UTF-8.
    EnvNotUtf8 {
        /// Environment variable name.
        name: &'static str,
    },
}

impl fmt::Display for ResolveError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::MissingHome => write!(
                f,
                "home directory is not set; it is required to resolve RawView paths"
            ),
            Self::HomeNotAbsolute => write!(f, "home directory must be an absolute path"),
            Self::MissingAppData => write!(
                f,
                "APPDATA is not set; it is required for the Windows config directory"
            ),
            Self::AppDataNotAbsolute => write!(f, "APPDATA must be an absolute path"),
            Self::MissingLocalAppData => write!(
                f,
                "the Windows local app data directory is not set; it is required for the cache directory"
            ),
            Self::LocalAppDataNotAbsolute => {
                write!(f, "the Windows local app data directory must be an absolute path")
            }
            Self::EmptyProjectRoot => write!(f, "project root is empty"),
            Self::PathNotUtf8 { what } => write!(f, "{what} is not valid UTF-8"),
            Self::EnvNotUtf8 { name } => {
                write!(f, "environment variable {name} is not valid UTF-8")
            }
        }
    }
}

impl std::error::Error for ResolveError {}

/// Resolve global config, project config, and cache directories.
///
/// `dir_exists` is called with a normalized path and must return true only when
/// that path is an existing directory. The callback may borrow the path only for
/// the duration of the call. This function does not touch the filesystem itself.
///
/// Global config order:
/// 1. `$XDG_CONFIG_HOME/raw-viewer` when that directory exists.
/// 2. `~/.config/raw-viewer` when that directory exists.
/// 3. The platform default: `~/.config/raw-viewer` on Linux,
///    `~/Library/Application Support/raw-viewer` on macOS, and
///    `%APPDATA%\raw-viewer` on Windows.
///
/// The cache directory is the platform cache directory plus `raw-viewer`.
/// On Linux the platform cache directory is `$XDG_CACHE_HOME` when that value is
/// absolute, otherwise `~/.cache`. macOS uses `~/Library/Caches`. Windows uses
/// local app data.
pub fn resolve_paths(
    inputs: &PathInputs,
    mut dir_exists: impl FnMut(&str) -> bool,
) -> Result<ResolvedPaths, ResolveError> {
    let env = normalize(inputs)?;
    let global_config_dir = resolve_global_config_dir(&env, &mut dir_exists)?;
    let cache_dir = resolve_cache_dir(&env)?;
    let project_config_dir = join(env.os, &env.project_root, PROJECT_CONFIG_DIRECTORY_NAME);
    Ok(ResolvedPaths {
        global_config_dir,
        project_config_dir,
        cache_dir,
    })
}

/// Read the process environment and resolve paths for `project_root`.
///
/// This does not create directories. Home, and the Windows config and cache
/// bases, come from [`directories::BaseDirs`].
pub fn resolve_paths_from_env(project_root: &Path) -> Result<ResolvedPaths, ResolveError> {
    let inputs = path_inputs_from_host(project_root)?;
    resolve_paths(&inputs, host_dir_exists)
}

fn path_inputs_from_host(project_root: &Path) -> Result<PathInputs, ResolveError> {
    let os = TargetOs::host();
    let project_root = path_to_utf8(project_root, "project root")?;
    let base = directories::BaseDirs::new();
    let home = match &base {
        Some(dirs) => Some(path_to_utf8(dirs.home_dir(), "home directory")?),
        None => env_path(if os == TargetOs::Windows {
            "USERPROFILE"
        } else {
            "HOME"
        })?,
    };
    let (app_data, local_app_data) = if os == TargetOs::Windows {
        match &base {
            Some(dirs) => (
                Some(path_to_utf8(dirs.config_dir(), "APPDATA")?),
                Some(path_to_utf8(dirs.cache_dir(), "LOCALAPPDATA")?),
            ),
            None => (env_path("APPDATA")?, env_path("LOCALAPPDATA")?),
        }
    } else {
        (None, None)
    };
    Ok(PathInputs {
        os,
        home,
        xdg_config_home: env_path("XDG_CONFIG_HOME")?,
        xdg_cache_home: env_path("XDG_CACHE_HOME")?,
        app_data,
        local_app_data,
        project_root,
    })
}

fn host_dir_exists(path: &str) -> bool {
    Path::new(path).is_dir()
}

fn env_path(name: &'static str) -> Result<Option<String>, ResolveError> {
    match env::var(name) {
        Ok(value) => {
            let trimmed = value.trim();
            if trimmed.is_empty() {
                Ok(None)
            } else {
                Ok(Some(trimmed.to_string()))
            }
        }
        Err(env::VarError::NotPresent) => Ok(None),
        Err(env::VarError::NotUnicode(_)) => Err(ResolveError::EnvNotUtf8 { name }),
    }
}

fn path_to_utf8(path: &Path, what: &'static str) -> Result<String, ResolveError> {
    path.to_str()
        .map(ToOwned::to_owned)
        .ok_or(ResolveError::PathNotUtf8 { what })
}

struct Normalized {
    os: TargetOs,
    home: Option<String>,
    xdg_config_home: Option<String>,
    xdg_cache_home: Option<String>,
    app_data: Option<String>,
    local_app_data: Option<String>,
    project_root: String,
}

fn normalize(inputs: &PathInputs) -> Result<Normalized, ResolveError> {
    let project_root =
        normalize_path(inputs.os, &inputs.project_root).ok_or(ResolveError::EmptyProjectRoot)?;
    let home = match inputs.home.as_deref() {
        None => None,
        Some(value) => match normalize_path(inputs.os, value) {
            None => None,
            Some(path) if is_absolute(inputs.os, &path) => Some(path),
            Some(_) => return Err(ResolveError::HomeNotAbsolute),
        },
    };
    let app_data = optional_absolute(inputs.os, inputs.app_data.as_deref())
        .map_err(|_| ResolveError::AppDataNotAbsolute)?;
    let local_app_data = optional_absolute(inputs.os, inputs.local_app_data.as_deref())
        .map_err(|_| ResolveError::LocalAppDataNotAbsolute)?;
    let xdg_config_home = ignore_relative(inputs.os, inputs.xdg_config_home.as_deref());
    let xdg_cache_home = if inputs.os == TargetOs::Linux {
        ignore_relative(inputs.os, inputs.xdg_cache_home.as_deref())
    } else {
        None
    };
    Ok(Normalized {
        os: inputs.os,
        home,
        xdg_config_home,
        xdg_cache_home,
        app_data,
        local_app_data,
        project_root,
    })
}

fn optional_absolute(os: TargetOs, value: Option<&str>) -> Result<Option<String>, ()> {
    match value {
        None => Ok(None),
        Some(value) => match normalize_path(os, value) {
            None => Ok(None),
            Some(path) if is_absolute(os, &path) => Ok(Some(path)),
            Some(_) => Err(()),
        },
    }
}

fn ignore_relative(os: TargetOs, value: Option<&str>) -> Option<String> {
    let path = normalize_path(os, value?)?;
    if is_absolute(os, &path) {
        Some(path)
    } else {
        None
    }
}

fn resolve_global_config_dir(
    env: &Normalized,
    dir_exists: &mut impl FnMut(&str) -> bool,
) -> Result<String, ResolveError> {
    if let Some(xdg) = &env.xdg_config_home {
        let candidate = join(env.os, xdg, APP_DIRECTORY_NAME);
        if dir_exists(&candidate) {
            return Ok(candidate);
        }
    }
    if let Some(home) = &env.home {
        let dot_config = join(env.os, home, ".config");
        let candidate = join(env.os, &dot_config, APP_DIRECTORY_NAME);
        if dir_exists(&candidate) {
            return Ok(candidate);
        }
    }
    platform_config_dir(env)
}

fn platform_config_dir(env: &Normalized) -> Result<String, ResolveError> {
    // These joins follow `directories::BaseDirs::config_dir`, then add
    // `raw-viewer`. Linux uses `$HOME/.config` even when `XDG_CONFIG_HOME` is
    // set, because that variable is only an override when `raw-viewer` exists
    // there. `BaseDirs::config_dir` on Linux already folds the variable in, so
    // the host wrapper does not pass that getter through for the Linux default.
    match env.os {
        TargetOs::Linux => {
            let home = require_home(env)?;
            let base = join(env.os, &home, ".config");
            Ok(join(env.os, &base, APP_DIRECTORY_NAME))
        }
        TargetOs::MacOs => {
            let home = require_home(env)?;
            let library = join(env.os, &home, "Library");
            let support = join(env.os, &library, "Application Support");
            Ok(join(env.os, &support, APP_DIRECTORY_NAME))
        }
        TargetOs::Windows => {
            let app_data = env.app_data.clone().ok_or(ResolveError::MissingAppData)?;
            Ok(join(env.os, &app_data, APP_DIRECTORY_NAME))
        }
    }
}

fn resolve_cache_dir(env: &Normalized) -> Result<String, ResolveError> {
    // Cache base matches `directories::BaseDirs::cache_dir`.
    let base = match env.os {
        TargetOs::Linux => {
            if let Some(xdg_cache) = &env.xdg_cache_home {
                xdg_cache.clone()
            } else {
                join(env.os, &require_home(env)?, ".cache")
            }
        }
        TargetOs::MacOs => {
            let home = require_home(env)?;
            let library = join(env.os, &home, "Library");
            join(env.os, &library, "Caches")
        }
        TargetOs::Windows => env
            .local_app_data
            .clone()
            .ok_or(ResolveError::MissingLocalAppData)?,
    };
    Ok(join(env.os, &base, APP_DIRECTORY_NAME))
}

fn require_home(env: &Normalized) -> Result<String, ResolveError> {
    env.home.clone().ok_or(ResolveError::MissingHome)
}

fn separator(os: TargetOs) -> char {
    match os {
        TargetOs::Windows => '\\',
        TargetOs::Linux | TargetOs::MacOs => '/',
    }
}

fn normalize_path(os: TargetOs, raw: &str) -> Option<String> {
    let trimmed = raw.trim();
    if trimmed.is_empty() {
        return None;
    }
    let converted = if os == TargetOs::Windows {
        trimmed.replace('/', "\\")
    } else {
        trimmed.to_string()
    };
    let stripped = strip_trailing_separators(os, &converted);
    if stripped.is_empty() {
        None
    } else {
        Some(stripped)
    }
}

fn strip_trailing_separators(os: TargetOs, path: &str) -> String {
    if is_filesystem_root(os, path) {
        return path.to_string();
    }
    let sep = separator(os);
    if path.chars().all(|c| c == sep) {
        return sep.to_string();
    }
    let trimmed = path.trim_end_matches(sep);
    if trimmed.is_empty() {
        return sep.to_string();
    }
    if os == TargetOs::Windows && is_drive_prefix(trimmed) {
        return format!("{trimmed}\\");
    }
    trimmed.to_string()
}

fn join(os: TargetOs, base: &str, child: &str) -> String {
    let child = child.trim_matches(|c| c == '/' || c == '\\');
    debug_assert!(
        !child.is_empty(),
        "refusing to join an empty path component"
    );
    let base = strip_trailing_separators(os, base);
    if is_filesystem_root(os, &base) {
        format!("{base}{child}")
    } else {
        format!("{base}{}{child}", separator(os))
    }
}

fn is_absolute(os: TargetOs, path: &str) -> bool {
    match os {
        TargetOs::Windows => is_unc(path) || is_drive_absolute(path),
        TargetOs::Linux | TargetOs::MacOs => path.starts_with('/'),
    }
}

fn is_filesystem_root(os: TargetOs, path: &str) -> bool {
    match os {
        TargetOs::Windows => path == "\\" || is_drive_root(path),
        TargetOs::Linux | TargetOs::MacOs => path == "/",
    }
}

fn is_drive_absolute(path: &str) -> bool {
    let mut chars = path.chars();
    matches!(
        (chars.next(), chars.next(), chars.next()),
        (Some(letter), Some(':'), Some('\\')) if letter.is_ascii_alphabetic()
    )
}

fn is_drive_root(path: &str) -> bool {
    let mut chars = path.chars();
    matches!(
        (chars.next(), chars.next(), chars.next(), chars.next()),
        (Some(letter), Some(':'), Some('\\'), None) if letter.is_ascii_alphabetic()
    )
}

fn is_drive_prefix(path: &str) -> bool {
    let mut chars = path.chars();
    matches!(
        (chars.next(), chars.next(), chars.next()),
        (Some(letter), Some(':'), None) if letter.is_ascii_alphabetic()
    )
}

fn is_unc(path: &str) -> bool {
    path.starts_with("\\\\")
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;

    const OSES: [TargetOs; 3] = [TargetOs::Linux, TargetOs::MacOs, TargetOs::Windows];

    fn sample(os: TargetOs) -> PathInputs {
        match os {
            TargetOs::Linux => PathInputs {
                os,
                home: Some("/home/alice".to_string()),
                xdg_config_home: None,
                xdg_cache_home: None,
                app_data: None,
                local_app_data: None,
                project_root: "/lab/project".to_string(),
            },
            TargetOs::MacOs => PathInputs {
                os,
                home: Some("/Users/alice".to_string()),
                xdg_config_home: None,
                xdg_cache_home: None,
                app_data: None,
                local_app_data: None,
                project_root: "/lab/project".to_string(),
            },
            TargetOs::Windows => PathInputs {
                os,
                home: Some(r"C:\Users\Alice".to_string()),
                xdg_config_home: None,
                xdg_cache_home: None,
                app_data: Some(r"C:\Users\Alice\AppData\Roaming".to_string()),
                local_app_data: Some(r"C:\Users\Alice\AppData\Local".to_string()),
                project_root: r"D:\lab\project".to_string(),
            },
        }
    }

    fn with_xdg(os: TargetOs) -> PathInputs {
        let mut inputs = sample(os);
        inputs.xdg_config_home = Some(xdg_config_home(os).to_string());
        inputs
    }

    fn xdg_config_home(os: TargetOs) -> &'static str {
        match os {
            TargetOs::Windows => r"D:\xdg\config",
            TargetOs::Linux | TargetOs::MacOs => "/xdg/config",
        }
    }

    fn xdg_app(os: TargetOs) -> &'static str {
        match os {
            TargetOs::Windows => r"D:\xdg\config\raw-viewer",
            TargetOs::Linux | TargetOs::MacOs => "/xdg/config/raw-viewer",
        }
    }

    fn dot_app(os: TargetOs) -> &'static str {
        match os {
            TargetOs::Linux => "/home/alice/.config/raw-viewer",
            TargetOs::MacOs => "/Users/alice/.config/raw-viewer",
            TargetOs::Windows => r"C:\Users\Alice\.config\raw-viewer",
        }
    }

    fn platform_config(os: TargetOs) -> &'static str {
        match os {
            TargetOs::Linux => "/home/alice/.config/raw-viewer",
            TargetOs::MacOs => "/Users/alice/Library/Application Support/raw-viewer",
            TargetOs::Windows => r"C:\Users\Alice\AppData\Roaming\raw-viewer",
        }
    }

    fn platform_cache(os: TargetOs) -> &'static str {
        match os {
            TargetOs::Linux => "/home/alice/.cache/raw-viewer",
            TargetOs::MacOs => "/Users/alice/Library/Caches/raw-viewer",
            TargetOs::Windows => r"C:\Users\Alice\AppData\Local\raw-viewer",
        }
    }

    fn project_config(os: TargetOs) -> &'static str {
        match os {
            TargetOs::Linux | TargetOs::MacOs => "/lab/project/.raw-viewer",
            TargetOs::Windows => r"D:\lab\project\.raw-viewer",
        }
    }

    fn sep(os: TargetOs) -> char {
        match os {
            TargetOs::Windows => '\\',
            TargetOs::Linux | TargetOs::MacOs => '/',
        }
    }

    fn is_inside(parent: &str, child: &str, separator: char) -> bool {
        let prefix = if parent.ends_with(separator) {
            parent.to_string()
        } else {
            format!("{parent}{separator}")
        };
        child.starts_with(&prefix)
    }

    #[test]
    fn xdg_raw_viewer_directory_wins_on_every_os() {
        for os in OSES {
            let mut seen = Vec::new();
            let resolved = resolve_paths(&with_xdg(os), |path| {
                seen.push(path.to_string());
                path == xdg_app(os)
            })
            .unwrap_or_else(|err| panic!("{os:?}: {err}"));
            assert_eq!(resolved.global_config_dir, xdg_app(os), "{os:?}");
            assert_eq!(seen, vec![xdg_app(os).to_string()], "{os:?}");
            assert_eq!(resolved.cache_dir, platform_cache(os), "{os:?}");
            assert_eq!(resolved.project_config_dir, project_config(os), "{os:?}");
        }
    }

    #[test]
    fn xdg_wins_when_home_dot_config_also_exists_on_every_os() {
        for os in OSES {
            let resolved = resolve_paths(&with_xdg(os), |path| {
                path == xdg_app(os) || path == dot_app(os)
            })
            .unwrap_or_else(|err| panic!("{os:?}: {err}"));
            assert_eq!(resolved.global_config_dir, xdg_app(os), "{os:?}");
        }
    }

    #[test]
    fn home_dot_config_used_when_xdg_directory_is_missing_on_every_os() {
        for os in OSES {
            let mut seen = Vec::new();
            let resolved = resolve_paths(&with_xdg(os), |path| {
                seen.push(path.to_string());
                path == dot_app(os)
            })
            .unwrap_or_else(|err| panic!("{os:?}: {err}"));
            assert_eq!(resolved.global_config_dir, dot_app(os), "{os:?}");
            assert_eq!(
                seen,
                vec![xdg_app(os).to_string(), dot_app(os).to_string()],
                "{os:?}"
            );
        }
    }

    #[test]
    fn home_dot_config_used_when_xdg_is_unset_on_every_os() {
        for os in OSES {
            let mut seen = Vec::new();
            let resolved = resolve_paths(&sample(os), |path| {
                seen.push(path.to_string());
                path == dot_app(os)
            })
            .unwrap_or_else(|err| panic!("{os:?}: {err}"));
            assert_eq!(resolved.global_config_dir, dot_app(os), "{os:?}");
            assert_eq!(seen, vec![dot_app(os).to_string()], "{os:?}");
        }
    }

    #[test]
    fn platform_default_used_when_neither_config_directory_exists_on_every_os() {
        for os in OSES {
            let mut seen = Vec::new();
            let resolved = resolve_paths(&with_xdg(os), |path| {
                seen.push(path.to_string());
                false
            })
            .unwrap_or_else(|err| panic!("{os:?}: {err}"));
            assert_eq!(resolved.global_config_dir, platform_config(os), "{os:?}");
            assert_ne!(resolved.global_config_dir, xdg_app(os), "{os:?}");
            assert!(
                !seen
                    .iter()
                    .any(|path| path == platform_config(os) && path != dot_app(os)),
                "{os:?} queried the platform default: {seen:?}"
            );
            assert_eq!(resolved.cache_dir, platform_cache(os), "{os:?}");
        }
    }

    #[test]
    fn empty_and_relative_xdg_config_home_are_ignored_on_every_os() {
        for os in OSES {
            for value in ["", "   ", "relative/config", "raw-viewer"] {
                let mut inputs = sample(os);
                inputs.xdg_config_home = Some(value.to_string());
                let mut seen = Vec::new();
                let resolved = resolve_paths(&inputs, |path| {
                    seen.push(path.to_string());
                    false
                })
                .unwrap_or_else(|err| panic!("{os:?} {value:?}: {err}"));
                assert_eq!(
                    resolved.global_config_dir,
                    platform_config(os),
                    "{os:?} {value:?}"
                );
                assert!(
                    seen.iter().all(|path| !path.contains("relative")),
                    "{os:?} {value:?}: {seen:?}"
                );
            }
        }
    }

    #[test]
    fn trailing_separator_on_xdg_config_home_still_selects_that_directory() {
        for os in OSES {
            let mut inputs = with_xdg(os);
            inputs.xdg_config_home = Some(format!("{}{}", xdg_config_home(os), sep(os)));
            let resolved = resolve_paths(&inputs, |path| path == xdg_app(os))
                .unwrap_or_else(|err| panic!("{os:?}: {err}"));
            assert_eq!(resolved.global_config_dir, xdg_app(os), "{os:?}");
        }
    }

    #[test]
    fn windows_accepts_forward_slashes_and_emits_backslashes() {
        let mut inputs = sample(TargetOs::Windows);
        inputs.home = Some("C:/Users/Alice".to_string());
        inputs.app_data = Some("C:/Users/Alice/AppData/Roaming".to_string());
        inputs.local_app_data = Some("C:/Users/Alice/AppData/Local".to_string());
        inputs.xdg_config_home = Some("D:/xdg/config/".to_string());
        inputs.project_root = "D:/lab/project/".to_string();
        let resolved = resolve_paths(&inputs, |path| path == r"D:\xdg\config\raw-viewer").unwrap();
        assert_eq!(resolved.global_config_dir, r"D:\xdg\config\raw-viewer");
        assert_eq!(
            resolved.cache_dir,
            r"C:\Users\Alice\AppData\Local\raw-viewer"
        );
        assert_eq!(resolved.project_config_dir, r"D:\lab\project\.raw-viewer");
    }

    #[test]
    fn cache_uses_platform_cache_dir_and_stays_outside_the_project_on_every_os() {
        for os in OSES {
            let inputs = sample(os);
            let resolved =
                resolve_paths(&inputs, |_| false).unwrap_or_else(|err| panic!("{os:?}: {err}"));
            assert_eq!(resolved.cache_dir, platform_cache(os), "{os:?}");
            assert!(!resolved.cache_dir.contains(".raw-viewer"), "{os:?}");
            assert!(
                !is_inside(&inputs.project_root, &resolved.cache_dir, sep(os)),
                "{os:?}: {} is inside {}",
                resolved.cache_dir,
                inputs.project_root
            );
            assert!(
                is_inside(&inputs.project_root, &resolved.project_config_dir, sep(os)),
                "{os:?}"
            );
            assert_eq!(resolved.project_config_dir, project_config(os), "{os:?}");
        }
    }

    #[test]
    fn linux_cache_honors_absolute_xdg_cache_home_only() {
        let mut absolute = sample(TargetOs::Linux);
        absolute.xdg_cache_home = Some("/xdg/cache/".to_string());
        let resolved = resolve_paths(&absolute, |_| false).unwrap();
        assert_eq!(resolved.cache_dir, "/xdg/cache/raw-viewer");

        for value in ["cache", "", "   "] {
            let mut inputs = sample(TargetOs::Linux);
            inputs.xdg_cache_home = Some(value.to_string());
            let resolved = resolve_paths(&inputs, |_| false).unwrap();
            assert_eq!(
                resolved.cache_dir,
                platform_cache(TargetOs::Linux),
                "{value:?}"
            );
        }
    }

    #[test]
    fn macos_and_windows_cache_ignore_xdg_cache_home() {
        let mut macos = sample(TargetOs::MacOs);
        macos.xdg_cache_home = Some("/xdg/cache".to_string());
        let resolved = resolve_paths(&macos, |_| false).unwrap();
        assert_eq!(resolved.cache_dir, platform_cache(TargetOs::MacOs));

        let mut windows = sample(TargetOs::Windows);
        windows.xdg_cache_home = Some(r"D:\xdg\cache".to_string());
        let resolved = resolve_paths(&windows, |_| false).unwrap();
        assert_eq!(resolved.cache_dir, platform_cache(TargetOs::Windows));
    }

    #[test]
    fn project_root_trailing_separator_is_removed_on_every_os() {
        for os in OSES {
            let mut inputs = sample(os);
            inputs.project_root = format!("{}{}", inputs.project_root, sep(os));
            let resolved =
                resolve_paths(&inputs, |_| false).unwrap_or_else(|err| panic!("{os:?}: {err}"));
            assert_eq!(resolved.project_config_dir, project_config(os), "{os:?}");
        }
    }

    #[test]
    fn filesystem_root_project_and_home_join_a_separator() {
        let mut linux = sample(TargetOs::Linux);
        linux.home = Some("/".to_string());
        linux.project_root = "/".to_string();
        let resolved = resolve_paths(&linux, |_| false).unwrap();
        assert_eq!(resolved.global_config_dir, "/.config/raw-viewer");
        assert_eq!(resolved.cache_dir, "/.cache/raw-viewer");
        assert_eq!(resolved.project_config_dir, "/.raw-viewer");

        let mut windows = sample(TargetOs::Windows);
        windows.home = None;
        windows.app_data = Some(r"C:\".to_string());
        windows.local_app_data = Some(r"C:\".to_string());
        windows.project_root = r"C:\".to_string();
        let resolved = resolve_paths(&windows, |_| false).unwrap();
        assert_eq!(resolved.global_config_dir, r"C:\raw-viewer");
        assert_eq!(resolved.cache_dir, r"C:\raw-viewer");
        assert_eq!(resolved.project_config_dir, r"C:\.raw-viewer");
    }

    #[test]
    fn missing_home_errors_when_the_platform_default_needs_it() {
        for os in [TargetOs::Linux, TargetOs::MacOs] {
            let mut inputs = sample(os);
            inputs.home = None;
            let mut seen = Vec::new();
            let err = resolve_paths(&inputs, |path| {
                seen.push(path.to_string());
                false
            })
            .unwrap_err();
            assert_eq!(err, ResolveError::MissingHome, "{os:?}");
            assert!(seen.is_empty(), "{os:?}: {seen:?}");
        }
    }

    #[test]
    fn linux_without_home_still_resolves_when_xdg_config_and_cache_exist() {
        let mut inputs = sample(TargetOs::Linux);
        inputs.home = None;
        inputs.xdg_config_home = Some("/xdg/config".to_string());
        inputs.xdg_cache_home = Some("/xdg/cache".to_string());
        let resolved = resolve_paths(&inputs, |path| path == "/xdg/config/raw-viewer").unwrap();
        assert_eq!(resolved.global_config_dir, "/xdg/config/raw-viewer");
        assert_eq!(resolved.cache_dir, "/xdg/cache/raw-viewer");
        assert_eq!(resolved.project_config_dir, project_config(TargetOs::Linux));
    }

    #[test]
    fn macos_xdg_hit_still_errors_when_cache_needs_a_missing_home() {
        let mut inputs = sample(TargetOs::MacOs);
        inputs.home = None;
        inputs.xdg_config_home = Some("/xdg/config".to_string());
        let err = resolve_paths(&inputs, |_| true).unwrap_err();
        assert_eq!(err, ResolveError::MissingHome);
    }

    #[test]
    fn windows_xdg_hit_does_not_need_home_or_appdata() {
        let mut inputs = sample(TargetOs::Windows);
        inputs.home = None;
        inputs.app_data = None;
        inputs.xdg_config_home = Some(r"D:\xdg\config".to_string());
        let resolved = resolve_paths(&inputs, |path| path == r"D:\xdg\config\raw-viewer").unwrap();
        assert_eq!(resolved.global_config_dir, r"D:\xdg\config\raw-viewer");
        assert_eq!(resolved.cache_dir, platform_cache(TargetOs::Windows));
    }

    #[test]
    fn windows_platform_default_errors_without_appdata_or_local_app_data() {
        let mut missing_app_data = sample(TargetOs::Windows);
        missing_app_data.home = None;
        missing_app_data.app_data = None;
        let err = resolve_paths(&missing_app_data, |_| false).unwrap_err();
        assert_eq!(err, ResolveError::MissingAppData);

        let mut missing_local = sample(TargetOs::Windows);
        missing_local.local_app_data = None;
        missing_local.xdg_config_home = Some(r"D:\xdg\config".to_string());
        let err =
            resolve_paths(&missing_local, |path| path == r"D:\xdg\config\raw-viewer").unwrap_err();
        assert_eq!(err, ResolveError::MissingLocalAppData);
    }

    #[test]
    fn relative_home_and_windows_bases_are_errors() {
        for os in OSES {
            let mut inputs = sample(os);
            inputs.home = Some("alice".to_string());
            assert_eq!(
                resolve_paths(&inputs, |_| false).unwrap_err(),
                ResolveError::HomeNotAbsolute,
                "{os:?}"
            );
        }

        let mut app_data = sample(TargetOs::Windows);
        app_data.home = None;
        app_data.app_data = Some(r"AppData\Roaming".to_string());
        assert_eq!(
            resolve_paths(&app_data, |_| false).unwrap_err(),
            ResolveError::AppDataNotAbsolute
        );

        let mut local = sample(TargetOs::Windows);
        local.local_app_data = Some("Local".to_string());
        assert_eq!(
            resolve_paths(&local, |_| false).unwrap_err(),
            ResolveError::LocalAppDataNotAbsolute
        );
    }

    #[test]
    fn empty_project_root_is_an_error_on_every_os() {
        for os in OSES {
            for value in ["", "   "] {
                let mut inputs = sample(os);
                inputs.project_root = value.to_string();
                assert_eq!(
                    resolve_paths(&inputs, |_| true).unwrap_err(),
                    ResolveError::EmptyProjectRoot,
                    "{os:?} {value:?}"
                );
            }
        }
    }

    #[test]
    fn host_cache_matches_directories_crate() {
        let base = directories::BaseDirs::new().expect("home directory");
        let project = std::env::temp_dir().join("raw-viewer-cache-probe");
        let resolved = resolve_paths_from_env(&project).expect("host paths");
        let expected = base.cache_dir().join(APP_DIRECTORY_NAME);
        assert_eq!(
            normalize_path(TargetOs::host(), &resolved.cache_dir).as_deref(),
            normalize_path(TargetOs::host(), &expected.to_string_lossy()).as_deref()
        );
    }

    #[test]
    fn host_platform_config_default_matches_directories_crate() {
        let base = directories::BaseDirs::new().expect("home directory");
        let os = TargetOs::host();
        let inputs = PathInputs {
            os,
            home: Some(path_to_utf8(base.home_dir(), "home directory").unwrap()),
            xdg_config_home: None,
            xdg_cache_home: None,
            app_data: if os == TargetOs::Windows {
                Some(path_to_utf8(base.config_dir(), "APPDATA").unwrap())
            } else {
                None
            },
            local_app_data: if os == TargetOs::Windows {
                Some(path_to_utf8(base.cache_dir(), "LOCALAPPDATA").unwrap())
            } else {
                None
            },
            project_root: if os == TargetOs::Windows {
                r"D:\lab\project".to_string()
            } else {
                "/lab/project".to_string()
            },
        };
        let resolved = resolve_paths(&inputs, |_| false).unwrap();
        let expected: PathBuf = match os {
            TargetOs::Linux => base.home_dir().join(".config").join(APP_DIRECTORY_NAME),
            TargetOs::MacOs | TargetOs::Windows => base.config_dir().join(APP_DIRECTORY_NAME),
        };
        assert_eq!(
            normalize_path(os, &resolved.global_config_dir).as_deref(),
            normalize_path(os, &expected.to_string_lossy()).as_deref()
        );
    }

    #[test]
    fn resolve_from_env_does_not_create_directories() {
        let project = std::env::temp_dir().join(format!(
            "raw-viewer-no-create-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .expect("clock")
                .as_nanos()
        ));
        assert!(!project.exists());
        let inputs = path_inputs_from_host(&project).unwrap();
        let predicted = resolve_paths(&inputs, host_dir_exists).unwrap();
        let global = PathBuf::from(&predicted.global_config_dir);
        let cache = PathBuf::from(&predicted.cache_dir);
        let global_existed = global.exists();
        let cache_existed = cache.exists();

        let resolved = resolve_paths_from_env(&project).unwrap();
        assert_eq!(resolved, predicted);
        assert!(!project.exists());
        assert!(!Path::new(&resolved.project_config_dir).exists());
        assert_eq!(global.exists(), global_existed);
        assert_eq!(cache.exists(), cache_existed);
        assert!(resolved.project_config_dir.ends_with(".raw-viewer"));
        assert!(resolved.cache_dir.ends_with("raw-viewer"));
        assert!(!resolved.cache_dir.ends_with(".raw-viewer"));
    }
}
