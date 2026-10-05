import CryptoKit
import Foundation

@main
enum CoreSelfCheck {
    static func main() async throws {
        let json = #"{"contract_version":1,"source":{"path":"data/raw/selected.csv","sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"},"instrument":{"id":"keysight-b1500a","name":"Keysight B1500A"},"application_mode":"list-sweep","view":{"kind":"xy","x":"voltage","y":["current"],"preserve_order":true},"channels":[{"name":"voltage","label":"Voltage","unit":"V","quantity":"voltage","values":[0.2,0.0,0.1]},{"name":"current","label":"Current","unit":"A","values":[3.0,1.0,2.0]}],"metadata_sections":[],"warnings":[],"support_status":"supported","provenance":{}}"#
        let value = try NormalizedMeasurement.decode(Data(json.utf8))
        precondition(value.view.preserveOrder)
        precondition(value.channel(named: "voltage")?.values == [0.2, 0.0, 0.1])
        precondition(value.channel(named: "voltage")?.quantity == "voltage")
        precondition(value.channel(named: "current")?.values == [3, 1, 2])
        precondition(AxisTransform.values([-1, 2], absolute: false, scale: .logarithmic) == .failure(.invalidLogDomain))
        precondition(AxisTransform.values([-1, 2], absolute: true, scale: .logarithmic) == .success([0, log10(2)]))
        do {
            _ = try NormalizedMeasurement.decode(Data(#"{"contract_version":2}"#.utf8))
            fatalError("unsupported version was accepted")
        } catch ContractError.unsupportedVersion(2) {
        }

        let inspections = [
            SourceInspection(source: "data/raw/a.csv", size: nil, instrumentID: "b1500", instrumentName: "B1500A",
                             applicationMode: "sweep", timestamp: "2026-09-30T10:00:00Z", deviceID: "D1",
                             category: "study-a", supportStatus: "supported", validationState: "valid",
                             readerVersion: "1", profileID: "iv", profileHash: "abc", error: nil),
            SourceInspection(source: "data/raw/b.csv", size: nil, instrumentID: "b1500", instrumentName: nil,
                             applicationMode: "pulse", timestamp: nil, deviceID: nil, category: nil,
                             supportStatus: nil, validationState: nil, readerVersion: nil, profileID: nil,
                             profileHash: nil, error: "unsupported")
        ]
        let grouping = SourceGrouping(inspections: inspections)
        precondition(grouping.sampleDevice.map(\.label) == ["D1"])
        precondition(grouping.category.map(\.label) == ["study-a"])
        precondition(grouping.measurementMode.map(\.label) == ["pulse", "sweep"])
        precondition(grouping.dateBatch.map(\.label) == ["2026-09-30"])
        precondition(SourceGrouping(inspections: [inspections[0]]).status.map(\.label) == ["Support: supported", "Validation: valid"])
        precondition(SourceGrouping.date(from: "2026-09-30T10:00:00Z") == "2026-09-30")
        precondition(SourceGrouping.date(from: "2026-+9-30T10:00:00Z") == nil)
        let filter = SourceFilter()
        precondition(filter.isEmpty)
        var g = SourceFilter(); g.toggle(facet: "instrument", value: "Fixture"); g.toggle(facet: "category", value: "Missing")
        precondition(!g.matches(["instrument": ["Fixture"], "category": ["S1"]]))
        g.clear()
        precondition(g.isEmpty && g.matches([:]))
        try await readerBoundarySelfCheck()
        try await filenameSelectorSelfCheck()
        try await overlayEligibilitySelfCheck()
        try await cacheSelfCheck()
        print("RawView core self-check passed")
    }

    /// Production-path cache boundary: a synthetic project stores a complete
    /// measurement, serves a warm load after full-digest verification, misses
    /// after a same-size/same-mtime content edit, ignores project-controlled
    /// cache files, round-trips exact sample bits/gaps, and enforces the LRU
    /// limit. Synthetic fixtures only.
    static func cacheSelfCheck() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rawview-cache-check-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        var csv = "SetupTitle, 2-terminal dual Vsweep\nDataName, V1, I1\n"
        for index in 0..<3000 { csv += "DataValue, \(Double(index) * 0.001), 1E-12\n" }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("data/instruments"), withIntermediateDirectories: true)
        try Data(keysightProfile.utf8).write(to: root.appendingPathComponent("data/instruments/keysight-b1500a.yaml"), options: [])
        try FileManager.default.createDirectory(at: root.appendingPathComponent("data/raw"), withIntermediateDirectories: true)
        try Data(csv.utf8).write(to: root.appendingPathComponent("data/raw/dual.csv"))
        let forgedProjectCache = root.appendingPathComponent("data/.cache/rawview/forged-entry")
        try FileManager.default.createDirectory(at: forgedProjectCache.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("project-controlled cache".utf8).write(to: forgedProjectCache)
        let project = try ProjectContext.open(root)
        let discovered = try project.discoverSources()
        precondition(!discovered.isEmpty)
        let cache = MeasurementCache(project: project, limitBytes: MeasurementCache.defaultLimitBytes)
        guard case .appLocal = cache.rootResolution else {
            fatalError("cache must be outside the selected project tree")
        }
        guard case .appLocal(let cachePath, _) = cache.rootResolution else {
            fatalError("cache must use an app-local directory")
        }
        precondition(cachePath != root.appendingPathComponent("data/.cache/rawview").path)
        let forgedProjectBytes = try Data(contentsOf: forgedProjectCache)
        precondition(forgedProjectBytes == Data("project-controlled cache".utf8),
                     "cache initialization must ignore project-controlled entries")
        let source = discovered[0]

        let inspectionCold = await InstrumentReader.inspectMany([source], project: project, cache: cache)
        precondition(inspectionCold.results.first?.inspection != nil)
        let inspectionStored = try cache.usage()
        precondition(inspectionStored.entryCount == 1,
                     "cache root \(inspectionStored.root), entries \(inspectionStored.entryCount)")
        let inspectionWarm = await InstrumentReader.inspectMany([source], project: project, cache: cache)
        precondition(inspectionWarm.results.first?.inspection?.instrumentID == inspectionCold.results.first?.inspection?.instrumentID)
        let inspectionReused = try cache.usage()
        precondition(inspectionReused.entryCount == 1)

        // Cold load stores an entry; warm load serves it unchanged.
        let cold = try await InstrumentReader.load(source.url, project: project, cache: cache)
        let stored = try cache.usage()
        precondition(stored.entryCount == 2)
        let warm = try await InstrumentReader.load(source.url, project: project, cache: cache)
        precondition(warm.source.sha256 == cold.source.sha256)
        precondition(warm.channel(named: "voltage")?.values == cold.channel(named: "voltage")?.values)
        precondition(warm.channels.count == cold.channels.count)
        let forgedProjectBytesAfterLoad = try Data(contentsOf: forgedProjectCache)
        precondition(forgedProjectBytesAfterLoad == Data("project-controlled cache".utf8),
                     "cache reads and writes must leave the project-controlled tree untouched")
        let warmMeasurement = try cache.measurement(for: source, project: project,
                                                    profileFingerprint: ProfileCatalog.load(project: project).fingerprint)
        precondition(warmMeasurement != nil)

        // The binary cache codec must preserve typed gaps and every Double bit
        // pattern, including signed zero, a subnormal, and a NaN payload.
        let edgeValues: [Double?] = [Double(bitPattern: 0x8000000000000000),
                                     Double(bitPattern: 1),
                                     Double(bitPattern: 0x7ff8000000000001), nil]
        let edgeMeasurement = NormalizedMeasurement(
            source: cold.source, instrument: cold.instrument, applicationMode: cold.applicationMode,
            view: cold.view,
            channels: [MeasurementChannel(name: "edge", label: "Edge", unit: "V", quantity: "voltage",
                                           values: edgeValues, gapReasons: [nil, nil, nil, .blank])],
            metadataSections: cold.metadataSections, warnings: cold.warnings,
            supportStatus: cold.supportStatus, provenance: cold.provenance)
        let restored = try MeasurementCache.decode(measurement: MeasurementCache.encode(measurement: edgeMeasurement))
        guard let restoredValues = restored.channels.first?.values else { fatalError("cache codec lost channel") }
        precondition(restoredValues.count == edgeValues.count)
        for index in 0..<3 {
            precondition(restoredValues[index]?.bitPattern == edgeValues[index]?.bitPattern)
        }
        precondition(restoredValues[3] == nil && restored.channels[0].gapReasons[3] == .blank)

        // A sparse oversized file must be rejected from its descriptor size
        // before the helper reads its contents into memory.
        let oversized = root.appendingPathComponent("oversized-cache-entry")
        FileManager.default.createFile(atPath: oversized.path, contents: Data())
        let oversizedHandle = try FileHandle(forWritingTo: oversized)
        try oversizedHandle.truncate(atOffset: UInt64(MeasurementCache.maximumEntryBytes + 1))
        try oversizedHandle.close()
        precondition(MeasurementCache.readBoundedFile(oversized, maximumBytes: MeasurementCache.maximumEntryBytes) == nil)

        // Same size, same mtime, changed bytes: the fresh full digest differs -> miss.
        let replacement = csv.replacingOccurrences(of: "DataValue, 0.001, 1E-12", with: "DataValue, 0.00X, 2E-12")
        precondition(replacement.utf8.count == csv.utf8.count)
        let mtime = try FileManager.default.attributesOfItem(atPath: source.url.path)[.modificationDate] as! Date
        try Data(replacement.utf8).write(to: source.url)
        try FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: source.url.path)
        let afterEdit = try cache.measurement(for: source, project: project, profileFingerprint: ProfileCatalog.load(project: project).fingerprint)
        precondition(afterEdit == nil)

        // LRU + clear: both entries fit alone, but not together; the older
        // entry is evicted and the newer one remains within the configured cap.
        let big = NormalizedMeasurement(
            source: cold.source, instrument: cold.instrument, applicationMode: cold.applicationMode,
            view: cold.view,
            channels: [MeasurementChannel(name: "pad", label: "Pad", unit: "V", quantity: "voltage",
                                         values: (0..<20_000).map { Double($0) * 0.123456789 })],
            metadataSections: [], warnings: [], supportStatus: "supported", provenance: [:])
        let coldBytes = try MeasurementCache.encode(measurement: cold).count
        let bigBytes = try MeasurementCache.encode(measurement: big).count
        let smallPayload = min(coldBytes, bigBytes)
        let largePayload = max(coldBytes, bigBytes)
        let evictionLimit = Int64(largePayload + smallPayload / 2 + 4096)
        precondition(Int64(coldBytes + bigBytes + 8192) > evictionLimit,
                     "LRU fixture entries must exceed the limit together")
        let small = MeasurementCache(project: project, limitBytes: evictionLimit, rootResolution: cache.rootResolution)
        try small.clear()
        let emptyUsage = try small.usage()
        precondition(emptyUsage.entryCount == 0)
        let identityPrefix = sha256Hex(Data("probe".utf8))
        try small.store(measurement: cold, profileFingerprint: "fp", source: source, prefixSHA256: identityPrefix)
        let firstUsage = try small.usage()
        precondition(firstUsage.entryCount == 1 && firstUsage.usedBytes <= evictionLimit)
        let fileManager = FileManager.default
        let cacheRoot = URL(fileURLWithPath: firstUsage.root, isDirectory: true)
        let entryDirectories = try fileManager.contentsOfDirectory(at: cacheRoot,
                                                                    includingPropertiesForKeys: nil)
            .flatMap { prefixURL in
                try fileManager.contentsOfDirectory(at: prefixURL, includingPropertiesForKeys: nil)
            }
        guard let oldEntry = entryDirectories.first else { fatalError("stored LRU fixture is missing") }
        try fileManager.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1)],
                                      ofItemAtPath: oldEntry.path)
        try small.store(measurement: big, profileFingerprint: "fp2", source: source, prefixSHA256: identityPrefix)
        let lruUsage = try small.usage()
        precondition(lruUsage.entryCount == 1, "LRU must evict one of two over-limit entries")
        precondition(lruUsage.usedBytes <= evictionLimit && lruUsage.usedBytes > firstUsage.usedBytes,
                     "LRU must retain newer entry: cold=\(coldBytes), big=\(bigBytes), first=\(firstUsage.usedBytes), after=\(lruUsage.usedBytes), limit=\(evictionLimit)")

        precondition(!FileManager.default.fileExists(atPath: root.appendingPathComponent("PROJECT_CODE_EXECUTED").path))
    }

    static func readerBoundarySelfCheck() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rawview-self-check-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let marker = root.appendingPathComponent("PROJECT_CODE_EXECUTED")
        let script = "from pathlib import Path\nPath(\"\(marker.path)\").write_text(\"ran\")\n"
        let outside = root.appendingPathComponent("outside.csv")

        func write(_ relativePath: String, _ contents: String) throws {
            let url = root.appendingPathComponent(relativePath)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(contents.utf8).write(to: url)
        }
        try write("data/raw/dual.csv", dualSweepCSV)
        try write("data/raw/no-header.csv", "SetupTitle, 2-terminal dual Vsweep\nMetaData, x, y\n")
        try write("data/raw/b.dat", "FIXTURE.DAT\nDATNAME, X, Y\nDATROW, 1, 2\n")
        try write("data/instruments/keysight-b1500a.yaml", keysightProfile)
        try write("data/instruments/unversioned-dat.yaml", unversionedDATProfile)
        try write("data/instruments/reader.py", script)
        try Data("outside marker".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("data/raw/escape.csv"), withDestinationURL: outside)

        let project = try ProjectContext.open(root)
        let sources = try project.discoverSources()
        precondition(sources.map(\.relativePath) == ["data/raw/b.dat", "data/raw/dual.csv", "data/raw/no-header.csv"])
        let report = await InstrumentReader.inspectMany(sources, project: project)
        precondition(report.results.count == 3)
        precondition(report.results.first { $0.id == "data/raw/dual.csv" }?.inspection?.instrumentID == "keysight-b1500a")
        precondition(report.results.first { $0.id == "data/raw/b.dat" }?.error?.contains("unversioned") == true)
        precondition(report.results.first { $0.id == "data/raw/no-header.csv" }?.inspection?.supportStatus == "supported")

        let dualURL = sources.first { $0.relativePath == "data/raw/dual.csv" }?.url
        guard let dualURL else { fatalError("dual fixture missing") }
        let measurement = try await InstrumentReader.load(dualURL, project: project)
        precondition(measurement.channel(named: "voltage")?.values == [0, 0.1, 0.2, 0.1, 0])
        precondition(measurement.channel(named: "current")?.values == [1e-12, 2e-12, 3e-12, 4e-12, 5e-12])
        precondition(measurement.channel(named: "voltage")?.quantity == "voltage")
        precondition(measurement.channel(named: "current")?.unit == "A")
        let dualData = try Data(contentsOf: dualURL)
        precondition(measurement.source.sha256 == sha256Hex(dualData))
        precondition(measurement.provenance["profile_id"] == "keysight-b1500a")

        do {
            let noHeaderURL = root.appendingPathComponent("data/raw/no-header.csv")
            _ = try await InstrumentReader.load(noHeaderURL, project: project)
            fatalError("a source without a DataName row was loaded")
        } catch {
            precondition(error.localizedDescription.contains("DataName"))
        }
        precondition(!FileManager.default.fileExists(atPath: marker.path))

        let outsideRoot = root.appendingPathComponent("instruments-outside-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: outsideRoot, withIntermediateDirectories: true)
        try Data(keysightProfile.utf8).write(to: outsideRoot.appendingPathComponent("keysight-b1500a.yaml"))
        let escapedProject = root.appendingPathComponent("escaped-project")
        try FileManager.default.createDirectory(at: escapedProject.appendingPathComponent("data/raw"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: escapedProject.appendingPathComponent("data/instruments"), withDestinationURL: outsideRoot)
        try Data("outside".utf8).write(to: escapedProject.appendingPathComponent("data/raw/source.csv"))
        let escapedContext = try ProjectContext.open(escapedProject)
        let escapedReport = await InstrumentReader.inspectMany(try escapedContext.discoverSources(), project: escapedContext)
        precondition(escapedReport.profileIssues.contains { $0.contains("resolves outside this project") })
        precondition(escapedReport.results.first?.inspection == nil)
        try FileManager.default.removeItem(at: outsideRoot)
    }

    /// Concise production-path check for the v2 basename gate. The broader
    /// matrix (isolation pairs, malformed shapes, v1, ambiguity) lives in the
    /// Swift Testing suite; this proves the gate loads, rejects on the
    /// basename alone, keeps header-only legacy matching, and never lets a
    /// malformed broken detect list exonerate a valid match.
    static func filenameSelectorSelfCheck() async throws {
        func write(_ root: URL, _ relativePath: String, _ contents: String) throws {
            let url = root.appendingPathComponent(relativePath)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(contents.utf8).write(to: url)
        }
        let csv = "SetupTitle, SYNTH-SPECIFIC-HEADER\nDataName, V1, I1\nDataValue, 0, 1E-12\nDataValue, 0.1, 2E-12\nDataValue, 0.2, 3E-12\n"
        // (a) All basename tokens plus a header alternative load every value.
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rawview-filename-gate-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try write(root, "data/raw/RUN_SYNTH-TOKEN_DUAL-SWEEP.csv", csv)
        try write(root, "data/instruments/synth.yaml", filenameV2Profile)
        let project = try ProjectContext.open(root)
        let report = await InstrumentReader.inspectMany(try project.discoverSources(), project: project)
        let good = report.results.first { $0.source.relativePath == "data/raw/RUN_SYNTH-TOKEN_DUAL-SWEEP.csv" }
        precondition(good?.inspection?.applicationMode == "dual-sweep")
        let measurement = try await InstrumentReader.load(good!.source.url, project: project)
        precondition(measurement.channel(named: "voltage")?.values == [0, 0.1, 0.2])
        precondition(measurement.channel(named: "current")?.values == [1e-12, 2e-12, 3e-12])
        // (b) One of two required tokens with a matching header is rejected on
        // the basename alone: the filename cause is named, no header cause is.
        let partialRoot = FileManager.default.temporaryDirectory.appendingPathComponent("rawview-filename-partial-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: partialRoot) }
        try write(partialRoot, "data/raw/run_synth-token_only.csv", csv)
        try write(partialRoot, "data/instruments/synth.yaml", filenameV2Profile)
        let partialProject = try ProjectContext.open(partialRoot)
        let partialReport = await InstrumentReader.inspectMany(try partialProject.discoverSources(), project: partialProject)
        precondition(partialReport.results.first?.inspection == nil)
        precondition(partialReport.results.first?.error?.contains("filename_contains_all tokens \"dual-sweep\" not in basename \"run_synth-token_only.csv\"") == true)
        precondition(partialReport.results.first?.error?.contains("not in header sample") == false)
        // (c) Without the optional selector the same header still matches.
        let legacyRoot = FileManager.default.temporaryDirectory.appendingPathComponent("rawview-filename-legacy-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: legacyRoot) }
        try write(legacyRoot, "data/raw/unrelated.csv", csv)
        try write(legacyRoot, "data/instruments/synth.yaml", filenameV2Profile.replacingOccurrences(of: "    filename_contains_all: [\"synth-token\", \"dual-sweep\"]\n", with: ""))
        let legacyProject = try ProjectContext.open(legacyRoot)
        let legacyReport = await InstrumentReader.inspectMany(try legacyProject.discoverSources(), project: legacyProject)
        precondition(legacyReport.results.first?.inspection?.applicationMode == "dual-sweep")
        // (d) A mixed scalar/non-scalar broken detect list is uncertain: it
        // cannot exonerate the exact valid match.
        let mixedRoot = FileManager.default.temporaryDirectory.appendingPathComponent("rawview-filename-mixed-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: mixedRoot) }
        try write(mixedRoot, "data/raw/run_synth-token_dual-sweep.csv", csv)
        try write(mixedRoot, "data/instruments/synth.yaml", filenameV2Profile)
        try write(mixedRoot, "data/instruments/broken.yaml", filenameV2Profile.replacingOccurrences(of: "    detect: [\"SYNTH-MISSING-HEADER\", \"SYNTH-SPECIFIC-HEADER\"]", with: "    detect:\n      - UNRELATED-HEADER\n      - bad: map"))
        let mixedProject = try ProjectContext.open(mixedRoot)
        let mixedReport = await InstrumentReader.inspectMany(try mixedProject.discoverSources(), project: mixedProject)
        precondition(mixedReport.results.first?.inspection == nil)
        precondition(mixedReport.results.first?.error?.contains("data/instruments/broken.yaml") == true)
        precondition(mixedReport.results.first?.error?.contains("modes[0].detect must contain only strings") == true)
    }

    /// Production-path overlay boundary: project -> versioned profiles ->
    /// full arrays -> exact-manifest eligibility. Synthetic fixtures only.
    static func overlayEligibilitySelfCheck() async throws {
        func write(_ root: URL, _ relativePath: String, _ contents: String) throws {
            let url = root.appendingPathComponent(relativePath)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(contents.utf8).write(to: url)
        }
        func loadAll(_ sources: [RawSource], project: ProjectContext) async throws -> [NormalizedMeasurement] {
            var out: [NormalizedMeasurement] = []
            for source in sources.sorted(by: { $0.relativePath < $1.relativePath }) {
                out.append(try await InstrumentReader.load(source.url, project: project))
            }
            return out
        }
        let csvA = "SetupTitle, 2-terminal dual Vsweep\nDataName, V1, I1\nDataValue, 0, 1E-12\nDataValue, 0.1, 2E-12\nDataValue, 0.2, \n"
        let csvB = "SetupTitle, 2-terminal dual Vsweep\nDataName, V1, I1\nDataValue, 0, 3E-12\nDataValue, 0.1, 4E-12\nDataValue, 0.2, 5E-12\n"
        let manifestAB = "study_id: synth-study-1\nsources:\n- path: data/raw/a.csv\n- path: data/raw/b.csv\n"
        // (a) Same manifest accepts and preserves full arrays/gaps in order.
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rawview-overlay-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try write(root, "data/raw/a.csv", csvA)
        try write(root, "data/raw/b.csv", csvB)
        // Manifest discovery must not descend into the selected raw tree.
        try write(root, "data/raw/metadata.yaml", "study_id: raw-file\nsources:\n  - path: a.csv\n")
        // Derived cache entries must never establish scientific membership.
        try write(root, "data/.cache/rawview/cache-manifest.yaml", manifestAB)
        // Study metadata without a source list is not a RawView manifest and
        // must not flood the reader sidebar with manifest errors.
        try write(root, "history/study.yaml", "study_id: archived-study\nstatus: completed\n")
        try write(root, "metadata/sources.yaml", "sources:\n  - id: legacy\n")
        try write(root, "data/instruments/keysight-b1500a.yaml", keysightProfile)
        // Nested project metadata commonly records project-relative data/raw paths.
        try write(root, "metadata/study.yaml", manifestAB)
        let project = try ProjectContext.open(root)
        let index = ManifestIndex.load(project: project)
        precondition(index.manifests.count == 1 && index.issues.isEmpty
                     && index.manifests[0].members == ["data/raw/a.csv", "data/raw/b.csv"])
        try FileManager.default.removeItem(at: root.appendingPathComponent("data/raw/metadata.yaml"))
        let measurements = try await loadAll(try project.discoverSources(), project: project)
        precondition(measurements.count == 2)
        guard case .eligible(let manifestPath) = OverlayEvaluator.evaluate(measurements: measurements, manifests: index.manifests) else {
            fatalError("same-manifest pair blocked")
        }
        precondition(manifestPath == "metadata/study.yaml")
        let a = measurements.first { $0.source.path == "data/raw/a.csv" }!
        precondition(a.channel(named: "voltage")?.values == [0, 0.1, 0.2])
        precondition(a.channel(named: "current")?.values == [1e-12, 2e-12, nil])
        precondition(OverlayEvaluator.visible(measurements: measurements, hidden: ["data/raw/b.csv"]).count == 1)
        precondition(OverlaySelection.focused(selected: ["data/raw/a.csv", "data/raw/b.csv"], current: "data/raw/b.csv") == "data/raw/b.csv")
        // (b) Same Study ID in different files remains different identities.
        let splitRoot = FileManager.default.temporaryDirectory.appendingPathComponent("rawview-overlay-split-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: splitRoot) }
        try write(splitRoot, "data/raw/a.csv", csvA)
        try write(splitRoot, "data/raw/b.csv", csvB)
        try write(splitRoot, "data/instruments/keysight-b1500a.yaml", keysightProfile)
        try write(splitRoot, "one.yaml", "study_id: synth-study-1\nsources:\n  - path: data/raw/a.csv\n")
        try write(splitRoot, "two.yaml", "study_id: synth-study-1\nsources:\n  - path: data/raw/b.csv\n")
        let splitProject = try ProjectContext.open(splitRoot)
        let splitMeasurements = try await loadAll(try splitProject.discoverSources(), project: splitProject)
        let splitResult = OverlayEvaluator.evaluate(measurements: splitMeasurements, manifests: ManifestIndex.load(project: splitProject).manifests)
        guard case .blocked(let splitReason) = splitResult else { fatalError("same-ID split manifests accepted") }
        precondition(splitReason.contains("different manifests"))
        // (c) Missing membership and unit mismatch block the whole comparison.
        let missRoot = FileManager.default.temporaryDirectory.appendingPathComponent("rawview-overlay-miss-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: missRoot) }
        try write(missRoot, "data/raw/a.csv", csvA)
        try write(missRoot, "data/raw/b.csv", csvB)
        try write(missRoot, "data/instruments/keysight-b1500a.yaml", keysightProfile)
        try write(missRoot, "study.yaml", "study_id: synth-study-1\nsources:\n  - path: data/raw/a.csv\n")
        let missProject = try ProjectContext.open(missRoot)
        let missMeasurements = try await loadAll(try missProject.discoverSources(), project: missProject)
        guard case .blocked(let missReason) = OverlayEvaluator.evaluate(measurements: missMeasurements, manifests: ManifestIndex.load(project: missProject).manifests) else {
            fatalError("missing membership accepted")
        }
        precondition(missReason.contains("data/raw/b.csv"))

        func unspecifiedSignal(path: String) -> NormalizedMeasurement {
            NormalizedMeasurement(
                source: SourceIdentity(path: path, sha256: String(repeating: "b", count: 64)),
                instrument: InstrumentIdentity(id: "synth", name: "Synth"),
                applicationMode: "wgfmu",
                view: MeasurementView(kind: "xy", x: "time", y: ["signal_1"], preserveOrder: true),
                channels: [
                    MeasurementChannel(name: "time", label: "Time", unit: "s", quantity: "time", values: [0, 1]),
                    MeasurementChannel(name: "signal_1", label: "Signal 1", unit: "unspecified", quantity: "signal_1", values: [1, 2]),
                ],
                metadataSections: [], warnings: [], supportStatus: "supported", provenance: [:]
            )
        }
        let unspecified = OverlayEvaluator.evaluate(
            measurements: [unspecifiedSignal(path: "data/raw/u1.csv"), unspecifiedSignal(path: "data/raw/u2.csv")],
            manifests: [StudyManifest(relativePath: "study.yaml", studyID: "synth-study-1",
                                      members: ["data/raw/u1.csv", "data/raw/u2.csv"])]
        )
        guard case .blocked(let unspecifiedReason) = unspecified else {
            fatalError("unspecified units accepted for overlay")
        }
        precondition(unspecifiedReason.lowercased().contains("unspecified"))

        func multiSignal(path: String, reversed: Bool = false) -> NormalizedMeasurement {
            NormalizedMeasurement(
                source: SourceIdentity(path: path, sha256: String(repeating: "c", count: 64)),
                instrument: InstrumentIdentity(id: "synth", name: "Synth"),
                applicationMode: "multi-channel",
                view: MeasurementView(kind: "xy", x: "time",
                                      y: reversed ? ["charge", "current"] : ["current", "charge"],
                                      preserveOrder: true),
                channels: [
                    MeasurementChannel(name: "time", label: "Time", unit: "s", quantity: "time", values: [0, 1]),
                    MeasurementChannel(name: "current", label: "Current", unit: "A", quantity: "current", values: [1, 2]),
                    MeasurementChannel(name: "charge", label: "Charge", unit: "C", quantity: "charge", values: [3, 4]),
                ],
                metadataSections: [], warnings: [], supportStatus: "supported", provenance: [:]
            )
        }
        let multiManifest = StudyManifest(relativePath: "study.yaml", studyID: "synth-study-1",
                                          members: ["data/raw/m1.csv", "data/raw/m2.csv"])
        guard case .eligible = OverlayEvaluator.evaluate(
            measurements: [multiSignal(path: "data/raw/m1.csv"), multiSignal(path: "data/raw/m2.csv")],
            manifests: [multiManifest]) else {
            fatalError("matching multi-Y signatures were blocked")
        }
        guard case .blocked = OverlayEvaluator.evaluate(
            measurements: [multiSignal(path: "data/raw/m1.csv"), multiSignal(path: "data/raw/m2.csv", reversed: true)],
            manifests: [multiManifest]) else {
            fatalError("different multi-Y order was accepted")
        }
    }

    static let filenameV2Profile = """
    schema_version: 2
    instrument:
      id: synth
      name: Synth
    formats:
      - id: csv
        kind: tabular
        extensions: [".csv"]
        delimiter: ","
        rows:
          names_prefix: "DataName"
          data_prefix: "DataValue"
        columns:
          voltage:
            header: "V1"
            quantity: voltage
            unit: "V"
          current:
            header: "I1"
            quantity: current
            unit: "A"
    modes:
      - id: dual-sweep
        format: csv
        filename_contains_all: ["synth-token", "dual-sweep"]
        detect: ["SYNTH-MISSING-HEADER", "SYNTH-SPECIFIC-HEADER"]
        extract:
          x: voltage
          y: [current]
    """

    static let dualSweepCSV = "\u{FEFF}SetupTitle, 2-terminal dual Vsweep\nDataName, V1, I1\nDataValue, 0, 1E-12\nDataValue, 0.1, 2E-12\nDataValue, 0.2, 3E-12\nDataValue, 0.1, 4E-12\nDataValue, 0, 5E-12\n"

    static let keysightProfile = """
    schema_version: 1
    instrument:
      id: keysight-b1500a
      name: Keysight B1500A
    formats:
      - id: csv
        kind: tabular
        extensions: [".csv"]
        delimiter: ","
        rows:
          names_prefix: "DataName"
          data_prefix: "DataValue"
        columns:
          voltage:
            header: "V1"
            quantity: voltage
            unit: "V"
          current:
            header: "I2"
            aliases: ["I1"]
            quantity: current
            unit: "A"
    modes:
      - id: dual-sweep
        format: csv
        detect: ["2-terminal dual Vsweep"]
        extract:
          x: voltage
          y: [current]
    """

    static let unversionedDATProfile = """
    instrument:
      id: fixture-dat
      name: Fixture DAT
    formats:
      - id: dat
        extensions: [".dat"]
        delimiter: ","
        rows:
          names_prefix: "DATNAME"
          data_prefix: "DATROW"
        columns:
          x:
            header: "X"
            unit: "s"
          y:
            header: "Y"
            unit: "V"
    modes:
      - id: default
        format: dat
        detect: ["FIXTURE.DAT"]
        extract:
          x: x
          y: [y]
    """
}
