import Testing
@testable import RawViewCore

struct SourceGroupingTests {
    @Test func projectsConfirmedMetadataAndPreservesStableSourceIdentity() {
        let first = inspection(
            source: "data/raw/a.csv", instrumentID: "b1500", instrumentName: "B1500A",
            mode: "sweep", timestamp: "2026-09-30T10:00:00Z", deviceID: "D1", category: "study-a",
            support: "supported", validation: "valid"
        )
        let second = inspection(source: "data/raw/b.csv", instrumentID: "b1500", mode: "pulse", category: "study-b")
        let grouping = SourceGrouping(inspections: [second, first])

        #expect(grouping.sampleDevice.map(\.label) == ["D1"])
        #expect(grouping.instrument.map(\.label) == ["B1500A"])
        #expect(grouping.category.map(\.label) == ["study-a", "study-b"])
        #expect(grouping.measurementMode.map(\.label) == ["pulse", "sweep"])
        #expect(grouping.dateBatch.map(\.label) == ["2026-09-30"])
        #expect(grouping.status.map(\.label) == ["Support: supported", "Validation: valid"])
        #expect(grouping.instrument[0].sourceIDs == ["data/raw/a.csv", "data/raw/b.csv"])
        #expect(grouping.category[0].sourceIDs == ["data/raw/a.csv"])
        #expect(grouping.sampleDevice[0].sourceIDs == ["data/raw/a.csv"])
    }

    @Test func omitsMissingValuesAndUsesCategoryOnly() {
        let value = inspection(source: "data/raw/no-metadata.csv", instrumentID: "", mode: " ", timestamp: "nonsense", deviceID: nil, category: nil)
        let grouping = SourceGrouping(inspections: [value])
        #expect(grouping.sampleDevice.isEmpty)
        #expect(grouping.instrument.isEmpty)
        #expect(grouping.category.isEmpty)
        #expect(grouping.measurementMode.isEmpty)
        #expect(grouping.dateBatch.isEmpty)
        #expect(grouping.status.isEmpty)
    }

    @Test func parsesRealFilenameTimestampConventionForDateBatch() {
        // Real convention DDMMYY-HHMMSS validates as a calendar date.
        #expect(SourceGrouping.date(from: "311224-235958") == "2024-12-31")
        #expect(SourceGrouping.date(from: "010100-000000") == "2000-01-01")
        #expect(SourceGrouping.date(from: "311224") == "2024-12-31")
        // Impossible calendar values stay unknown instead of grouping.
        #expect(SourceGrouping.date(from: "999999-999999") == nil)
        #expect(SourceGrouping.date(from: "321224-235958") == nil)
        #expect(SourceGrouping.date(from: "311324-235958") == nil)
        #expect(SourceGrouping.date(from: "311224-246060") == nil)
    }

    @Test func rejectsNonDigitDateComponents() {
        let value = inspection(source: "data/raw/malformed-date.csv", timestamp: "2026-+9-30T10:00:00Z")
        #expect(SourceGrouping(inspections: [value]).dateBatch.isEmpty)
    }

    @Test func keepsDistinctInstrumentsSeparateWhenDisplayNamesCollide() {
        let first = inspection(source: "data/raw/a.csv", instrumentID: "id-1", instrumentName: "Shared Name")
        let second = inspection(source: "data/raw/b.csv", instrumentID: "id-2", instrumentName: "Shared Name")
        let grouping = SourceGrouping(inspections: [first, second])
        #expect(grouping.instrument.count == 2)
        #expect(Set(grouping.instrument.flatMap(\.sourceIDs)) == ["data/raw/a.csv", "data/raw/b.csv"])
    }

    private func inspection(
        source: String, instrumentID: String? = nil, instrumentName: String? = nil,
        mode: String? = nil, timestamp: String? = nil, deviceID: String? = nil,
        category: String? = nil, support: String? = nil, validation: String? = nil
    ) -> SourceInspection {
        SourceInspection(source: source, size: nil, instrumentID: instrumentID, instrumentName: instrumentName,
                         applicationMode: mode, timestamp: timestamp, deviceID: deviceID, category: category,
                         supportStatus: support, validationState: validation, readerVersion: nil, profileID: nil,
                         profileHash: nil, error: nil)
    }
}
