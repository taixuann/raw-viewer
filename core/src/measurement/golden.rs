use super::contract::{
    ContractError, GapReason, InstrumentIdentity, JSONValue, MeasurementChannel, MeasurementView,
    MetadataField, MetadataSection, NormalizedMeasurement, SourceIdentity,
};
use serde_json::{json, Map, Value};
use std::collections::BTreeMap;

impl NormalizedMeasurement {
    pub fn to_golden_json(&self) -> Value {
        let mut root = Map::new();
        if let Some(mode) = &self.application_mode {
            root.insert("application_mode".into(), json!(mode));
        }
        root.insert(
            "channels".into(),
            Value::Array(self.channels.iter().map(encode_golden_channel).collect()),
        );
        root.insert("contract_version".into(), json!(1));
        root.insert("instrument".into(), encode_instrument(&self.instrument));
        root.insert(
            "metadata_sections".into(),
            Value::Array(
                self.metadata_sections
                    .iter()
                    .map(encode_metadata_section)
                    .collect(),
            ),
        );
        root.insert("provenance".into(), encode_string_map(&self.provenance));
        root.insert("source".into(), encode_source(&self.source));
        root.insert("support_status".into(), json!(self.support_status));
        root.insert("view".into(), encode_view(&self.view));
        root.insert(
            "warnings".into(),
            Value::Array(self.warnings.iter().map(|w| json!(w)).collect()),
        );
        Value::Object(root)
    }

    pub fn from_golden_json(value: &Value) -> Result<Self, ContractError> {
        let contract_version = value
            .get("contract_version")
            .and_then(|v| v.as_i64())
            .ok_or_else(|| {
                ContractError::Invalid("Missing or malformed contract version".to_string())
            })?;
        if contract_version != 1 {
            return Err(ContractError::UnsupportedVersion(contract_version));
        }

        let source = decode_source(value.get("source").ok_or_else(|| {
            ContractError::Invalid("Malformed normalized measurement: missing source".to_string())
        })?)?;
        let instrument = decode_instrument(value.get("instrument").ok_or_else(|| {
            ContractError::Invalid(
                "Malformed normalized measurement: missing instrument".to_string(),
            )
        })?)?;
        let view = decode_view(value.get("view").ok_or_else(|| {
            ContractError::Invalid("Malformed normalized measurement: missing view".to_string())
        })?)?;
        let channels = decode_golden_channels(value.get("channels").ok_or_else(|| {
            ContractError::Invalid("Malformed normalized measurement: missing channels".to_string())
        })?)?;
        let metadata_sections =
            decode_metadata_sections(value.get("metadata_sections").unwrap_or(&Value::Null))?;
        let warnings = decode_string_array(value.get("warnings").unwrap_or(&Value::Null))?;
        let support_status = value
            .get("support_status")
            .and_then(|v| v.as_str())
            .ok_or_else(|| {
                ContractError::Invalid(
                    "Malformed normalized measurement: missing support_status".to_string(),
                )
            })?
            .to_string();
        let application_mode = value
            .get("application_mode")
            .and_then(|v| v.as_str())
            .map(str::to_string);
        let provenance = decode_string_map(value.get("provenance").unwrap_or(&json!({})))?;

        let measurement = NormalizedMeasurement {
            source,
            instrument,
            application_mode,
            view,
            channels,
            metadata_sections,
            warnings,
            support_status,
            provenance,
        };
        super::contract::validate_measurement(&measurement)?;
        Ok(measurement)
    }
}

fn encode_source(source: &SourceIdentity) -> Value {
    let mut map = Map::new();
    map.insert("path".into(), json!(source.path));
    map.insert("sha256".into(), json!(source.sha256));
    Value::Object(map)
}

fn encode_instrument(instrument: &InstrumentIdentity) -> Value {
    let mut map = Map::new();
    map.insert("id".into(), json!(instrument.id));
    if let Some(model) = &instrument.model {
        map.insert("model".into(), json!(model));
    }
    map.insert("name".into(), json!(instrument.name));
    if let Some(vendor) = &instrument.vendor {
        map.insert("vendor".into(), json!(vendor));
    }
    Value::Object(map)
}

fn encode_view(view: &MeasurementView) -> Value {
    let mut map = Map::new();
    map.insert("kind".into(), json!(view.kind));
    map.insert("preserve_order".into(), json!(view.preserve_order));
    if let Some(x) = &view.x {
        map.insert("x".into(), json!(x));
    }
    if let Some(y) = &view.y {
        map.insert(
            "y".into(),
            Value::Array(y.iter().map(|s| json!(s)).collect()),
        );
    }
    Value::Object(map)
}

fn encode_string_map(map: &BTreeMap<String, String>) -> Value {
    let mut obj = Map::new();
    for (key, value) in map {
        obj.insert(key.clone(), json!(value));
    }
    Value::Object(obj)
}

