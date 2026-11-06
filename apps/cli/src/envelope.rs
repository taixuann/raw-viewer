use serde::{Deserialize, Serialize};
use serde_json::Value;

pub const EXIT_OK: i32 = 0;
pub const EXIT_USAGE: i32 = 1;
pub const EXIT_NOT_FOUND: i32 = 2;
pub const EXIT_AMBIGUOUS_PROFILE: i32 = 3;
pub const EXIT_VALIDATION: i32 = 4;
pub const EXIT_IO: i32 = 5;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SuccessEnvelope {
    pub ok: bool,
    pub command: String,
    pub data: Value,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ErrorDetail {
    pub code: String,
    pub message: String,
    pub details: Value,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ErrorEnvelope {
    pub ok: bool,
    pub command: String,
    pub error: ErrorDetail,
}

pub struct CliResult {
    pub exit_code: i32,
    pub output: Result<Value, (String, String, Value)>,
}

impl CliResult {
    pub fn ok(data: Value) -> Self {
        Self {
            exit_code: EXIT_OK,
            output: Ok(data),
        }
    }

    pub fn not_found(message: impl Into<String>) -> Self {
        Self {
            exit_code: EXIT_NOT_FOUND,
            output: Err((
                "not_found".to_string(),
                message.into(),
                serde_json::json!({}),
            )),
        }
    }

    pub fn ambiguous_profile(message: impl Into<String>, candidate_ids: Vec<String>) -> Self {
        Self {
            exit_code: EXIT_AMBIGUOUS_PROFILE,
            output: Err((
                "ambiguous_profile".to_string(),
                message.into(),
                serde_json::json!({ "candidate_ids": candidate_ids }),
            )),
        }
    }

    pub fn validation(message: impl Into<String>) -> Self {
        Self {
            exit_code: EXIT_VALIDATION,
            output: Err((
                "validation_error".to_string(),
                message.into(),
                serde_json::json!({}),
            )),
        }
    }

    pub fn io(message: impl Into<String>) -> Self {
        Self {
            exit_code: EXIT_IO,
            output: Err((
                "io_error".to_string(),
                message.into(),
                serde_json::json!({}),
            )),
        }
    }
}
