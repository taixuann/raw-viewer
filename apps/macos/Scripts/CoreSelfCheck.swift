import CryptoKit
import Darwin
import Foundation
import SQLite3

private func writeFixture(_ root: URL, _ relativePath: String, _ contents: String) throws {
    let url = root.appendingPathComponent(relativePath)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(contents.utf8).write(to: url)
}

/// Sendable visit counter for the self-check's producer/hook assertions.
private final class VisitTally: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    @discardableResult func increment() -> Int {
        lock.lock()
        defer { lock.unlock() }
        count += 1
        return count
    }
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
        try await genericTableFallbackSelfCheck()
        try projectSettingsSelfCheck()
        try await sourceTreeSelfCheck()
        try await activeProjectTestSelfCheck()
        try plotStyleAndExportSelfCheck()
        try scientificPresetsSelfCheck()
        try presetCatalogSelfCheck()
        try categoryRuleEngineSelfCheck()
        try await projectIndexStoreSelfCheck()
        try await projectIndexerSelfCheck()
        try await indexCommandSelfCheck()
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
        try small.store(measurement: cold, profileFingerprint: "fp", source: source, prefixSHA256: identityPrefix, project: project)
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
        try small.store(measurement: big, profileFingerprint: "fp2", source: source, prefixSHA256: identityPrefix, project: project)
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
        precondition((sources.first(where: { $0.relativePath == "data/raw/dual.csv" })?.mtime ?? 0) > 0)
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
        precondition(InstrumentReader.version == "1.3.0", "reader cache identity must advance with the new parser")
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

            // Multi-source profile fallback: empty data/instruments/rawview falls back to data/.rawview/instrument
            let fallbackRoot = FileManager.default.temporaryDirectory.appendingPathComponent("rawview-prof-fallback-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: fallbackRoot) }
            try writeFixture(fallbackRoot, "data/raw/a.csv", dualSweepCSV)
            // Empty data/instruments/rawview directory
            try FileManager.default.createDirectory(at: fallbackRoot.appendingPathComponent("data/instruments/rawview"), withIntermediateDirectories: true)
            // Real profile in data/.rawview/instrument/
            try writeFixture(fallbackRoot, "data/.rawview/instrument/b1500.yaml", keysightProfile)
            let fallbackCatalog = ProfileCatalog.load(project: try ProjectContext.open(fallbackRoot))
            precondition(fallbackCatalog.profiles.count == 1, "profile was not discovered from data/.rawview/instrument when data/instruments/rawview is empty")

            // .rawviewer/instrument takes top priority over data/.rawview/instrument
            try writeFixture(fallbackRoot, ".rawviewer/instrument/custom.yaml", keysightProfile)
            let topCatalog = ProfileCatalog.load(project: try ProjectContext.open(fallbackRoot))
            precondition(topCatalog.profiles.count == 1, ".rawviewer/instrument did not take priority")
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
            precondition(cacheRoot.pathComponents.contains("RawView-v\(MeasurementCache.schema)"), "audit f4: current cache reused legacy app-local ancestors")
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
            guard case .supported(let selectedInspection, _) = inspection else {
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
            guard case .supported(let inspection, _) = result.outcome else {
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
            guard case .supported(let inspection, _) = outcome else {
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
        try cache.store(measurement: measurement, profileFingerprint: "fp-preflight", source: probe, prefixSHA256: prefixDigest, preflightCap: 50, project: project)
        let afterSkip = try cache.usage().entryCount
        precondition(afterSkip == before, "preflight stored an over-cap entry")
        try cache.store(measurement: measurement, profileFingerprint: "fp-preflight", source: probe, prefixSHA256: prefixDigest, project: project)
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

    static func genericTableFallbackSelfCheck() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rawview-generic-check-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("data/raw"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let csvContent = """
        time,voltage,current
        0.1,1.0,0.01
        0.2,2.0,0.02
        0.3,3.0,0.03
        0.4,4.0,0.04
        """
        let csvURL = root.appendingPathComponent("data/raw/unprofiled.csv")
        try csvContent.write(to: csvURL, atomically: true, encoding: .utf8)

        let project = try ProjectContext.open(root)
        let source = RawSource(relativePath: "data/raw/unprofiled.csv", url: csvURL, byteSize: Int64(csvContent.utf8.count))
        let inspectionReport = await InstrumentReader.inspectMany([source], project: project, cache: nil)
        guard let insp = inspectionReport.results.first?.inspection else {
            fatalError("Expected unprofiled CSV to be supported via generic table fallback")
        }
        precondition(insp.instrumentID == "generic-table")
        precondition(insp.profileID == "generic-table")

        let measurement = try await InstrumentReader.load(source.url, project: project, cache: nil)
        precondition(measurement.instrument.id == "generic-table")
        let xChannel = measurement.channel(named: measurement.view.x ?? "")
        let yChannel = measurement.channel(named: measurement.view.y?.first ?? "")
        precondition(xChannel?.values.count == 4)
        precondition(yChannel?.values.count == 4)
    }

    /// Task 2 mirror of `Tests/RawViewCoreTests/SourceTreeTests.swift`. The
    /// Swift Testing suite cannot build in this environment (`error: no such
    /// module 'Testing'`, recorded as NOT_ASSESSED), so these preconditions
    /// carry the same evidence. Synthetic fixtures only: no real project data.
    static func sourceTreeSelfCheck() async throws {
        let fm = FileManager.default
        // configuredRootWorksAcrossLoadInspectCacheAndManifest
        do {
            let root = fm.temporaryDirectory.appendingPathComponent("rawview-t2-configured-\(UUID().uuidString)")
            defer { try? fm.removeItem(at: root) }
            try ProjectSettingsStore.save(ProjectSettings(dataRoot: "measurements", defaultView: "tree"), projectRoot: root)
            try writeFixture(root, "measurements/batch/a.csv", dualSweepCSV)
            try writeFixture(root, "data/instruments/keysight-b1500a.yaml", keysightProfile)
            try writeFixture(root, "study/study.yaml", "study_id: configured-study\nsources:\n  - path: measurements/batch/a.csv\n")
            let csvURL = root.appendingPathComponent("measurements/batch/a.csv")
            let bytesBefore = try Data(contentsOf: csvURL)
            let mtimeBefore = try fm.attributesOfItem(atPath: csvURL.path)[.modificationDate] as? Date

            let project = try ProjectContext.open(root)
            precondition(project.dataRootRelativePath == "measurements", "configured data root was not honored")
            precondition(project.rawRoot.path.hasSuffix("/measurements"), "raw root is not the configured root")
            let inventory = try await project.discoverInventoryAsync()
            precondition(inventory.issues.isEmpty && inventory.isComplete, "complete inventory reported issues")
            precondition(inventory.sources.map(\.relativePath) == ["measurements/batch/a.csv"], "configured-root discovery lost project-relative identity")
            precondition(inventory.directoryPaths == ["measurements/batch"], "directory inventory changed")
            guard let source = inventory.sources.first else { fatalError("configured root discovered no source") }
            precondition(project.sourceRelativePath(of: source.url) == "measurements/batch/a.csv")

            let measurement = try await InstrumentReader.load(source.url, project: project)
            precondition(measurement.source.path == "measurements/batch/a.csv", "load lost the project-relative source path")
            precondition(measurement.instrument.id == "keysight-b1500a", "configured root did not resolve the profile")
            let report = await InstrumentReader.inspectMany(inventory.sources, project: project)
            precondition(report.results.first?.inspection?.instrumentID == "keysight-b1500a", "inspection failed under the configured root")

            let cache = MeasurementCache(project: project)
            let catalog = ProfileCatalog.load(project: project)
            _ = try await InstrumentReader.load(source.url, project: project, cache: cache)
            let cached = try cache.measurement(for: source, project: project, profileFingerprint: catalog.fingerprint)
            precondition(cached?.source.path == "measurements/batch/a.csv", "cache round trip lost the configured root")
            let producerCalls = VisitTally()
            let producer: @Sendable (Data, Int64, URL) async throws -> MeasurementCache.CachedInspection = { _, _, _ in
                producerCalls.increment()
                return .blocked("synthetic")
            }
            let first = try await cache.inspection(for: source, project: project, catalogFingerprint: catalog.fingerprint, producer: producer)
            precondition(!first.fromCache, "fresh inspection cache entry came from cache")
            let second = try await cache.inspection(for: source, project: project, catalogFingerprint: catalog.fingerprint, producer: producer)
            precondition(second.fromCache && producerCalls.value == 1, "warm inspection cache entry re-ran the producer")

            let index = ManifestIndex.load(project: project)
            precondition(index.issues.isEmpty && index.manifests.count == 1, "configured root changed manifest discovery")
            precondition(index.manifests.first?.members == ["measurements/batch/a.csv"], "manifest membership lost project-relative identity")
            let bytesAfter = try Data(contentsOf: csvURL)
            let mtimeAfter = try fm.attributesOfItem(atPath: csvURL.path)[.modificationDate] as? Date
            precondition(bytesAfter == bytesBefore, "raw fixture bytes changed")
            precondition(mtimeAfter == mtimeBefore, "raw fixture mtime changed")
        }
        // treePreservesIntermediateAndEmptyFolders + treeIDsSeparateDirectoryAndSource
        do {
            let root = fm.temporaryDirectory.appendingPathComponent("rawview-t2-tree-\(UUID().uuidString)")
            defer { try? fm.removeItem(at: root) }
            try ProjectSettingsStore.save(ProjectSettings(dataRoot: "measurements", defaultView: "tree"), projectRoot: root)
            try writeFixture(root, "measurements/batch/nested/a.csv", "synthetic")
            try fm.createDirectory(at: root.appendingPathComponent("measurements/empty"), withIntermediateDirectories: true)

            let project = try ProjectContext.open(root)
            let inventory = try await project.discoverInventoryAsync()
            precondition(inventory.issues.isEmpty, "tree fixture reported issues")
            precondition(inventory.directoryPaths == ["measurements/batch", "measurements/batch/nested", "measurements/empty"],
                         "intermediate or empty directories are missing from the inventory")
            let tree = SourceTree(inventory: inventory, project: project)
            precondition(tree.root.id == "directory:measurements" && tree.root.name == "measurements" && tree.root.sourceID == nil,
                         "tree root node changed")
            guard let batch = tree.root.children.first(where: { $0.name == "batch" }),
                  let nested = batch.children.first(where: { $0.name == "nested" }),
                  let empty = tree.root.children.first(where: { $0.name == "empty" }) else {
                fatalError("tree lost an intermediate or empty folder")
            }
            precondition(nested.children.map(\.id) == ["source:measurements/batch/nested/a.csv"], "nested source node changed")
            precondition(empty.id == "directory:measurements/empty" && empty.children.isEmpty, "empty directory node changed")

            var directoryIDs: [String] = []
            var sourceIDs: [String] = []
            func walk(_ node: SourceTreeNode) {
                if node.sourceID != nil { sourceIDs.append(node.id) } else { directoryIDs.append(node.id) }
                node.children.forEach(walk)
            }
            walk(tree.root)
            precondition(directoryIDs.allSatisfy { $0.hasPrefix("directory:") }, "directory id lost its prefix")
            precondition(sourceIDs.allSatisfy { $0.hasPrefix("source:") }, "source id lost its prefix")
            precondition(Set(directoryIDs).isDisjoint(with: Set(sourceIDs)), "directory and source ids collide")
            precondition(sourceIDs == ["source:measurements/batch/nested/a.csv"], "source ids changed")
            precondition(directoryIDs.contains("directory:measurements/batch"), "intermediate directory id missing")
            guard let file = nested.children.first else { fatalError("file node missing") }
            precondition(file.name == "a.csv" && file.sourceID == "measurements/batch/nested/a.csv" && file.children.isEmpty,
                         "file node identity changed")
        }
        // dotRootExcludesViewerMetadataAndSnapshots
        do {
            let root = fm.temporaryDirectory.appendingPathComponent("rawview-t2-dot-\(UUID().uuidString)")
            defer { try? fm.removeItem(at: root) }
            try ProjectSettingsStore.save(ProjectSettings(dataRoot: ".", defaultView: "tree"), projectRoot: root)
            try writeFixture(root, ".rawviewer/evil.csv", "viewer metadata")
            try writeFixture(root, "data/.rawview/legacy.csv", "legacy index")
            try writeFixture(root, "data/snapshot/export.csv", "snapshot export")
            try writeFixture(root, "data/raw/ok.csv", "synthetic")
            try writeFixture(root, "run.csv", "synthetic")
            try writeFixture(root, "notes/study.csv", "synthetic")

            let project = try ProjectContext.open(root)
            precondition(project.dataRootRelativePath == ".", "dot data root was not honored")
            let inventory = try await project.discoverInventoryAsync()
            precondition(inventory.issues.isEmpty, "dot-root inventory reported issues")
            precondition(inventory.sources.map(\.relativePath) == ["data/raw/ok.csv", "notes/study.csv", "run.csv"],
                         "viewer metadata or snapshot paths entered the dot-root inventory")
            precondition(inventory.directoryPaths == ["data", "data/raw", "notes"],
                         "viewer metadata or snapshot directories entered the dot-root inventory")
            let tree = SourceTree(inventory: inventory, project: project)
            precondition(tree.root.id == "directory:." && tree.root.name == root.lastPathComponent, "dot-root tree node changed")

            let index = ManifestIndex.load(project: project)
            precondition(index.manifests.isEmpty, "dot root discovered study manifests")
            precondition(index.issues.contains { $0.contains("data root \".\"") && $0.contains("no study manifests") },
                         "dot root lacks the explicit no-manifest diagnostic")
        }
        // nestedDataRawMarkerNoLongerPrunesSelectedData
        do {
            let root = fm.temporaryDirectory.appendingPathComponent("rawview-t2-marker-\(UUID().uuidString)")
            defer { try? fm.removeItem(at: root) }
            try writeFixture(root, "data/raw/top.csv", "synthetic")
            try writeFixture(root, "data/raw/inner/data/raw/deep.csv", "synthetic")

            let project = try ProjectContext.open(root)
            precondition(project.dataRootRelativePath == "data/raw", "legacy default root changed")
            let inventory = try await project.discoverInventoryAsync()
            precondition(inventory.issues.isEmpty, "nested-marker fixture reported issues")
            precondition(inventory.sources.map(\.relativePath) == ["data/raw/inner/data/raw/deep.csv", "data/raw/top.csv"],
                         "a nested data/raw marker still prunes the selected data root")
            precondition(inventory.directoryPaths.contains("data/raw/inner") && inventory.directoryPaths.contains("data/raw/inner/data/raw"),
                         "a directory inside the selected root is missing from the tree")
            let tree = SourceTree(inventory: inventory, project: project)
            guard let inner = tree.root.children.first(where: { $0.name == "inner" }),
                  let nestedData = inner.children.first(where: { $0.name == "data" }),
                  let nestedRaw = nestedData.children.first(where: { $0.name == "raw" }) else {
                fatalError("nested marker directory is not in the tree")
            }
            precondition(nestedRaw.children.map(\.sourceID) == ["data/raw/inner/data/raw/deep.csv"], "nested source pruned")
        }
        // rootSwitchDoesNotReuseDerivedNamespace
        do {
            let root = fm.temporaryDirectory.appendingPathComponent("rawview-t2-switch-\(UUID().uuidString)")
            defer { try? fm.removeItem(at: root) }
            try writeFixture(root, "data/raw/a.csv", dualSweepCSV)
            let contained = try ProjectContext.open(root, dataRootRelativePath: "data/raw")
            let dot = try ProjectContext.open(root, dataRootRelativePath: ".")
            let url = root.resolvingSymlinksInPath().standardizedFileURL.appendingPathComponent("data/raw/a.csv")
            precondition(contained.sourceRelativePath(of: url) == "data/raw/a.csv" && dot.sourceRelativePath(of: url) == "data/raw/a.csv",
                         "equal project-relative identity changed")
            let source = RawSource(relativePath: "data/raw/a.csv", url: url, byteSize: 64)

            let cache = MeasurementCache(project: contained)
            let calls = VisitTally()
            let producer: @Sendable (Data, Int64, URL) async throws -> MeasurementCache.CachedInspection = { _, _, _ in
                calls.increment()
                return .blocked("synthetic")
            }
            let fingerprint = "fp-root-switch"
            let underContained = try await cache.inspection(for: source, project: contained, catalogFingerprint: fingerprint, producer: producer)
            precondition(!underContained.fromCache, "seeded entry came from cache")
            let underDot = try await cache.inspection(for: source, project: dot, catalogFingerprint: fingerprint, producer: producer)
            precondition(!underDot.fromCache, "a root switch reused the previous root's derived cache namespace")
            precondition(calls.value == 2, "root switch did not run the producer per root")
            let again = try await cache.inspection(for: source, project: contained, catalogFingerprint: fingerprint, producer: producer)
            precondition(again.fromCache && calls.value == 2, "same-root inspection missed the warm entry")
        }
        // partialDirectoryFailureKeepsSiblingsAndFailsCLICompleteness
        do {
            let root = fm.temporaryDirectory.appendingPathComponent("rawview-t2-partial-\(UUID().uuidString)")
            let locked = root.appendingPathComponent("data/raw/locked")
            defer {
                try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path)
                try? fm.removeItem(at: root)
            }
            try writeFixture(root, "data/raw/ok1.csv", "synthetic")
            try writeFixture(root, "data/raw/ok2.csv", "synthetic")
            try writeFixture(root, "data/raw/locked/hidden.csv", "synthetic")
            try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)

            let project = try ProjectContext.open(root)
            let inventory = try await project.discoverInventoryAsync()
            precondition(inventory.sources.map(\.relativePath) == ["data/raw/ok1.csv", "data/raw/ok2.csv"],
                         "an unreadable directory hid its accessible siblings")
            precondition(inventory.directoryPaths.contains("data/raw/locked"), "the unreadable directory itself is missing")
            precondition(!inventory.isComplete && !inventory.issues.isEmpty, "a partial inventory claimed completeness")
            precondition(inventory.issues.allSatisfy {
                if case .enumeration(let path, _) = $0 { return path == "data/raw/locked" }
                return false
            }, "partial I/O was not reported as a typed enumeration issue")
        }
        // metadataReadFailureIsReported
        do {
            let root = fm.temporaryDirectory.appendingPathComponent("rawview-t2-metadata-\(UUID().uuidString)")
            defer { try? fm.removeItem(at: root) }
            try writeFixture(root, "data/raw/run.csv", "synthetic")
            try writeFixture(root, "data/raw/ghost-a.csv", "synthetic")
            try writeFixture(root, "data/raw/ghost-b.csv", "synthetic")
            let ghostA = root.appendingPathComponent("data/raw/ghost-a.csv")
            let ghostB = root.appendingPathComponent("data/raw/ghost-b.csv")
            let ghostPaths = ["data/raw/ghost-a.csv", "data/raw/ghost-b.csv"]

            let project = try ProjectContext.open(root)
            let visits = VisitTally()
            let inventory = try await project.discoverInventoryAsync(onVisitFile: { _ in
                if visits.increment() == 1 {
                    try? FileManager.default.removeItem(at: ghostA)
                    try? FileManager.default.removeItem(at: ghostB)
                }
            })
            precondition(!inventory.isComplete, "metadata read failure claimed completeness")
            let metadataPaths = inventory.issues.compactMap { issue -> String? in
                if case .metadata(let path, _) = issue { return path }
                return nil
            }
            precondition(!metadataPaths.isEmpty, "metadata read failure was silent")
            precondition(metadataPaths.allSatisfy { ghostPaths.contains($0) }, "an unrelated entry was blamed")
            for path in metadataPaths {
                precondition(!inventory.sources.contains { $0.relativePath == path },
                             "a source with failed metadata entered the inventory")
            }
            precondition(inventory.sources.contains { $0.relativePath == "data/raw/run.csv" }, "healthy sibling dropped")
        }
        // fileMetadataFailureKeepsFollowingDirectorySources
        do {
            let root = fm.temporaryDirectory.appendingPathComponent("rawview-t2-filemeta-\(UUID().uuidString)")
            defer { try? fm.removeItem(at: root) }
            try writeFixture(root, "data/raw/trigger.csv", "synthetic")
            try writeFixture(root, "data/raw/zghost.csv", "synthetic")
            try writeFixture(root, "data/raw/kept/s1.csv", "synthetic")
            try writeFixture(root, "data/raw/kept/s2.csv", "synthetic")
            let ghost = root.appendingPathComponent("data/raw/zghost.csv")

            let project = try ProjectContext.open(root)
            let visits = VisitTally()
            let inventory = try await project.discoverInventoryAsync(onVisitFile: { _ in
                if visits.increment() == 1 {
                    try? FileManager.default.removeItem(at: ghost)
                }
            })
            precondition(inventory.issues.contains {
                if case .metadata(let path, _) = $0 { return path == "data/raw/zghost.csv" }
                return false
            }, "the file metadata failure was not recorded")
            precondition(!inventory.isComplete, "a file metadata failure claimed completeness")
            precondition(inventory.sources.map(\.relativePath) == [
                "data/raw/kept/s1.csv", "data/raw/kept/s2.csv", "data/raw/trigger.csv"
            ], "a file metadata failure pruned the following directory: \(inventory.sources.map(\.relativePath))")
            precondition(inventory.directoryPaths.contains("data/raw/kept"), "the surviving directory left the inventory")
        }
        // customDataRootDataDoesNotInventorySnapshotOrLegacyIndex
        do {
            let root = fm.temporaryDirectory.appendingPathComponent("rawview-t2-customdata-\(UUID().uuidString)")
            defer { try? fm.removeItem(at: root) }
            try ProjectSettingsStore.save(ProjectSettings(dataRoot: "data", defaultView: "tree"), projectRoot: root)
            try writeFixture(root, "data/raw/a.csv", "synthetic")
            try writeFixture(root, "data/study/b.csv", "synthetic")
            try writeFixture(root, "data/snapshot/export.csv", "snapshot export")
            try writeFixture(root, "data/.rawview/legacy.csv", "legacy index")
            try writeFixture(root, "data/instruments/keysight-b1500a.yaml", keysightProfile)

            let project = try ProjectContext.open(root)
            precondition(project.dataRootRelativePath == "data", "custom data root was not honored")
            let inventory = try await project.discoverInventoryAsync()
            precondition(inventory.issues.isEmpty, "custom-root inventory reported issues")
            precondition(inventory.sources.map(\.relativePath) == ["data/raw/a.csv", "data/study/b.csv"],
                         "snapshot or legacy index paths entered the custom-root inventory")
            precondition(inventory.directoryPaths == ["data/instruments", "data/raw", "data/study"],
                         "snapshot or legacy index directories entered the custom-root inventory")

            for forbidden in ["data/snapshot", "data/snapshot/nested", "data/.rawview", ".rawviewer", ".rawviewer/setting"] {
                var saveRejected = false
                do {
                    try ProjectSettingsStore.save(ProjectSettings(dataRoot: forbidden, defaultView: "tree"), projectRoot: root)
                } catch is ProjectSettingsError { saveRejected = true }
                precondition(saveRejected, "save accepted forbidden data root \(forbidden)")
                var openRejected = false
                do { _ = try ProjectContext.open(root, dataRootRelativePath: forbidden) } catch { openRejected = true }
                precondition(openRejected, "open accepted forbidden data root \(forbidden)")
            }
            let settingsAfter = try ProjectSettingsStore.load(projectRoot: root)
            precondition(settingsAfter?.dataRoot == "data", "forbidden root overwrote settings")

            try writeFixture(root, "data/snapshot/snap.yaml", "study_id: snapshot-study\nsources:\n  - path: data/raw/a.csv\n")
            try writeFixture(root, "study.yaml", "study_id: kept\nsources:\n  - path: data/raw/a.csv\n")
            let index = ManifestIndex.load(project: project)
            precondition(index.issues.isEmpty, "custom root reported manifest issues")
            precondition(index.manifests.map(\.relativePath) == ["study.yaml"], "a snapshot-namespace manifest was discovered")
            precondition(index.manifests.first?.members == ["data/raw/a.csv"], "manifest membership changed")
        }
        // configuredRootKeepsZeroOpenAndLinkRegressions
        do {
            let root = fm.temporaryDirectory.appendingPathComponent("rawview-t2-regress-\(UUID().uuidString)")
            defer { try? fm.removeItem(at: root) }
            try ProjectSettingsStore.save(ProjectSettings(dataRoot: "measurements", defaultView: "tree"), projectRoot: root)
            try writeFixture(root, "measurements/batch/a.csv", dualSweepCSV)
            try writeFixture(root, "measurements/skip.SPE", "prohibited")
            try writeFixture(root, "measurements/skip.affm", "prohibited")
            try writeFixture(root, "measurements/inside-target.csv", dualSweepCSV)
            try writeFixture(root, "outside.csv", "outside data")
            let rawRoot = root.appendingPathComponent("measurements")
            try fm.createSymbolicLink(at: rawRoot.appendingPathComponent("escape.csv"),
                                      withDestinationURL: root.appendingPathComponent("outside.csv"))
            let speURL = rawRoot.appendingPathComponent("skip.SPE")
            let speBytes = try Data(contentsOf: speURL)
            let speMtime = try fm.attributesOfItem(atPath: speURL.path)[.modificationDate] as? Date

            let project = try ProjectContext.open(root)
            let inventory = try await project.discoverInventoryAsync()
            precondition(inventory.sources.map(\.relativePath) == ["measurements/batch/a.csv", "measurements/escape.csv", "measurements/inside-target.csv"],
                         "excluded suffixes or link handling changed under a configured root: sources=\(inventory.sources.map(\.relativePath)) dirs=\(inventory.directoryPaths) issues=\(inventory.issues)")
            precondition(inventory.sources.first(where: { $0.relativePath == "measurements/escape.csv" })?.byteSize == 0,
                         "a symlinked source claimed a target size")

            var speRejected = false
            do { _ = try await InstrumentReader.load(speURL, project: project) } catch {
                speRejected = true
                precondition(error.localizedDescription.contains("skips .spe and .affm"), ".spe diagnostic changed")
            }
            precondition(speRejected, ".spe source was opened")
            let speBytesAfter = try Data(contentsOf: speURL)
            let speMtimeAfter = try fm.attributesOfItem(atPath: speURL.path)[.modificationDate] as? Date
            precondition(speBytesAfter == speBytes, ".spe bytes changed")
            precondition(speMtimeAfter == speMtime, ".spe mtime changed")

            let linkReport = await InstrumentReader.inspectMany(inventory.sources, project: project)
            guard let escape = linkReport.results.first(where: { $0.id == "measurements/escape.csv" }) else {
                fatalError("escape link missing from inspection")
            }
            precondition(escape.inspection == nil, "an outside link produced an inspection")
            precondition(escape.error?.contains("outside") == true, "outside link diagnostic lost \"outside\"")
            precondition(escape.error?.contains("data root (\"measurements\")") == true,
                         "outside link diagnostic does not name the configured root")

            let swapped = rawRoot.appendingPathComponent("inside-target.csv")
            try fm.removeItem(at: swapped)
            try fm.createSymbolicLink(at: swapped, withDestinationURL: rawRoot.appendingPathComponent("batch/a.csv"))
            var swapRejected = false
            do { _ = try await InstrumentReader.load(swapped, project: project) } catch {
                swapRejected = true
                precondition(error.localizedDescription.contains("symlink"), "swap diagnostic lost \"symlink\"")
                precondition(error.localizedDescription.contains("never followed"), "swap diagnostic lost \"never followed\"")
            }
            precondition(swapRejected, "swapped-in symlink was opened")
            let outsideAfter = try Data(contentsOf: root.appendingPathComponent("outside.csv"))
            precondition(outsideAfter == Data("outside data".utf8),
                         "the outside link target was read")
        }
        // sessionStateRejectsStaleWorkAfterRootChange
        do {
            var state = ProjectSessionState()
            let first = state.beginRootChange()
            precondition(state.accepts(generation: first))
            state.selectedSourceIDs.insert("measurements/batch/a.csv")
            state.expandedDirectoryIDs.insert("directory:measurements/batch")
            let second = state.beginRootChange()
            precondition(second == first + 1, "root change did not advance the generation")
            precondition(state.selectedSourceIDs.isEmpty && state.expandedDirectoryIDs.isEmpty, "root change kept root-scoped state")
            precondition(!state.accepts(generation: first), "a superseded root generation was accepted")
            precondition(state.accepts(generation: second), "the current root generation was rejected")
        }
    }

    /// Task 1 mirror of ProjectSettingsTests (the Swift Testing suite cannot
    /// run in toolchains without the Testing module): settings round trip and
    /// exact YAML, proven absence vs corruption, the fail-closed rejection
    /// matrix with the 64 KiB cap, symlink refusals, and whole-project move
    /// identity with unchanged raw bytes/mtime. Synthetic fixtures only.
    static func projectSettingsSelfCheck() throws {
        let fm = FileManager.default
        let validV1 = "schema_version: 1\ndata_root: \"data/raw\"\ndefault_view: \"tree\"\n"
        let validV2 = "schema_version: 2\ndata_root: \"data/raw\"\ndefault_view: \"tree\"\ndefault_preset: \"nature-single\"\n"
        // 1. Round trip is project-relative and byte-exact; "." also round-trips.
        do {
            let root = fm.temporaryDirectory.appendingPathComponent("rawview-settings-roundtrip-\(UUID().uuidString)")
            defer { try? fm.removeItem(at: root) }
            try writeFixture(root, "measurements/batch/a.csv", "synthetic")
            let settings = ProjectSettings(dataRoot: "measurements", defaultView: "tree", defaultPreset: "nature-single")
            try ProjectSettingsStore.save(settings, projectRoot: root)
            let url = ProjectSettingsStore.settingsURL(projectRoot: root)
            precondition(url.path.hasSuffix(".rawviewer/setting.yaml"), "settings file location changed: \(url.path)")
            let text = try String(contentsOf: url, encoding: .utf8)
            precondition(text == "schema_version: 3\ndata_root: \"measurements\"\ndefault_view: \"tree\"\ndefault_preset: \"nature-single\"\ndeveloper_mode: false\nexplorer_views: []\n",
                         "exact schema v3 YAML changed: \(text)")
            precondition(!text.contains(root.path), "settings stored the absolute project directory")
            let loaded = try ProjectSettingsStore.load(projectRoot: root)
            precondition(loaded == settings, "round trip lost settings")
            let dot = ProjectSettings(dataRoot: ".", defaultView: "tree", defaultPreset: "nature-single")
            try ProjectSettingsStore.save(dot, projectRoot: root)
            let loadedDot = try ProjectSettingsStore.load(projectRoot: root)
            precondition(loadedDot == dot, "dot data root did not round trip")

            // Schema v3: developer_mode and explorer_views round-trip; legacy
            // files default to developerMode false with no views.
            let v3 = ProjectSettings(
                dataRoot: "data/raw", developerMode: true,
                explorerViews: [ExplorerViewDefinition(grammarID: "standard-scientific", variable: "study")])
            try ProjectSettingsStore.save(v3, projectRoot: root)
            let loadedV3 = try ProjectSettingsStore.load(projectRoot: root)
            precondition(loadedV3 == v3, "schema v3 developer_mode/explorer_views did not round trip")
            precondition(loadedV3?.developerMode == true, "developer_mode true did not persist")
            let legacyV1 = try ProjectSettingsStore.parse(text: validV1)
            precondition(legacyV1.developerMode == false && legacyV1.explorerViews.isEmpty,
                         "v1 settings must default to developerMode false with no views")

            // Test legacy fallback from .rawviewer/setting/setting.yaml (schema v1)
            let legacyRoot = fm.temporaryDirectory.appendingPathComponent("rawview-settings-legacy-\(UUID().uuidString)")
            defer { try? fm.removeItem(at: legacyRoot) }
            try writeFixture(legacyRoot, ".rawviewer/setting/setting.yaml", validV1)
            let loadedLegacy = try ProjectSettingsStore.load(projectRoot: legacyRoot)
            precondition(loadedLegacy == ProjectSettings(dataRoot: "data/raw", defaultView: "tree", defaultPreset: "nature-single"),
                         "legacy fallback did not parse correctly")
        }
        // 2. Proven absence is nil; corrupt settings throw — even beside a missing data/raw.
        do {
            let fresh = fm.temporaryDirectory.appendingPathComponent("rawview-settings-absent-\(UUID().uuidString)")
            defer { try? fm.removeItem(at: fresh) }
            try writeFixture(fresh, "data/raw/a.csv", "synthetic")
            let absent = try ProjectSettingsStore.load(projectRoot: fresh)
            precondition(absent == nil, "missing settings were not nil")
            let legacyRootPath = try ProjectContext.open(fresh).dataRootRelativePath
            precondition(legacyRootPath == "data/raw", "compatibility open lost the data/raw default")
            let corrupt = fm.temporaryDirectory.appendingPathComponent("rawview-settings-corrupt-\(UUID().uuidString)")
            defer { try? fm.removeItem(at: corrupt) }
            try writeFixture(corrupt, ".rawviewer/setting.yaml", "schema_version: 99\ndata_root: \"data/raw\"\ndefault_view: \"tree\"\n")
            var loadRejected = false
            do { _ = try ProjectSettingsStore.load(projectRoot: corrupt) } catch is ProjectSettingsError { loadRejected = true }
            precondition(loadRejected, "corrupt settings loaded")
            var openRejected = false
            do { _ = try ProjectContext.open(corrupt) } catch is ProjectSettingsError { openRejected = true }
            precondition(openRejected, "open silently recovered corrupt settings")
        }
        // 3. Version/key/path rejection matrix, 64 KiB cap, and save-side validation.
        do {
            func expectReject(_ yaml: String, _ label: String) throws {
                let root = fm.temporaryDirectory.appendingPathComponent("rawview-settings-reject-\(UUID().uuidString)")
                defer { try? fm.removeItem(at: root) }
                try writeFixture(root, ".rawviewer/setting.yaml", yaml)
                var rejected = false
                do { _ = try ProjectSettingsStore.load(projectRoot: root) } catch is ProjectSettingsError { rejected = true }
                precondition(rejected, "\(label) was accepted")
            }
            let head = "data_root: \"data/raw\"\ndefault_view: \"tree\"\n"
            try expectReject("schema_version: 99\n" + head, "schema_version 99")
            try expectReject("schema_version: 2\n" + head + "extra: 1\n", "unknown key")
            try expectReject("schema_version: 2\ndata_root: \"a\"\ndata_root: \"b\"\ndefault_view: \"tree\"\n", "duplicate key")
            for badRoot in ["/abs", "../outside", "data/../../x", "data/./raw", "data/raw/", "~", "data\"raw", "data\\raw"] {
                try expectReject("schema_version: 2\ndata_root: \"\(badRoot)\"\ndefault_view: \"tree\"\n", "data_root \(badRoot)")
            }
            try expectReject("schema_version: 2\ndata_root: \"data/raw\"\ndefault_view: \"list\"\n", "unknown default_view")
            // 64 KiB UTF-8 cap: comment padding under the cap loads; over the cap fails closed.
            let root = fm.temporaryDirectory.appendingPathComponent("rawview-settings-cap-\(UUID().uuidString)")
            defer { try? fm.removeItem(at: root) }
            let pad = "# " + String(repeating: "p", count: 97) + "\n"
            let under = validV2 + String(repeating: pad, count: 600)
            precondition(Data(under.utf8).count <= ProjectSettingsStore.maximumFileBytes, "under-cap fixture must fit the cap")
            try writeFixture(root, ".rawviewer/setting.yaml", under)
            let underLoaded = try ProjectSettingsStore.load(projectRoot: root)
            precondition(underLoaded == ProjectSettings(dataRoot: "data/raw", defaultView: "tree", defaultPreset: "nature-single"),
                         "under-cap padded settings were rejected")
            let over = validV2 + String(repeating: pad, count: 700)
            precondition(Data(over.utf8).count > ProjectSettingsStore.maximumFileBytes, "over-cap fixture must exceed the cap")
            try writeFixture(root, ".rawviewer/setting.yaml", over)
            var capped = false
            do { _ = try ProjectSettingsStore.load(projectRoot: root) } catch is ProjectSettingsError { capped = true }
            precondition(capped, "oversized settings were accepted")
            // Save validates before touching the project.
            var saveRejected = false
            do { try ProjectSettingsStore.save(ProjectSettings(dataRoot: "../escape", defaultView: "tree"), projectRoot: root) } catch is ProjectSettingsError { saveRejected = true }
            precondition(saveRejected, "save accepted an escaping data_root")
            // A backslash would be re-read as a YAML escape sequence (a
            // different value than the one stored), so saving it must fail.
            var backslashSaveRejected = false
            do { try ProjectSettingsStore.save(ProjectSettings(dataRoot: "data\\raw", defaultView: "tree"), projectRoot: root) } catch is ProjectSettingsError { backslashSaveRejected = true }
            precondition(backslashSaveRejected, "save accepted a backslash data_root")
        }
        // 4. Symlinked namespace, symlinked settings file, and symlinked configured root all fail closed.
        do {
            let namespace = fm.temporaryDirectory.appendingPathComponent("rawview-settings-nslink-\(UUID().uuidString)")
            defer { try? fm.removeItem(at: namespace) }
            let outside = fm.temporaryDirectory.appendingPathComponent("rawview-settings-outside-\(UUID().uuidString)")
            defer { try? fm.removeItem(at: outside) }
            try writeFixture(outside, "setting.yaml", validV2)
            try fm.createDirectory(at: namespace, withIntermediateDirectories: true)
            try fm.createSymbolicLink(at: namespace.appendingPathComponent(".rawviewer"), withDestinationURL: outside)
            var nsLoadRejected = false
            do { _ = try ProjectSettingsStore.load(projectRoot: namespace) } catch is ProjectSettingsError { nsLoadRejected = true }
            precondition(nsLoadRejected, "symlinked settings namespace loaded")
            var nsSaveRejected = false
            do { try ProjectSettingsStore.save(ProjectSettings(dataRoot: "data/raw", defaultView: "tree"), projectRoot: namespace) } catch is ProjectSettingsError { nsSaveRejected = true }
            precondition(nsSaveRejected, "save followed a symlinked settings namespace")
            let targetText = try String(contentsOf: outside.appendingPathComponent("setting.yaml"), encoding: .utf8)
            precondition(targetText == validV2, "refused save touched the symlink target")
            let fileLink = fm.temporaryDirectory.appendingPathComponent("rawview-settings-filelink-\(UUID().uuidString)")
            defer { try? fm.removeItem(at: fileLink) }
            try writeFixture(fileLink, ".rawviewer/placeholder", "x")
            try Data(validV2.utf8).write(to: fileLink.appendingPathComponent("real.yaml"))
            try fm.createSymbolicLink(at: fileLink.appendingPathComponent(".rawviewer/setting.yaml"),
                                      withDestinationURL: fileLink.appendingPathComponent("real.yaml"))
            var fileLoadRejected = false
            do { _ = try ProjectSettingsStore.load(projectRoot: fileLink) } catch is ProjectSettingsError { fileLoadRejected = true }
            precondition(fileLoadRejected, "symlinked settings file was followed")
            var fileSaveRejected = false
            do { try ProjectSettingsStore.save(ProjectSettings(dataRoot: "data/raw", defaultView: "tree"), projectRoot: fileLink) } catch is ProjectSettingsError { fileSaveRejected = true }
            precondition(fileSaveRejected, "save replaced a symlinked settings file")
            let rootLink = fm.temporaryDirectory.appendingPathComponent("rawview-settings-rootlink-\(UUID().uuidString)")
            defer { try? fm.removeItem(at: rootLink) }
            try writeFixture(rootLink, ".rawviewer/setting.yaml", validV2)
            try writeFixture(rootLink, "real-raw/a.csv", "synthetic")
            try fm.createSymbolicLink(at: rootLink.appendingPathComponent("data"),
                                      withDestinationURL: rootLink.appendingPathComponent("real-raw"))
            var rootRejected = false
            do { _ = try ProjectContext.open(rootLink) } catch is ReaderError { rootRejected = true }
            precondition(rootRejected, "open followed a symlinked configured-root component")
        }
        // 5. Whole-project move preserves the data root and relative identities;
        // raw fixture bytes and mtime stay unchanged.
        do {
            let a = fm.temporaryDirectory.appendingPathComponent("rawview-settings-moveA-\(UUID().uuidString)")
            let b = fm.temporaryDirectory.appendingPathComponent("rawview-settings-moveB-\(UUID().uuidString)")
            defer { try? fm.removeItem(at: a); try? fm.removeItem(at: b) }
            try writeFixture(a, ".rawviewer/setting/setting.yaml", "schema_version: 1\ndata_root: \"measurements\"\ndefault_view: \"tree\"\n")
            try writeFixture(a, "measurements/batch/a.csv", "synthetic,measurement")
            let original = a.appendingPathComponent("measurements/batch/a.csv")
            let bytesBefore = try Data(contentsOf: original)
            let mtimeBefore = try fm.attributesOfItem(atPath: original.path)[.modificationDate] as? Date
            let openedA = try ProjectContext.open(a)
            precondition(openedA.dataRootRelativePath == "measurements", "configured open lost the data root")
            precondition(openedA.rawRoot.path.hasSuffix("/measurements"), "configured open lost the raw root")
            let sourcesA = try openedA.discoverSources()
            precondition(sourcesA.map(\.relativePath) == ["measurements/batch/a.csv"],
                         "custom-root discovery identity changed: \(sourcesA.map(\.relativePath))")
            precondition(openedA.sourceRelativePath(of: sourcesA[0].url) == "measurements/batch/a.csv",
                         "sourceRelativePath lost the project-relative identity")
            precondition(openedA.sourceRelativePath(of: a.appendingPathComponent("outside.csv")) == nil,
                         "sourceRelativePath claimed an outside path")
            try fm.moveItem(at: a, to: b)
            let openedB = try ProjectContext.open(b)
            precondition(openedB.dataRootRelativePath == "measurements", "moved project lost its configured data root")
            let movedSettings = try ProjectSettingsStore.load(projectRoot: b)
            precondition(movedSettings == ProjectSettings(dataRoot: "measurements", defaultView: "tree"),
                         "moved settings changed")
            let movedPaths = try openedB.discoverSources().map(\.relativePath)
            precondition(movedPaths == ["measurements/batch/a.csv"],
                         "moved discovery identity changed")
            let moved = b.appendingPathComponent("measurements/batch/a.csv")
            let movedBytes = try Data(contentsOf: moved)
            precondition(movedBytes == bytesBefore, "move changed raw bytes")
            let mtimeAfter = try fm.attributesOfItem(atPath: moved.path)[.modificationDate] as? Date
            precondition(mtimeAfter == mtimeBefore, "move changed raw mtime")
        }
    }

    static func presetCatalogSelfCheck() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("rawview-preset-check-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        try writeFixture(root, "data/raw/seed.csv", "voltage,current\n0.1,1.0\n")

        // 1. Without custom presets: PresetCatalog.load returns standard presets
        let proj = try ProjectContext.open(root)
        let standard = PresetCatalog.load(project: proj)
        precondition(standard.count == ScientificPreset.allCases.count, "default preset catalog count mismatch")
        precondition(standard.contains(where: { $0.id == "nature-single" }))

        // 2. With custom preset in .rawviewer/preset/
        let customYAML = """
        id: custom-jacs
        name: JACS Custom
        publisher: JACS
        width_mm: 82.5
        height_mm: 60.0
        open_frame: true
        serif: true
        spine_thickness_pt: 1.0
        tick_length_pt: 5.0
        title_pt: 9.0
        axis_label_pt: 8.5
        tick_label_pt: 8.0
        legend_pt: 7.5
        """
        try writeFixture(root, ".rawviewer/preset/custom-jacs.yaml", customYAML)
        let loaded = PresetCatalog.load(project: proj)
        precondition(loaded.count == ScientificPreset.allCases.count + 1, "custom preset was not merged")
        guard let custom = loaded.first(where: { $0.id == "custom-jacs" }) else {
            preconditionFailure("custom-jacs preset missing")
        }
        precondition(custom.displayName == "JACS Custom")
        precondition(custom.publisher == "JACS")
        precondition(custom.widthMM == 82.5)
        precondition(custom.heightMM == 60.0)
        precondition(custom.isOpenFrame == true)
        precondition(custom.isSerif == true)
        precondition(custom.spineThicknessPt == 1.0)
    }

    static func categoryRuleEngineSelfCheck() throws {
        // 1. Basic tokenization
        let tokens = CategoryRuleEngine.tokenize(filename: "SampleA_IV_101026.csv", delimiters: ["_"])
        precondition(tokens == ["SampleA", "IV", "101026"], "tokenize failed: \(tokens)")

        // 2. Extract with rule mapping
        let rule = CategoryRule(
            delimiters: ["_"],
            categoryIndex: 1,
            deviceIndex: 0,
            dateIndex: 2,
            categoryMap: ["IV": "I-V Sweep", "CV": "C-V Characteristic"]
        )
        let facts = CategoryRuleEngine.extract(from: "SampleA_IV_101026.csv", rules: rule)
        precondition(facts.category == "I-V Sweep", "category mapping failed")
        precondition(facts.deviceID == "SampleA", "device mapping failed")
        precondition(facts.timestamp == "101026", "date mapping failed")

        // 3. Fallback when rules is nil
        let legacyFacts = CategoryRuleEngine.extract(from: "SampleA_IV_101026.csv", rules: nil)
        precondition(legacyFacts.category == nil, "unconfigured category should be nil")
    }

    static func activeProjectTestSelfCheck() async throws {
        let testRoot = URL(fileURLWithPath: "/Users/tai/research-projects/active-projects/test", isDirectory: true)
        guard FileManager.default.fileExists(atPath: testRoot.path) else { return }
        let project = try ProjectContext.open(testRoot)
        let discovered = try await project.discoverSourcesAsync()
        precondition(discovered.count >= 2, "Expected at least 2 raw sources in active-projects/test, found \(discovered.count)")

        let inspectionReport = await InstrumentReader.inspectMany(discovered, project: project, cache: nil)
        for res in inspectionReport.results {
            guard let insp = res.inspection else {
                fatalError("Source \(res.source.relativePath) failed inspection: \(res.error ?? "unknown")")
            }
            precondition(insp.instrumentID == "generic-table", "Expected generic-table profile for \(res.source.relativePath)")
            let meas = try await InstrumentReader.load(res.source.url, project: project, cache: nil)
            precondition(!meas.channels.isEmpty, "Measurement channels should not be empty")
            precondition(meas.channels.first!.values.count > 0, "Measurement values should be loaded")
        }
    }

    static func plotStyleAndExportSelfCheck() throws {
        precondition(PlotMarkType.line.rawValue == "Line")
        precondition(PlotMarkType.dots.rawValue == "Dots")
        precondition(PlotMarkType.lineAndDots.rawValue == "Both")

        precondition(PlotInterpolation.linear.rawValue == "Linear")
        precondition(PlotInterpolation.spline.rawValue == "Spline")
        precondition(PlotInterpolation.step.rawValue == "Step")

        // Legacy compatibility mappings
        precondition(PlotRenderStyle.line.markType == .line)
        precondition(PlotRenderStyle.line.interpolation == .linear)
        precondition(PlotRenderStyle.spline.markType == .line)
        precondition(PlotRenderStyle.spline.interpolation == .spline)
        precondition(PlotRenderStyle.scatter.markType == .dots)
        precondition(PlotRenderStyle.lineAndScatter.markType == .lineAndDots)
    }

    static func scientificPresetsSelfCheck() throws {
        precondition(ScientificPreset.allCases.count == 6)
        precondition(ScientificPreset.standardPresets.count == 4)
        precondition(ScientificPreset.openFramePresets.count == 2)

        let nature = ScientificPreset.natureSingle
        precondition(nature.publisher == "Nature")
        precondition(!nature.isOpenFrame)
        precondition(abs(nature.widthMM - 59.1) < 0.01)
        precondition(abs(nature.heightMM - 50.0) < 0.01)
        precondition(abs(nature.spineThicknessPt - 0.8) < 0.01)
        precondition(abs(nature.tickLengthPt - 4.25) < 0.01)

        let ieee = ScientificPreset.ieeeSingle
        precondition(ieee.isSerif)
        precondition(abs(ieee.tickLengthPt - 4.25) < 0.01)

        for p in ScientificPreset.allCases {
            precondition(!p.id.isEmpty && !p.displayName.isEmpty)
            precondition(p.aspectRatio > 0.5 && p.aspectRatio < 2.5)
            precondition(p.spineThicknessPt > 0 && p.tickLengthPt > 0)
        }
    }

    // MARK: Task 3 — ProjectIndexStore

    /// Synthetic project under the temporary directory: `data/raw/<files>`.
    private static func pidxProject(
        files: [String: String] = ["data/raw/seed.csv": "synthetic"]
    ) throws -> (project: ProjectContext, root: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pidx-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for (relativePath, body) in files {
            let url = root.appendingPathComponent(relativePath)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(body.utf8).write(to: url)
        }
        let project = try ProjectContext.open(root, dataRootRelativePath: "data/raw")
        return (project, root)
    }

    private static func pidxDigests(_ urls: [URL]) -> [String: String] {
        var result: [String: String] = [:]
        for url in urls where FileManager.default.fileExists(atPath: url.path) {
            result[url.path] = sha256Hex((try? Data(contentsOf: url)) ?? Data())
        }
        return result
    }

    private static func pidxTreeSnapshot(root: URL) -> [String: String] {
        var snapshot: [String: String] = [:]
        let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        while let entry = enumerator?.nextObject() as? URL {
            let relative = entry.path.hasPrefix(root.path + "/")
                ? String(entry.path.dropFirst(root.path.count + 1))
                : entry.lastPathComponent
            let values = try? entry.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            if values?.isSymbolicLink == true {
                snapshot[relative] = "symlink"
            } else if values?.isDirectory == true {
                snapshot[relative] = "dir"
            } else if let data = try? Data(contentsOf: entry) {
                snapshot[relative] = sha256Hex(data)
            }
        }
        return snapshot
    }

    /// Real legacy WAL database whose committed rows stay in `-wal` with
    /// `-shm` present; the caller closes the returned connection.
    private static func pidxLegacyWAL(at url: URL, rows: Int) throws -> OpaquePointer {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let db else {
            throw NSError(domain: "CoreSelfCheck", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "cannot open legacy fixture"])
        }
        func exec(_ sql: String) throws {
            var message: UnsafeMutablePointer<CChar>?
            let rc = sqlite3_exec(db, sql, nil, nil, &message)
            guard rc == SQLITE_OK else {
                let text = message.map { String(cString: $0) } ?? "sqlite error \(rc)"
                sqlite3_free(message)
                throw NSError(domain: "CoreSelfCheck", code: Int(rc),
                              userInfo: [NSLocalizedDescriptionKey: text])
            }
        }
        try exec("PRAGMA journal_mode = WAL;")
        try exec("""
        CREATE TABLE sources (
            relative_path TEXT PRIMARY KEY,
            mtime INTEGER NOT NULL,
            byte_size INTEGER NOT NULL,
            instrument_id TEXT,
            instrument_name TEXT,
            application_mode TEXT,
            device_id TEXT,
            timestamp TEXT,
            category TEXT,
            support_status TEXT NOT NULL,
            validation_state TEXT NOT NULL,
            reader_version TEXT NOT NULL,
            profile_id TEXT,
            profile_hash TEXT NOT NULL,
            error TEXT
        );
        """)
        for index in 0..<rows {
            try exec("INSERT OR REPLACE INTO sources (relative_path, mtime, byte_size, support_status, validation_state, reader_version, profile_hash) "
                + "VALUES ('data/raw/f\(index).csv', \(index), 10, 'supported', 'valid', '1.3.0', 'abc');")
        }
        return db
    }

    private static func pidxRemoveIndexed(_ url: URL) {
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: url.path + suffix)
        }
    }

    /// Cross-process lease probe: a flock belongs to the open file
    /// description, not to a process. The holder descriptor (opened without
    /// O_CLOEXEC) is inherited by a spawned child across posix_spawn, and
    /// this process then drops its own reference, leaving the child as the
    /// sole holder. The parent must observe busy while that holder lives and
    /// free once the holder is SIGKILLed — crash release through OS locking,
    /// with no stale marker consulted.
    private static func pidxProbeLeaseAcrossCrash(leasePath: String) -> (busyWhileHeld: Bool, acquiredAfterCrash: Bool) {
        let fd = Darwin.open(leasePath, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { return (false, false) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            Darwin.close(fd)
            return (false, false)
        }
        var holder: pid_t = 0
        var arguments: [UnsafeMutablePointer<CChar>?] = [strdup("/bin/sleep"), strdup("60"), nil]
        let spawnResult = arguments.withUnsafeMutableBufferPointer { buffer in
            posix_spawn(&holder, "/bin/sleep", nil, nil, buffer.baseAddress, nil)
        }
        for case let argument? in arguments { free(argument) }
        // Drop our reference: after a successful spawn the sleeping child
        // holds the lock alone.
        Darwin.close(fd)
        guard spawnResult == 0, holder > 0 else { return (false, false) }

        var busyWhileHeld = false
        let probe = Darwin.open(leasePath, O_CREAT | O_RDWR, 0o600)
        if probe >= 0 {
            busyWhileHeld = flock(probe, LOCK_EX | LOCK_NB) != 0
            Darwin.close(probe)
        }

        kill(holder, SIGKILL)
        var status: Int32 = 0
        _ = waitpid(holder, &status, 0)

        var acquiredAfterCrash = false
        let after = Darwin.open(leasePath, O_CREAT | O_RDWR, 0o600)
        if after >= 0 {
            acquiredAfterCrash = flock(after, LOCK_EX | LOCK_NB) == 0
            if acquiredAfterCrash { _ = flock(after, LOCK_UN) }
            Darwin.close(after)
        }
        return (busyWhileHeld, acquiredAfterCrash)
    }

    /// Mirror of Tests/RawViewCoreTests/ProjectIndexStoreTests.swift: Task 3
    /// safe SQLite namespace, relocation, advisory trust, and writer lease.
    /// Synthetic fixtures only; the failed VFS proof gate means product code
    /// performs no project-local SQLite write here.
    static func projectIndexStoreSelfCheck() async throws {
        // open resolves and creates nothing.
        let basic = try pidxProject()
        defer { try? FileManager.default.removeItem(at: basic.root) }
        let beforeBasic = pidxTreeSnapshot(root: basic.root)
        let store = try await ProjectIndexStore.open(project: basic.project)
        let usage = try await store.usage()
        precondition(pidxTreeSnapshot(root: basic.root) == beforeBasic,
                     "store open/usage must not create, write, or delete anything in the project")
        precondition(usage.storageMode == .destination, "writable project with nothing yet resolves to the preferred destination")
        precondition(!usage.destinationExists && !usage.legacyExists && !usage.stagingExists, "clean project reports empty storage")
        precondition(usage.projectWritable, "clean temp project must be writable")
        precondition(usage.destinationURL.path == ProjectIndexStore.preferredDestinationURL(project: basic.project).path,
                     "preferred destination is .rawviewer/index.db, resolved by the store")
        precondition(usage.legacyURL.path == ProjectIndexStore.legacyIndexURL(project: basic.project).path, "legacy URL stays the existing runtime location")

        // legacyWALBackupIncludesCommittedRows: migration withheld by the gate;
        // backup mechanics still include WAL-committed rows at a non-project staging copy.
        let wal = try pidxProject()
        defer { try? FileManager.default.removeItem(at: wal.root) }
        let legacyURL = ProjectIndexStore.legacyIndexURL(project: wal.project)
        let fixture = try pidxLegacyWAL(at: legacyURL, rows: 25)
        defer { sqlite3_close_v2(fixture) }
        let walURL = URL(fileURLWithPath: legacyURL.path + "-wal")
        let shmURL = URL(fileURLWithPath: legacyURL.path + "-shm")
        precondition(FileManager.default.fileExists(atPath: walURL.path),
                     "fixture must keep committed rows in the WAL")
        let legacyBefore = pidxDigests([legacyURL, walURL])
        let shmSizeBefore = (try? Data(contentsOf: shmURL))?.count
        precondition(legacyBefore.count == 2 && shmSizeBefore != nil,
                     "legacy db, WAL, and SHM must all exist")
        let walStore = try await ProjectIndexStore.open(project: wal.project)
        let walReport = try await walStore.migrateLegacy()
        precondition(walReport.outcome == .withheldPendingStorageDecision,
                     "VFS proof gate failed: publication to the project-local destination is withheld")
        precondition(walReport.copiedRows == 0, "a withheld migration copies nothing")
        precondition(walReport.warnings.contains { $0.contains("withheld") }, "the report must carry the gate warning")
        precondition(!FileManager.default.fileExists(
            atPath: ProjectIndexStore.preferredDestinationURL(project: wal.project).path),
            "the gate forbids creating the project-local destination")
        precondition(pidxDigests([legacyURL, walURL]) == legacyBefore,
                     "migration must never touch legacy db/WAL bytes")
        precondition((try? Data(contentsOf: shmURL))?.count == shmSizeBefore,
                     "migration must preserve the SHM file in place")
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("staging-" + UUID().uuidString + ".db")
        defer { pidxRemoveIndexed(staging) }
        let source = try IndexDatabase.openReadOnly(at: legacyURL)
        try source.backup(to: staging)
        let copied = try IndexDatabase.open(at: staging)
        precondition(copied.lookupAll().count == 25, "backup must include rows committed only to the WAL")
        let integrityOK = try copied.integrityCheck()
        precondition(integrityOK, "staging backup must pass integrity_check")
        try copied.checkpoint()
        try copied.close()
        let reopened = try IndexDatabase.open(at: staging)
        precondition(reopened.lookupAll().count == 25, "rows survive checkpoint and close")
        try reopened.close()
        try source.close()
        // db and -wal (the data and the committed log) stay byte-identical.
        // The -shm wal-index is derived state: SQLite's own reader may
        // refresh it in place while opening the WAL database, so it is
        // asserted by presence and size — it is never deleted or replaced,
        // and no committed data lives there.
        precondition(pidxDigests([legacyURL, walURL]) == legacyBefore,
                     "read-only backup must not modify legacy db/WAL bytes")
        precondition(FileManager.default.fileExists(atPath: shmURL.path)
                        && (try? Data(contentsOf: shmURL))?.count == shmSizeBefore,
                     "SHM must be preserved in place")

        // destinationConflictPreservesBoth: existing destination wins; both
        // databases survive byte-for-byte; no staging appears.
        let conflict = try pidxProject()
        defer { try? FileManager.default.removeItem(at: conflict.root) }
        let destination = ProjectIndexStore.preferredDestinationURL(project: conflict.project)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let destinationBytes = Data("SQLite format 3\0".utf8) + Data(repeating: 0x5A, count: 4096)
        try destinationBytes.write(to: destination)
        let conflictLegacy = ProjectIndexStore.legacyIndexURL(project: conflict.project)
        let conflictFixture = try pidxLegacyWAL(at: conflictLegacy, rows: 7)
        defer { sqlite3_close_v2(conflictFixture) }
        let conflictWAL = URL(fileURLWithPath: conflictLegacy.path + "-wal")
        let conflictSHM = URL(fileURLWithPath: conflictLegacy.path + "-shm")
        let conflictBefore = pidxDigests([destination, conflictLegacy, conflictWAL, conflictSHM])
        precondition(conflictBefore.count == 4, "destination and legacy db/WAL/SHM must all exist")
        let conflictStore = try await ProjectIndexStore.open(project: conflict.project)
        let conflictReport = try await conflictStore.migrateLegacy()
        precondition(conflictReport.outcome == .destinationExists, "an existing destination wins")
        precondition(conflictReport.copiedRows == 0, "a preserved destination receives no copy")
        precondition(pidxDigests([destination, conflictLegacy, conflictWAL, conflictSHM]) == conflictBefore,
                     "existing destination and legacy index must both survive byte-for-byte")
        let conflictEntries = try FileManager.default.contentsOfDirectory(
            atPath: destination.deletingLastPathComponent().path)
            .filter { !$0.hasSuffix(".lock") }
        precondition(conflictEntries == ["index.db"], "no staging or replacement file may appear: \(conflictEntries)")

        // migrationFailureLeavesLegacyIntact: unusable legacy is reported and
        // retained; nothing is created or deleted.
        let failed = try pidxProject()
        defer { try? FileManager.default.removeItem(at: failed.root) }
        let failedLegacy = ProjectIndexStore.legacyIndexURL(project: failed.project)
        try FileManager.default.createDirectory(at: failedLegacy.deletingLastPathComponent(), withIntermediateDirectories: true)
        let garbage = Data((0..<512).map { UInt8($0 % 251) })
        try garbage.write(to: failedLegacy)
        let failedBefore = pidxDigests([failedLegacy])
        precondition(failedBefore.count == 1, "garbage legacy fixture must exist")
        let failedStore = try await ProjectIndexStore.open(project: failed.project)
        let failedReport = try await failedStore.migrateLegacy()
        precondition(failedReport.outcome == .legacyUnavailable, "an unusable legacy index is reported")
        precondition(failedReport.warnings.contains { $0.contains("retained") }, "the warning must say the legacy index is retained")
        precondition(pidxDigests([failedLegacy]) == failedBefore, "an unusable legacy index is retained untouched")
        precondition(!FileManager.default.fileExists(
            atPath: ProjectIndexStore.preferredDestinationURL(project: failed.project).path),
            "a failed migration creates no destination")
        let failedEntries = try FileManager.default.contentsOfDirectory(atPath: failed.root.path)
        precondition(!failedEntries.contains(".rawviewer"), "no destination namespace may be created by a failed migration")

        // busyWriterIsReportedAndCrashReleasesLease: OS-managed lock per
        // bounded writer job; reads never contend; SIGKILL releases it.
        let lease = try pidxProject()
        defer { try? FileManager.default.removeItem(at: lease.root) }
        let leaseStore = try await ProjectIndexStore.open(project: lease.project)
        try await leaseStore.withWriterJob {
            let innerUsage = try await leaseStore.usage()
            precondition(!innerUsage.destinationExists, "reads inside a writer job still work")
            do {
                try await leaseStore.withWriterJob { }
                preconditionFailure("a second concurrent writer job must report busy")
            } catch ProjectIndexStore.StoreError.busy {
                // expected: the first job still holds the OS lock
            } catch {
                preconditionFailure("unexpected error instead of busy: \(error)")
            }
        }
        let probe = pidxProbeLeaseAcrossCrash(
            leasePath: ProjectIndexStore.writerLeaseURL(project: lease.project).path)
        precondition(probe.busyWhileHeld, "a second writer process must observe the lease as busy")
        precondition(probe.acquiredAfterCrash, "a crashed holder's lease must be released by the OS")
        try await leaseStore.withWriterJob { }

        // indexNamespaceChangesWithRootCatalogReader: every namespace axis
        // invalidates stored rows; matching content stays advisory only.
        let namespace = try pidxProject()
        defer { try? FileManager.default.removeItem(at: namespace.root) }
        let namespaceStore = try await ProjectIndexStore.open(project: namespace.project, catalogFingerprint: "fp-current")
        let active = namespaceStore.activeNamespace
        precondition(active.schemaVersion == IndexDatabase.namespaceSchemaVersion, "namespace carries the index schema version")
        precondition(active.readerVersion == InstrumentReader.version, "namespace carries the reader version")
        precondition(active.dataRoot == "data/raw", "namespace carries the normalized data root")
        precondition(active.projectIdentity == sha256Hex(Data(namespace.project.root.path.utf8)),
                     "namespace carries the canonical project identity")
        precondition(active.catalogFingerprint == "fp-current", "namespace carries the catalog fingerprint")
        let seed = namespace.project.root.appendingPathComponent("data/raw/seed.csv")
        let seedSource = RawSource(relativePath: "data/raw/seed.csv", url: seed, byteSize: 8)
        let securedSeed = try MeasurementCache.openSecuredPrefix(source: seedSource, project: namespace.project)
        defer { try? securedSeed.handle.close() }
        let seedDigest = sha256Hex(securedSeed.prefix)
        let seedRecord = IndexDatabase.Record(
            relativePath: "data/raw/seed.csv", mtime: 1, byteSize: securedSeed.descriptorSize,
            prefixSHA256: seedDigest, descriptorSize: securedSeed.descriptorSize)
        precondition(namespaceStore.disposition(
            record: seedRecord, storedNamespace: active,
            observedPrefixSHA256: seedDigest, observedDescriptorSize: securedSeed.descriptorSize
        ) == .advisoryHint, "matching namespace and content stay advisory")
        func axisNamespace(
            projectIdentity: String = active.projectIdentity,
            dataRoot: String = active.dataRoot,
            readerVersion: String = active.readerVersion,
            catalogFingerprint: String = active.catalogFingerprint,
            schemaVersion: Int = active.schemaVersion
        ) -> IndexNamespace {
            IndexNamespace(schemaVersion: schemaVersion, projectIdentity: projectIdentity,
                           dataRoot: dataRoot, readerVersion: readerVersion,
                           catalogFingerprint: catalogFingerprint)
        }
        let axisChanges: [IndexNamespace] = [
            axisNamespace(dataRoot: "measurements"),
            axisNamespace(readerVersion: "0.9.0"),
            axisNamespace(catalogFingerprint: "fp-older"),
            axisNamespace(projectIdentity: String(repeating: "0", count: 64)),
            axisNamespace(schemaVersion: active.schemaVersion + 1),
        ]
        for stored in axisChanges {
            precondition(ProjectIndexStore.disposition(
                record: seedRecord, storedNamespace: stored, activeNamespace: active,
                observedPrefixSHA256: seedDigest, observedDescriptorSize: securedSeed.descriptorSize
            ) == .staleNamespace, "namespace change must invalidate: \(stored)")
        }
        precondition(namespaceStore.disposition(
            record: seedRecord, storedNamespace: active,
            observedPrefixSHA256: String(repeating: "a", count: 64),
            observedDescriptorSize: securedSeed.descriptorSize
        ) == .staleContent, "content mismatch must invalidate even with a matching namespace")

        // unsafeMetadataNamespaceFailsClosed: symlinked metadata namespace and
        // symlinked destination leaf are refusals, never paths to follow.
        let unsafeProject = try pidxProject()
        defer { try? FileManager.default.removeItem(at: unsafeProject.root) }
        let metadata = unsafeProject.root.appendingPathComponent(".rawviewer")
        let target = unsafeProject.root.deletingLastPathComponent()
            .appendingPathComponent("elsewhere-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: target) }
        try FileManager.default.createSymbolicLink(at: metadata, withDestinationURL: target)
        do {
            _ = try await ProjectIndexStore.open(project: unsafeProject.project)
            preconditionFailure("a symlinked .rawviewer namespace must be refused")
        } catch ProjectIndexStore.StoreError.unsafeNamespace(let path) {
            precondition(path.contains(".rawviewer"), "the refusal names the offending namespace")
        }
        precondition(!FileManager.default.fileExists(atPath: target.appendingPathComponent("index.db").path),
                     "the symlink target must never receive an index")
        try FileManager.default.removeItem(at: metadata)
        try FileManager.default.createDirectory(at: metadata, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            atPath: metadata.appendingPathComponent("index.db").path,
            withDestinationPath: "/tmp/rawview-evil.db")
        do {
            _ = try await ProjectIndexStore.open(project: unsafeProject.project)
            preconditionFailure("a symlinked index.db destination must be refused")
        } catch ProjectIndexStore.StoreError.unsafeNamespace(let path) {
            precondition(path.hasSuffix("index.db"), "the refusal names the destination leaf")
        }

        // readOnlyProjectUsesPrivateFallback: a read-only project resolves to
        // the owner-private app-local index and gains no project namespace.
        let readOnly = try pidxProject()
        defer {
            chmod(readOnly.root.path, 0o755)
            try? FileManager.default.removeItem(at: readOnly.root)
        }
        guard chmod(readOnly.root.path, 0o555) == 0 else {
            preconditionFailure("chmod 0555 failed on the synthetic project root")
        }
        let readOnlyStore = try await ProjectIndexStore.open(project: readOnly.project)
        let readOnlyUsage = try await readOnlyStore.usage()
        precondition(!readOnlyUsage.projectWritable, "the project root is no longer writable")
        precondition(readOnlyUsage.storageMode == .privateFallback, "read-only project selects the private fallback")
        precondition(!readOnlyUsage.destinationExists, "no private index exists yet")
        let appLocal = MeasurementCache.appLocalRoot(project: readOnly.project)
        precondition(readOnlyUsage.destinationURL.path.hasPrefix(appLocal.path),
                     "read-only project must resolve to the private app-local index: \(readOnlyUsage.destinationURL.path)")
        precondition(!FileManager.default.fileExists(atPath: readOnly.root.appendingPathComponent(".rawviewer").path),
                     "a read-only project must never gain a project-local index namespace")

        // forgedIndexCannotPromoteTrustedInspection: forged scientific fields
        // with correct digest/catalog metadata stay advisory; imported legacy
        // rows without validity fields are never restorable.
        let forged = try pidxProject()
        defer { try? FileManager.default.removeItem(at: forged.root) }
        let forgedFile = forged.project.root.appendingPathComponent("data/raw/seed.csv")
        let forgedSource = RawSource(relativePath: "data/raw/seed.csv", url: forgedFile, byteSize: 8)
        let securedForged = try MeasurementCache.openSecuredPrefix(source: forgedSource, project: forged.project)
        defer { try? securedForged.handle.close() }
        let forgedDigest = sha256Hex(securedForged.prefix)
        let forgedNamespace = ProjectIndexStore.makeNamespace(project: forged.project, catalogFingerprint: "fp-forged")
        let forgedDBURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("forged-" + UUID().uuidString + ".db")
        defer { pidxRemoveIndexed(forgedDBURL) }
        let forgedDB = try IndexDatabase.open(at: forgedDBURL)
        try forgedDB.writeMetadata(forgedNamespace)
        let readBack = try forgedDB.readMetadata()
        precondition(readBack == forgedNamespace, "index_metadata round-trips the namespace")
        precondition(readBack == forgedNamespace, "metadata row reads back stable")
        let forgedRecord = IndexDatabase.Record(
            relativePath: "data/raw/seed.csv", mtime: 1, byteSize: securedForged.descriptorSize,
            instrumentID: "keysight-b1500a", applicationMode: "forged-mode",
            supportStatus: "supported", validationState: "profile valid; source not loaded",
            readerVersion: InstrumentReader.version, profileID: "forged-profile",
            profileHash: "forged-profile-hash",
            prefixSHA256: forgedDigest, descriptorSize: securedForged.descriptorSize,
            recordState: .advisoryHint)
        try forgedDB.upsertBatch([forgedRecord])
        guard let storedForged = forgedDB.lookupAll()["data/raw/seed.csv"] else {
            preconditionFailure("forged row must round-trip through the index database")
        }
        precondition(storedForged.prefixSHA256 == forgedDigest, "the forge keeps correct digest metadata")
        precondition(storedForged.descriptorSize == securedForged.descriptorSize, "descriptor size round-trips")
        precondition(storedForged.recordState == .advisoryHint, "every project row is explicitly advisory")
        guard let metadataNamespace = try forgedDB.readMetadata() else {
            preconditionFailure("index_metadata row must exist")
        }
        let forgedDisposition = ProjectIndexStore.disposition(
            record: storedForged, storedNamespace: metadataNamespace, activeNamespace: forgedNamespace,
            observedPrefixSHA256: forgedDigest, observedDescriptorSize: securedForged.descriptorSize)
        precondition(forgedDisposition == .advisoryHint, "correct digest metadata still resolves to a hint")
        precondition(!forgedDisposition.grantsInspectionAuthority,
                     "correct digest metadata must never promote a forged row to trusted inspection authority")
        let legacyRow = IndexDatabase.Record(
            relativePath: "data/raw/legacy.csv", mtime: 2, byteSize: 4,
            applicationMode: "legacy-mode", supportStatus: "supported")
        precondition(ProjectIndexStore.disposition(
            record: legacyRow, storedNamespace: forgedNamespace, activeNamespace: forgedNamespace,
            observedPrefixSHA256: forgedDigest, observedDescriptorSize: 4
        ) == .staleContent, "legacy rows without a matching prefix digest are not restorable")

        // sameSizeSameTimeHeaderEditInvalidatesIndex: size and recorded mtime
        // stay identical after a header edit; only the prefix digest notices.
        let edited = try pidxProject(files: ["data/raw/edited.csv": String(repeating: "A", count: 2048)])
        defer { try? FileManager.default.removeItem(at: edited.root) }
        let editedFile = edited.project.root.appendingPathComponent("data/raw/edited.csv")
        let attributesBefore = try FileManager.default.attributesOfItem(atPath: editedFile.path)
        let mtimeBefore = (attributesBefore[.modificationDate] as? Date) ?? Date(timeIntervalSince1970: 0)
        let sizeBefore = (attributesBefore[.size] as? NSNumber)?.int64Value ?? 0
        let editedSource = RawSource(relativePath: "data/raw/edited.csv", url: editedFile, byteSize: sizeBefore)
        let securedEditedBefore = try MeasurementCache.openSecuredPrefix(source: editedSource, project: edited.project)
        let digestBefore = sha256Hex(securedEditedBefore.prefix)
        try securedEditedBefore.handle.close()
        let editedNamespace = ProjectIndexStore.makeNamespace(project: edited.project, catalogFingerprint: "fp-edit")
        let editedRecord = IndexDatabase.Record(
            relativePath: "data/raw/edited.csv", mtime: Int64(mtimeBefore.timeIntervalSince1970),
            byteSize: sizeBefore, instrumentID: "keysight-b1500a",
            applicationMode: "list-sweep", supportStatus: "supported",
            readerVersion: InstrumentReader.version,
            prefixSHA256: digestBefore, descriptorSize: sizeBefore, recordState: .advisoryHint)
        precondition(ProjectIndexStore.disposition(
            record: editedRecord, storedNamespace: editedNamespace, activeNamespace: editedNamespace,
            observedPrefixSHA256: digestBefore, observedDescriptorSize: sizeBefore
        ) == .advisoryHint, "fresh content matches its recorded digest")
        var editedBytes = try Data(contentsOf: editedFile)
        precondition(editedBytes.count == Int(sizeBefore), "fixture size precondition")
        editedBytes.replaceSubrange(0..<4, with: Data("EVIL".utf8))
        try editedBytes.write(to: editedFile)
        try FileManager.default.setAttributes([.modificationDate: mtimeBefore], ofItemAtPath: editedFile.path)
        let attributesAfter = try FileManager.default.attributesOfItem(atPath: editedFile.path)
        let mtimeAfter = (attributesAfter[.modificationDate] as? Date) ?? Date(timeIntervalSince1970: 0)
        let sizeAfter = (attributesAfter[.size] as? NSNumber)?.int64Value ?? 0
        precondition(sizeAfter == sizeBefore, "the edit must keep the same size")
        precondition(Int64(mtimeAfter.timeIntervalSince1970) == Int64(mtimeBefore.timeIntervalSince1970),
                     "the edit must keep the same recorded mtime — size/mtime lookup still matches")
        let securedEditedAfter = try MeasurementCache.openSecuredPrefix(source: editedSource, project: edited.project)
        let digestAfter = sha256Hex(securedEditedAfter.prefix)
        try securedEditedAfter.handle.close()
        precondition(digestAfter != digestBefore, "the secured prefix digest must notice the edit")
        precondition(ProjectIndexStore.disposition(
            record: editedRecord, storedNamespace: editedNamespace, activeNamespace: editedNamespace,
            observedPrefixSHA256: digestAfter, observedDescriptorSize: sizeAfter
        ) == .staleContent, "a same-size/same-time header edit must invalidate the index row")
    }

    // MARK: - Task 4: shared indexing coordinator, validated restoration, cutover

    private static let indexerGenericCSV = "time,voltage\n0.1,1\n0.2,2\n0.3,3\n"
    private static let indexerUnresolvableCSV = "notes\nplain prose without numbers\nmore prose without digits\n"

    private static func indexerProject(
        files: [String: String],
        withProfile: Bool = false
    ) throws -> (project: ProjectContext, root: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pidxc-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        if withProfile {
            try writeFixture(root, "data/instruments/keysight-b1500a.yaml", keysightProfile)
        }
        for (relativePath, body) in files {
            try writeFixture(root, relativePath, body)
        }
        return (try ProjectContext.open(root, dataRootRelativePath: "data/raw"), root)
    }

    private static func indexerRows(_ project: ProjectContext) -> [String: IndexDatabase.Record] {
        guard let db = try? IndexDatabase.open(at: project.indexDatabaseURL) else { return [:] }
        defer { try? db.close() }
        return db.lookupAll()
    }

    private static func indexerCohort() -> [String: String] {
        [
            "data/raw/matched-a.csv": dualSweepCSV,
            "data/raw/matched-b.csv": dualSweepCSV,
            "data/raw/generic-a.csv": indexerGenericCSV,
            "data/raw/generic-b.csv": indexerGenericCSV,
            "data/raw/notes.csv": indexerUnresolvableCSV
        ]
    }

    /// Removes the synthetic project together with its owner-private
    /// app-local state (cache, index, lease) for this project digest.
    private static func removeIndexerProject(_ root: URL, _ project: ProjectContext) {
        try? FileManager.default.removeItem(
            at: MeasurementCache.appLocalRoot(project: project).deletingLastPathComponent())
        try? FileManager.default.removeItem(at: root)
    }

    /// Task 4 mirror of Tests/RawViewCoreTests/ProjectIndexerTests.swift:
    /// bounded prefix-only generic inspection, typed dispositions, the shared
    /// coordinator/store validity seam, and the app-local cutover.
    static func projectIndexerSelfCheck() async throws {
        // prefixOnlyInspectionNeverReopensSource: generic inspection consumes
        // only the pinned 64 KiB prefix; the pathname is gone afterwards.
        let prefixCase = try indexerProject(files: ["data/raw/table.csv": indexerGenericCSV])
        defer { removeIndexerProject(prefixCase.root, prefixCase.project) }
        let prefixURL = prefixCase.root.appendingPathComponent("data/raw/table.csv")
        let prefixSource = RawSource(relativePath: "data/raw/table.csv", url: prefixURL,
                                      byteSize: Int64(indexerGenericCSV.utf8.count))
        let securedPrefix = try MeasurementCache.openSecuredPrefix(source: prefixSource, project: prefixCase.project)
        let pinnedPrefix = securedPrefix.prefix
        try securedPrefix.handle.close()
        try FileManager.default.removeItem(at: prefixURL)
        let preview = try GenericTableReader.inspect(prefix: pinnedPrefix)
        precondition(preview.delimiter == ",", "prefix preview must detect the delimiter from pinned bytes")
        precondition(preview.headerLineIndex == 0, "prefix preview must detect the header line")
        precondition(preview.sampleRows.first == [0.1, 1.0], "prefix preview must sample pinned rows")
        precondition(preview.sampleRows.count <= 5, "the preview samples rows; it never counts the file")
        let prefixCatalog = ProfileCatalog.load(project: prefixCase.project)
        guard case .supported(let prefixInspection, let prefixDisposition) = try InstrumentReader.inspectPinned(
            source: prefixSource, project: prefixCase.project, catalog: prefixCatalog,
            prefix: pinnedPrefix, descriptorSize: Int64(indexerGenericCSV.utf8.count), actualURL: prefixURL) else {
            preconditionFailure("pinned bytes must still produce a structural candidate")
        }
        precondition(prefixDisposition == .structuralCandidate, "unprofiled generic inspection is a structural candidate")
        precondition(prefixInspection.instrumentID == "generic-table", "structural candidate keeps its reader identity")
        precondition(prefixInspection.validationState?.contains("structural candidate") == true,
                     "structural candidate carries unresolved semantic status")

        // truncatedSampleRemainsUnresolved: a prefix cut before any resolvable
        // numeric block stays an unresolved deterministic block.
        let truncatedCase = try indexerProject(files: ["data/raw/cut.csv": indexerGenericCSV])
        defer { removeIndexerProject(truncatedCase.root, truncatedCase.project) }
        let cutURL = truncatedCase.root.appendingPathComponent("data/raw/cut.csv")
        let cutSource = RawSource(relativePath: "data/raw/cut.csv", url: cutURL, byteSize: 64)
        let truncated = Data("time,voltage,current\n0.1,1".utf8)
        var previewThrew = false
        do { _ = try GenericTableReader.inspect(prefix: truncated) } catch { previewThrew = true }
        precondition(previewThrew, "an unresolvable prefix must not produce a preview")
        guard case .blocked(let cutMessage) = try InstrumentReader.inspectPinned(
            source: cutSource, project: truncatedCase.project,
            catalog: ProfileCatalog.load(project: truncatedCase.project),
            prefix: truncated, descriptorSize: 64, actualURL: cutURL) else {
            preconditionFailure("an unresolvable prefix must resolve to a deterministic block")
        }
        precondition(!cutMessage.isEmpty, "the unresolved block keeps its reader diagnostic")

        // genericReadFailureRemainsTransient: an unreadable source is a typed
        // transient failure — never an inspection and never a persisted row.
        let transientCase = try indexerProject(files: ["data/raw/present.csv": indexerGenericCSV])
        defer { removeIndexerProject(transientCase.root, transientCase.project) }
        let goneSource = RawSource(relativePath: "data/raw/gone.csv",
                                   url: transientCase.root.appendingPathComponent("data/raw/gone.csv"),
                                   byteSize: 64)
        let transientReport = await InstrumentReader.inspectMany([goneSource], project: transientCase.project, cache: nil)
        guard let transientResult = transientReport.results.first else {
            preconditionFailure("inspectMany must report every requested source")
        }
        precondition(transientResult.inspection == nil, "a read failure never produces an inspection")
        precondition(transientResult.disposition == .transientFailure, "a read failure is transient, not blocked")
        precondition(transientResult.error?.isEmpty == false, "a transient failure keeps its diagnostic")

        // CLIAndGUIShareIndexValidity: the headless coordinator and the GUI
        // restore seam are one store, and both report typed outcomes.
        let shared = try indexerProject(files: indexerCohort(), withProfile: true)
        defer { removeIndexerProject(shared.root, shared.project) }
        let cliReport = try await ProjectIndexer.run(project: shared.project)
        precondition(cliReport.complete, "a clean cohort run is complete")
        precondition(cliReport.discovered == 5 && cliReport.inspected == 5, "every source is inspected: \(cliReport)")
        precondition(cliReport.structuralCandidates == 2, "two unprofiled generic sources are structural candidates")
        precondition(cliReport.deterministicBlocked == 1, "one unresolvable source is deterministically blocked")
        precondition(cliReport.inspected - cliReport.structuralCandidates - cliReport.deterministicBlocked == 2,
                     "the remaining inspected sources are profile matches")
        precondition(cliReport.transientFailures == 0 && cliReport.cancelled == 0 && cliReport.inventoryFailures == 0,
                     "a clean run reports no failures: \(cliReport)")
        precondition(cliReport.storageMode == .destination,
                     "the writable index resolves to the store destination")

        let sharedStore = try await ProjectIndexStore.open(project: shared.project)
        let sharedSources = try shared.project.discoverSources()
        for source in sharedSources {
            let restored = try await sharedStore.validatedInspection(for: source, project: shared.project)
            let freshReport = await InstrumentReader.inspectMany([source], project: shared.project, cache: nil)
            guard let fresh = freshReport.results.first else { continue }
            precondition(restored?.disposition == fresh.disposition,
                         "\(source.relativePath): restored disposition diverged from a fresh inspection")
            precondition(restored?.inspection?.instrumentID == fresh.inspection?.instrumentID,
                         "\(source.relativePath): restored identity diverged from a fresh inspection")
            precondition(restored?.inspection?.applicationMode == fresh.inspection?.applicationMode,
                         "\(source.relativePath): restored mode diverged from a fresh inspection")
            precondition(restored?.error == fresh.error,
                         "\(source.relativePath): restored diagnostic diverged from a fresh inspection")
        }
        // GUI-side focused write is visible to the next coordinator run.
        let focused = try requireLike(sharedSources.first)
        let focusedReport = await InstrumentReader.inspectMany([focused], project: shared.project, cache: nil)
        let focusedResult = try requireLike(focusedReport.results.first)
        try await sharedStore.withWriterJob {
            try await sharedStore.record(focusedResult, source: focused, project: shared.project)
        }
        let rerun = try await ProjectIndexer.run(project: shared.project)
        precondition(rerun.complete && rerun.discovered == cliReport.discovered && rerun.inspected == cliReport.inspected,
                     "the shared seam must not change reported outcomes: \(rerun)")
        precondition(rerun.structuralCandidates == cliReport.structuralCandidates
                        && rerun.deterministicBlocked == cliReport.deterministicBlocked,
                     "disposition counts must be stable across runs")

        // catalogChangeInvalidatesAllAffectedHints: a new catalog fingerprint
        // makes every previously recorded hint unrestorable.
        try writeFixture(shared.root, "data/instruments/extra.yaml", """
        schema_version: 1
        instrument:
          id: extra-instrument
          name: Extra Fixture
        formats: []
        modes: []
        """)
        let afterCatalog = try await ProjectIndexStore.open(project: shared.project)
        for source in sharedSources {
            let restored = try await afterCatalog.validatedInspection(for: source, project: shared.project)
            precondition(restored == nil, "\(source.relativePath): stale-catalog hint was restored")
        }
        try? FileManager.default.removeItem(at: shared.root.appendingPathComponent("data/instruments/extra.yaml"))

        // deletedFilesDisappear: refresh drops rows whose source is gone.
        let deleted = try indexerProject(files: indexerCohort(), withProfile: true)
        defer { removeIndexerProject(deleted.root, deleted.project) }
        _ = try await ProjectIndexer.run(project: deleted.project)
        precondition(indexerRows(deleted.project).count == 5, "the first run records every source")
        try FileManager.default.removeItem(at: deleted.root.appendingPathComponent("data/raw/matched-b.csv"))
        let refresh = try await ProjectIndexer.run(project: deleted.project)
        precondition(refresh.complete && refresh.discovered == 4, "the refreshed run sees the deletion")
        precondition(indexerRows(deleted.project).count == 4, "refresh removes the stale row")
        precondition(indexerRows(deleted.project)["data/raw/matched-b.csv"] == nil, "the deleted path disappears")
        let deletedStore = try await ProjectIndexStore.open(project: deleted.project)
        let ghost = RawSource(relativePath: "data/raw/matched-b.csv",
                               url: deleted.root.appendingPathComponent("data/raw/matched-b.csv"), byteSize: 10)
        let deletedGhostRestored = try await deletedStore.validatedInspection(for: ghost, project: deleted.project)
        precondition(deletedGhostRestored == nil,
                     "a deleted source never restores")

        // blockedSourcesRemainVisible: deterministic blocks stay recorded and
        // restore to a recomputed diagnostic, never to the stored payload.
        let blocked = try indexerProject(
            files: ["data/raw/notes.csv": indexerUnresolvableCSV, "data/raw/table.csv": indexerGenericCSV])
        defer { removeIndexerProject(blocked.root, blocked.project) }
        let blockedReport = try await ProjectIndexer.run(project: blocked.project)
        precondition(blockedReport.complete && blockedReport.deterministicBlocked == 1
                        && blockedReport.structuralCandidates == 1, "\(blockedReport)")
        let blockedRows = indexerRows(blocked.project)
        precondition(blockedRows.count == 2, "both sources stay visible in the index")
        guard let blockedRow = blockedRows["data/raw/notes.csv"], blockedRow.error?.isEmpty == false else {
            preconditionFailure("the blocked source keeps a recorded diagnostic")
        }
        let blockedStore = try await ProjectIndexStore.open(project: blocked.project)
        let blockedSource = try requireLike(try blocked.project.discoverSources().first {
            $0.relativePath == "data/raw/notes.csv"
        })
        let blockedRestored = try await blockedStore.validatedInspection(for: blockedSource, project: blocked.project)
        precondition(blockedRestored?.disposition == .deterministicBlocked, "the block is restorable")
        precondition(blockedRestored?.inspection == nil, "a blocked source never carries an inspection")
        precondition(blockedRestored?.error == blockedRow.error,
                     "the diagnostic is recomputed from the pinned prefix, not promoted from the row")

        // transientErrorsAreNotCached: a source that cannot be opened is not
        // persisted, does not restore, and keeps the report incomplete.
        let transient = try indexerProject(
            files: ["data/raw/table.csv": indexerGenericCSV, "data/raw/locked.csv": indexerGenericCSV])
        defer {
            chmod(transient.root.appendingPathComponent("data/raw/locked.csv").path, 0o644)
            removeIndexerProject(transient.root, transient.project)
        }
        let lockedURL = transient.root.appendingPathComponent("data/raw/locked.csv")
        guard chmod(lockedURL.path, 0o000) == 0 else {
            preconditionFailure("chmod 000 failed on the synthetic fixture")
        }
        let transientRun = try await ProjectIndexer.run(project: transient.project)
        precondition(transientRun.transientFailures == 1 && transientRun.inspected == 1, "\(transientRun)")
        precondition(transientRun.complete == false, "a transient failure keeps the report incomplete")
        let transientRows = indexerRows(transient.project)
        precondition(transientRows["data/raw/locked.csv"] == nil, "a transient failure must not be persisted")
        precondition(transientRows["data/raw/table.csv"] != nil, "verified outcomes are still persisted")
        let transientStore = try await ProjectIndexStore.open(project: transient.project)
        let lockedSource = try requireLike(try transient.project.discoverSources().first {
            $0.relativePath == "data/raw/locked.csv"
        })
        let lockedRestored = try await transientStore.validatedInspection(for: lockedSource, project: transient.project)
        precondition(lockedRestored == nil,
                     "a transient source never restores from the index")

        // cancelledIndexKeepsCompletedBatches: cancellation after the first
        // batch keeps completed batches durable and never inflates inspected.
        var many: [String: String] = [:]
        for index in 0..<300 {
            many["data/raw/run-\(String(format: "%03d", index)).csv"] = indexerGenericCSV
        }
        let cancelled = try indexerProject(files: many, withProfile: true)
        defer { removeIndexerProject(cancelled.root, cancelled.project) }
        let indexTask = Task {
            try await ProjectIndexer.run(project: cancelled.project, rebuild: false) { completed, _ in
                if completed >= 1 {
                    withUnsafeCurrentTask { $0?.cancel() }
                }
            }
        }
        let cancelledReport = try await indexTask.value
        precondition(cancelledReport.discovered == 300, "every source was discovered")
        precondition(cancelledReport.inspected == 256, "exactly the first batch was inspected: \(cancelledReport)")
        precondition(cancelledReport.cancelled == 44, "unvisited sources are cancelled, not inspected")
        precondition(cancelledReport.transientFailures == 0 && cancelledReport.structuralCandidates == 256,
                     "completed work keeps its typed outcomes: \(cancelledReport)")
        precondition(cancelledReport.complete == false, "a cancelled run is never complete")
        precondition(indexerRows(cancelled.project).count == 256, "completed batches stay durable")

        // sourceFailureDoesNotDropOtherResults: one unreadable source is
        // isolated; the other results survive and the report stays incomplete.
        let mixed = try indexerProject(
            files: ["data/raw/a.csv": indexerGenericCSV, "data/raw/b.csv": indexerGenericCSV,
                    "data/raw/c.csv": indexerUnresolvableCSV, "data/raw/locked.csv": indexerGenericCSV],
            withProfile: true)
        defer {
            chmod(mixed.root.appendingPathComponent("data/raw/locked.csv").path, 0o644)
            removeIndexerProject(mixed.root, mixed.project)
        }
        guard chmod(mixed.root.appendingPathComponent("data/raw/locked.csv").path, 0o000) == 0 else {
            preconditionFailure("chmod 000 failed on the synthetic fixture")
        }
        let mixedReport = try await ProjectIndexer.run(project: mixed.project)
        precondition(mixedReport.discovered == 4 && mixedReport.inspected == 3 && mixedReport.transientFailures == 1,
                     "\(mixedReport)")
        precondition(mixedReport.deterministicBlocked == 1 && mixedReport.structuralCandidates == 2, "\(mixedReport)")
        precondition(mixedReport.complete == false, "an isolated failure keeps the report incomplete")
        precondition(mixedReport.inspected + mixedReport.transientFailures + mixedReport.cancelled == mixedReport.discovered,
                     "outcome classes must partition the discovered sources")
        let mixedRows = indexerRows(mixed.project)
        precondition(mixedRows.count == 3, "only verified outcomes are persisted")
        precondition(mixedRows["data/raw/locked.csv"] == nil, "the failing source stays unpersisted")

        // forgedRecordCannotPromoteInspection: correct validity metadata with
        // forged scientific fields still recomputes from the pinned prefix.
        let forged = try indexerProject(files: ["data/raw/matched.csv": dualSweepCSV], withProfile: true)
        defer { removeIndexerProject(forged.root, forged.project) }
        _ = try await ProjectIndexer.run(project: forged.project)
        guard let forgedDB = try? IndexDatabase.open(at: forged.project.indexDatabaseURL),
              let original = forgedDB.lookupAll()["data/raw/matched.csv"] else {
            preconditionFailure("the run must persist the matched source")
        }
        try forgedDB.upsertBatch([IndexDatabase.Record(
            relativePath: original.relativePath, mtime: original.mtime, byteSize: original.byteSize,
            instrumentID: "forged-instrument", instrumentName: "Forged", applicationMode: "forged-mode",
            supportStatus: "supported", validationState: "profile valid; source not loaded",
            readerVersion: original.readerVersion, profileID: "forged-profile", profileHash: "forged-hash",
            prefixSHA256: original.prefixSHA256, descriptorSize: original.descriptorSize,
            recordState: .advisoryHint)])
        try forgedDB.close()
        let forgedStore = try await ProjectIndexStore.open(project: forged.project)
        let forgedSource = try requireLike(try forged.project.discoverSources().first)
        let forgedRestored = try await forgedStore.validatedInspection(for: forgedSource, project: forged.project)
        precondition(forgedRestored?.inspection?.instrumentID == "keysight-b1500a",
                     "a forged row must never reach restoration")
        precondition(forgedRestored?.inspection?.applicationMode == "dual-sweep",
                     "the outcome is recomputed from the pinned prefix and current catalog")
        precondition(forgedRestored?.inspection?.profileID != "forged-profile", "forged fields never survive")
        precondition(forgedRestored?.disposition == .profileMatched, "the recomputed outcome keeps its disposition")

        // sameSizeSameTimeEditInvalidatesStoredInspection: size and mtime stay
        // identical; only the pinned prefix digest notices the edit.
        let edited = try indexerProject(
            files: ["data/raw/edited.csv": String(repeating: "A", count: 2048) + "\n"])
        defer { removeIndexerProject(edited.root, edited.project) }
        _ = try await ProjectIndexer.run(project: edited.project)
        let editedStore = try await ProjectIndexStore.open(project: edited.project)
        let editedURL = edited.root.appendingPathComponent("data/raw/edited.csv")
        let editedSource = try requireLike(try edited.project.discoverSources().first)
        let untouchedRestored = try await editedStore.validatedInspection(for: editedSource, project: edited.project)
        precondition(untouchedRestored != nil,
                     "the untouched source restores")
        let beforeEdit = try FileManager.default.attributesOfItem(atPath: editedURL.path)
        let editMtime = (beforeEdit[.modificationDate] as? Date) ?? Date(timeIntervalSince1970: 0)
        let editSize = (beforeEdit[.size] as? NSNumber)?.int64Value ?? 0
        var editBytes = try Data(contentsOf: editedURL)
        precondition(Int64(editBytes.count) == editSize, "fixture size precondition")
        editBytes.replaceSubrange(0..<4, with: Data("EVIL".utf8))
        try editBytes.write(to: editedURL)
        try FileManager.default.setAttributes([.modificationDate: editMtime], ofItemAtPath: editedURL.path)
        let afterEdit = try FileManager.default.attributesOfItem(atPath: editedURL.path)
        precondition((afterEdit[.size] as? NSNumber)?.int64Value == editSize, "the edit keeps the same size")
        precondition(abs(((afterEdit[.modificationDate] as? Date)?.timeIntervalSince(editMtime) ?? 999)) < 0.002,
                     "the edit keeps the same recorded mtime")
        let editedRestored = try await editedStore.validatedInspection(for: editedSource, project: edited.project)
        precondition(editedRestored == nil,
                     "same-size/same-mtime edits must not restore")

        // rebuildBypassesIndexWithoutDeletingRawOrCache: poisoned rows are
        // rewritten, raw bytes/mtimes and cache entries survive, and outcomes
        // match the ordinary run exactly.
        let rebuild = try indexerProject(files: indexerCohort(), withProfile: true)
        defer { removeIndexerProject(rebuild.root, rebuild.project) }
        let rebuildCold = try await ProjectIndexer.run(project: rebuild.project)
        precondition(rebuildCold.complete, "the first run completes")
        let rebuildURL = rebuild.root.appendingPathComponent("data/raw/matched-a.csv")
        let rawBytesBefore = try Data(contentsOf: rebuildURL)
        let rawMtimeBefore = (try FileManager.default.attributesOfItem(atPath: rebuildURL.path)[.modificationDate] as? Date)
        let rebuildCache = MeasurementCache(project: rebuild.project)
        let cacheBefore = try rebuildCache.usage().entryCount
        precondition(cacheBefore > 0, "the private cache holds verified entries after a run")
        guard let rebuildDB = try? IndexDatabase.open(at: rebuild.project.indexDatabaseURL),
              let rebuildOriginal = rebuildDB.lookupAll()["data/raw/matched-a.csv"] else {
            preconditionFailure("the run must persist the matched source")
        }
        try rebuildDB.upsertBatch([IndexDatabase.Record(
            relativePath: rebuildOriginal.relativePath, mtime: rebuildOriginal.mtime,
            byteSize: rebuildOriginal.byteSize, instrumentID: "poisoned", applicationMode: "poisoned-mode",
            prefixSHA256: rebuildOriginal.prefixSHA256, descriptorSize: rebuildOriginal.descriptorSize)])
        try rebuildDB.close()
        let rebuilt = try await ProjectIndexer.run(project: rebuild.project, rebuild: true)
        precondition(rebuilt == rebuildCold, "rebuild and ordinary run report identical outcomes")
        precondition(indexerRows(rebuild.project)["data/raw/matched-a.csv"]?.instrumentID == "keysight-b1500a",
                     "rebuild rewrites poisoned rows from a fresh inspection")
        let rawBytes = try Data(contentsOf: rebuildURL)
        precondition(rawBytes == rawBytesBefore, "rebuild never writes raw bytes")
        let rawMtime = try FileManager.default.attributesOfItem(atPath: rebuildURL.path)[.modificationDate] as? Date
        precondition(rawMtime == rawMtimeBefore,
                     "rebuild never rewrites raw mtimes")
        let rebuildUsage = try rebuildCache.usage()
        precondition(rebuildUsage.entryCount >= cacheBefore,
                     "rebuild never deletes private cache data")

        // coldAndWarmRunsReportOutcomeParity: identical outcomes and counts on
        // one fixed synthetic cohort; timings are recorded, never thresholded.
        let parity = try indexerProject(files: indexerCohort(), withProfile: true)
        defer { removeIndexerProject(parity.root, parity.project) }
        let coldStart = Date()
        let coldReport = try await ProjectIndexer.run(project: parity.project)
        let coldSeconds = Date().timeIntervalSince(coldStart)
        let warmStart = Date()
        let warmReport = try await ProjectIndexer.run(project: parity.project)
        let warmSeconds = Date().timeIntervalSince(warmStart)
        precondition(coldReport.complete && warmReport.complete, "both parity runs complete")
        precondition(coldReport == warmReport, "cold and warm runs must report identical outcomes")
        precondition(coldReport.discovered == 5 && coldReport.inspected == 5
                        && coldReport.structuralCandidates == 2 && coldReport.deterministicBlocked == 1,
                     "the parity cohort counts are fixed: \(coldReport)")
        print(String(format: "index parity cohort (5 sources): cold %.3fs, warm %.3fs revalidation; no threshold asserted",
                     coldSeconds, warmSeconds))

        // firstGUIOpenMigratesBeforeDestinationCreation: read-only seams create
        // nothing, the first leased write imports legacy hints and only then
        // creates the app-local destination, and legacy stays byte-identical.
        let cutover = try indexerProject(files: ["data/raw/table.csv": indexerGenericCSV])
        defer { removeIndexerProject(cutover.root, cutover.project) }
        let legacyURL = ProjectIndexStore.legacyIndexURL(project: cutover.project)
        let legacyFixture = try pidxLegacyWAL(at: legacyURL, rows: 3)
        defer { sqlite3_close_v2(legacyFixture) }
        let legacyWAL = URL(fileURLWithPath: legacyURL.path + "-wal")
        let legacySHM = URL(fileURLWithPath: legacyURL.path + "-shm")
        let legacyBefore = pidxDigests([legacyURL, legacyWAL])
        precondition(legacyBefore.count == 2 && FileManager.default.fileExists(atPath: legacySHM.path),
                     "legacy db, WAL, and SHM must exist")
        let destination = ProjectIndexStore.preferredDestinationURL(project: cutover.project)
        precondition(cutover.project.indexDatabaseURL.path == destination.path,
                     "the runtime index URL is the store-resolved app-local destination")
        let cutoverStore = try await ProjectIndexStore.open(project: cutover.project)
        let cutoverUsage = try await cutoverStore.usage()
        precondition(cutoverUsage.legacyExists && !cutoverUsage.destinationExists, "only the legacy index exists yet")
        precondition(cutoverUsage.legacyURL.path == legacyURL.path, "usage reports the legacy source")
        let cutoverSource = try requireLike(try cutover.project.discoverSources().first)
        let beforeMigrationRestored = try await cutoverStore.validatedInspection(for: cutoverSource, project: cutover.project)
        precondition(beforeMigrationRestored == nil,
                     "nothing restores before migration")
        precondition(!FileManager.default.fileExists(atPath: destination.path),
                     "read-only seams must not create the destination")
        let firstWrite = try requireLike(
            (await InstrumentReader.inspectMany([cutoverSource], project: cutover.project, cache: nil)).results.first)
        var refusedWithoutLease = false
        do { try await cutoverStore.record(firstWrite, source: cutoverSource, project: cutover.project) }
        catch { refusedWithoutLease = true }
        precondition(refusedWithoutLease, "destination creation must require the writer lease")
        precondition(!FileManager.default.fileExists(atPath: destination.path),
                     "the refused write created nothing")
        try await cutoverStore.withWriterJob {
            try await cutoverStore.record(firstWrite, source: cutoverSource, project: cutover.project)
        }
        precondition(FileManager.default.fileExists(atPath: destination.path),
                     "the writer job creates the destination after migration")
        let cutoverRows = indexerRows(cutover.project)
        precondition(cutoverRows.count == 4, "3 imported legacy hints plus the recorded source: \(cutoverRows.keys.sorted())")
        guard let importedHint = cutoverRows["data/raw/f0.csv"] else {
            preconditionFailure("legacy hints must be imported into the app-local destination")
        }
        precondition(importedHint.recordState == .advisoryHint, "imported rows stay advisory hints")
        precondition(importedHint.prefixSHA256 == nil, "an imported hint carries no verified prefix")
        precondition(cutoverRows["data/raw/table.csv"] != nil, "the fresh record sits beside the imported hints")
        let cutoverRestored = try await cutoverStore.validatedInspection(for: cutoverSource, project: cutover.project)
        precondition(cutoverRestored != nil,
                     "post-migration restoration validates through the store")
        let hintGhost = RawSource(relativePath: "data/raw/f0.csv",
                                   url: cutover.root.appendingPathComponent("data/raw/f0.csv"), byteSize: 10)
        let hintGhostRestored = try await cutoverStore.validatedInspection(for: hintGhost, project: cutover.project)
        precondition(hintGhostRestored == nil,
                     "an unverifiable imported hint never restores an inspection")
        precondition(pidxDigests([legacyURL, legacyWAL]) == legacyBefore,
                     "legacy db/WAL must stay byte-identical after migration")
        precondition(FileManager.default.fileExists(atPath: legacySHM.path),
                     "legacy SHM is preserved, never deleted")

        // Cutover audit: no GUI source opens or reads the index database
        // directly any more — stats, rebuild, focused, resumed, lazy and
        // eager restoration all go through the store/coordinator.
        let appSourcesRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/RawViewApp", isDirectory: true)
        let appSources = (try FileManager.default.contentsOfDirectory(atPath: appSourcesRoot.path))
            .filter { $0.hasSuffix(".swift") }
        precondition(!appSources.isEmpty, "app source audit must find files")
        for name in appSources {
            let text = String(data: try Data(contentsOf: appSourcesRoot.appendingPathComponent(name)),
                              encoding: .utf8) ?? ""
            precondition(!text.contains("IndexDatabase"),
                         "\(name) still opens the index database directly; the cutover is incomplete")
            precondition(!text.contains("asInspection"),
                         "\(name) still restores from advisory record payloads")
        }
        precondition(cutover.project.indexDatabaseURL.path
                        .hasSuffix(".rawviewer/index.db"),
                     "the writable index is project-local .rawviewer/index.db")
        precondition(ProjectIndexStore.legacyIndexURL(project: cutover.project).path
                        .hasSuffix("data/.rawview/index.db"),
                     "the legacy project path stays named for hints and rollback only")
    }

    private static func indexCommandSelfCheck() async throws {
        // 1. Argument parsing assertions
        let parsed = try IndexCommand.parse(["--project", "/tmp/p", "--data-root", "data/raw", "--save-settings", "--rebuild", "--json"])
        precondition(parsed.projectURL.path == URL(fileURLWithPath: "/tmp/p").standardizedFileURL.path)
        precondition(parsed.dataRoot == "data/raw")
        precondition(parsed.saveSettings && parsed.rebuild && parsed.jsonOutput)

        var missingCaught = false
        do { _ = try IndexCommand.parse([]) } catch IndexCommandError.missingProjectArgument { missingCaught = true } catch {}
        precondition(missingCaught, "missing project throws IndexCommandError.missingProjectArgument")

        var saveWithoutRootCaught = false
        do { _ = try IndexCommand.parse(["--project", "/tmp/p", "--save-settings"]) } catch IndexCommandError.saveSettingsRequiresDataRoot { saveWithoutRootCaught = true } catch {}
        precondition(saveWithoutRootCaught, "--save-settings without --data-root throws")

        var outsideCaught = false
        do { _ = try IndexCommand.parse(["--project", "/tmp/p", "--data-root", "../esc"]) } catch IndexCommandError.outsideProjectBoundary { outsideCaught = true } catch {}
        precondition(outsideCaught, "outside relative root throws")

        // 2. Synthetic fixture execution:
        let fixture = try indexerProject(files: ["data/raw/f1.csv": indexerGenericCSV, "data/raw/f2.csv": dualSweepCSV], withProfile: true)
        defer { removeIndexerProject(fixture.root, fixture.project) }

        // Without saved settings and without explicit --data-root: exit code 2
        let noConfigOpts = IndexCommandOptions(projectURL: fixture.root)
        let (_, codeNoConfig) = await IndexCommand.run(options: noConfigOpts)
        precondition(codeNoConfig == .configurationOrArguments, "no config and no explicit root is exit 2")

        // With explicit --data-root and --save-settings: exit code 0, complete == true
        let saveOpts = IndexCommandOptions(projectURL: fixture.root, dataRoot: "data/raw", saveSettings: true)
        let (saveReport, codeSave) = await IndexCommand.run(options: saveOpts)
        precondition(codeSave == .success, "explicit data-root with save-settings succeeds")
        precondition(saveReport?.complete == true, "report is complete")
        precondition(saveReport?.discovered == 2, "discovered 2 files")

        // Subsequent run with no --data-root now succeeds using saved settings
        let savedRunOpts = IndexCommandOptions(projectURL: fixture.root)
        let (savedRunReport, codeSavedRun) = await IndexCommand.run(options: savedRunOpts)
        precondition(codeSavedRun == .success, "run with saved settings succeeds")
        precondition(savedRunReport?.complete == true, "saved settings run is complete")

        // Rebuild run
        let rebuildOpts = IndexCommandOptions(projectURL: fixture.root, rebuild: true)
        let (rebuildReport, codeRebuild) = await IndexCommand.run(options: rebuildOpts)
        precondition(codeRebuild == .success, "rebuild succeeds")
        precondition(rebuildReport?.complete == true, "rebuild is complete")

        // Writer busy check: hold flock lease
        let leaseURL = MeasurementCache.appLocalRoot(project: fixture.project)
            .appendingPathComponent(ProjectIndexStore.writerLeaseFileName)
        try FileManager.default.createDirectory(at: leaseURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fd = Darwin.open(leaseURL.path, O_RDWR | O_CREAT, 0o600)
        precondition(fd >= 0, "open lease fd")
        let lockRc = flock(fd, LOCK_EX | LOCK_NB)
        precondition(lockRc == 0, "acquired external lease lock")

        let busyOpts = IndexCommandOptions(projectURL: fixture.root)
        let (_, codeBusy) = await IndexCommand.run(options: busyOpts)
        flock(fd, LOCK_UN)
        Darwin.close(fd)
        precondition(codeBusy == .writerBusy, "when lease is held, exit code is writerBusy (3)")

        // FlattenedTree arbitrary depth test
        let leaf = SourceTreeNode(id: "source:a/b/c/d/sample.csv", name: "sample.csv", sourceID: "a/b/c/d/sample.csv", children: [])
        let nodeD = SourceTreeNode(id: "directory:a/b/c/d", name: "d", sourceID: nil, children: [leaf])
        let nodeC = SourceTreeNode(id: "directory:a/b/c", name: "c", sourceID: nil, children: [nodeD])
        let nodeB = SourceTreeNode(id: "directory:a/b", name: "b", sourceID: nil, children: [nodeC])
        let nodeA = SourceTreeNode(id: "directory:a", name: "a", sourceID: nil, children: [nodeB])

        // Test collapse/expand with depth tracking
        let itemsCollapsed = SourceTree.flattenNodes([nodeA], depth: 0, expandedIDs: [])
        precondition(itemsCollapsed.count == 1, "collapsed tree has only root directory")
        precondition(itemsCollapsed[0].depth == 0, "depth 0")

        let itemsAllExpanded = SourceTree.flattenNodes([nodeA], depth: 0, expandedIDs: ["directory:a", "directory:a/b", "directory:a/b/c", "directory:a/b/c/d"])
        precondition(itemsAllExpanded.count == 5, "fully expanded tree has 5 items (4 dirs + 1 file)")
        precondition(itemsAllExpanded[4].node.sourceID == "a/b/c/d/sample.csv", "leaf sourceID matches")
        precondition(itemsAllExpanded[4].depth == 4, "deep-nested leaf depth is 4")
        precondition(!itemsAllExpanded[4].isDirectory, "leaf is not directory")
    }
}


