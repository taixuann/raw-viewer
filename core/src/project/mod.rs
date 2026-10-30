use std::path::{Path, PathBuf};

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ProjectError {
    InvalidRoot(String),
}

impl std::fmt::Display for ProjectError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            ProjectError::InvalidRoot(msg) => f.write_str(msg),
        }
    }
}

impl std::error::Error for ProjectError {}

#[derive(Debug, Clone)]
pub struct ProjectContext {
    pub root: PathBuf,
    pub raw_root: PathBuf,
    pub data_root_relative_path: String,
}

impl ProjectContext {
    pub const DEFAULT_DATA_ROOT: &'static str = "data/raw";

    pub fn open(root: &Path) -> Result<Self, ProjectError> {
        Self::open_with_data_root(root, Self::DEFAULT_DATA_ROOT)
    }

    pub fn open_with_data_root(root: &Path, data_root: &str) -> Result<Self, ProjectError> {
        if data_root.contains("..") || data_root.starts_with('/') {
            return Err(ProjectError::InvalidRoot(format!(
                "invalid data root \"{data_root}\""
            )));
        }
        let canonical_root = root.canonicalize().unwrap_or_else(|_| root.to_path_buf());
        let raw = if data_root == "." {
            canonical_root.clone()
        } else {
            canonical_root.join(data_root)
        };
        Ok(Self {
            root: canonical_root,
            raw_root: raw,
            data_root_relative_path: data_root.to_string(),
        })
    }

    pub fn relative_path_of(&self, path: &Path) -> Option<String> {
        let canonical = path.canonicalize().unwrap_or_else(|_| path.to_path_buf());
        let relative = if canonical.starts_with(&self.root) {
            canonical
                .strip_prefix(&self.root)
                .ok()?
                .to_string_lossy()
                .trim_start_matches('/')
                .to_string()
        } else {
            return None;
        };
        Some(relative)
    }

    pub fn source_relative_path(&self, source: &Path) -> Option<String> {
        let claimed = source
            .canonicalize()
            .unwrap_or_else(|_| source.to_path_buf());
        let relative = if claimed.starts_with(&self.root) {
            claimed
                .strip_prefix(&self.root)
                .ok()?
                .to_string_lossy()
                .trim_start_matches('/')
                .to_string()
        } else {
            return None;
        };
        let relative = relative.replace('\\', "/");
        if self.data_root_relative_path == "." {
            return Some(relative);
        }
        if relative == self.data_root_relative_path
            || relative.starts_with(&format!("{}/", self.data_root_relative_path))
        {
            Some(relative)
        } else {
            None
        }
    }

    pub fn source_path(&self, relative: &Path) -> PathBuf {
        self.root.join(relative)
    }
}
