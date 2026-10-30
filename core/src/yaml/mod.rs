//! Ordered YAML subset used by instrument profiles and project settings.
//!
//! Unknown constructs fail closed instead of being guessed.

mod parser;

pub use parser::{parse, YamlNode, YamlParseError};
