mod cell;
mod comment_tsv;
mod first_row;
mod generic_table;
mod instrument;
mod line_puller;
mod tabular;
mod v3;

pub const READER_VERSION: &str = "1.3.0";

use std::fmt;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ReaderError {
    InvalidProject,
    SourceOutsideRaw { path: String, data_root: String },
    InvalidSource(String),
    EmptyFile,
    NoNumericDataFound,
    UnreadableEncoding,
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
            ReaderError::EmptyFile => f.write_str("The file is empty."),
            ReaderError::NoNumericDataFound => {
                f.write_str("Could not detect a numeric data block in this file.")
            }
            ReaderError::UnreadableEncoding => {
                f.write_str("The file could not be read with text encoding.")
            }
        }
    }
}

impl std::error::Error for ReaderError {}

pub use generic_table::{
    inspect, load_measurement_default, GenericTableInspection, GenericTablePreview,
};
pub use instrument::{load_measurement, parse_filename};
