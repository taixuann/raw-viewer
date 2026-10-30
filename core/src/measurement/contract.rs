use serde::Deserialize;
use std::collections::{BTreeMap, HashSet};

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ContractError {
    UnsupportedVersion(i64),
    Invalid(String),
}

impl std::fmt::Display for ContractError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            ContractError::UnsupportedVersion(v) => write!(f, "unsupported contract version {v}"),
            ContractError::Invalid(msg) => f.write_str(msg),
        }
    }
}

impl std::error::Error for ContractError {}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
pub struct SourceIdentity {
    pub path: String,
    pub sha256: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
pub struct InstrumentIdentity {
    pub id: String,
    pub name: String,
    pub vendor: Option<String>,
    pub model: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Deserialize)]
pub struct MeasurementView {
    pub kind: String,
    pub x: Option<String>,
    pub y: Option<Vec<String>>,
    #[serde(rename = "preserve_order")]
    pub preserve_order: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize, serde::Serialize)]
#[serde(rename_all = "lowercase")]
pub enum GapReason {
    Blank,
    Nan,
    Infinite,
    Saturated,
    Unknown,
}

impl GapReason {
    pub fn as_str(self) -> &'static str {
        match self {
            GapReason::Blank => "blank",
            GapReason::Nan => "nan",
            GapReason::Infinite => "infinite",
            GapReason::Saturated => "saturated",
            GapReason::Unknown => "unknown",
        }
    }

    pub fn parse(s: &str) -> Option<Self> {
        match s {
            "blank" => Some(GapReason::Blank),
            "nan" => Some(GapReason::Nan),
            "infinite" => Some(GapReason::Infinite),
            "saturated" => Some(GapReason::Saturated),
            "unknown" => Some(GapReason::Unknown),
            _ => None,
        }
    }
}

#[derive(Debug, Clone, PartialEq)]
pub struct MeasurementChannel {
    pub name: String,
    pub label: String,
    pub unit: String,
    pub quantity: Option<String>,
    pub values: Vec<Option<f64>>,
    pub gap_reasons: Vec<Option<GapReason>>,
}

impl MeasurementChannel {
    pub fn row_count(&self) -> usize {
        self.values.len()
    }

    pub fn gap_count(&self) -> usize {
        self.values.iter().filter(|v| v.is_none()).count()
    }
}

#[derive(Debug, Clone, PartialEq)]
pub enum JSONValue {
    String(String),
    Number(f64),
    Boolean(bool),
    Null,
}

#[derive(Debug, Clone, PartialEq)]
pub struct MetadataField {
    pub key: String,
    pub label: String,
    pub value: JSONValue,
    pub unit: Option<String>,
    pub kind: String,
}

#[derive(Debug, Clone, PartialEq)]
pub struct MetadataSection {
    pub title: String,
    pub fields: Vec<MetadataField>,
}

#[derive(Debug, Clone, PartialEq)]
pub struct NormalizedMeasurement {
    pub source: SourceIdentity,
    pub instrument: InstrumentIdentity,
    pub application_mode: Option<String>,
    pub view: MeasurementView,
    pub channels: Vec<MeasurementChannel>,
    pub metadata_sections: Vec<MetadataSection>,
    pub warnings: Vec<String>,
    pub support_status: String,
    pub provenance: BTreeMap<String, String>,
}

impl NormalizedMeasurement {
    pub fn channel(&self, name: &str) -> Option<&MeasurementChannel> {
        self.channels.iter().find(|c| c.name == name)
    }

    pub fn decode(data: &[u8]) -> Result<Self, ContractError> {
        let root: serde_json::Value = serde_json::from_slice(data).map_err(|e| {
            ContractError::Invalid(format!("Missing or malformed contract version: {e}"))
        })?;

        let contract_version = root
            .get("contract_version")
            .and_then(|v| v.as_i64())
            .ok_or_else(|| {
                ContractError::Invalid("Missing or malformed contract version".to_string())
            })?;

        if contract_version != 1 {
            return Err(ContractError::UnsupportedVersion(contract_version));
        }

        decode_envelope(root)
    }
}

