import Foundation
import Testing
@testable import RawViewCore

@Test func selectedSourceContractPreservesDeclaredChannelOrder() throws {
    let json = #"{"contract_version":1,"source":{"path":"data/raw/selected.csv","sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"},"instrument":{"id":"keysight-b1500a","name":"Keysight B1500A"},"application_mode":"list-sweep","view":{"kind":"xy","x":"voltage","y":["current"],"preserve_order":true},"channels":[{"name":"voltage","label":"Voltage","unit":"V","values":[0.2,0.0,0.1]},{"name":"current","label":"Current","unit":"A","values":[3,1,2]}],"metadata_sections":[],"warnings":[],"support_status":"supported","provenance":{}}"#
    let measurement = try NormalizedMeasurement.decode(Data(json.utf8))
    #expect(measurement.view.preserveOrder)
    #expect(measurement.channel(named: "voltage")?.values == [0.2, 0.0, 0.1])
    #expect(measurement.channel(named: "current")?.values == [3, 1, 2])
}

@Test func rejectsUnsupportedContractVersion() {
    let json = #"{"contract_version":2}"#
    #expect(throws: ContractError.unsupportedVersion(2)) {
        try NormalizedMeasurement.decode(Data(json.utf8))
    }
}
