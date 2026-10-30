import Foundation
import Testing
@testable import RawViewCore

@Test func selectedSourceContractPreservesDeclaredChannelOrder() throws {
    let json = #"{"contract_version":1,"source":{"path":"data/raw/selected.csv","sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"},"instrument":{"id":"keysight-b1500a","name":"Keysight B1500A"},"application_mode":"list-sweep","view":{"kind":"xy","x":"voltage","y":["current"],"preserve_order":true},"channels":[{"name":"voltage","label":"Voltage","unit":"V","quantity":"voltage","values":[0.2,0.0,0.1]},{"name":"current","label":"Current","unit":"A","values":[3,1,2]}],"metadata_sections":[],"warnings":[],"support_status":"supported","provenance":{}}"#
    let measurement = try NormalizedMeasurement.decode(Data(json.utf8))
    #expect(measurement.view.preserveOrder)
    #expect(measurement.channel(named: "voltage")?.values == [0.2, 0.0, 0.1])
    #expect(measurement.channel(named: "voltage")?.quantity == "voltage")
    #expect(measurement.channel(named: "current")?.values == [3, 1, 2])
    #expect(measurement.channel(named: "current")?.quantity == nil)
}

@Test func rejectsUnsupportedContractVersion() {
    let json = #"{"contract_version":2}"#
    #expect(throws: ContractError.unsupportedVersion(2)) {
        try NormalizedMeasurement.decode(Data(json.utf8))
    }
}

@Test func contractAcceptsNullGapsAndRejectsNonFiniteNumbers() throws {
    let json = #"{"contract_version":1,"source":{"path":"data/raw/g.csv","sha256":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"},"instrument":{"id":"keysight-b1500a","name":"Keysight B1500A"},"application_mode":"dual-sweep","view":{"kind":"xy","x":"voltage","y":["current"],"preserve_order":true},"channels":[{"name":"voltage","label":"Voltage","unit":"V","quantity":"voltage","values":[0,0.1,null]},{"name":"current","label":"Current","unit":"A","values":[1e-12,null,3e-12]}],"metadata_sections":[],"warnings":[],"support_status":"supported","provenance":{}}"#
    let measurement = try NormalizedMeasurement.decode(Data(json.utf8))
    #expect(measurement.channel(named: "voltage")?.values == [0, 0.1, nil])
    #expect(measurement.channel(named: "current")?.gapCount == 1)
    #expect(AxisTransform.segments(x: [0, 0.1, nil], y: [1e-12, nil, 3e-12]) == [[0]])
}

@Test func contractGapReasonsRoundTripThroughDecode() throws {
    let json = #"{"contract_version":1,"source":{"path":"data/raw/g.csv","sha256":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"},"instrument":{"id":"keysight-b1500a","name":"Keysight B1500A"},"application_mode":"dual-sweep","view":{"kind":"xy","x":"voltage","y":["current"],"preserve_order":true},"channels":[{"name":"voltage","label":"Voltage","unit":"V","values":[0.0,0.1]},{"name":"current","label":"Current","unit":"A","values":[null,null],"gap_reasons":["blank","nan"]}],"metadata_sections":[],"warnings":[],"support_status":"supported","provenance":{}}"#
    let measurement = try NormalizedMeasurement.decode(Data(json.utf8))
    #expect(measurement.channel(named: "current")?.gapReasons == [.blank, .nan])
}

@Test func contractRejectsMisalignedGapReasons() throws {
    let json = #"{"contract_version":1,"source":{"path":"data/raw/g.csv","sha256":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"},"instrument":{"id":"keysight-b1500a","name":"Keysight B1500A"},"application_mode":"dual-sweep","view":{"kind":"xy","x":"voltage","y":["current"],"preserve_order":true},"channels":[{"name":"voltage","label":"Voltage","unit":"V","values":[1.0]},{"name":"current","label":"Current","unit":"A","values":[null],"gap_reasons":["blank","nan"]}],"metadata_sections":[],"warnings":[],"support_status":"supported","provenance":{}}"#
    #expect(throws: ContractError.self) {
        try NormalizedMeasurement.decode(Data(json.utf8))
    }
}