pub(crate) fn validate_measurement(
    measurement: &NormalizedMeasurement,
) -> Result<(), ContractError> {
    let valid_sha = measurement.source.sha256.len() == 64
        && measurement
            .source
            .sha256
            .chars()
            .all(|c| c.is_ascii_hexdigit());
    if measurement.source.path.is_empty() || !valid_sha {
        return Err(ContractError::Invalid(
            "Source path or SHA-256 is missing or malformed".to_string(),
        ));
    }

    const VIEW_KINDS: &[&str] = &[
        "xy",
        "timeseries",
        "spectrum",
        "table",
        "metadata-only",
        "regions",
    ];
    if !VIEW_KINDS.contains(&measurement.view.kind.as_str()) {
        return Err(ContractError::Invalid(format!(
            "Unknown view kind {}",
            measurement.view.kind
        )));
    }

    let names: HashSet<_> = measurement
        .channels
        .iter()
        .map(|c| c.name.as_str())
        .collect();
    if names.len() != measurement.channels.len() {
        return Err(ContractError::Invalid(
            "Channel names must be unique".to_string(),
        ));
    }

    for channel in &measurement.channels {
        if channel.values.len() != channel.gap_reasons.len() {
            return Err(ContractError::Invalid(format!(
                "gap_reasons length ({}) must match values length ({})",
                channel.gap_reasons.len(),
                channel.values.len()
            )));
        }
        for value in &channel.values {
            if let Some(v) = value {
                if !v.is_finite() {
                    return Err(ContractError::Invalid(
                        "Channels must contain only finite values or null gaps".to_string(),
                    ));
                }
            }
        }
        for (value, reason) in channel.values.iter().zip(channel.gap_reasons.iter()) {
            if value.is_some() && reason.is_some() {
                return Err(ContractError::Invalid(
                    "Malformed normalized measurement: a present sample has a gap reason."
                        .to_string(),
                ));
            }
        }
    }

    if let Some(count) = measurement.channels.first().map(|c| c.values.len()) {
        if !measurement.channels.iter().all(|c| c.values.len() == count) {
            return Err(ContractError::Invalid(
                "Channel lengths differ; row alignment is unknown".to_string(),
            ));
        }
    }

    if measurement.view.kind != "metadata-only" {
        let channel_names: HashSet<_> = measurement
            .channels
            .iter()
            .map(|c| c.name.as_str())
            .collect();
        let ok = measurement.view.preserve_order
            && measurement
                .view
                .x
                .as_ref()
                .is_some_and(|x| channel_names.contains(x.as_str()))
            && measurement.view.y.as_ref().is_some_and(|y| {
                !y.is_empty() && y.iter().all(|n| channel_names.contains(n.as_str()))
            });
        if !ok {
            return Err(ContractError::Invalid(
                "View channels are missing or acquisition ordering is not declared".to_string(),
            ));
        }
    }

    Ok(())
}

fn decode_envelope(root: serde_json::Value) -> Result<NormalizedMeasurement, ContractError> {
    let envelope: MeasurementEnvelope = serde_json::from_value(root)
        .map_err(|e| ContractError::Invalid(format!("Malformed normalized measurement: {e}")))?;

    let measurement = NormalizedMeasurement {
        source: envelope.source,
        instrument: envelope.instrument,
        application_mode: envelope.application_mode,
        view: envelope.view,
        channels: envelope.channels.into_iter().map(Into::into).collect(),
        metadata_sections: envelope
            .metadata_sections
            .into_iter()
            .map(Into::into)
            .collect(),
        warnings: envelope.warnings,
        support_status: envelope.support_status,
        provenance: envelope.provenance.unwrap_or_default(),
    };
    validate_measurement(&measurement)?;
    Ok(measurement)
}

