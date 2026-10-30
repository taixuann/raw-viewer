//! Normalized measurement contract (v1): decode, validate, and golden JSON.

mod contract;
mod golden;

pub use contract::{
    ContractError, GapReason, InstrumentIdentity, JSONValue, MeasurementChannel, MeasurementView,
    MetadataField, MetadataSection, NormalizedMeasurement, SourceIdentity,
};

#[cfg(test)]
mod tests {
    use super::{ContractError, GapReason, NormalizedMeasurement};

    #[test]
    fn rejects_unsupported_contract_version() {
        let json = br#"{"contract_version":2}"#;
        let err = NormalizedMeasurement::decode(json).unwrap_err();
        assert_eq!(err, ContractError::UnsupportedVersion(2));
    }

    #[test]
    fn contract_accepts_null_gaps() {
        let json = br#"{"contract_version":1,"source":{"path":"data/raw/g.csv","sha256":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"},"instrument":{"id":"keysight-b1500a","name":"Keysight B1500A"},"application_mode":"dual-sweep","view":{"kind":"xy","x":"voltage","y":["current"],"preserve_order":true},"channels":[{"name":"voltage","label":"Voltage","unit":"V","quantity":"voltage","values":[0,0.1,null]},{"name":"current","label":"Current","unit":"A","values":[1e-12,null,3e-12]}],"metadata_sections":[],"warnings":[],"support_status":"supported","provenance":{}}"#;
        let measurement = NormalizedMeasurement::decode(json).expect("decode");
        assert_eq!(
            measurement.channel("voltage").unwrap().values,
            vec![Some(0.0), Some(0.1), None]
        );
        assert_eq!(measurement.channel("current").unwrap().gap_count(), 1);
    }

    #[test]
    fn contract_gap_reasons_round_trip_via_golden_json() {
        let json = br#"{"contract_version":1,"source":{"path":"data/raw/g.csv","sha256":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"},"instrument":{"id":"keysight-b1500a","name":"Keysight B1500A"},"application_mode":"dual-sweep","view":{"kind":"xy","x":"voltage","y":["current"],"preserve_order":true},"channels":[{"name":"voltage","label":"Voltage","unit":"V","values":[0.0,0.1]},{"name":"current","label":"Current","unit":"A","values":[null,null],"gap_reasons":["blank","nan"]}],"metadata_sections":[],"warnings":[],"support_status":"supported","provenance":{}}"#;
        let decoded = NormalizedMeasurement::decode(json).expect("decode");
        assert_eq!(
            decoded.channel("current").unwrap().gap_reasons,
            vec![Some(GapReason::Blank), Some(GapReason::Nan)]
        );
        let golden = decoded.to_golden_json();
        let round_trip =
            NormalizedMeasurement::from_golden_json(&golden).expect("from golden json");
        assert_eq!(
            round_trip.channel("current").unwrap().gap_reasons,
            vec![Some(GapReason::Blank), Some(GapReason::Nan)]
        );
        assert_eq!(
            round_trip.channel("voltage").unwrap().values,
            decoded.channel("voltage").unwrap().values
        );
    }
}
