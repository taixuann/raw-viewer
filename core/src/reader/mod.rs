mod cell;
mod comment_tsv;
mod first_row;
mod instrument;
mod line_puller;
mod tabular;

use std::fmt;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ReaderError {
    InvalidProject,
    SourceOutsideRaw { path: String, data_root: String },
    InvalidSource(String),
}

impl fmt::Display for ReaderError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            ReaderError::InvalidProject => {
                f.write_str("Choose a project containing a readable data/raw directory.")
            }
            ReaderError::SourceOutsideRaw { path, data_root } => write!(
                f,
                "{path}: resolves outside this project's data root (\"{data_root}\")."
            ),
            ReaderError::InvalidSource(message) => f.write_str(message),
        }
    }
}

impl std::error::Error for ReaderError {}

pub use instrument::{load_measurement, parse_filename, READER_VERSION};