fn encode_golden_channel(channel: &MeasurementChannel) -> Value {
    let mut map = Map::new();
    map.insert("label".into(), json!(channel.label));
    map.insert("name".into(), json!(channel.name));
    if let Some(quantity) = &channel.quantity {
        map.insert("quantity".into(), json!(quantity));
    }
    map.insert("unit".into(), json!(channel.unit));
    map.insert(
        "gap_reasons".into(),
        Value::Array(
            channel
                .gap_reasons
                .iter()
                .map(|reason| match reason {
                    Some(r) => json!(r.as_str()),
                    None => Value::Null,
                })
                .collect(),
        ),
    );
    map.insert(
        "values".into(),
        Value::Array(
            channel
                .values
                .iter()
                .map(|value| match value {
                    Some(v) => json!({ "bits": format!("{:016x}", v.to_bits()) }),
                    None => Value::Null,
                })
                .collect(),
        ),
    );
    Value::Object(map)
}

fn encode_metadata_section(section: &MetadataSection) -> Value {
    json!({
        "title": section.title,
        "fields": section.fields.iter().map(encode_metadata_field).collect::<Vec<_>>(),
    })
}

fn encode_metadata_field(field: &MetadataField) -> Value {
    let mut map = Map::new();
    map.insert("key".into(), json!(field.key));
    map.insert("kind".into(), json!(field.kind));
    map.insert("label".into(), json!(field.label));
    if let Some(unit) = &field.unit {
        map.insert("unit".into(), json!(unit));
    }
    map.insert("value".into(), encode_json_value(&field.value));
    Value::Object(map)
}

fn encode_json_value(value: &JSONValue) -> Value {
    match value {
        JSONValue::String(s) => json!(s),
        JSONValue::Number(n) => encode_golden_number(*n),
        JSONValue::Boolean(b) => json!(b),
        JSONValue::Null => Value::Null,
    }
}

fn encode_golden_number(n: f64) -> Value {
    if n.is_finite() && n.fract() == 0.0 {
        if n >= 0.0 && n <= u64::MAX as f64 {
            json!(n as u64)
        } else if n >= i64::MIN as f64 && n <= i64::MAX as f64 {
            json!(n as i64)
        } else {
            json!(n)
        }
    } else {
        json!(n)
    }
}

fn decode_source(value: &Value) -> Result<SourceIdentity, ContractError> {
    Ok(SourceIdentity {
        path: value
            .get("path")
            .and_then(|v| v.as_str())
            .unwrap_or_default()
            .to_string(),
        sha256: value
            .get("sha256")
            .and_then(|v| v.as_str())
            .unwrap_or_default()
            .to_string(),
    })
}

fn decode_instrument(value: &Value) -> Result<InstrumentIdentity, ContractError> {
    Ok(InstrumentIdentity {
        id: value
            .get("id")
            .and_then(|v| v.as_str())
            .ok_or_else(|| ContractError::Invalid("Missing instrument id".to_string()))?
            .to_string(),
        name: value
            .get("name")
            .and_then(|v| v.as_str())
            .ok_or_else(|| ContractError::Invalid("Missing instrument name".to_string()))?
            .to_string(),
        vendor: value
            .get("vendor")
            .and_then(|v| v.as_str())
            .map(str::to_string),
        model: value
            .get("model")
            .and_then(|v| v.as_str())
            .map(str::to_string),
    })
}

fn decode_view(value: &Value) -> Result<MeasurementView, ContractError> {
    Ok(MeasurementView {
        kind: value
            .get("kind")
            .and_then(|v| v.as_str())
            .ok_or_else(|| ContractError::Invalid("Missing view kind".to_string()))?
            .to_string(),
        x: value.get("x").and_then(|v| v.as_str()).map(str::to_string),
        y: value.get("y").and_then(|v| {
            v.as_array().map(|arr| {
                arr.iter()
                    .filter_map(|item| item.as_str().map(str::to_string))
                    .collect()
            })
        }),
        preserve_order: value
            .get("preserve_order")
            .and_then(|v| v.as_bool())
            .unwrap_or(false),
    })
}

fn decode_golden_channels(value: &Value) -> Result<Vec<MeasurementChannel>, ContractError> {
    let array = value.as_array().ok_or_else(|| {
        ContractError::Invalid("Malformed normalized measurement: channels".to_string())
    })?;
    array.iter().map(decode_golden_channel).collect()
}

