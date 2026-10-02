import Foundation
import Testing
@testable import RawViewCore

@Test func decodesInspectionMetadataAndSourceErrors() throws {
    let json = #"{"sources":[{"source":"data/raw/a.csv","size":42,"instrument_id":"b1500","instrument_name":"B1500A","application_mode":"sweep","timestamp":"2026-09-30T10:00:00Z","device_id":"D1","study_token":"study-a","support_status":"supported","validation_state":"valid","reader_version":"1.2","profile_id":"iv","profile_hash":"abc"},{"source":"data/raw/b.csv","error":"unsupported format"}]}"#
    let values = try JSONDecoder().decode(InspectionEnvelope.self, from: Data(json.utf8)).sources
    #expect(values.count == 2)
    #expect(values[0].instrumentID == "b1500")
    #expect(values[0].profileHash == "abc")
    #expect(values[1].error == "unsupported format")
}

@Test func malformedInspectionRowDoesNotDiscardNeighboringRows() throws {
    let json = #"{"sources":[{"source":"data/raw/a.csv","instrument_id":"fixture"},{"source":"data/raw/b.csv","size":"bad"},{"source":"data/raw/c.csv","error":"unsupported format"}]}"#
    let values = try InspectionEnvelope.decodeRows(Data(json.utf8))
    #expect(values.count == 3)
    #expect(values[0].inspection?.instrumentID == "fixture")
    #expect(values[1].inspection == nil)
    #expect(values[1].source == "data/raw/b.csv")
    #expect(values[1].error?.contains("Malformed") == true)
    #expect(values[2].error == "unsupported format")
}

@Test func inspectionChunksNeverExceed256() {
    let values = (0..<513).map { RawSource(relativePath: "data/raw/\($0).csv", url: URL(fileURLWithPath: "/tmp/\($0).csv"), byteSize: 1) }
    let chunks = InspectionBatch.chunks(values)
    #expect(chunks.map(\.count) == [256, 256, 1])
    #expect(chunks.flatMap { $0 }.map(\.relativePath) == values.map(\.relativePath))
}

@Test func sourceInspectionErrorCanRemainLocalToOneSource() {
    let source = RawSource(relativePath: "data/raw/b.csv", url: URL(fileURLWithPath: "/tmp/b.csv"), byteSize: 1)
    let result = SourceInspectionResult(source: source, inspection: nil, error: "unsupported format")
    #expect(result.id == source.relativePath)
    #expect(result.error == "unsupported format")
}

@Test func cancellationBeforeProcessStartPreventsLaunch() throws {
    let marker = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/touch")
    process.arguments = [marker.path]
    let runner = RunningProcess()
    runner.cancel()
    #expect(throws: CancellationError.self) { try runner.start(process) }
    #expect(!FileManager.default.fileExists(atPath: marker.path))
}
