import Foundation

@main
enum CoreSelfCheck {
    static func main() async throws {
        let json = #"{"contract_version":1,"source":{"path":"data/raw/selected.csv","sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"},"instrument":{"id":"keysight-b1500a","name":"Keysight B1500A"},"application_mode":"list-sweep","view":{"kind":"xy","x":"voltage","y":["current"],"preserve_order":true},"channels":[{"name":"voltage","label":"Voltage","unit":"V","values":[0.2,0.0,0.1]},{"name":"current","label":"Current","unit":"A","values":[3.0,1.0,2.0]}],"metadata_sections":[],"warnings":[],"support_status":"supported","provenance":{}}"#
        let value = try NormalizedMeasurement.decode(Data(json.utf8))
        precondition(value.view.preserveOrder)
        precondition(value.channel(named: "voltage")?.values == [0.2, 0.0, 0.1])
        precondition(value.channel(named: "current")?.values == [3, 1, 2])
        precondition(AxisTransform.values([-1, 2], absolute: false, scale: .logarithmic) == .failure(.invalidLogDomain))
        precondition(AxisTransform.values([-1, 2], absolute: true, scale: .logarithmic) == .success([0, log10(2)]))
        let inspectionJSON = #"{"sources":[{"source":"data/raw/a.csv","size":7,"instrument_id":"fixture","instrument_name":"Fixture","application_mode":"sweep","timestamp":"2026-09-30","device_id":"D1","study_token":"S1","support_status":"supported","validation_state":"valid","reader_version":"1","profile_id":"iv","profile_hash":"abc"},{"source":"data/raw/b.csv","size":"malformed"},{"source":"data/raw/c.csv","error":"unsupported"}]}"#
        let inspections = try InspectionEnvelope.decodeRows(Data(inspectionJSON.utf8))
        precondition(inspections.count == 3)
        precondition(inspections.first?.inspection?.instrumentID == "fixture" && inspections.first?.inspection?.profileHash == "abc")
        precondition(inspections[1].inspection == nil && inspections[1].error?.contains("Malformed") == true)
        precondition(inspections.last?.error == "unsupported")
        let grouping = SourceGrouping(inspections: inspections.compactMap(\.inspection))
        precondition(grouping.sampleDevice.map(\.label) == ["D1"])
        precondition(grouping.instrument.map(\.label) == ["Fixture"])
        precondition(grouping.study.map(\.label) == ["S1"])
        precondition(grouping.study[0].sourceIDs == ["data/raw/a.csv"])
        precondition(grouping.measurementMode.map(\.label) == ["sweep"])
        precondition(grouping.dateBatch.map(\.label) == ["2026-09-30"])
        precondition(grouping.status.map(\.label) == ["Support: supported", "Validation: valid"])
        let malformedDate = SourceInspection(source: "data/raw/malformed-date.csv", size: nil,
                                             instrumentID: nil, instrumentName: nil, applicationMode: nil,
                                             timestamp: "2026-+9-30T10:00:00Z", deviceID: nil, studyToken: nil,
                                             supportStatus: nil, validationState: nil, readerVersion: nil,
                                             profileID: nil, profileHash: nil, error: nil)
        precondition(SourceGrouping(inspections: [malformedDate]).dateBatch.isEmpty)
        let filter = SourceFilter()
        precondition(filter.isEmpty)
        precondition(filter.matches(["instrument": ["Fixture"], "study": ["S1"]]))
        var f = SourceFilter(); f.toggle(facet: "instrument", value: "Fixture")
        precondition(f.matches(["instrument": ["Fixture"], "study": ["Other"]]))   // OR within facet
        var g = SourceFilter(); g.toggle(facet: "instrument", value: "Fixture"); g.toggle(facet: "study", value: "Missing")
        precondition(!g.matches(["instrument": ["Fixture"], "study": ["S1"]]))     // AND across facets excludes
        g.clear()
        precondition(g.isEmpty && g.matches([:]))
        var h = SourceFilter(); h.toggle(facet: "instrument", value: "A"); h.toggle(facet: "instrument", value: "B")
        precondition(h.matches(["instrument": ["B"]]))                              // OR values
        h.remove(facet: "instrument", value: "A")
        precondition(h.matches(["instrument": ["B"]]) && !h.isEmpty)
        precondition(SourceGrouping.date(from: "2026-09-30T10:00:00Z") == "2026-09-30")
        precondition(SourceGrouping.date(from: "2026-+9-30T10:00:00Z") == nil)
        let cancelledRunner = RunningProcess()
        let cancellationMarker = FileManager.default.temporaryDirectory.appendingPathComponent("rawview-cancel-\(UUID().uuidString)")
        let cancelledProcess = Process()
        cancelledProcess.executableURL = URL(fileURLWithPath: "/usr/bin/touch")
        cancelledProcess.arguments = [cancellationMarker.path]
        cancelledRunner.cancel()
        do { try cancelledRunner.start(cancelledProcess); fatalError("cancelled process launched") }
        catch is CancellationError { }
        precondition(!FileManager.default.fileExists(atPath: cancellationMarker.path))
        let batchSources = (0..<513).map { RawSource(relativePath: "data/raw/\($0).csv", url: URL(fileURLWithPath: "/tmp/\($0).csv"), byteSize: 1) }
        precondition(InspectionBatch.chunks(batchSources).map(\.count) == [256, 256, 1])
        do {
            _ = try NormalizedMeasurement.decode(Data(#"{"contract_version":2}"#.utf8))
            fatalError("unsupported version was accepted")
        } catch ContractError.unsupportedVersion(2) {
        }
        try await trustBoundarySelfCheck()
        print("RawView core self-check passed")
    }

    static func trustBoundarySelfCheck() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rawview-self-check-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let raw = root.appendingPathComponent("data/raw")
        let instruments = root.appendingPathComponent("data/instruments")
        try FileManager.default.createDirectory(at: raw.appendingPathComponent("nested"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: instruments, withIntermediateDirectories: true)
        try Data("b".utf8).write(to: raw.appendingPathComponent("z.csv"))
        try Data("a".utf8).write(to: raw.appendingPathComponent("nested/a.csv"))
        let outside = root.appendingPathComponent("outside.csv")
        try Data("outside marker".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: raw.appendingPathComponent("escape.csv"), withDestinationURL: outside)
        let readerlessProject = try ProjectContext.open(root)
        let discovered = try readerlessProject.discoverSources()
        precondition(ReaderApproval.issue(afterUserReviewOf: readerlessProject) == nil)
        precondition(discovered.map(\.relativePath) == ["data/raw/nested/a.csv", "data/raw/z.csv"])
        precondition(discovered.map(\.byteSize) == [1, 1])
        let externalReader = root.appendingPathComponent("external-reader.py")
        let readerMarker = root.appendingPathComponent("EXTERNAL_READER_EXECUTED")
        try Data("from pathlib import Path\nPath(\"\(readerMarker.path)\").write_text(\"ran\")\n".utf8).write(to: externalReader)
        try FileManager.default.createSymbolicLink(at: instruments.appendingPathComponent("reader.py"), withDestinationURL: externalReader)
        let unsafeReaderProject = try ProjectContext.open(root)
        let unsafeReaderSources = try unsafeReaderProject.discoverSources()
        precondition(unsafeReaderSources.map(\.relativePath) == ["data/raw/nested/a.csv", "data/raw/z.csv"])
        precondition(ReaderApproval.issue(afterUserReviewOf: unsafeReaderProject) == nil)
        precondition(!FileManager.default.fileExists(atPath: readerMarker.path))
        try FileManager.default.removeItem(at: instruments.appendingPathComponent("reader.py"))
        let reader = instruments.appendingPathComponent("reader.py")
        let stubReader = """
        import hashlib, json, pathlib, sys
        source = pathlib.Path(sys.argv[2]).resolve()
        root = pathlib.Path(__file__).resolve().parents[2]
        (root / "UNTRUSTED_READER_EXECUTED").write_text("ran")
        print(json.dumps({
            "contract_version": 1,
            "source": {"path": source.relative_to(root).as_posix(), "sha256": hashlib.sha256(source.read_bytes()).hexdigest()},
            "instrument": {"id": "synthetic", "name": "Synthetic test"},
            "application_mode": "xy",
            "view": {"kind": "xy", "x": "x", "y": ["y"], "preserve_order": True},
            "channels": [{"name": "x", "label": "X", "unit": "", "values": [0.2, 0.0, 0.1]}, {"name": "y", "label": "Y", "unit": "", "values": [3.0, 1.0, 2.0]}],
            "metadata_sections": [], "warnings": [], "support_status": "supported", "provenance": {}
        }))
        """
        try Data(stubReader.utf8).write(to: reader)
        let source = raw.appendingPathComponent("selected.csv")
        try Data("synthetic test marker".utf8).write(to: source)
        let project = try ProjectContext.open(root)
        precondition(project.containsSource(source))
        precondition(!project.containsSource(raw.appendingPathComponent("escape.csv")))
        let escapedProject = root.appendingPathComponent("escaped-project")
        let escapedRaw = escapedProject.appendingPathComponent("data/raw")
        let outsideInstruments = root.appendingPathComponent("outside-instruments")
        try FileManager.default.createDirectory(at: escapedRaw, withIntermediateDirectories: true)
        try Data("inventory".utf8).write(to: escapedRaw.appendingPathComponent("source.csv"))
        try FileManager.default.createDirectory(at: outsideInstruments, withIntermediateDirectories: true)
        try Data("from pathlib import Path\nPath(\"\(readerMarker.path)\").write_text(\"ran\")\n".utf8)
            .write(to: outsideInstruments.appendingPathComponent("reader.py"))
        try FileManager.default.createSymbolicLink(at: escapedProject.appendingPathComponent("data/instruments"), withDestinationURL: outsideInstruments)
        let instrumentsEscapedProject = try ProjectContext.open(escapedProject)
        let instrumentsEscapedSources = try instrumentsEscapedProject.discoverSources()
        precondition(instrumentsEscapedSources.map(\.relativePath) == ["data/raw/source.csv"])
        precondition(ReaderApproval.issue(afterUserReviewOf: instrumentsEscapedProject) == nil)
        precondition(!FileManager.default.fileExists(atPath: readerMarker.path))

        let internalProject = root.appendingPathComponent("internal-symlink-project")
        let internalRaw = internalProject.appendingPathComponent("data/raw")
        let internalInstruments = internalProject.appendingPathComponent("shared-instruments")
        let internalMarker = internalProject.appendingPathComponent("INTERNAL_READER_EXECUTED")
        try FileManager.default.createDirectory(at: internalRaw, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: internalInstruments, withIntermediateDirectories: true)
        try Data("inventory".utf8).write(to: internalRaw.appendingPathComponent("source.csv"))
        try Data("from pathlib import Path\nPath(\"\(internalMarker.path)\").write_text(\"ran\")\n".utf8)
            .write(to: internalInstruments.appendingPathComponent("reader.py"))
        try FileManager.default.createSymbolicLink(
            at: internalProject.appendingPathComponent("data/instruments"),
            withDestinationURL: internalInstruments
        )
        let internallyLinkedProject = try ProjectContext.open(internalProject)
        let internallyLinkedSources = try internallyLinkedProject.discoverSources()
        precondition(internallyLinkedSources.map(\.relativePath) == ["data/raw/source.csv"])
        precondition(!FileManager.default.fileExists(atPath: internalMarker.path))
        precondition(ReaderApproval.issue(afterUserReviewOf: internallyLinkedProject) != nil)
        precondition(!FileManager.default.fileExists(atPath: internalMarker.path))

        guard let oldApproval = ReaderApproval.issue(afterUserReviewOf: project) else { throw ReaderClientError.invalidProject }
        try Data("# changed after review\n".utf8).write(to: reader)
        do { _ = try await ReaderClient.load(source, project: project, approval: oldApproval); fatalError("changed reader passed review") }
        catch ReaderClientError.untrusted { }
        precondition(!FileManager.default.fileExists(atPath: root.appendingPathComponent("UNTRUSTED_READER_EXECUTED").path))
        try Data(stubReader.utf8).write(to: reader)
        let diagnosticReader = stubReader.replacingOccurrences(of: "import hashlib, json, pathlib, sys", with: "import hashlib, json, pathlib, sys\nprint('reader diagnostic', file=sys.stderr)")
        try Data(diagnosticReader.utf8).write(to: reader)
        guard let approvedAgain = ReaderApproval.issue(afterUserReviewOf: project) else { throw ReaderClientError.invalidProject }
        let loaded = try await ReaderClient.load(source, project: project, approval: approvedAgain)
        precondition(loaded.measurement.channel(named: "x")?.values == [0.2, 0.0, 0.1])
        precondition(loaded.measurement.source.path == "data/raw/selected.csv")
        precondition(loaded.readerSHA256.count == 64)
        precondition(FileManager.default.fileExists(atPath: root.appendingPathComponent("UNTRUSTED_READER_EXECUTED").path))
        let inspectProjectRoot = root.appendingPathComponent("inspect-fixture")
        let inspectRaw = inspectProjectRoot.appendingPathComponent("data/raw")
        let inspectInstruments = inspectProjectRoot.appendingPathComponent("data/instruments")
        try FileManager.default.createDirectory(at: inspectRaw, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: inspectInstruments, withIntermediateDirectories: true)
        let deepRaw = inspectRaw
            .appendingPathComponent(String(repeating: "a", count: 180), isDirectory: true)
            .appendingPathComponent(String(repeating: "b", count: 180), isDirectory: true)
            .appendingPathComponent(String(repeating: "c", count: 180), isDirectory: true)
        try FileManager.default.createDirectory(at: deepRaw, withIntermediateDirectories: true)
        for index in 0..<257 {
            let name = String(repeating: "s", count: 150) + "-\(index).csv"
            try Data("fixture".utf8).write(to: deepRaw.appendingPathComponent(name))
        }
        let inspectReader = """
        import json, pathlib, sys
        sys.stderr.write("x" * 200000)
        sys.stderr.flush()
        paths = json.load(sys.stdin)
        pathlib.Path(__file__).with_name("batch-count").open("a").write(str(len(paths)) + "\\n")
        print(json.dumps({"sources": [
            ({"source": p, "error": "fixture failure"} if p.endswith("-1.csv") else
             {"source": p, "size": "malformed"} if p.endswith("-2.csv") else
             {"source": p, "instrument_id": "fixture"})
            for p in paths
        ]}))
        """
        try Data(inspectReader.utf8).write(to: inspectInstruments.appendingPathComponent("reader.py"))
        let inspectProject = try ProjectContext.open(inspectProjectRoot)
        let inspectSources = try inspectProject.discoverSources()
        guard let inspectApproval = ReaderApproval.issue(afterUserReviewOf: inspectProject) else { throw ReaderClientError.invalidProject }
        precondition(inspectApproval.isCurrent(for: inspectProject))
        let inspectionProgress = InspectionProgressRecorder()
        let inspectionResults = await ReaderClient.inspectMany(inspectSources, project: inspectProject, approval: inspectApproval,
            onProgress: { rows, completed in await inspectionProgress.record(rows.count, completed) })
        precondition(inspectionResults.count == 257)
        precondition(inspectionResults.first(where: { $0.id.hasSuffix("-1.csv") })?.error == "fixture failure")
        precondition(inspectionResults.first(where: { $0.id.hasSuffix("-2.csv") })?.error?.contains("Malformed") == true)
        precondition(inspectionResults.filter { $0.inspection != nil }.count == 255)
        precondition(inspectionResults.filter { $0.error != nil }.count == 2)
        let inspectionProgressValues = await inspectionProgress.values
        precondition(inspectionProgressValues == [256, 257])
        let inspectionCancellation = InspectionCancellationHandle()
        let cancelledInspection = Task {
            await ReaderClient.inspectMany(inspectSources, project: inspectProject, approval: inspectApproval,
                onProgress: { _, completed in
                    if completed == 256 { await inspectionCancellation.cancel() }
                })
        }
        await inspectionCancellation.set(cancelledInspection)
        let cancelledInspectionResults = await cancelledInspection.value
        precondition(cancelledInspectionResults.count == 257)
        precondition(cancelledInspectionResults.filter { $0.error == ReaderClientError.cancelled.localizedDescription }.count == 1)
        let batchCountURL = inspectInstruments.appendingPathComponent("batch-count")
        let priorBatches = try String(contentsOf: batchCountURL, encoding: .utf8)
        let safeSource = inspectSources[0]
        let forgedSource = RawSource(relativePath: safeSource.relativePath, url: root.appendingPathComponent("forged.csv"), byteSize: 1)
        let duplicateResults = await ReaderClient.inspectMany([safeSource, forgedSource], project: inspectProject, approval: inspectApproval)
        precondition(duplicateResults.count == 2)
        precondition(duplicateResults.allSatisfy { $0.inspection == nil && $0.error == ReaderClientError.duplicateSourceIdentity.localizedDescription })
        let batchesAfterDuplicates = try String(contentsOf: batchCountURL, encoding: .utf8)
        precondition(batchesAfterDuplicates == priorBatches)
        let batchSizes = priorBatches
            .split(whereSeparator: \.isNewline).compactMap { Int($0) }
        precondition(batchSizes == [256, 1, 256])
        try Data("# changed".utf8).write(to: inspectInstruments.appendingPathComponent("reader.py"))
        precondition(!inspectApproval.isCurrent(for: inspectProject))
        let afterRevocation: ReaderApproval? = nil
        precondition(afterRevocation == nil)
        try Data("import sys\nsys.stdout.write('x' * (33 * 1024 * 1024))\n".utf8).write(to: reader)
        guard let outputApproval = ReaderApproval.issue(afterUserReviewOf: project) else { throw ReaderClientError.invalidProject }
        do { _ = try await ReaderClient.load(source, project: project, approval: outputApproval); fatalError("oversized reader output was accepted") }
        catch ReaderClientError.readerOutputTooLarge { }
    }
}

private actor InspectionProgressRecorder {
    private(set) var values: [Int] = []
    func record(_ rowCount: Int, _ completed: Int) {
        precondition(rowCount == (completed - (values.last ?? 0)))
        values.append(completed)
    }
}

private actor InspectionCancellationHandle {
    private var task: Task<[SourceInspectionResult], Never>?
    func set(_ task: Task<[SourceInspectionResult], Never>) { self.task = task }
    func cancel() { task?.cancel() }
}