fn decode_golden_channel(value: &Value) -> Result<MeasurementChannel, ContractError> {
    let name = value
        .get("name")
        .and_then(|v| v.as_str())
        .ok_or_else(|| ContractError::Invalid("Missing channel name".to_string()))?
        .to_string();
    let label = value
        .get("label")
        .and_then(|v| v.as_str())
        .unwrap_or_default()
        .to_string();
    let unit = value
        .get("unit")
        .and_then(|v| v.as_str())
        .unwrap_or_default()
        .to_string();
    let quantity = value
        .get("quantity")
        .and_then(|v| v.as_str())
        .map(str::to_string);
    let values_array = value
        .get("values")
        .and_then(|v| v.as_array())
        .ok_or_else(|| ContractError::Invalid(format!("Channel {name} missing values array")))?;
    let mut values = Vec::with_capacity(values_array.len());
    for sample in values_array {
        if sample.is_null() {
            values.push(None);
            continue;
        }
        let bits = sample.get("bits").and_then(|v| v.as_str()).ok_or_else(|| {
            ContractError::Invalid(format!("Channel {name} value missing bits object"))
        })?;
        let parsed = u64::from_str_radix(bits, 16).map_err(|_| {
            ContractError::Invalid(format!("Channel {name} has malformed bits hex"))
        })?;
        values.push(Some(f64::from_bits(parsed)));
    }

    let gap_reasons = if let Some(reasons) = value.get("gap_reasons") {
        let arr = reasons.as_array().ok_or_else(|| {
            ContractError::Invalid(format!("Channel {name} gap_reasons must be an array"))
        })?;
        if arr.len() != values.len() {
            return Err(ContractError::Invalid(format!(
                "gap_reasons length ({}) must match values length ({})",
                arr.len(),
                values.len()
            )));
        }
        arr.iter()
            .map(|item| {
                if item.is_null() {
                    Ok(None)
                } else {
                    let s = item.as_str().ok_or_else(|| {
                        ContractError::Invalid(format!("Channel {name} gap_reason must be string"))
                    })?;
                    GapReason::parse(s)
                        .ok_or_else(|| ContractError::Invalid(format!("Unknown gap reason {s}")))
                        .map(Some)
                }
            })
            .collect::<Result<Vec<_>, _>>()?
    } else {
        values
            .iter()
            .map(|v| {
                if v.is_none() {
                    Some(GapReason::Unknown)
                } else {
                    None
                }
            })
            .collect()
    };

    Ok(MeasurementChannel {
        name,
        label,
        unit,
        quantity,
        values,
        gap_reasons,
    })
}

fn decode_metadata_sections(value: &Value) -> Result<Vec<MetadataSection>, ContractError> {
    if value.is_null() {
        return Ok(Vec::new());
    }
    let array = value
        .as_array()
        .ok_or_else(|| ContractError::Invalid("metadata_sections must be an array".to_string()))?;
    array.iter().map(decode_metadata_section).collect()
}

fn decode_metadata_section(value: &Value) -> Result<MetadataSection, ContractError> {
    let title = value
        .get("title")
        .and_then(|v| v.as_str())
        .unwrap_or_default()
        .to_string();
    let fields = decode_metadata_fields(value.get("fields").unwrap_or(&Value::Null))?;
    Ok(MetadataSection { title, fields })
}

fn decode_metadata_fields(value: &Value) -> Result<Vec<MetadataField>, ContractError> {
    if value.is_null() {
        return Ok(Vec::new());
    }
    let array = value.as_array().ok_or_else(|| {
        ContractError::Invalid("metadata field list must be an array".to_string())
    })?;
    array.iter().map(decode_metadata_field).collect()
}

fn decode_metadata_field(value: &Value) -> Result<MetadataField, ContractError> {
    Ok(MetadataField {
        key: value
            .get("key")
            .and_then(|v| v.as_str())
            .unwrap_or_default()
            .to_string(),
        label: value
            .get("label")
            .and_then(|v| v.as_str())
            .unwrap_or_default()
            .to_string(),
        value: decode_json_value(value.get("value").unwrap_or(&Value::Null))?,
        unit: value
            .get("unit")
            .and_then(|v| v.as_str())
            .map(str::to_string),
        kind: value
            .get("kind")
            .and_then(|v| v.as_str())
            .unwrap_or_default()
            .to_string(),
    })
}

fn decode_json_value(value: &Value) -> Result<JSONValue, ContractError> {
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
    Err(ContractError::Invalid(
        "Unsupported metadata JSON value".to_string(),
    ))
}

fn decode_string_array(value: &Value) -> Result<Vec<String>, ContractError> {
    if value.is_null() {
        return Ok(Vec::new());
    }
    Ok(value
        .as_array()
        .ok_or_else(|| ContractError::Invalid("warnings must be an array".to_string()))?
        .iter()
        .filter_map(|v| v.as_str().map(str::to_string))
        .collect())
}

fn decode_string_map(value: &Value) -> Result<BTreeMap<String, String>, ContractError> {
    let obj = value
        .as_object()
        .ok_or_else(|| ContractError::Invalid("provenance must be an object".to_string()))?;
    Ok(obj
        .iter()
        .filter_map(|(k, v)| v.as_str().map(|s| (k.clone(), s.to_string())))
        .collect())
}
