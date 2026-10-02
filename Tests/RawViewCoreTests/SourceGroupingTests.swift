import Testing
@testable import RawViewCore

struct SourceGroupingTests {
    @Test func projectsConfirmedMetadataAndPreservesStableSourceIdentity() {
        let first = inspection(
            source: "data/raw/a.csv", instrumentID: "b1500", instrumentName: "B1500A",
            mode: "sweep", timestamp: "2026-09-30T10:00:00Z", deviceID: "D1", studyToken: "study-a",
            support: "supported", validation: "valid"
        )
        let second = inspection(source: "data/raw/b.csv", instrumentID: "b1500", mode: "pulse", studyToken: "study-b")
        let grouping = SourceGrouping(inspections: [second, first])

        #expect(grouping.sampleDevice.map(\.label) == ["D1"])
        #expect(grouping.instrument.map(\.label) == ["B1500A"])
        #expect(grouping.study.map(\.label) == ["study-a", "study-b"])
        #expect(grouping.measurementMode.map(\.label) == ["pulse", "sweep"])
        #expect(grouping.dateBatch.map(\.label) == ["2026-09-30"])
        #expect(grouping.status.map(\.label) == ["Support: supported", "Validation: valid"])
        #expect(grouping.instrument[0].sourceIDs == ["data/raw/a.csv", "data/raw/b.csv"])
        #expect(grouping.study[0].sourceIDs == ["data/raw/a.csv"])
        #expect(grouping.sampleDevice[0].sourceIDs == ["data/raw/a.csv"])
    }

    @Test func omitsMissingValuesAndUsesStudyTokenOnly() {
        let value = inspection(source: "data/raw/no-metadata.csv", instrumentID: "", mode: " ", timestamp: "nonsense", deviceID: nil, studyToken: nil)
        let grouping = SourceGrouping(inspections: [value])
        #expect(grouping.sampleDevice.isEmpty)
        #expect(grouping.instrument.isEmpty)
        #expect(grouping.study.isEmpty)
        #expect(grouping.measurementMode.isEmpty)
        #expect(grouping.dateBatch.isEmpty)
        #expect(grouping.status.isEmpty)
    }

    @Test func rejectsNonDigitDateComponents() {
        let value = inspection(source: "data/raw/malformed-date.csv", timestamp: "2026-+9-30T10:00:00Z")
        #expect(SourceGrouping(inspections: [value]).dateBatch.isEmpty)
    }

    private func inspection(
        source: String, instrumentID: String? = nil, instrumentName: String? = nil,
        mode: String? = nil, timestamp: String? = nil, deviceID: String? = nil,
        studyToken: String? = nil, support: String? = nil, validation: String? = nil
    ) -> SourceInspection {
        SourceInspection(source: source, size: nil, instrumentID: instrumentID, instrumentName: instrumentName,
                         applicationMode: mode, timestamp: timestamp, deviceID: deviceID, studyToken: studyToken,
                         supportStatus: support, validationState: validation, readerVersion: nil, profileID: nil,
                         profileHash: nil, error: nil)
    }
}
