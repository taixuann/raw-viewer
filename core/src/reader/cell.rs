use super::ReaderError;
use crate::measurement::GapReason;
use crate::reader::tabular;

pub struct CellLedger {
    pub values: Vec<Vec<Option<f64>>>,
    pub reasons: Vec<Vec<Option<GapReason>>>,
    pub warnings: Vec<String>,
    pub gap_total: usize,
}

impl CellLedger {
    pub fn new(count: usize) -> Self {
        Self {
            values: vec![Vec::new(); count],
            reasons: vec![Vec::new(); count],
            gap_total: 0,
            warnings: Vec::new(),
        }
    }

    pub fn record(&mut self, column: usize, reason: GapReason, message: String) {
        self.values[column].push(None);
        self.reasons[column].push(Some(reason));
        self.gap_total += 1;
        if self.warnings.len() < 32 {
            self.warnings.push(message);
        }
    }

    pub fn summarize(&self, relative_path: &str) -> Vec<String> {
        let mut warnings = self.warnings.clone();
        if self.gap_total > warnings.len() {
            warnings.push(format!(
                "{relative_path}: ... and {} more gap cells shown as gaps.",
                self.gap_total - warnings.len()
            ));
        }
        warnings
    }
}

pub fn append_cell(
    raw: &str,
    column: usize,
    key: &str,
    line_number: usize,
    relative_path: &str,
    decimal: char,
    ledger: &mut CellLedger,
) -> Result<(), ReaderError> {
    if let Some(reason) = tabular::gap_reason(raw) {
        let kind = if reason == GapReason::Blank {
            "is blank"
        } else if reason == GapReason::Nan {
            "records NaN"
        } else {
            "records infinity"
        };
        ledger.record(
            column,
            reason,
            format!(
                "{relative_path} line {line_number}: column \"{key}\" value \"{raw}\" {kind}; shown as a gap."
            ),
        );
        return Ok(());
    }
    let normalized = tabular::decimal_number(raw, decimal);
    if !tabular::is_valid_decimal(&normalized) {
        return Err(ReaderError::InvalidSource(format!(
            "{relative_path} line {line_number}: column \"{key}\" value \"{raw}\" is not a finite number."
        )));
    }
    match normalized.parse::<f64>() {
        Ok(value) if value.is_finite() => {
            ledger.values[column].push(Some(value));
            ledger.reasons[column].push(None);
            Ok(())
        }
        Ok(_) => {
            ledger.record(
                column,
                GapReason::Saturated,
                format!(
                    "{relative_path} line {line_number}: column \"{key}\" value \"{raw}\" overflowed to a non-finite value (saturation); shown as a gap."
                ),
            );
            Ok(())
        }
        Err(_) => Err(ReaderError::InvalidSource(format!(
            "{relative_path} line {line_number}: column \"{key}\" value \"{raw}\" is not a finite number."
        ))),
    }
}