#[derive(Debug, Deserialize)]
struct MeasurementEnvelope {
    source: SourceIdentity,
    instrument: InstrumentIdentity,
    application_mode: Option<String>,
    view: MeasurementView,
    channels: Vec<MeasurementChannelWire>,
    metadata_sections: Vec<MetadataSectionWire>,
    warnings: Vec<String>,
    support_status: String,
    provenance: Option<BTreeMap<String, String>>,
}

#[derive(Debug)]
struct MeasurementChannelWire {
    name: String,
    label: String,
    unit: String,
    quantity: Option<String>,
    values: Vec<Option<f64>>,
    gap_reasons: Vec<Option<GapReason>>,
}

impl<'de> Deserialize<'de> for MeasurementChannelWire {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: serde::Deserializer<'de>,
    {
        #[derive(Deserialize)]
        struct Raw {
            name: String,
            label: String,
            unit: String,
            quantity: Option<String>,
            values: Vec<Option<f64>>,
            #[serde(default, rename = "gap_reasons")]
            gap_reasons: Option<Vec<Option<GapReason>>>,
        }
        let raw = Raw::deserialize(deserializer)?;
        let gap_reasons = match raw.gap_reasons {
            Some(reasons) => {
                if reasons.len() != raw.values.len() {
                    return Err(serde::de::Error::custom(format!(
                        "gap_reasons length ({}) must match values length ({})",
                        reasons.len(),
                        raw.values.len()
                    )));
                }
                reasons
            }
            None => raw
                .values
                .iter()
                .map(|v| {
                    if v.is_none() {
                        Some(GapReason::Unknown)
                    } else {
                        None
                    }
                })
                .collect(),
        };
        Ok(MeasurementChannelWire {
            name: raw.name,
            label: raw.label,
            unit: raw.unit,
            quantity: raw.quantity,
            values: raw.values,
            gap_reasons,
        })
    }
}

impl From<MeasurementChannelWire> for MeasurementChannel {
    fn from(w: MeasurementChannelWire) -> Self {
        MeasurementChannel {
            name: w.name,
            label: w.label,
            unit: w.unit,
            quantity: w.quantity,
            values: w.values,
            gap_reasons: w.gap_reasons,
        }
    }
}

#[derive(Debug, Deserialize)]
struct MetadataSectionWire {
    title: String,
    fields: Vec<MetadataFieldWire>,
}

#[derive(Debug, Deserialize)]
struct MetadataFieldWire {
    key: String,
    label: String,
    #[serde(deserialize_with = "deserialize_json_value_field")]
    value: JSONValue,
    unit: Option<String>,
    kind: String,
}

fn deserialize_json_value_field<'de, D>(deserializer: D) -> Result<JSONValue, D::Error>
where
    D: serde::Deserializer<'de>,
{
    let value = serde_json::Value::deserialize(deserializer)?;
    decode_json_value_wire(&value).map_err(serde::de::Error::custom)
}

fn decode_json_value_wire(value: &serde_json::Value) -> Result<JSONValue, String> {
    if value.is_null() {
        return Ok(JSONValue::Null);
    }
    if let Some(b) = value.as_bool() {
        return Ok(JSONValue::Boolean(b));
    }
    if let Some(n) = value.as_f64() {
        return Ok(JSONValue::Number(n));
    }
    if let Some(s) = value.as_str() {
        return Ok(JSONValue::String(s.to_string()));
    }
    Err("Unsupported metadata JSON value".to_string())
}

impl From<MetadataFieldWire> for MetadataField {
    fn from(w: MetadataFieldWire) -> Self {
        MetadataField {
            key: w.key,
            label: w.label,
            value: w.value,
            unit: w.unit,
            kind: w.kind,
        }
    }
}

impl From<MetadataSectionWire> for MetadataSection {
    fn from(w: MetadataSectionWire) -> Self {
        MetadataSection {
            title: w.title,
            fields: w.fields.into_iter().map(Into::into).collect(),
        }
    }
}
