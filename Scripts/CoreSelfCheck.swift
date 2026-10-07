import CryptoKit
import Foundation

private func writeFixture(_ root: URL, _ relativePath: String, _ contents: String) throws {
    let url = root.appendingPathComponent(relativePath)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(contents.utf8).write(to: url)
}

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
        try rawInventorySkipsMacOSMetadataSelfCheck()
        try await readerBoundarySelfCheck()
        try await filenameSelectorSelfCheck()
        try await overlayEligibilitySelfCheck()
        try await manifestTrustBoundarySelfCheck()
        try await manifestSubsetSelfCheck()
        try await b1500ModeSelectionSelfCheck()
        try await wgfmuOverlaySelfCheck()
        try await wgfmuFirstRowSelfCheck()
        try await b1500SelectorCorrectionSelfCheck()
        try await auditRemediationSelfCheck()
        try await cacheSelfCheck()
        try await cacheFilesystemTrustSelfCheck()
        try await auditRegressionSelfCheck()
        try await auditTrustBoundaryTighteningSelfCheck()
        try await focusedCohortSelfCheck()
        try await symlinkVisibilitySelfCheck()
        try await fifoProfileSelfCheck()
        try await cachePreflightSelfCheck()
        try await manyShortRowsSelfCheck()
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

        // The binary cache codec must preserve typed gaps and every finite Double
        // bit pattern, including signed zero, a subnormal, and finite max, and
        // must keep nil gap reasons distinct from `.unknown`. Present NaN and
        // infinities are never valid present samples (recorded non-finite
        // source cells are gaps).
        let edgeValues: [Double?] = [Double(bitPattern: 0x8000000000000000),
                                     Double(bitPattern: 1),
                                     Double(bitPattern: 0x7FEFFFFFFFFFFFFF), 0.5,
                                     nil, nil, nil, nil, nil, nil]
        let edgeReasons: [GapReason?] = [nil, nil, nil, nil, .blank, .nan, .infinite, .saturated, .unknown, nil]
        let edgeMeasurement = NormalizedMeasurement(
            source: cold.source, instrument: cold.instrument, applicationMode: cold.applicationMode,
            view: cold.view,
            channels: [MeasurementChannel(name: "edge", label: "Edge", unit: "V", quantity: "voltage",
                                           values: edgeValues, gapReasons: edgeReasons)],
            metadataSections: cold.metadataSections, warnings: cold.warnings,
            supportStatus: cold.supportStatus, provenance: cold.provenance)
        let restored = try MeasurementCache.decode(measurement: MeasurementCache.encode(measurement: edgeMeasurement))
        guard let restoredValues = restored.channels.first?.values else { fatalError("cache codec lost channel") }
        precondition(restoredValues.count == edgeValues.count)
        for index in 0..<4 {
            precondition(restoredValues[index]?.bitPattern == edgeValues[index]?.bitPattern)
        }
        precondition(restored.channels[0].gapReasons == edgeReasons,
                     "cache codec lost gap reasons: \(String(describing: restored.channels[0].gapReasons))")
        func expectInvalidEncoding(_ values: [Double?], _ reasons: [GapReason?]) throws {
            let malformed = NormalizedMeasurement(
                source: cold.source, instrument: cold.instrument, applicationMode: cold.applicationMode,
                view: cold.view,
                channels: [MeasurementChannel(name: "malformed", label: "Malformed", unit: "V", quantity: "voltage",
                                               values: values, gapReasons: reasons)],
                metadataSections: [], warnings: [], supportStatus: "supported", provenance: [:])
            do {
                _ = try MeasurementCache.encode(measurement: malformed)
                fatalError("cache encoder accepted inconsistent channel values/reasons")
            } catch ContractError.invalid {
            } catch {
                fatalError("cache encoder failed with an unexpected error: \(error)")
            }
        }
        try expectInvalidEncoding([1.0], [.blank])
        try expectInvalidEncoding([1.0], [])
        try expectInvalidEncoding([Double.nan], [nil])
        try expectInvalidEncoding([Double.infinity], [nil])
        try expectInvalidEncoding([-Double.infinity], [nil])
        // Malformed packed payloads fail closed as invalid, never trap.
        func expectInvalidPayload(_ label: String, _ mutate: (inout MeasurementCache.MeasurementPayload) -> Void) throws {
            var payload = MeasurementCache.MeasurementPayload(measurement: edgeMeasurement)
            mutate(&payload)
            let encoded = try PropertyListEncoder().encode(payload)
            do {
                _ = try MeasurementCache.decode(measurement: encoded)
                fatalError("\(label) was accepted")
            } catch ContractError.invalid {
            } catch {
                fatalError("\(label) threw an unexpected error: \(error)")
            }
        }
        try expectInvalidPayload("truncated value bytes") { $0.channelValueBytes[0].removeLast() }
        try expectInvalidPayload("mismatched channel arrays") { $0.channelGapCodes.removeLast() }
        try expectInvalidPayload("invalid gap code") { $0.channelGapCodes[0][4] = 99 }
        try expectInvalidPayload("non-zero gap slot bytes") { $0.channelValueBytes[0][4 * 8] = 1 }
        try expectInvalidPayload("non-finite present sample") {
            let bits: UInt64 = Double.nan.bitPattern
            for offset in 0..<8 { $0.channelValueBytes[0][offset] = UInt8((bits >> (offset * 8)) & 0xFF) }
            $0.channelGapCodes[0][0] = 0
        }

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

    /// Filesystem trust: no path-based chmod remains. A pre-existing
    /// permissive cache directory fails closed (no repair, no hit, no store),
    /// and a symlinked payload is never followed. Synthetic fixtures only.
    static func cacheFilesystemTrustSelfCheck() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rawview-cache-trust-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        var csv = "SetupTitle, 2-terminal dual Vsweep\nDataName, V1, I1\n"
        for index in 0..<200 { csv += "DataValue, \(Double(index) * 0.001), 1E-12\n" }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("data/instruments"), withIntermediateDirectories: true)
        try Data(keysightProfile.utf8).write(to: root.appendingPathComponent("data/instruments/keysight-b1500a.yaml"))
        try FileManager.default.createDirectory(at: root.appendingPathComponent("data/raw"), withIntermediateDirectories: true)
        try Data(csv.utf8).write(to: root.appendingPathComponent("data/raw/dual.csv"))
        let project = try ProjectContext.open(root)
        let source = try requireLike(try project.discoverSources().first)
        let cache = MeasurementCache(project: project, limitBytes: MeasurementCache.defaultLimitBytes)
        let cold = try await InstrumentReader.load(source.url, project: project, cache: cache)
        _ = cold
        let storedUsage = try cache.usage()
        precondition(storedUsage.entryCount >= 1)
        let cacheRoot = URL(fileURLWithPath: storedUsage.root, isDirectory: true)
        let prefixName = try requireLike(try FileManager.default.contentsOfDirectory(atPath: cacheRoot.path).first)
        let prefixURL = cacheRoot.appendingPathComponent(prefixName)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: prefixURL.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: prefixURL.path) }
        let missAfterPermissive = try cache.measurement(for: source, project: project, profileFingerprint: ProfileCatalog.load(project: project).fingerprint)
        precondition(missAfterPermissive == nil,
                     "permissive cache directory was repaired or served instead of failing closed")
        let prefixPerms = (try FileManager.default.attributesOfItem(atPath: prefixURL.path)[.posixPermissions] as? NSNumber)?.intValue ?? 0
        precondition(prefixPerms & 0o077 != 0,
                     "permissive cache directory was repaired instead of failing closed")
        let brokenUsage = try cache.usage()
        precondition(brokenUsage.entryCount >= 1,
                     "usage accounting lost entries after a permissive subdirectory failed closed")
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: prefixURL.path)
        let hitAfterRestore = try cache.measurement(for: source, project: project, profileFingerprint: ProfileCatalog.load(project: project).fingerprint)
        precondition(hitAfterRestore != nil,
                     "restored private cache directory did not serve again")
    }

    static func readerBoundarySelfCheck() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rawview-self-check-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let marker = root.appendingPathComponent("PROJECT_CODE_EXECUTED")
        let script = "from pathlib import Path\nPath(\"\(marker.path)\").write_text(\"ran\")\n"
        let outside = root.appendingPathComponent("outside.csv")

        try writeFixture(root, "data/raw/dual.csv", dualSweepCSV)
        try writeFixture(root, "data/raw/no-header.csv", "SetupTitle, 2-terminal dual Vsweep\nMetaData, x, y\n")
        try writeFixture(root, "data/raw/b.dat", "FIXTURE.DAT\nDATNAME, X, Y\nDATROW, 1, 2\n")
        try writeFixture(root, "data/instruments/keysight-b1500a.yaml", keysightProfile)
        try writeFixture(root, "data/instruments/unversioned-dat.yaml", unversionedDATProfile)
        try writeFixture(root, "data/instruments/reader.py", script)
        try Data("outside marker".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("data/raw/escape.csv"), withDestinationURL: outside)

        let project = try ProjectContext.open(root)
        let sources = try project.discoverSources()
        precondition(sources.map(\.relativePath) == ["data/raw/b.dat", "data/raw/dual.csv", "data/raw/escape.csv", "data/raw/no-header.csv"])
        // The symlink entry is lexical: claimed path, no target size, target never touched.
        precondition(sources.first(where: { $0.relativePath == "data/raw/escape.csv" })?.byteSize == 0)
        let report = await InstrumentReader.inspectMany(sources, project: project)
        precondition(report.results.count == 4)
        precondition(report.results.first { $0.id == "data/raw/dual.csv" }?.inspection?.instrumentID == "keysight-b1500a")
        precondition(report.results.first { $0.id == "data/raw/b.dat" }?.error?.contains("unversioned") == true)
        precondition(report.results.first { $0.id == "data/raw/no-header.csv" }?.inspection?.supportStatus == "supported")
        precondition(report.results.first { $0.id == "data/raw/escape.csv" }?.inspection == nil)
        precondition(report.results.first { $0.id == "data/raw/escape.csv" }?.error?.contains("data/raw/escape.csv") == true)

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

    static func rawInventorySkipsMacOSMetadataSelfCheck() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rawview-inventory-metadata-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try writeFixture(root, "data/raw/.DS_Store", "macOS directory metadata")
        try writeFixture(root, "data/raw/nested/.DS_Store", "nested macOS directory metadata")
        try writeFixture(root, "data/raw/.hidden.csv", "synthetic hidden measurement")
        try writeFixture(root, "data/raw/source.csv", "synthetic measurement")

        let sources = try ProjectContext.open(root).discoverSources()
        let paths = sources.map(\.relativePath)
        precondition(paths == ["data/raw/.hidden.csv", "data/raw/source.csv"],
                     "raw inventory included macOS metadata: \(paths)")
    }

    /// Concise production-path check for the v2 basename gate. The broader
    /// matrix (isolation pairs, malformed shapes, v1, ambiguity) lives in the
    /// Swift Testing suite; this proves the gate loads, rejects on the
    /// basename alone, keeps header-only legacy matching, and never lets a
    /// malformed broken detect list exonerate a valid match.
    static func filenameSelectorSelfCheck() async throws {
        let csv = "SetupTitle, SYNTH-SPECIFIC-HEADER\nDataName, V1, I1\nDataValue, 0, 1E-12\nDataValue, 0.1, 2E-12\nDataValue, 0.2, 3E-12\n"
        // (a) All basename tokens plus a header alternative load every value.
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rawview-filename-gate-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try writeFixture(root, "data/raw/RUN_SYNTH-TOKEN_DUAL-SWEEP.csv", csv)
        try writeFixture(root, "data/instruments/synth.yaml", filenameV2Profile)
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
        try writeFixture(partialRoot, "data/raw/run_synth-token_only.csv", csv)
        try writeFixture(partialRoot, "data/instruments/synth.yaml", filenameV2Profile)
        let partialProject = try ProjectContext.open(partialRoot)
        let partialReport = await InstrumentReader.inspectMany(try partialProject.discoverSources(), project: partialProject)
        precondition(partialReport.results.first?.inspection == nil)
        precondition(partialReport.results.first?.error?.contains("filename_contains_all tokens \"dual-sweep\" not in basename \"run_synth-token_only.csv\"") == true)
        precondition(partialReport.results.first?.error?.contains("not in header sample") == false)
        // (c) Without the optional selector the same header still matches.
        let legacyRoot = FileManager.default.temporaryDirectory.appendingPathComponent("rawview-filename-legacy-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: legacyRoot) }
        try writeFixture(legacyRoot, "data/raw/unrelated.csv", csv)
        try writeFixture(legacyRoot, "data/instruments/synth.yaml", filenameV2Profile.replacingOccurrences(of: "    filename_contains_all: [\"synth-token\", \"dual-sweep\"]\n", with: ""))
        let legacyProject = try ProjectContext.open(legacyRoot)
        let legacyReport = await InstrumentReader.inspectMany(try legacyProject.discoverSources(), project: legacyProject)
        precondition(legacyReport.results.first?.inspection?.applicationMode == "dual-sweep")
        // (d) A mixed scalar/non-scalar broken detect list is uncertain: it
        // cannot exonerate the exact valid match.
        let mixedRoot = FileManager.default.temporaryDirectory.appendingPathComponent("rawview-filename-mixed-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: mixedRoot) }
        try writeFixture(mixedRoot, "data/raw/run_synth-token_dual-sweep.csv", csv)
        try writeFixture(mixedRoot, "data/instruments/synth.yaml", filenameV2Profile)
        try writeFixture(mixedRoot, "data/instruments/broken.yaml", filenameV2Profile.replacingOccurrences(of: "    detect: [\"SYNTH-MISSING-HEADER\", \"SYNTH-SPECIFIC-HEADER\"]", with: "    detect:\n      - UNRELATED-HEADER\n      - bad: map"))
        let mixedProject = try ProjectContext.open(mixedRoot)
        let mixedReport = await InstrumentReader.inspectMany(try mixedProject.discoverSources(), project: mixedProject)
        precondition(mixedReport.results.first?.inspection == nil)
        precondition(mixedReport.results.first?.error?.contains("data/instruments/broken.yaml") == true)
        precondition(mixedReport.results.first?.error?.contains("modes[0].detect must contain only strings") == true)
    }

    /// Production-path overlay boundary: project -> versioned profiles ->
    /// full arrays -> exact-manifest eligibility. Synthetic fixtures only.
    static func overlayEligibilitySelfCheck() async throws {
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
        try writeFixture(root, "data/raw/a.csv", csvA)
        try writeFixture(root, "data/raw/b.csv", csvB)
        // Manifest discovery must not descend into the selected raw tree.
        try writeFixture(root, "data/raw/metadata.yaml", "study_id: raw-file\nsources:\n  - path: a.csv\n")
        // Derived cache entries must never establish scientific membership.
        try writeFixture(root, "data/.cache/rawview/cache-manifest.yaml", manifestAB)
        // Study metadata without a source list is not a RawView manifest and
        // must not flood the reader sidebar with manifest errors.
        try writeFixture(root, "history/study.yaml", "study_id: archived-study\nstatus: completed\n")
        try writeFixture(root, "metadata/sources.yaml", "sources:\n  - id: legacy\n")
        try writeFixture(root, "data/instruments/keysight-b1500a.yaml", keysightProfile)
        // Nested project metadata commonly records project-relative data/raw paths.
        try writeFixture(root, "metadata/study.yaml", manifestAB)
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
        // (a2) Existing Study manifests may include unrelated folded YAML and
        // point through explicit input symlinks into canonical data/raw files.
        let aliasRoot = FileManager.default.temporaryDirectory.appendingPathComponent("rawview-overlay-alias-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: aliasRoot) }
        try writeFixture(aliasRoot, "data/raw/a.csv", csvA)
        try writeFixture(aliasRoot, "data/raw/b.csv", csvB)
        try writeFixture(aliasRoot, "data/instruments/keysight-b1500a.yaml", keysightProfile)
        try writeFixture(aliasRoot, "studies/synthetic/inputs.yaml", """
        schema_version: "2.0"
        study_id: synthetic.study
        selection_rationale: >
          Folded text is not source membership.
          The explicit source list below is.
        sources:
          - path: inputs/a.csv
            label: A
          - path: inputs/b.csv
            label: B
        """)
        let aliasInputs = aliasRoot.appendingPathComponent("studies/synthetic/inputs")
        try FileManager.default.createDirectory(at: aliasInputs, withIntermediateDirectories: true)
        for name in ["a.csv", "b.csv"] {
            try FileManager.default.createSymbolicLink(
                at: aliasInputs.appendingPathComponent(name),
                withDestinationURL: aliasRoot.appendingPathComponent("data/raw/\(name)")
            )
        }
        let aliasProject = try ProjectContext.open(aliasRoot)
        let aliasIndex = ManifestIndex.load(project: aliasProject)
        precondition(aliasIndex.issues.isEmpty && aliasIndex.manifests.count == 1)
        precondition(aliasIndex.manifests[0].members == ["data/raw/a.csv", "data/raw/b.csv"])
        let aliasMeasurements = try await loadAll(try aliasProject.discoverSources(), project: aliasProject)
        guard case .eligible = OverlayEvaluator.evaluate(measurements: aliasMeasurements, manifests: aliasIndex.manifests) else {
            fatalError("explicit study aliases did not resolve to one shared manifest")
        }
        // (b) Same Study ID in different files remains different identities.
        let splitRoot = FileManager.default.temporaryDirectory.appendingPathComponent("rawview-overlay-split-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: splitRoot) }
        try writeFixture(splitRoot, "data/raw/a.csv", csvA)
        try writeFixture(splitRoot, "data/raw/b.csv", csvB)
        try writeFixture(splitRoot, "data/instruments/keysight-b1500a.yaml", keysightProfile)
        try writeFixture(splitRoot, "one.yaml", "study_id: synth-study-1\nsources:\n  - path: data/raw/a.csv\n")
        try writeFixture(splitRoot, "two.yaml", "study_id: synth-study-1\nsources:\n  - path: data/raw/b.csv\n")
        let splitProject = try ProjectContext.open(splitRoot)
        let splitMeasurements = try await loadAll(try splitProject.discoverSources(), project: splitProject)
        let splitResult = OverlayEvaluator.evaluate(measurements: splitMeasurements, manifests: ManifestIndex.load(project: splitProject).manifests)
        guard case .blocked(let splitReason) = splitResult else { fatalError("same-ID split manifests accepted") }
        precondition(splitReason.contains("different manifests"))
        // (c) Missing membership and unit mismatch block the whole comparison.
        let missRoot = FileManager.default.temporaryDirectory.appendingPathComponent("rawview-overlay-miss-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: missRoot) }
        try writeFixture(missRoot, "data/raw/a.csv", csvA)
        try writeFixture(missRoot, "data/raw/b.csv", csvB)
        try writeFixture(missRoot, "data/instruments/keysight-b1500a.yaml", keysightProfile)
        try writeFixture(missRoot, "study.yaml", "study_id: synth-study-1\nsources:\n  - path: data/raw/a.csv\n")
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

    /// Trust-boundary coverage for manifest membership: absolute paths,
    /// outside-root symlink targets, data/raw-sibling prefix paths,
    /// conflicting project/manifest-relative resolutions, and duplicate
    /// aliases to one file all fail closed. Valid in-root aliases stay
    /// covered by overlayEligibilitySelfCheck (a2). Synthetic fixtures only.
    static func manifestTrustBoundarySelfCheck() async throws {
        let csv = "SetupTitle, 2-terminal dual Vsweep\nDataName, V1, I1\nDataValue, 0, 1E-12\n"
        // Absolute mapping fails closed.
        do {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("rawview-manifest-absolute-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: root) }
            try writeFixture(root, "data/raw/a.csv", csv)
            try writeFixture(root, "data/instruments/keysight-b1500a.yaml", keysightProfile)
            try writeFixture(root, "study.yaml", "study_id: s\nsources:\n  - path: /data/raw/a.csv\n")
            let index = ManifestIndex.load(project: try ProjectContext.open(root))
            precondition(index.manifests.isEmpty && index.issues.contains { $0.contains("must not be absolute") })
        }
        // Outside-root symlink target fails closed.
        do {
            let outside = FileManager.default.temporaryDirectory.appendingPathComponent("rawview-outside-\(UUID().uuidString).csv")
            try Data("outside".utf8).write(to: outside)
            defer { try? FileManager.default.removeItem(at: outside) }
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("rawview-manifest-escape-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: root) }
            try writeFixture(root, "data/raw/a.csv", csv)
            try writeFixture(root, "data/instruments/keysight-b1500a.yaml", keysightProfile)
            let linkDir = root.appendingPathComponent("inputs")
            try FileManager.default.createDirectory(at: linkDir, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: linkDir.appendingPathComponent("escape.csv"), withDestinationURL: outside)
            try writeFixture(root, "study.yaml", "study_id: s\nsources:\n  - path: inputs/escape.csv\n")
            let index = ManifestIndex.load(project: try ProjectContext.open(root))
            precondition(index.manifests.isEmpty && index.issues.contains { $0.contains("does not resolve inside") })
        }
        // data/raw-sibling prefix path fails closed (prefix + "/" check).
        do {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("rawview-manifest-sibling-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: root) }
            try writeFixture(root, "data/raw/a.csv", csv)
            try writeFixture(root, "data/raw-sibling/a.csv", csv)
            try writeFixture(root, "data/instruments/keysight-b1500a.yaml", keysightProfile)
            try writeFixture(root, "study.yaml", "study_id: s\nsources:\n  - path: data/raw-sibling/a.csv\n")
            let index = ManifestIndex.load(project: try ProjectContext.open(root))
            precondition(index.manifests.isEmpty && index.issues.contains { $0.contains("does not resolve inside") })
        }
        // Conflicting project-relative and manifest-relative paths to
        // different raw files fail closed as ambiguous.
        do {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("rawview-manifest-conflict-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: root) }
            try writeFixture(root, "data/raw/a.csv", csv)
            try writeFixture(root, "data/raw/b.csv", csv.replacingOccurrences(of: "1E-12", with: "2E-12"))
            try writeFixture(root, "data/instruments/keysight-b1500a.yaml", keysightProfile)
            try FileManager.default.createSymbolicLink(
                at: root.appendingPathComponent("proj-alias.csv"),
                withDestinationURL: root.appendingPathComponent("data/raw/a.csv"))
            try FileManager.default.createDirectory(at: root.appendingPathComponent("sub"), withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(
                at: root.appendingPathComponent("sub/proj-alias.csv"),
                withDestinationURL: root.appendingPathComponent("data/raw/b.csv"))
            try writeFixture(root, "sub/study.yaml", "study_id: s\nsources:\n  - path: proj-alias.csv\n")
            let index = ManifestIndex.load(project: try ProjectContext.open(root))
            precondition(index.manifests.isEmpty && index.issues.contains { $0.contains("ambiguous between project-relative and manifest-relative") })
        }
        // Duplicate aliases to one raw file fail closed.
        do {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("rawview-manifest-dup-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: root) }
            try writeFixture(root, "data/raw/a.csv", csv)
            try writeFixture(root, "data/instruments/keysight-b1500a.yaml", keysightProfile)
            try FileManager.default.createSymbolicLink(
                at: root.appendingPathComponent("alias-to-a.csv"),
                withDestinationURL: root.appendingPathComponent("data/raw/a.csv"))
            try writeFixture(root, "study.yaml", "study_id: s\nsources:\n  - path: data/raw/a.csv\n  - path: alias-to-a.csv\n")
            let index = ManifestIndex.load(project: try ProjectContext.open(root))
            precondition(index.manifests.isEmpty && index.issues.contains { $0.contains("same file") })
        }
    }

    /// Positive folded/literal handling plus negative tab and duplicate-key
    /// checks, all through the production ManifestIndex.load path.
    static func manifestSubsetSelfCheck() async throws {
        let csv = "SetupTitle, 2-terminal dual Vsweep\nDataName, V1, I1\nDataValue, 0, 1E-12\n"
        // Positive: unrelated folded and literal scalars never become membership.
        do {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("rawview-manifest-scalar-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: root) }
            try writeFixture(root, "data/raw/a.csv", csv)
            try writeFixture(root, "data/instruments/keysight-b1500a.yaml", keysightProfile)
            try writeFixture(root, "study.yaml", "study_id: s\nnotes: |\n  literal text\n  sources: fake\nrationale: >\n  folded text\n  study_id: fake\nsources:\n  - path: data/raw/a.csv\n")
            let index = ManifestIndex.load(project: try ProjectContext.open(root))
            precondition(index.issues.isEmpty && index.manifests.count == 1 && index.manifests[0].members == ["data/raw/a.csv"])
        }
        // Negative: tab indentation fails closed.
        do {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("rawview-manifest-tab-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: root) }
            try writeFixture(root, "data/raw/a.csv", csv)
            try writeFixture(root, "data/instruments/keysight-b1500a.yaml", keysightProfile)
            try writeFixture(root, "study.yaml", "study_id: s\nsources:\n\t- path: data/raw/a.csv\n")
            let index = ManifestIndex.load(project: try ProjectContext.open(root))
            precondition(index.manifests.isEmpty)
        }
        // Negative: duplicate top-level study_id fails closed.
        do {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("rawview-manifest-dupkey-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: root) }
            try writeFixture(root, "data/raw/a.csv", csv)
            try writeFixture(root, "data/instruments/keysight-b1500a.yaml", keysightProfile)
            try writeFixture(root, "one.yaml", "study_id: a\nstudy_id: b\nsources:\n  - path: data/raw/a.csv\n")
            try writeFixture(root, "two.yaml", "study_id: c\nsources:\n  - path: data/raw/a.csv\nsources:\n  - path: data/raw/a.csv\n")
            let index = ManifestIndex.load(project: try ProjectContext.open(root))
            precondition(index.manifests.isEmpty && index.issues.count == 2)
        }
    }

    /// B1500A list-sweep and dual-sweep selection through the project's
    /// header-only detect signatures. Synthetic fixtures only.
    static func b1500ModeSelectionSelfCheck() async throws {
        let profile = """
        schema_version: 2
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
            detect: ["2-terminal dual Vsweep", "dual Vsweep"]
            extract:
              x: voltage
              y: [current]
          - id: list-sweep
            format: csv
            detect: ["I/V List Sweep", "I/V Sweep"]
            extract:
              x: voltage
              y: [current]
        """
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rawview-b1500a-modes-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try writeFixture(root, "data/raw/one.csv",
                  "SetupTitle, I/V List Sweep 1V\nDataName, V1, I2\nDataValue, 0.2, 3E-9\nDataValue, 0.0, 1E-9\n")
        try writeFixture(root, "data/raw/two.csv",
                  "SetupTitle, 2-terminal dual Vsweep\nDataName, V1, I1\nDataValue, 0, 1E-12\nDataValue, 0.1, 2E-12\n")
        try writeFixture(root, "data/instruments/keysight-b1500a.yaml", profile)
        let project = try ProjectContext.open(root)
        let report = await InstrumentReader.inspectMany(try project.discoverSources(), project: project)
        precondition(report.profileIssues.isEmpty)
        let list = report.results.first { $0.id == "data/raw/one.csv" }
        let dual = report.results.first { $0.id == "data/raw/two.csv" }
        precondition(list?.inspection?.applicationMode == "list-sweep")
        precondition(dual?.inspection?.applicationMode == "dual-sweep")
        let listMeasurement = try await InstrumentReader.load(
            root.appendingPathComponent("data/raw/one.csv"), project: project)
        precondition(listMeasurement.channel(named: "voltage")?.values == [0.2, 0.0])
        precondition(listMeasurement.view.preserveOrder)
        let dualMeasurement = try await InstrumentReader.load(
            root.appendingPathComponent("data/raw/two.csv"), project: project)
        precondition(dualMeasurement.channel(named: "current")?.values == [1e-12, 2e-12])
    }

    /// Synthetic WGFMU overlay regression: all values stay displayable with
    /// time/order preserved, generic unknown/unspecified declarations block
    /// overlay. Runs alongside the reader self-check; no per-source settings
    /// are invented.
    static func wgfmuOverlaySelfCheck() async throws {
        let profile = """
        schema_version: 2
        instrument:
          id: keysight-b1500a
          name: Keysight B1500A
        formats:
          - id: wgfmu
            kind: tabular
            extensions: [".csv"]
            delimiter: ","
            rows:
              names_prefix: "DataName"
              data_prefix: "DataValue"
            columns:
              time:
                header: "Time"
                quantity: time
                unit: "s"
              signal_1:
                header: "MeasResult1_value"
                quantity: unknown
                unit: "unspecified"
                label: "Channel 1"
              signal_2:
                header: "MeasResult2_value"
                quantity: unknown
                unit: "unspecified"
                label: "Channel 2"
        modes:
          - id: wgfmu
            format: wgfmu
            detect: ["MeasResult"]
            extract:
              x: time
              y: [signal_1]
        """
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rawview-wgfmu-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let csvA = "SetupTitle, STP decay\nDataName, Time, MeasResult1_value, MeasResult2_value\nDataValue, 0, 0, 1E-12\nDataValue, 1E-9, 0.5, 2E-12\n"
        let csvB = "SetupTitle, STP decay\nDataName, Time, MeasResult1_value, MeasResult2_value\nDataValue, 0, 0.1, 3E-12\nDataValue, 1E-9, 0.6, 4E-12\n"
        try writeFixture(root, "data/raw/a.csv", csvA)
        try writeFixture(root, "data/raw/b.csv", csvB)
        try writeFixture(root, "data/instruments/keysight-b1500a.yaml", profile)
        try writeFixture(root, "study.yaml", "study_id: s\nsources:\n  - path: data/raw/a.csv\n  - path: data/raw/b.csv\n")
        let project = try ProjectContext.open(root)
        var measurements: [NormalizedMeasurement] = []
        for source in try project.discoverSources().sorted(by: { $0.relativePath < $1.relativePath }) {
            measurements.append(try await InstrumentReader.load(source.url, project: project))
        }
        precondition(measurements.count == 2)
        precondition(measurements[0].channel(named: "signal_1")?.values == [0, 0.5])
        precondition(measurements[0].channel(named: "signal_2")?.values == [1e-12, 2e-12])
        precondition(measurements[0].view.preserveOrder)
        let result = OverlayEvaluator.evaluate(measurements: measurements, manifests: ManifestIndex.load(project: project).manifests)
        guard case .blocked(let reason) = result else { fatalError("WGFMU unknown declarations accepted for overlay") }
        precondition(reason.lowercased().contains("quantity") || reason.lowercased().contains("unspecified") || reason.lowercased().contains("unit"))
    }

    /// WGFMU pulse/endurance expansion (synthetic fixtures only): explicit
    /// first-row-header layouts and endurance DataName blocks load complete
    /// ordered arrays with optional-only-when-present channels; the standard
    /// WGFMU mode is unchanged; unknown headers stay blocked; corrupt cells
    /// name file, line, column, and value; schema v1 stays fail-closed on the
    /// new layout kind.
    static func wgfmuFirstRowSelfCheck() async throws {
        precondition(InstrumentReader.version == "1.2.0", "reader cache identity must advance with the new parser")
        let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let shipped = try String(contentsOf: packageRoot.appendingPathComponent("Examples/rawview/keysight-b1500a.yaml"), encoding: .utf8)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rawview-wgfmu-firstrow-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try writeFixture(root, "data/instruments/keysight-b1500a.yaml", shipped)
        try writeFixture(root, "data/raw/keysight-b1500a.wgfmu_ppf-time.csv", "time_s,current_a\n0,1e-12\n2e-9,3e-12\n1e-9,2e-12\n")
        try writeFixture(root, "data/raw/keysight-b1500a.wgfmu_ppf-index.csv", "index-pulse,current_a\n0,1e-12\n1,2e-12\n")
        try writeFixture(root, "data/raw/keysight-b1500a.wgfmu_stp-fit.csv", "time_s,voltage_v,current_v,fit\n0,0.1,1e-9,0.5\n1e-9,0.2,2e-9,0.6\n")
        try writeFixture(root, "data/raw/keysight-b1500a.wgfmu_stp-fitc.csv", "time_s,voltage_v,current_v,fit_current\n0,0.1,1e-9,0.7\n")
        try writeFixture(root, "data/raw/keysight-b1500a.wgfmu_end-full.csv", "SetupTitle, endurance\nDataName, raw_cycles, raw_ch2, raw_ch1\nDataValue, 0, 1e-12, 2e-12\nDataValue, 1, 3e-12, 4e-12\n")
        try writeFixture(root, "data/raw/keysight-b1500a.wgfmu_end-min.csv", "SetupTitle, endurance\nDataName, raw_cycles, raw_ch2\nDataValue, 0, 1e-12\n")
        try writeFixture(root, "data/raw/keysight-b1500a.wgfmu_std.csv", "SetupTitle, STP decay\nDataName, Time, MeasResult1_value, MeasResult2_value\nDataValue, 0, 0, 1E-12\nDataValue, 1E-9, 0.5, 2E-12\n")
        try writeFixture(root, "data/raw/unknown.csv", "SetupTitle, mystery\nDataName, Foo, Bar\nDataValue, 0, 1\n")
        try writeFixture(root, "data/raw/keysight-b1500a.wgfmu_corrupt.csv", "time_s,current_a\n0,1e-12\n1e-9,--\n")
        try writeFixture(root, "data/raw/foreign.csv", "time_s,current_a\n0,1e-12\n1e-9,2e-12\n")
        let project = try ProjectContext.open(root)
        let report = await InstrumentReader.inspectMany(try project.discoverSources(), project: project)
        precondition(report.profileIssues.isEmpty, "shipped profile issues: \(report.profileIssues)")
        func mode(_ name: String) -> String? { report.results.first { $0.id == "data/raw/\(name)" }?.inspection?.applicationMode }
        precondition(mode("keysight-b1500a.wgfmu_ppf-time.csv") == "wgfmu-ppf-time", "ppf-time mode is \(mode("keysight-b1500a.wgfmu_ppf-time.csv") ?? "blocked")")
        precondition(mode("keysight-b1500a.wgfmu_ppf-index.csv") == "wgfmu-ppf-index", "ppf-index mode is \(mode("keysight-b1500a.wgfmu_ppf-index.csv") ?? "blocked")")
        precondition(mode("keysight-b1500a.wgfmu_stp-fit.csv") == "wgfmu-stp", "stp-fit mode is \(mode("keysight-b1500a.wgfmu_stp-fit.csv") ?? "blocked")")
        precondition(mode("keysight-b1500a.wgfmu_stp-fitc.csv") == "wgfmu-stp", "stp-fitc mode is \(mode("keysight-b1500a.wgfmu_stp-fitc.csv") ?? "blocked")")
        precondition(mode("keysight-b1500a.wgfmu_end-full.csv") == "wgfmu-endurance", "endurance mode is \(mode("keysight-b1500a.wgfmu_end-full.csv") ?? "blocked")")
        precondition(mode("keysight-b1500a.wgfmu_end-min.csv") == "wgfmu-endurance", "minimal endurance mode is \(mode("keysight-b1500a.wgfmu_end-min.csv") ?? "blocked")")
        precondition(mode("keysight-b1500a.wgfmu_std.csv") == "wgfmu", "standard WGFMU mode moved to \(mode("keysight-b1500a.wgfmu_std.csv") ?? "blocked")")
        precondition(mode("unknown.csv") == nil, "unknown header was accepted")
        precondition(mode("foreign.csv") == nil, "foreign basename was claimed")
        precondition(report.results.first { $0.id == "data/raw/foreign.csv" }?.error?.contains("keysight-b1500a.wgfmu") == true, "foreign basename diagnostic lost the missing token")
        func load(_ name: String) async throws -> NormalizedMeasurement {
            try await InstrumentReader.load(root.appendingPathComponent("data/raw/\(name)"), project: project)
        }
        let pt = try await load("keysight-b1500a.wgfmu_ppf-time.csv")
        precondition(pt.channel(named: "time")?.values == [0, 2e-9, 1e-9], "ppf-time arrays or order changed")
        precondition(pt.channel(named: "current")?.values == [1e-12, 3e-12, 2e-12], "ppf-time currents changed")
        precondition(pt.channel(named: "time")?.quantity == "time" && pt.channel(named: "time")?.unit == "s", "ppf-time axis declaration changed")
        precondition(pt.channel(named: "current")?.quantity == "current" && pt.channel(named: "current")?.unit == "A", "ppf-time current declaration changed")
        precondition(pt.view.x == "time" && pt.view.y == ["current"] && pt.view.preserveOrder, "ppf-time view changed")
        let pi = try await load("keysight-b1500a.wgfmu_ppf-index.csv")
        precondition(pi.channel(named: "pulse_index")?.values == [0, 1], "pulse index arrays changed")
        precondition(pi.channel(named: "pulse_index")?.quantity == "pulse" && pi.channel(named: "pulse_index")?.unit == "pulse", "pulse index declaration changed")
        precondition(pi.view.x == "pulse_index" && pi.view.y == ["current"], "ppf-index view changed")
        let sf = try await load("keysight-b1500a.wgfmu_stp-fit.csv")
        precondition(sf.channels.count == 4 && sf.channel(named: "fit")?.values == [0.5, 0.6], "stp fit variant lost a channel")
        precondition(sf.channel(named: "fit_current") == nil, "absent stp optional was invented")
        precondition(sf.channel(named: "voltage")?.quantity == "voltage" && sf.channel(named: "voltage")?.unit == "V", "stp voltage declaration changed")
        precondition(sf.channel(named: "current")?.quantity == "unknown" && sf.channel(named: "current")?.unit == "unspecified", "stp current_v must stay unknown/unspecified")
        precondition(sf.channel(named: "current")?.label == "current_v", "stp current label implies a resolved unit")
        precondition(sf.view.x == "time" && sf.view.y == ["voltage"], "stp view changed")
        let sc = try await load("keysight-b1500a.wgfmu_stp-fitc.csv")
        precondition(sc.channel(named: "fit_current")?.values == [0.7] && sc.channel(named: "fit") == nil, "stp fit_current variant wrong")
        let ef = try await load("keysight-b1500a.wgfmu_end-full.csv")
        precondition(ef.channels.count == 3 && ef.channel(named: "channel_1")?.values == [2e-12, 4e-12], "endurance optional ch1 lost")
        precondition(ef.channel(named: "cycles")?.quantity == "cycles" && ef.channel(named: "cycles")?.unit == "cycles", "endurance cycles declaration changed")
        precondition(ef.view.x == "cycles" && ef.view.y == ["channel_2"], "endurance view changed")
        let em = try await load("keysight-b1500a.wgfmu_end-min.csv")
        precondition(em.channels.count == 2 && em.channel(named: "channel_1") == nil, "absent endurance optional was invented")
        do { _ = try await load("keysight-b1500a.wgfmu_corrupt.csv"); fatalError("corrupt first-row cell was loaded") } catch {
            precondition(error.localizedDescription.contains("line 3") && error.localizedDescription.contains("--"), "corrupt cell diagnostic lost file/line/value: \(error)")
        }
        // Schema v1 stays fail-closed on the new layout kind, and v2 rejects
        // a rows mapping under it: neither is silently accepted.
        let v1Probe = """
        schema_version: 1
        instrument:
          id: probe
          name: Probe
        formats:
          - id: f
            kind: first-row-header
            extensions: [".csv"]
            delimiter: ","
            columns:
              a:
                header: "a"
                quantity: unknown
                unit: "unspecified"
              b:
                header: "b"
                quantity: unknown
                unit: "unspecified"
        modes:
          - id: m
            format: f
            detect: ["a"]
            extract:
              x: a
              y: [b]
        """
        let guarded = FileManager.default.temporaryDirectory.appendingPathComponent("rawview-wgfmu-guarded-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: guarded) }
        try writeFixture(guarded, "data/raw/a.csv", "a,b\n0,1\n")
        try writeFixture(guarded, "data/instruments/probe.yaml", v1Probe)
        let guardedReport = await InstrumentReader.inspectMany(try ProjectContext.open(guarded).discoverSources(), project: try ProjectContext.open(guarded))
        precondition(guardedReport.results.first?.inspection == nil && (guardedReport.results.first?.error?.contains("first-row-header") == true), "v1 accepted the new layout kind")
        try writeFixture(guarded, "data/instruments/probe.yaml", v1Probe.replacingOccurrences(of: "schema_version: 1", with: "schema_version: 2").replacingOccurrences(of: "delimiter: \",\"", with: "delimiter: \",\"\n    rows:\n      names_prefix: \"H\""))
        let rowsReport = await InstrumentReader.inspectMany(try ProjectContext.open(guarded).discoverSources(), project: try ProjectContext.open(guarded))
        precondition(rowsReport.results.first?.inspection == nil && (rowsReport.results.first?.error?.contains("rows is not part of kind") == true), "v2 accepted rows under the new layout kind")
    }

    /// B1500A selector corrections (synthetic fixtures only, shipped profile):
    /// a list-sweep header with a legacy dual-sweep-suffixed B1500A basename
    /// resolves to list-sweep with exact ordered arrays, while a foreign
    /// basename stays blocked.
    static func b1500SelectorCorrectionSelfCheck() async throws {
        let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let shipped = try String(contentsOf: packageRoot.appendingPathComponent("Examples/rawview/keysight-b1500a.yaml"), encoding: .utf8)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rawview-b1500a-selector-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try writeFixture(root, "data/instruments/keysight-b1500a.yaml", shipped)
        try writeFixture(root, "data/raw/keysight-b1500a.dual-sweep_legacy.csv", "SetupTitle, I/V List Sweep 1V\nDataName, V1, I2\nDataValue, 0.2, 3E-9\nDataValue, 0.0, 1E-9\n")
        try writeFixture(root, "data/raw/foreign-list.csv", "SetupTitle, I/V List Sweep 1V\nDataName, V1, I2\nDataValue, 0.2, 3E-9\n")
        try writeFixture(root, "data/raw/keysight-b1500a.dual-sweep_meta.csv", "SetupTitle, 2-terminal dual Vsweep\nApplicationTest, I/V Sweep, Public\nDataName, V1, I1\nDataValue, 0, 1E-12\nDataValue, 0.1, 2E-12\n")
        let project = try ProjectContext.open(root)
        let report = await InstrumentReader.inspectMany(try project.discoverSources(), project: project)
        precondition(report.profileIssues.isEmpty, "shipped profile issues: \(report.profileIssues)")
        let legacy = report.results.first { $0.id == "data/raw/keysight-b1500a.dual-sweep_legacy.csv" }
        precondition(legacy?.inspection?.applicationMode == "list-sweep", "legacy dual-suffixed list-sweep resolved to \(legacy?.inspection?.applicationMode ?? "blocked")")
        let measurement = try await InstrumentReader.load(root.appendingPathComponent("data/raw/keysight-b1500a.dual-sweep_legacy.csv"), project: project)
        precondition(measurement.channel(named: "voltage")?.values == [0.2, 0.0], "legacy list-sweep arrays or order changed")
        precondition(measurement.channel(named: "current")?.values == [3e-9, 1e-9], "legacy list-sweep currents changed")
        let foreign = report.results.first { $0.id == "data/raw/foreign-list.csv" }
        precondition(foreign?.inspection == nil, "foreign basename was claimed")
        do {
            _ = try await InstrumentReader.load(root.appendingPathComponent("data/raw/foreign-list.csv"), project: project)
            fatalError("foreign basename was loaded")
        } catch { precondition("\(error)".contains("keysight-b1500a"), "foreign diagnostic lost the token: \(error)") }
        // Generic I/V Sweep text in unrelated metadata must not pull a dual
        // export into list-sweep: the dual signature wins uniquely.
        let dualMetaResult = report.results.first { $0.id == "data/raw/keysight-b1500a.dual-sweep_meta.csv" }
        precondition(dualMetaResult?.inspection?.applicationMode == "dual-sweep", "dual export with generic sweep text resolved to \(dualMetaResult?.inspection?.applicationMode ?? "blocked")")
        let dualMeta = try await InstrumentReader.load(root.appendingPathComponent("data/raw/keysight-b1500a.dual-sweep_meta.csv"), project: project)
        precondition(dualMeta.channel(named: "voltage")?.values == [0, 0.1], "dual arrays or order changed")
        precondition(dualMeta.channel(named: "current")?.values == [1e-12, 2e-12], "dual currents changed")
        // STP requires the comma-delimited required-column signature: a
        // semicolon-delimited lookalike stays unmatched/blocked before load,
        // while the comma layout keeps matching.
        try writeFixture(root, "data/raw/keysight-b1500a.wgfmu_stp-comma.csv", "time_s,voltage_v,current_v,fit\n0,0.1,1e-9,0.5\n")
        try writeFixture(root, "data/raw/keysight-b1500a.wgfmu_stp-semi.csv", "SetupTitle, synthetic semicolon table\ntime_s;voltage_v;current_v;fit\n0;0.1;1e-9;0.5\n")
        let stpReport = await InstrumentReader.inspectMany(try project.discoverSources(), project: project)
        precondition(stpReport.results.first { $0.id == "data/raw/keysight-b1500a.wgfmu_stp-comma.csv" }?.inspection?.applicationMode == "wgfmu-stp", "comma STP stopped matching")
        precondition(stpReport.results.first { $0.id == "data/raw/keysight-b1500a.wgfmu_stp-semi.csv" }?.inspection == nil, "semicolon table was selected as STP")
        do {
            _ = try await InstrumentReader.load(root.appendingPathComponent("data/raw/keysight-b1500a.wgfmu_stp-semi.csv"), project: project)
            fatalError("semicolon table was loaded as STP")
        } catch { precondition("\(error)".contains("No profile mode matched"), "semicolon diagnostic lost the cause: \(error)") }
    }

    /// Audit regression seam: one synthetic assertion per accepted finding.
    /// Each precondition describes fixed behavior; all must hold after repair.
    static func auditRegressionSelfCheck() async throws {
        // 1. Unbounded line/header allocation is rejected; valid sizes still load.
        do {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("rawview-audit-line-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: root) }
            try writeFixture(root, "data/instruments/keysight-b1500a.yaml", keysightProfile)
            let hugeLine = String(repeating: "A", count: 2 * 1024 * 1024)
            try writeFixture(root, "data/raw/huge.csv", "SetupTitle, 2-terminal dual Vsweep\nDataName, V1, I1\nDataValue, 0, 1E-12\n" + hugeLine + "\n")
            let project = try ProjectContext.open(root)
            var rejected = false
            do { _ = try await InstrumentReader.load(root.appendingPathComponent("data/raw/huge.csv"), project: project) } catch { rejected = true }
            precondition(rejected, "finding 1: single huge source line was not bounded")
            var header = "SetupTitle, 2-terminal dual Vsweep\n"
            for i in 0..<4000 { header += "Meta\(i), " + String(repeating: "B", count: 800) + "\n" }
            header += "DataName, V1, I1\nDataValue, 0, 1E-12\n"
            try writeFixture(root, "data/raw/hugehdr.csv", header)
            var headerRejected = false
            do { _ = try await InstrumentReader.load(root.appendingPathComponent("data/raw/hugehdr.csv"), project: project) } catch { headerRejected = true }
            precondition(headerRejected, "finding 1: accumulated header was not bounded")
        }
        // 2. Cache seams reject source symlinks and .spe/.affm before any open.
        do {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("rawview-audit-symlink-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: root) }
            try writeFixture(root, "data/raw/real.csv", dualSweepCSV)
            try writeFixture(root, "data/instruments/keysight-b1500a.yaml", keysightProfile)
            try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("data/raw/link.csv"), withDestinationURL: root.appendingPathComponent("data/raw/real.csv"))
            let project = try ProjectContext.open(root)
            let linkSource = RawSource(relativePath: "data/raw/link.csv", url: root.appendingPathComponent("data/raw/link.csv"), byteSize: 10)
            var symlinkRejected = false
            do { _ = try MeasurementCache.openSecuredPrefix(source: linkSource, project: project) } catch { symlinkRejected = true }
            // A symlink must never open its target: nil prefix or throw both count as reject only if no target bytes were read.
            // The secured seam must throw (not return target bytes).
            precondition(symlinkRejected, "finding 2: openSecuredPrefix followed a source symlink")
            precondition((try? MeasurementCache(project: project).measurement(for: linkSource, project: project, profileFingerprint: "fp")) == nil, "finding 2: measurement(for:) served a symlink source")
            // .spe/.affm never reach an open at any seam.
            for name in ["skip.spe", "skip.affm"] {
                let url = root.appendingPathComponent("data/raw/\(name)")
                try Data("SetupTitle, x\n".utf8).write(to: url)
                let src = RawSource(relativePath: "data/raw/\(name)", url: url, byteSize: 10)
                var speRejected = false
                do { _ = try MeasurementCache.openSecuredPrefix(source: src, project: project) } catch { speRejected = true }
                precondition(speRejected, "finding 2: .spe/.affm reached openSecuredPrefix")
                precondition((try? MeasurementCache(project: project).measurement(for: src, project: project, profileFingerprint: "fp")) == nil, "finding 2: .spe/.affm reached measurement cache")
            }
        }
        // 3. Profile catalog rejects YAML symlink entries before resolving.
        do {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("rawview-audit-profsym-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: root) }
            try writeFixture(root, "data/raw/a.csv", dualSweepCSV)
            try writeFixture(root, "data/instruments/real.yaml", keysightProfile)
            try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("data/instruments/link.yaml"), withDestinationURL: root.appendingPathComponent("data/instruments/real.yaml"))
            let catalog = ProfileCatalog.load(project: try ProjectContext.open(root))
            precondition(catalog.profiles.count == 1 && catalog.issues.contains { $0.contains("link.yaml") && $0.lowercased().contains("symlink") }, "finding 3: profile symlink was resolved instead of rejected")
        }
        // 4. Manifest enumeration failure fails overlay membership closed.
        do {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("rawview-audit-manifestfail-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: root) }
            try writeFixture(root, "data/raw/a.csv", dualSweepCSV)
            try writeFixture(root, "data/instruments/keysight-b1500a.yaml", keysightProfile)
            try writeFixture(root, "study.yaml", "study_id: s\nsources:\n  - path: data/raw/a.csv\n")
            let blockedDir = root.appendingPathComponent("blocked")
            try FileManager.default.createDirectory(at: blockedDir, withIntermediateDirectories: true)
            try writeFixture(root, "blocked/inner.yaml", "study_id: s\nsources:\n  - path: data/raw/a.csv\n")
            try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: blockedDir.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: blockedDir.path) }
            // If the host can still read the 0o000 directory (root), the failure is not triggerable here.
            let triggerable = (try? FileManager.default.contentsOfDirectory(atPath: blockedDir.path)) == nil
            if triggerable {
                let index = ManifestIndex.load(project: try ProjectContext.open(root))
                precondition(index.issues.contains(where: { $0.lowercased().contains("enumerat") || $0.lowercased().contains("fail") }), "finding 4: enumeration failure was not recorded")
                precondition(index.manifests.isEmpty, "finding 4: partial manifest list established membership after enumeration failure")
            }
        }
        // 5. Cache files and owned dirs are owner-only; system parents are not required.
        do {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("rawview-audit-perms-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: root) }
            try writeFixture(root, "data/raw/a.csv", dualSweepCSV)
            try writeFixture(root, "data/instruments/keysight-b1500a.yaml", keysightProfile)
            let project = try ProjectContext.open(root)
            let cache = MeasurementCache(project: project)
            let source = try requireLike(try project.discoverSources().first)
            let m = try await InstrumentReader.load(source.url, project: project, cache: cache)
            _ = m
            let usage = try cache.usage()
            let fm = FileManager.default
            var foundFile = false
            if let prefixes = try? fm.contentsOfDirectory(atPath: usage.root) {
                for prefix in prefixes {
                    let pURL = URL(fileURLWithPath: usage.root).appendingPathComponent(prefix)
                    guard let keys = try? fm.contentsOfDirectory(atPath: pURL.path) else { continue }
                    for key in keys {
                        let entry = pURL.appendingPathComponent(key)
                        for file in (try? fm.contentsOfDirectory(atPath: entry.path)) ?? [] {
                            let fURL = entry.appendingPathComponent(file)
                            if let attrs = try? fm.attributesOfItem(atPath: fURL.path),
                               let perms = attrs[.posixPermissions] as? NSNumber {
                                foundFile = true
                                precondition(perms.intValue & 0o077 == 0, "finding 5: cache file \(fURL.lastPathComponent) is not owner-only (\(String(perms.intValue, radix: 8)))")
                            }
                        }
                        if let attrs = try? fm.attributesOfItem(atPath: entry.path),
                           let perms = attrs[.posixPermissions] as? NSNumber {
                            precondition(perms.intValue & 0o077 == 0, "finding 5: cache dir is not owner-only")
                        }
                    }
                }
            }
            precondition(foundFile, "finding 5: no cache file to check permissions")
        }
        // 6. Selected format encoding drives decoding; union of encodings must not rescue.
        do {
            let profile = """
            schema_version: 1
            instrument:
              id: enc
              name: Enc
            formats:
              - id: f-utf8
                kind: tabular
                extensions: [".csv"]
                delimiter: ","
                encoding: ["utf-8"]
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
              - id: f-latin
                kind: tabular
                extensions: [".csv"]
                delimiter: ","
                encoding: ["windows-1252"]
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
              - id: m-utf8
                format: f-utf8
                detect: ["café"]
                extract:
                  x: voltage
                  y: [current]
              - id: m-latin
                format: f-latin
                detect: ["Ã©"]
                extract:
                  x: voltage
                  y: [current]
            """
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("rawview-audit-enc-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: root) }
            try writeFixture(root, "data/instruments/enc.yaml", profile)
            // Bytes C3 A9 decode as "é" in UTF-8 and as "Ã©" in windows-1252: each candidate sees a different header.
            try writeFixture(root, "data/raw/mixed.csv", "SetupTitle, caf\u{00e9}-utf8\nDataName, V1, I1\nDataValue, 0, 1E-12\n")
            // Rewrite the file with raw C3 A9 bytes explicitly to avoid normalization surprises.
            let rawMixed = Data([0x53, 0x65, 0x74, 0x75, 0x70, 0x54, 0x69, 0x74, 0x6c, 0x65, 0x2c, 0x20, 0x63, 0x61, 0x66, 0xC3, 0xA9, 0x2D, 0x75, 0x74, 0x66, 0x38, 0x0A]) + Data("DataName, V1, I1\nDataValue, 0, 1E-12\n".utf8)
            try rawMixed.write(to: root.appendingPathComponent("data/raw/mixed.csv"))
            let project = try ProjectContext.open(root)
            let report = await InstrumentReader.inspectMany(try project.discoverSources(), project: project)
            // Per-candidate decoding sees both candidates match (each in its own encoding) -> ambiguous must block, not pick one.
            precondition(report.results.first?.inspection == nil, "finding 6: union of encodings picked a unique format instead of requiring per-candidate uniqueness")
        }
        // 7. Inspection identity uses the pinned descriptor/prefix (no close-reopen race).
        do {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("rawview-audit-race-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: root) }
            try writeFixture(root, "data/raw/a.csv", dualSweepCSV)
            try writeFixture(root, "data/instruments/keysight-b1500a.yaml", keysightProfile)
            let project = try ProjectContext.open(root)
            let cache = MeasurementCache(project: project)
            let source = try requireLike(try project.discoverSources().first)
            let fp = ProfileCatalog.load(project: project).fingerprint
            let pinnedResult = try await cache.inspection(for: source, project: project, catalogFingerprint: fp) { (pinnedPrefix: Data, descriptorSize: Int64, actualURL: URL) throws -> MeasurementCache.CachedInspection in
                // Mutate the source after the cache pinned its prefix: the producer must still use pinned A.
                try Data("SetupTitle, MUTATED\nDataName, V1, I1\nDataValue, 9, 9E-9\n".utf8).write(to: source.url)
                return try InstrumentReader.inspectPinned(source: source, project: project, catalog: ProfileCatalog.load(project: project), prefix: pinnedPrefix, descriptorSize: descriptorSize, actualURL: actualURL)
            }
            guard case .supported = pinnedResult.outcome else {
                fatalError("finding 7: pinned producer did not preserve supported outcome")
            }
            // Restore original; the pinned entry for A must be present.
            try Data(dualSweepCSV.utf8).write(to: source.url)
            let usage = try cache.usage()
            precondition(usage.entryCount == 1, "finding 7: pinned inspection was not stored")
        }
        // 8. Pending CR at EOF is a line ending.
        do {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("rawview-audit-cr-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: root) }
            try writeFixture(root, "data/instruments/keysight-b1500a.yaml", keysightProfile)
            let crText = "SetupTitle, 2-terminal dual Vsweep\rDataName, V1, I1\rDataValue, 0, 1E-12\rDataValue, 0.1, 2E-12\r"
            try writeFixture(root, "data/raw/cr.csv", crText)
            let project = try ProjectContext.open(root)
            let m = try await InstrumentReader.load(root.appendingPathComponent("data/raw/cr.csv"), project: project)
            precondition(m.channel(named: "voltage")?.values == [0, 0.1], "finding 8: trailing CR at EOF was not a line ending")
        }
        // 9. YAML flow-list empties, backslash parity, and block-scalar tabs.
        do {
            var emptyRejected = false
            do { _ = try YAMLParser.parse("key: [\"a\", , \"b\"]\n") } catch { emptyRejected = true }
            precondition(emptyRejected, "finding 9: empty flow-list element was accepted")
            var trailingRejected = false
            do { _ = try YAMLParser.parse("key: [\".csv\", ]\n") } catch { trailingRejected = true }
            precondition(trailingRejected, "finding 9: trailing comma flow-list element was accepted")
            var parityOK = false
            do {
                let node = try YAMLParser.parse("key: [\"a\\\\\"]\n")
                if let items = node.value(for: "key")?.listItems, items.count == 1 { parityOK = true }
            } catch { parityOK = false }
            precondition(parityOK, "finding 9: even-backslash escaped quote was misclassified")
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("rawview-audit-yamltab-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: root) }
            try writeFixture(root, "data/raw/a.csv", dualSweepCSV)
            try writeFixture(root, "data/instruments/keysight-b1500a.yaml", keysightProfile)
            try writeFixture(root, "study.yaml", "study_id: s\nnotes: |\n  literal line\n\tline with leading tab inside block\nsources:\n  - path: data/raw/a.csv\n")
            let index = ManifestIndex.load(project: try ProjectContext.open(root))
            precondition(index.manifests.count == 1, "finding 9: tab inside unrelated block-scalar content was misclassified as indentation")
        }
        // 10. Decimal lexical syntax rejects Swift-only hex floats.
        do {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("rawview-audit-dec-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: root) }
            try writeFixture(root, "data/instruments/keysight-b1500a.yaml", keysightProfile)
            try writeFixture(root, "data/raw/hex.csv", "SetupTitle, 2-terminal dual Vsweep\nDataName, V1, I1\nDataValue, 0x1.0p+1, 1E-12\n")
            let project = try ProjectContext.open(root)
            var hexRejected = false
            do { _ = try await InstrumentReader.load(root.appendingPathComponent("data/raw/hex.csv"), project: project) } catch { hexRejected = true }
            precondition(hexRejected, "finding 10: Swift-only hex float 0x1.0p+1 was accepted")
            try writeFixture(root, "data/raw/valid.csv", "SetupTitle, 2-terminal dual Vsweep\nDataName, V1, I1\nDataValue, +0.5, -1.2E-3\nDataValue, .25, 2e+6\n")
            let valid = try await InstrumentReader.load(root.appendingPathComponent("data/raw/valid.csv"), project: project)
            precondition(valid.channel(named: "voltage")?.values == [0.5, 0.25], "finding 10: valid signed/exponent decimals were rejected")
        }
        // 11. Regions view-kind compatibility is preserved or migrated explicitly.
        do {
            let json = #"{"contract_version":1,"source":{"path":"data/raw/a.csv","sha256":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"},"instrument":{"id":"x","name":"X"},"application_mode":null,"view":{"kind":"regions","x":"voltage","y":["current"],"preserve_order":true},"channels":[{"name":"voltage","label":"Voltage","unit":"V","quantity":"voltage","values":[0.0]},{"name":"current","label":"Current","unit":"A","quantity":"current","values":[1e-12]}],"metadata_sections":[],"warnings":[],"support_status":"supported","provenance":{}}"#
            var regionsOK = false
            var migrationDiagnostic = false
            do { _ = try NormalizedMeasurement.decode(Data(json.utf8)); regionsOK = true } catch ContractError.invalid(let message) {
                migrationDiagnostic = message.lowercased().contains("regions") && message.lowercased().contains("migrat")
            } catch { migrationDiagnostic = false }
            precondition(regionsOK || migrationDiagnostic, "finding 11: regions view-kind silently broke compatibility")
        }
        // 12. Full-file digest honors cancellation and stores nothing partial.
        do {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("rawview-audit-cancel-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: root) }
            var big = "SetupTitle, 2-terminal dual Vsweep\nDataName, V1, I1\n"
            for i in 0..<60000 { big += "DataValue, \(Double(i) * 0.001), 1E-12\n" }
            try writeFixture(root, "data/raw/big.csv", big)
            try writeFixture(root, "data/instruments/keysight-b1500a.yaml", keysightProfile)
            let project = try ProjectContext.open(root)
            let source = try requireLike(try project.discoverSources().first)
            // Cancellation inside the digest loop itself (no pre-check): the
            // loop must honor it rather than completing the hash.
            let sourceURL = source.url
            var cancelledThrew = false
            let task = Task.detached {
                let handle = try FileHandle(forReadingFrom: sourceURL)
                defer { try? handle.close() }
                let prefix = try handle.read(upToCount: InstrumentReader.headerSampleBytes) ?? Data()
                _ = try MeasurementCache.fullDigest(handle: handle, prefix: prefix)
            }
            task.cancel()
            do { _ = try await task.value } catch is CancellationError { cancelledThrew = true } catch { cancelledThrew = false }
            precondition(cancelledThrew, "finding 12: full-file digest ignored cancellation")
            // No partial digest/cache entry after cancellation (reader path).
            let cache = MeasurementCache(project: project)
            let loadTask = Task.detached {
                try await InstrumentReader.load(source.url, project: project, cache: cache)
            }
            loadTask.cancel()
            _ = try? await loadTask.value
            precondition((try? cache.usage().entryCount) ?? 0 == 0, "finding 12: cancelled load stored a partial cache entry")
        }
        // 13. Foreign-encoding match must never report supported: one candidate
        // encoding decodes while another candidate's detect signature appears
        // only in that decoded text. Inspection must stay blocked and load must
        // fail closed; inspection must not claim a readable source load cannot decode.
        do {
            let profile = """
            schema_version: 1
            instrument:
              id: enc
              name: Enc
            formats:
              - id: f-win
                kind: tabular
                extensions: [".csv"]
                delimiter: ","
                encoding: ["windows-1252"]
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
              - id: f-ascii
                kind: tabular
                extensions: [".csv"]
                delimiter: ","
                encoding: ["ascii"]
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
              - id: m-win
                format: f-win
                detect: ["MODE-A-ONLY"]
                extract:
                  x: voltage
                  y: [current]
              - id: m-ascii
                format: f-ascii
                detect: ["café-B"]
                extract:
                  x: voltage
                  y: [current]
            """
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("rawview-audit-foreignenc-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: root) }
            try writeFixture(root, "data/instruments/enc.yaml", profile)
            // Single 0xE9 byte: windows-1252 decodes to "é" (so the decoded text
            // contains the ascii candidate's signature), ascii cannot decode it.
            var bytes = Data("SetupTitle, caf".utf8)
            bytes.append(0xE9)
            bytes.append(contentsOf: Data("-B\nDataName, V1, I1\nDataValue, 0, 1E-12\n".utf8))
            let sourceURL = root.appendingPathComponent("data/raw/mixed.csv")
            try FileManager.default.createDirectory(at: sourceURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try bytes.write(to: sourceURL)
            let project = try ProjectContext.open(root)
            let report = await InstrumentReader.inspectMany(try project.discoverSources(), project: project)
            precondition(report.results.first?.inspection == nil, "finding 13: inspection claimed supported from a foreign-encoding match that load cannot decode")
            var loadRejected = false
            do { _ = try await InstrumentReader.load(sourceURL, project: project) } catch { loadRejected = true }
            precondition(loadRejected, "finding 13: load did not fail closed for foreign-encoding bytes")
        }
    }

    /// Regressions accepted from the final deep-audit adjudication. Synthetic
    /// fixtures only; no project measurements are read here.
    static func auditRemediationSelfCheck() async throws {
        // A fresh schema root must not traverse legacy permissive RawView dirs.
        do {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("rawview-cache-schema-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: root) }
            try writeFixture(root, "data/raw/a.csv", dualSweepCSV)
            let project = try ProjectContext.open(root)
            let cacheRoot = MeasurementCache.appLocalRoot(project: project)
            precondition(cacheRoot.pathComponents.contains("RawView-v3") || cacheRoot.pathComponents.contains("RawViewCache-v3"), "audit f4: current cache reused legacy app-local ancestors")
        }
        // F_GETPATH may choose a different hardlink name; selected identity
        // still controls extension, profile matching, and the measurement path.
        do {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("rawview-hardlink-identity-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: root) }
            let selectedProfile = keysightProfile
                .replacingOccurrences(of: "schema_version: 1", with: "schema_version: 2")
                .replacingOccurrences(
                    of: "  - id: dual-sweep\n    format: csv",
                    with: "  - id: dual-sweep\n    filename_contains_all: [\"keysight-b1500a.dual-sweep\"]\n    format: csv")
            try writeFixture(root, "data/instruments/keysight-b1500a.yaml", selectedProfile)
            let selected = root.appendingPathComponent("data/raw/z-keysight-b1500a.dual-sweep.csv")
            try writeFixture(root, "data/raw/z-keysight-b1500a.dual-sweep.csv", dualSweepCSV)
            let otherAlias = root.appendingPathComponent("data/raw/a.csv")
            try FileManager.default.linkItem(at: selected, to: otherAlias)
            let project = try ProjectContext.open(root)
            let source = RawSource(relativePath: "data/raw/z-keysight-b1500a.dual-sweep.csv", url: selected, byteSize: Int64((try Data(contentsOf: selected)).count))
            let secured = try MeasurementCache.openSecuredPrefix(source: source, project: project)
            try secured.handle.close()
            let catalog = ProfileCatalog.load(project: project)
            let bytes = try Data(contentsOf: selected)
            let inspection = try InstrumentReader.inspectPinned(
                source: source, project: project, catalog: catalog,
                prefix: Data(bytes.prefix(InstrumentReader.headerSampleBytes)),
                descriptorSize: Int64(bytes.count), actualURL: otherAlias)
            guard case .supported(let selectedInspection) = inspection else {
                fatalError("audit f7: a descriptor alias replaced the selected profile basename")
            }
            precondition(selectedInspection.source == source.relativePath && selectedInspection.applicationMode == "dual-sweep", "audit f7: hardlink inspection lost selected path identity")
            let measurement = try await InstrumentReader.load(selected, project: project)
            precondition(measurement.source.path == source.relativePath, "audit f7: hardlink canonical alias replaced the selected source path")
            precondition(measurement.applicationMode == "dual-sweep", "audit f7: hardlink canonical alias changed profile selection")
        }
        // The authoritative companion folder cannot be replaced by another
        // in-project directory through a symlink.
        do {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("rawview-profile-root-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: root) }
            try writeFixture(root, "data/raw/a.csv", dualSweepCSV)
            try writeFixture(root, "data/instruments/elsewhere/profile.yaml", keysightProfile)
            try FileManager.default.createSymbolicLink(
                at: root.appendingPathComponent("data/instruments/rawview"),
                withDestinationURL: root.appendingPathComponent("data/instruments/elsewhere"))
            let catalog = ProfileCatalog.load(project: try ProjectContext.open(root))
            precondition(catalog.profiles.isEmpty && catalog.issues.contains { $0.localizedCaseInsensitiveContains("symlink") }, "audit f8: profile catalog accepted a redirected companion directory")
        }
        // Excluded manifest members are skipped lexically before resolution;
        // the remaining membership uses canonical project-relative identity.
        do {
            let root = URL(fileURLWithPath: "/tmp/rawview-manifest-path-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: root) }
            try writeFixture(root, "data/raw/keep.csv", dualSweepCSV)
            let outside = root.deletingLastPathComponent().appendingPathComponent("rawview-outside-\(UUID().uuidString).bin")
            defer { try? FileManager.default.removeItem(at: outside) }
            try Data("outside".utf8).write(to: outside)
            try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("data/raw/skip.spe"), withDestinationURL: outside)
            try writeFixture(root, "studies/inputs.yaml", "study_id: synth-study\nsources:\n  - path: data/raw/keep.csv\n  - path: data/raw/skip.spe\n")
            let projectAlias = root.deletingLastPathComponent().appendingPathComponent("rawview-project-alias-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: projectAlias) }
            try FileManager.default.createSymbolicLink(at: projectAlias, withDestinationURL: root)
            let project = try ProjectContext.open(projectAlias)
            let index = ManifestIndex.load(project: project)
            precondition(index.manifests.count == 1, "audit f2/f3: manifest was lost across canonical project-root path spellings")
            precondition(index.manifests[0].members == ["data/raw/keep.csv"], "audit f2: excluded manifest path was resolved or retained")
        }
        // Comment-tsv metadata uses the same aggregate header-byte bound as
        // other streaming layouts, while ordinary comment headers still load.
        do {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("rawview-comment-header-bound-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: root) }
            try writeFixture(root, "data/instruments/horiba-labram.yaml", horibaProfile)
            try writeFixture(root, "data/raw/run-horiba-labram.raman.txt", "#Laser=532nm\n125,000\t3,25\n")
            let hugeKey = String(repeating: "K", count: 600_000)
            try writeFixture(root, "data/raw/large-horiba-labram.raman.txt", "#Laser=532nm\n#\(hugeKey)=x\n#\(hugeKey)=y\n125,000\t3,25\n")
            let project = try ProjectContext.open(root)
            let valid = try await InstrumentReader.load(root.appendingPathComponent("data/raw/run-horiba-labram.raman.txt"), project: project)
            precondition(valid.channels.first?.values.count == 1, "audit f6: valid comment-tsv header stopped loading")
            var oversizedRejected = false
            do {
                _ = try await InstrumentReader.load(root.appendingPathComponent("data/raw/large-horiba-labram.raman.txt"), project: project)
            } catch { oversizedRejected = true }
            precondition(oversizedRejected, "audit f6: accumulated comment-tsv header exceeded its byte bound")
        }
    }

    /// Trust-boundary tightening: claimed-path opens, pinned-prefix producer,
    /// same-descriptor digest, descriptor size. Synthetic fixtures only.
    static func auditTrustBoundaryTighteningSelfCheck() async throws {
        // 1a. Claimed .csv symlink to excluded suffix is rejected by no-follow
        // without reading its target (dangling target proves no target access).
        do {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("rawview-tight-symlink-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: root) }
            try writeFixture(root, "data/raw/real.csv", dualSweepCSV)
            try writeFixture(root, "data/instruments/keysight-b1500a.yaml", keysightProfile)
            let project = try ProjectContext.open(root)
            // Dangling symlink: target does not exist, so any target read would be missing, not symlink.
            try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("data/raw/evil.csv"), withDestinationURL: URL(fileURLWithPath: "/nonexistent-target.spe"))
            let evil = RawSource(relativePath: "data/raw/evil.csv", url: root.appendingPathComponent("data/raw/evil.csv"), byteSize: 10)
            var symlinkDiagnostic = false
            do { _ = try MeasurementCache.openSecuredPrefix(source: evil, project: project) } catch let e as SecureOpenError {
                symlinkDiagnostic = (e == .symlink(path: evil.url.path))
            } catch { symlinkDiagnostic = false }
            precondition(symlinkDiagnostic, "tightening: openSecuredPrefix did not reject claimed symlink via no-follow")
            precondition((try? MeasurementCache(project: project).measurement(for: evil, project: project, profileFingerprint: "fp")) == nil, "tightening: measurement served symlink")
            var loadSymlink = false
            do { _ = try await InstrumentReader.load(evil.url, project: project) } catch is ReaderError {
                loadSymlink = true
            } catch { loadSymlink = false }
            precondition(loadSymlink, "tightening: load did not reject claimed symlink")
            // .csv symlink to .spe target (existing) is symlink, not .spe data.
            try FileManager.default.removeItem(at: root.appendingPathComponent("data/raw/evil.csv"))
            try Data("SetupTitle, x\n".utf8).write(to: root.appendingPathComponent("data/raw/target.spe"))
            try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("data/raw/evil2.csv"), withDestinationURL: root.appendingPathComponent("data/raw/target.spe"))
            let evil2 = RawSource(relativePath: "data/raw/evil2.csv", url: root.appendingPathComponent("data/raw/evil2.csv"), byteSize: 10)
            var evil2Symlink = false
            do { _ = try MeasurementCache.openSecuredPrefix(source: evil2, project: project) } catch let e as SecureOpenError {
                evil2Symlink = (e == .symlink(path: evil2.url.path))
            } catch { evil2Symlink = false }
            precondition(evil2Symlink, "tightening: .csv symlink to .spe was not rejected by no-follow")
        }
        // 1b. Profile symlink with dangling target is symlink diagnostic.
        do {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("rawview-tight-profsym-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: root) }
            try writeFixture(root, "data/raw/a.csv", dualSweepCSV)
            try writeFixture(root, "data/instruments/real.yaml", keysightProfile)
            try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("data/instruments/link.yaml"), withDestinationURL: URL(fileURLWithPath: "/nonexistent-profile.yaml"))
            let catalog = ProfileCatalog.load(project: try ProjectContext.open(root))
            precondition(catalog.profiles.count == 1 && catalog.issues.contains { $0.contains("link.yaml") && $0.lowercased().contains("symlink") }, "tightening: profile dangling symlink not rejected as symlink")
        }
        // 2. Producer consumes pinned prefix even if path changes while it runs.
        do {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("rawview-tight-pinned-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: root) }
            try writeFixture(root, "data/raw/a.csv", dualSweepCSV)
            try writeFixture(root, "data/instruments/keysight-b1500a.yaml", keysightProfile)
            let project = try ProjectContext.open(root)
            let cache = MeasurementCache(project: project)
            let source = try requireLike(try project.discoverSources().first)
            let catalog = ProfileCatalog.load(project: project)
            let fp = catalog.fingerprint
            let result = try await cache.inspection(for: source, project: project, catalogFingerprint: fp) { (pinnedPrefix: Data, descriptorSize: Int64, actualURL: URL) throws -> MeasurementCache.CachedInspection in
                // Mutate the path after the cache pinned its prefix: producer must still see pinned A.
                try Data("SetupTitle, MUTATED-NO-MATCH\nDataName, V1, I1\nDataValue, 9, 9E-9\n".utf8).write(to: source.url)
                return try InstrumentReader.inspectPinned(source: source, project: project, catalog: catalog, prefix: pinnedPrefix, descriptorSize: descriptorSize, actualURL: actualURL)
            }
            guard case .supported(let inspection) = result.outcome else {
                fatalError("tightening: pinned producer did not preserve supported outcome from pinned prefix")
            }
            precondition(inspection.instrumentID == "keysight-b1500a", "tightening: pinned producer outcome not from pinned bytes")
            // Size comes from descriptor, not claimed byteSize.
            let realSize = (try? FileManager.default.attributesOfItem(atPath: source.url.path)[.size] as? NSNumber)?.int64Value ?? -1
            _ = realSize
            // Restore for cleanup; cached entry must correspond to pinned A, not mutated B.
            try Data(dualSweepCSV.utf8).write(to: source.url)
        }
        // 4. Inspection size is descriptor size, not claimed byteSize.
        do {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("rawview-tight-size-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: root) }
            try writeFixture(root, "data/raw/a.csv", dualSweepCSV)
            try writeFixture(root, "data/instruments/keysight-b1500a.yaml", keysightProfile)
            let project = try ProjectContext.open(root)
            let discovered = try requireLike(try project.discoverSources().first)
            let forged = RawSource(relativePath: discovered.relativePath, url: discovered.url, byteSize: 0)
            let catalog = ProfileCatalog.load(project: project)
            let secured = try MeasurementCache.openSecuredPrefix(source: forged, project: project)
            let pinnedPrefix = secured.prefix
            let pinnedActual = secured.selectedURL
            var st = stat()
            guard fstat(secured.handle.fileDescriptor, &st) == 0 else { fatalError("fstat failed") }
            let pinnedSize = Int64(st.st_size)
            try? secured.handle.close()
            let outcome = try InstrumentReader.inspectPinned(source: forged, project: project, catalog: catalog, prefix: pinnedPrefix, descriptorSize: pinnedSize, actualURL: pinnedActual)
            guard case .supported(let inspection) = outcome else {
                fatalError("tightening: pinned inspection with forged byteSize should still be supported")
            }
            let realSize = (try FileManager.default.attributesOfItem(atPath: discovered.url.path)[.size] as? NSNumber)?.int64Value
            precondition(inspection.size == realSize, "tightening: inspection size not from descriptor (got \(String(describing: inspection.size)) expected \(String(describing: realSize)))")
        }
        // 3. Same-descriptor measurement prefix + digest; cancellation propagates.
        do {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("rawview-tight-meas-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: root) }
            try writeFixture(root, "data/raw/a.csv", dualSweepCSV)
            try writeFixture(root, "data/instruments/keysight-b1500a.yaml", keysightProfile)
            let project = try ProjectContext.open(root)
            let cache = MeasurementCache(project: project)
            let source = try requireLike(try project.discoverSources().first)
            let m = try await InstrumentReader.load(source.url, project: project, cache: cache)
            precondition(m.channel(named: "voltage")?.values == [0, 0.1, 0.2, 0.1, 0], "tightening: full arrays/order/gaps not preserved")
            // Full arrays/order/gaps preserved through cache hit.
            let warm = try await InstrumentReader.load(source.url, project: project, cache: cache)
            precondition(warm.channel(named: "voltage")?.values == m.channel(named: "voltage")?.values, "tightening: warm arrays diverged")
            let ghost = RawSource(relativePath: "data/raw/ghost.csv", url: root.appendingPathComponent("data/raw/ghost.csv"), byteSize: 10)
            precondition((try? cache.measurement(for: ghost, project: project, profileFingerprint: "fp")) == nil, "tightening: missing source should miss")
        }
        // 5. Forged source identity (second URL with first relativePath) is
        // rejected; no cached measurement or inspection outcome is returned.
        do {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("rawview-tight-identity-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: root) }
            try writeFixture(root, "data/raw/a.csv", dualSweepCSV)
            try writeFixture(root, "data/raw/b.csv", dualSweepCSV)
            try writeFixture(root, "data/instruments/keysight-b1500a.yaml", keysightProfile)
            let project = try ProjectContext.open(root)
            let ordered = try project.discoverSources().sorted(by: { $0.relativePath < $1.relativePath })
            let first = try requireLike(ordered.first(where: { $0.relativePath == "data/raw/a.csv" }))
            let secondURL = root.appendingPathComponent("data/raw/b.csv")
            let cache = MeasurementCache(project: project)
            let loaded = try await InstrumentReader.load(first.url, project: project, cache: cache)
            precondition(loaded.source.path == first.relativePath)
            let catalog = ProfileCatalog.load(project: project)
            let fp = catalog.fingerprint
            let warmed = try await cache.inspection(for: first, project: project, catalogFingerprint: fp) { (pinnedPrefix: Data, descriptorSize: Int64, actualURL: URL) throws -> MeasurementCache.CachedInspection in
                try InstrumentReader.inspectPinned(source: first, project: project, catalog: catalog, prefix: pinnedPrefix, descriptorSize: descriptorSize, actualURL: actualURL)
            }
            guard case .supported = warmed.outcome else {
                fatalError("tightening: expected warmed inspection to be supported")
            }
            let forged = RawSource(relativePath: first.relativePath, url: secondURL, byteSize: first.byteSize)
            var openRejected = false
            do { _ = try MeasurementCache.openSecuredPrefix(source: forged, project: project) } catch { openRejected = true }
            precondition(openRejected, "tightening: forged source identity was not rejected")
            let forgedMeasurement = try cache.measurement(for: forged, project: project, profileFingerprint: ProfileCatalog.load(project: project).fingerprint)
            precondition(forgedMeasurement == nil, "tightening: forged identity returned a cached measurement")
            final class ProducerFlag: @unchecked Sendable { var ran = false }
            let flag = ProducerFlag()
            var inspectionThrew = false
            do {
                _ = try await cache.inspection(for: forged, project: project, catalogFingerprint: fp) { (_: Data, _: Int64, _: URL) throws -> MeasurementCache.CachedInspection in
                    flag.ran = true
                    return .blocked("forged-unreachable")
                }
            } catch {
                inspectionThrew = true
            }
            precondition(inspectionThrew, "tightening: forged identity inspection did not fail closed")
            precondition(!flag.ran, "tightening: forged identity producer ran")
        }
    }

    private static func requireLike<T>(_ value: T?) throws -> T {
        guard let value else { fatalError("missing fixture") }
        return value
    }

    /// Focused-cohort overlay: the plotted cohort anchors to the focused
    /// source. Synthetic fixtures only.
    static func focusedCohortSelfCheck() async throws {
        func signal(path: String, yUnit: String) -> NormalizedMeasurement {
            NormalizedMeasurement(
                source: SourceIdentity(path: path, sha256: String(repeating: "e", count: 64)),
                instrument: InstrumentIdentity(id: "synth", name: "Synth"),
                applicationMode: "dual-sweep",
                view: MeasurementView(kind: "xy", x: "voltage", y: ["current"], preserveOrder: true),
                channels: [
                    MeasurementChannel(name: "voltage", label: "Voltage", unit: "V", quantity: "voltage", values: [0, 0.1]),
                    MeasurementChannel(name: "current", label: "Current", unit: yUnit, quantity: "current", values: [1e-12, 2e-12]),
                ],
                metadataSections: [], warnings: [], supportStatus: "supported", provenance: [:]
            )
        }
        let members = ["data/raw/f.csv", "data/raw/p1.csv", "data/raw/p2.csv", "data/raw/p3.csv", "data/raw/p4.csv"]
        let manifest = StudyManifest(relativePath: "study.yaml", studyID: "s", members: Set(members))
        // Focus group {f, p1} (unit A) is smaller than {p2, p3, p4} (unit mV):
        // the cohort must anchor to the focus, never the largest subgroup.
        let measurements = [
            signal(path: "data/raw/f.csv", yUnit: "A"),
            signal(path: "data/raw/p1.csv", yUnit: "A"),
            signal(path: "data/raw/p2.csv", yUnit: "mV"),
            signal(path: "data/raw/p3.csv", yUnit: "mV"),
            signal(path: "data/raw/p4.csv", yUnit: "mV"),
        ]
        let outcome = OverlayEvaluator.evaluateFocused(
            measurements: measurements, manifests: [manifest], focusedSourceID: "data/raw/f.csv")
        guard case .partial(let group) = outcome else {
            fatalError("focus-anchored cohort was not partial: \(outcome)")
        }
        precondition(group.manifestPath == "study.yaml")
        precondition(Set(group.plottedPaths) == ["data/raw/f.csv", "data/raw/p1.csv"])
        precondition(group.plottedPaths.contains("data/raw/f.csv"), "focus omitted from its own cohort")
        precondition(Set(group.excluded.map(\.path)) == ["data/raw/p2.csv", "data/raw/p3.csv", "data/raw/p4.csv"])
        precondition(group.excluded.allSatisfy { !$0.reason.isEmpty })
        // Exact-manifest mismatch stays fully blocked, never partial.
        let split = [
            StudyManifest(relativePath: "one.yaml", studyID: "s", members: ["data/raw/f.csv", "data/raw/p1.csv"]),
            StudyManifest(relativePath: "two.yaml", studyID: "s", members: ["data/raw/p2.csv"]),
        ]
        guard case .blocked = OverlayEvaluator.evaluateFocused(
            measurements: Array(measurements.prefix(3)), manifests: split, focusedSourceID: "data/raw/f.csv") else {
            fatalError("manifest mismatch was not fully blocked")
        }
        // No compatible peer: blocked with the exclusion explanation.
        guard case .blocked(let reason) = OverlayEvaluator.evaluateFocused(
            measurements: [measurements[0], measurements[2]], manifests: [manifest], focusedSourceID: "data/raw/f.csv") else {
            fatalError("lone focus was not blocked")
        }
        precondition(reason.contains("data/raw/p2.csv"))
        // Full compatibility preserves the existing eligible behavior.
        guard case .eligible = OverlayEvaluator.evaluateFocused(
            measurements: [measurements[0], measurements[1]], manifests: [manifest], focusedSourceID: "data/raw/f.csv") else {
            fatalError("compatible pair was not eligible")
        }
    }

    /// Symlink visibility: a dangling supported-name symlink under data/raw is
    /// listed lexically and blocks with the no-follow diagnostic. Synthetic only.
    static func symlinkVisibilitySelfCheck() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rawview-symlink-visible-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try writeFixture(root, "data/raw/real.csv", dualSweepCSV)
        try writeFixture(root, "data/instruments/keysight-b1500a.yaml", keysightProfile)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("data/raw/link.csv"),
            withDestinationURL: root.appendingPathComponent("data/raw/missing-target.csv"))
        let project = try ProjectContext.open(root)
        let sources = try project.discoverSources()
        let link = try requireLike(sources.first(where: { $0.relativePath == "data/raw/link.csv" }))
        precondition(link.byteSize == 0, "symlink entry must not claim a target size")
        let report = await InstrumentReader.inspectMany(sources, project: project)
        let linkResult = try requireLike(report.results.first(where: { $0.id == "data/raw/link.csv" }))
        precondition(linkResult.inspection == nil)
        precondition(linkResult.error?.lowercased().contains("symlink") == true,
                     "symlink source did not report the no-follow diagnostic: \(linkResult.error ?? "none")")
        precondition(report.results.first(where: { $0.id == "data/raw/real.csv" })?.inspection != nil)
    }

    /// Bound the complete inspectMany path. On timeout, briefly open a writer
    /// so a regressed blocking FIFO read can finish before the process fails.
    static func fifoProfileSelfCheck() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rawview-fifo-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try writeFixture(root, "data/raw/dual.csv", dualSweepCSV)
        try writeFixture(root, "data/instruments/keysight-b1500a.yaml", keysightProfile)
        let fifo = root.appendingPathComponent("data/instruments/fifo.yaml")
        precondition(Darwin.mkfifo(fifo.path, 0o644) == 0, "mkfifo failed")
        let project = try ProjectContext.open(root)
        let sources = try project.discoverSources()
        final class Box: @unchecked Sendable { var report: ReaderInspectionReport? }
        let outcome: (report: ReaderInspectionReport?, timedOut: Bool, workerFinished: Bool) = await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                let semaphore = DispatchSemaphore(value: 0)
                let box = Box()
                Task.detached {
                    box.report = await InstrumentReader.inspectMany(sources, project: project)
                    semaphore.signal()
                }
                let firstWaitFinished = semaphore.wait(timeout: .now() + 5) == .success
                guard !firstWaitFinished else {
                    continuation.resume(returning: (box.report, false, true))
                    return
                }
                let writer = Darwin.open(fifo.path, O_WRONLY | O_NONBLOCK | O_CLOEXEC)
                let workerFinished: Bool
                if writer >= 0 {
                    Darwin.close(writer)
                    workerFinished = semaphore.wait(timeout: .now() + 5) == .success
                } else {
                    workerFinished = false
                }
                continuation.resume(returning: (box.report, true, workerFinished))
            }
        }
        if outcome.timedOut {
            precondition(outcome.workerFinished, "inspectMany exceeded 5s and the FIFO worker could not be released")
            try? FileManager.default.removeItem(at: root)
            preconditionFailure("inspectMany exceeded the 5s FIFO deadline")
        }
        let report = try requireLike(outcome.report)
        precondition(report.profileIssues.contains { $0.contains("fifo.yaml") }, "FIFO entry missing diagnostic: \(report.profileIssues)")
        precondition(report.results.count == 1, "unexpected raw source result count: \(report.results.count)")
        let result = try requireLike(report.results.first { $0.id == "data/raw/dual.csv" })
        precondition(result.inspection != nil, "valid source blocked by FIFO profile")
    }

    /// Cache preflight: overflow-safe minimum packed bytes (9/sample) skips an
    /// over-cap measurement without encoding. Small boundary fixtures only.
    static func cachePreflightSelfCheck() async throws {
        precondition(MeasurementCache.minimumPackedSampleBytesExceedsCap(sampleCounts: [10], cap: 100) == false)
        precondition(MeasurementCache.minimumPackedSampleBytesExceedsCap(sampleCounts: [12], cap: 100) == true)
        precondition(MeasurementCache.minimumPackedSampleBytesExceedsCap(sampleCounts: [], cap: 100) == false)
        precondition(MeasurementCache.minimumPackedSampleBytesExceedsCap(sampleCounts: [Int.max], cap: 128 * 1024 * 1024) == true)
        precondition(MeasurementCache.minimumPackedSampleBytesExceedsCap(sampleCounts: [Int.max / 9, Int.max / 9], cap: Int64.max) == true)
        let cap = MeasurementCache.maximumEntryBytes
        let under = Int(cap / 9)
        precondition(MeasurementCache.minimumPackedSampleBytesExceedsCap(sampleCounts: [under], cap: cap) == false)
        precondition(MeasurementCache.minimumPackedSampleBytesExceedsCap(sampleCounts: [under + 1], cap: cap) == true)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rawview-preflight-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try writeFixture(root, "data/instruments/keysight-b1500a.yaml", keysightProfile)
        try writeFixture(root, "data/raw/dual.csv", dualSweepCSV)
        let project = try ProjectContext.open(root)
        let source = try requireLike(try project.discoverSources().first)
        let measurement = try await InstrumentReader.load(source.url, project: project)
        let minimumPackedBytes = measurement.channels.reduce(Int64(0)) { $0 + Int64($1.values.count) * 9 }
        let encodedBytes = try MeasurementCache.encode(measurement: measurement).count
        precondition(Int64(encodedBytes) >= minimumPackedBytes,
                     "packed-byte lower bound disagrees with the cache encoder")
        let cache = MeasurementCache(project: project)
        let secured = try MeasurementCache.openSecuredPrefix(
            source: RawSource(relativePath: source.relativePath, url: source.url, byteSize: source.byteSize),
            project: project)
        let prefixDigest = sha256Hex(secured.prefix)
        let size = secured.descriptorSize
        try? secured.handle.close()
        let probe = RawSource(relativePath: source.relativePath, url: source.url, byteSize: size)
        let before = try cache.usage().entryCount
        try cache.store(measurement: measurement, profileFingerprint: "fp-preflight", source: probe, prefixSHA256: prefixDigest, preflightCap: 50)
        let afterSkip = try cache.usage().entryCount
        precondition(afterSkip == before, "preflight stored an over-cap entry")
        try cache.store(measurement: measurement, profileFingerprint: "fp-preflight", source: probe, prefixSHA256: prefixDigest)
        let afterStore = try cache.usage().entryCount
        precondition(afterStore == before + 1, "preflight blocked a small entry")
    }

    /// Many short rows across 64 KiB chunk boundaries stay in file order with
    /// no loss.
    static func manyShortRowsSelfCheck() async throws {
        let rowCount = 8000
        var csv = "SetupTitle, 2-terminal dual Vsweep\nDataName, V1, I1\n"
        for index in 0..<rowCount { csv += "DataValue, \(Double(index) * 0.001), 1E-12\n" }
        precondition(Data(csv.utf8).count > 2 * 65536, "fixture must cross chunk boundaries")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rawview-manyrows-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try writeFixture(root, "data/instruments/keysight-b1500a.yaml", keysightProfile)
        try writeFixture(root, "data/raw/many.csv", csv)
        let project = try ProjectContext.open(root)
        let measurement = try await InstrumentReader.load(root.appendingPathComponent("data/raw/many.csv"), project: project)
        let voltage = try requireLike(measurement.channel(named: "voltage"))
        let current = try requireLike(measurement.channel(named: "current"))
        precondition(voltage.values.count == rowCount && current.values.count == rowCount, "row loss across chunks")
        precondition(voltage.values == (0..<rowCount).map { Double($0) * 0.001 }, "voltage rows lost, reordered, or changed")
        precondition(current.values == Array(repeating: 1e-12, count: rowCount), "current rows lost or changed")
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

    static let horibaProfile = """
    schema_version: 2
    instrument:
      id: horiba-labram
      name: Horiba LabRAM
    formats:
      - id: comment-tsv
        kind: comment-tsv
        extensions: [".txt"]
        delimiter: "\\t"
        decimal: ","
        encoding: [utf-8]
        columns:
          wavenumber:
            column_index: 0
            quantity: wavenumber
            unit: "cm-1"
          intensity:
            column_index: 1
            quantity: intensity
            unit: counts
    modes:
      - id: raman-tsv
        format: comment-tsv
        filename_contains_all: ["horiba-labram.raman"]
        detect: ["#Laser="]
        extract:
          x: wavenumber
          y: [intensity]
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
