import Foundation
import Testing
@testable import RawViewCore

@Test func sourceInspectionErrorCanRemainLocalToOneSource() {
    let source = RawSource(relativePath: "data/raw/b.csv", url: URL(fileURLWithPath: "/tmp/b.csv"), byteSize: 1)
    let result = SourceInspectionResult(source: source, inspection: nil, error: "unsupported format")
    #expect(result.id == source.relativePath)
    #expect(result.error == "unsupported format")
    #expect(result.inspection == nil)
}

@Test func sourceInspectionCarriesProfileIdentityAndSupportState() {
    let source = RawSource(relativePath: "data/raw/a.csv", url: URL(fileURLWithPath: "/tmp/a.csv"), byteSize: 42)
    let inspection = SourceInspection(
        source: source.relativePath, size: 42, instrumentID: "keysight-b1500a", instrumentName: "Keysight B1500A",
        applicationMode: "dual-sweep", timestamp: nil, deviceID: nil, category: nil,
        supportStatus: "supported", validationState: "profile valid; source not loaded",
        readerVersion: InstrumentReader.version, profileID: "keysight-b1500a", profileHash: "abc", error: nil
    )
    let result = SourceInspectionResult(source: source, inspection: inspection, error: nil)
    #expect(result.inspection?.instrumentID == "keysight-b1500a")
    #expect(result.inspection?.applicationMode == "dual-sweep")
    #expect(result.inspection?.profileHash == "abc")
    #expect(result.inspection?.readerVersion == InstrumentReader.version)
}
