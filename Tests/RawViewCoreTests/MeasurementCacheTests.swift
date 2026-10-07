import CryptoKit
import Foundation
import Testing
@testable import RawViewCore

/// Cache boundary: selected project -> profile validation/inspection -> full arrays -> cache.
/// Synthetic fixtures only; no real project data, paths, or identifiers appear here.
struct MeasurementCacheTests {
    // MARK: helpers

    private func makeCacheProject(rowCount: Int = 7) throws -> (root: URL, project: ProjectContext) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rawview-cache-\(UUID().uuidString)")
        // Rows beyond the first 64 KiB stay outside the inspection prefix, so a
        // row-only edit can leave the exact header prefix unchanged.
        var csv = "SetupTitle, 2-terminal dual Vsweep\nDataName, V1, I1\n"
        var values: [Double] = []
        var v = 0.0
        for _ in 0..<(rowCount + 3000) {
            values.append(v)
            v += 0.01
            if v > 1 { v = 0 }
        }
        for (index, value) in values.enumerated() {
            csv += String(format: "DataValue, %.3f, %.5E\n", value, 1e-12 + Double(index % 9) * 1e-13)
        }
        for (relativePath, data) in [
            "data/instruments/keysight-b1500a.yaml": Data(Fixtures.keysightProfile.utf8),
            "data/raw/dual-sweep.csv": Data(csv.utf8),
        ] {
            let url = root.appendingPathComponent(relativePath)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
        }
        return (root, try ProjectContext.open(root))
    }

    /// Rewrites the source's data rows (never the header, never the size) and
    /// restores the original mtime, so only row content differs.
    private func rewriteRowsChangingOneValue(_ source: RawSource) throws {
        var original = try String(contentsOf: source.url, encoding: .utf8)
        // Flip one row value far beyond the 64 KiB header prefix.
        if let marker = original.range(of: "DataValue, 0.500, ", options: .backwards) {
            let valueStart = original.index(marker.upperBound, offsetBy: 0)
            original.replaceSubrange(valueStart..<original.index(valueStart, offsetBy: 6), with: "9.999E")
        }
        let data = Data(original.utf8)
        let attributes = try FileManager.default.attributesOfItem(atPath: source.url.path)
        let mtime = attributes[.modificationDate] as! Date
        try data.write(to: source.url)
        try FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: source.url.path)
    }

    private func loadMeasurement(_ source: RawSource, project: ProjectContext) async throws -> NormalizedMeasurement {
        try await InstrumentReader.load(source.url, project: project)
    }

    private var syntheticMeasurement: NormalizedMeasurement {
        NormalizedMeasurement(
            source: SourceIdentity(path: "data/raw/synth.csv", sha256: String(repeating: "a", count: 64)),
            instrument: InstrumentIdentity(id: "synth", name: "Synth", vendor: "SynthCo", model: "S-1"),
            applicationMode: "dual-sweep",
            view: MeasurementView(kind: "xy", x: "voltage", y: ["current"], preserveOrder: true),
            channels: [
                MeasurementChannel(name: "voltage", label: "Voltage", unit: "V", quantity: "voltage",
                                   values: [0, Double(bitPattern: 0x8000000000000000),
                                            Double(bitPattern: 1),
                                            Double(bitPattern: 0x7FEFFFFFFFFFFFFF),
                                            nil, nil,
                                            Double(bitPattern: 0x7FEFFFFFFFFFFFFF &- 1), 0.5],
                                   gapReasons: [nil, nil, nil, nil, .blank, nil, nil, nil]),
                MeasurementChannel(name: "current", label: "Current", unit: "A", quantity: "current",
                                   values: [1e-12, nil, -3e-12, nil,
                                            Double(sign: .minus, exponent: 1023, significand: 1.5), nil,
                                            2.5e-12, nil],
                                   gapReasons: [nil, .nan, nil, .infinite, nil, .saturated, nil, .unknown]),
            ],
            metadataSections: [
                MetadataSection(title: "Acquisition", fields: [
                    MetadataField(key: "SetupTitle", label: "Setuptitle", value: .string("2-terminal dual Vsweep"), unit: nil, kind: "string"),
                    MetadataField(key: "Dimension1", label: "Dimension1", value: .string("5, 5"), unit: nil, kind: "string"),
                ]),
                MetadataSection(title: "Identity", fields: [
                    MetadataField(key: "device_id", label: "Device id", value: .string("synth-device"), unit: nil, kind: "string"),
                ]),
            ],
            warnings: ["data/raw/synth.csv line 4: column \"current\" records NaN; shown as a gap."],
            supportStatus: "supported",
            provenance: ["reader_version": InstrumentReader.version, "profile_id": "synth", "profile_hash": "abc123", "profile_schema_version": "2", "mode": "dual-sweep"]
        )
    }

    // MARK: Slice 1 — bitwise full-payload round-trip

    @Test func cacheRoundTripsMeasurementBitwiseIncludingGapsAndMetadata() async throws {
        let original = syntheticMeasurement
        let encoded = try MeasurementCache.encode(measurement: original)
        let restored = try MeasurementCache.decode(measurement: encoded)

        #expect(restored.source == original.source)
        #expect(restored.instrument == original.instrument)
        #expect(restored.applicationMode == original.applicationMode)
        #expect(restored.view.kind == original.view.kind)
        #expect(restored.view.x == original.view.x)
        #expect(restored.view.y == original.view.y)
        #expect(restored.view.preserveOrder == original.view.preserveOrder)
        #expect(restored.warnings == original.warnings)
        #expect(restored.supportStatus == original.supportStatus)
        #expect(restored.provenance == original.provenance)
        // Exact Double bit patterns (including signed zero, a subnormal, and
        // finite max), gap reasons (including nil vs `.unknown`), order.
        for (channel, expected) in zip(restored.channels, original.channels) {
            #expect(channel.name == expected.name)
            #expect(channel.label == expected.label)
            #expect(channel.unit == expected.unit)
            #expect(channel.quantity == expected.quantity)
            #expect(channel.values.count == expected.values.count)
            for (index, value) in channel.values.enumerated() {
                switch (value, expected.values[index]) {
                case (nil, nil): break
                case (let v?, let e?):
                    #expect(v.bitPattern == e.bitPattern, "bit pattern drifted at row \(index)")
                default:
                    Issue.record("gap mismatch at row \(index): \(String(describing: value)) vs \(String(describing: expected.values[index]))")
                }
            }
            for (index, reason) in channel.gapReasons.enumerated() {
                #expect(reason == expected.gapReasons[index], "gap reason drifted at row \(index)")
            }
        }
        for (section, expected) in zip(restored.metadataSections, original.metadataSections) {
            #expect(section.title == expected.title)
            #expect(section.fields.count == expected.fields.count)
            for (field, expectedField) in zip(section.fields, expected.fields) {
                #expect(field.key == expectedField.key)
                #expect(field.label == expectedField.label)
                #expect(field.unit == expectedField.unit)
                #expect(field.kind == expectedField.kind)
                #expect(field.value.displayText == expectedField.value.displayText)
            }
        }
    }

    private func securedPrefixInfo(_ source: RawSource, project: ProjectContext) throws -> (prefixSHA256: String, size: Int64) {
        let secured = try MeasurementCache.openSecuredPrefix(source: source, project: project)
        defer { try? secured.handle.close() }
        return (sha256Hex(secured.prefix), secured.descriptorSize)
    }

    private func storeViaDescriptor(_ cache: MeasurementCache, measurement: NormalizedMeasurement, source: RawSource, project: ProjectContext, fingerprint: String) throws {
        let info = try securedPrefixInfo(source, project: project)
        try cache.store(measurement: measurement, profileFingerprint: fingerprint,
                        source: RawSource(relativePath: source.relativePath, url: source.url, byteSize: info.size),
                        prefixSHA256: info.prefixSHA256)
    }

    // MARK: Slice 4 — measurement store/hit/miss with full-digest verification

    @Test func measurementCacheHitRestoresAfterStoreAndMissAfterContentEdit() async throws {
        let (root, project) = try makeCacheProject()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = MeasurementCache(project: project, limitBytes: 512 * 1024 * 1024)
        let source = try #require(try project.discoverSources().first)
        let measurement = try await loadMeasurement(source, project: project)

        try storeViaDescriptor(cache, measurement: measurement, source: source, project: project, fingerprint: "fp-1")
        // First retrieval verifies the full-content digest before decoding.
        let hit = try cache.measurement(for: source, project: project, profileFingerprint: "fp-1")
        #expect(hit != nil)
        #expect(hit?.channel(named: "current")?.values == measurement.channel(named: "current")?.values)
        #expect(hit?.source.sha256 == measurement.source.sha256)

        // Same size, same mtime, different bytes: the fresh digest differs -> miss.
        let url = source.url
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let originalMtime = attributes[.modificationDate] as! Date
        let replacement = "SetupTitle, 2-terminal dual Vsweep\nDataName, V1, I1\nDataValue, 0, 1E-12\nDataValue, 0.1, 3E-12\nDataValue, 0.2, 3E-12\nDataValue, 0.1, 4E-12\nDataValue, 0, 5E-12\n"
        try Data(replacement.utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: originalMtime], ofItemAtPath: url.path)

        let miss = try cache.measurement(for: source, project: project, profileFingerprint: "fp-1")
        #expect(miss == nil)
    }

    @Test func fullDigestGateRejectsSameSizeSameMtimeBodyEditBeyondPrefix() async throws {
        // Same relative path, same descriptor size, same exact 64 KiB prefix
        // digest, same fingerprint — only the recorded full-content digest
        // differs. The entry must NOT be served: the verification gate alone
        // rejects it (this test is the one that fails if the gate is removed).
        let (root, project) = try makeCacheProject(rowCount: 12000)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = MeasurementCache(project: project, limitBytes: 512 * 1024 * 1024)
        let source = try #require(try project.discoverSources().first)
        let measurement = try await loadMeasurement(source, project: project)
        let identity = try securedPrefixInfo(source, project: project)
        try storeViaDescriptor(cache, measurement: measurement, source: source, project: project, fingerprint: "fp-1")
        #expect(try cache.measurement(for: source, project: project, profileFingerprint: "fp-1") != nil)

        // Same-length row-only edit beyond the 64 KiB prefix, mtime restored.
        try rewriteRowsChangingOneValue(source)
        // Assert the identity inputs are unchanged by construction, so only
        // the recorded full-content digest can reject the entry now.
        let afterEditIdentity = try securedPrefixInfo(source, project: project)
        #expect(afterEditIdentity.prefixSHA256 == identity.prefixSHA256)
        #expect(afterEditIdentity.size == identity.size)
        let afterEdit = try cache.measurement(for: source, project: project, profileFingerprint: "fp-1")
        #expect(afterEdit == nil, "full-digest verification gate did not reject a body edit with identical identity inputs")
    }

    @Test func measurementCacheMissesWhenProfileFingerprintChanges() async throws {
        let (root, project) = try makeCacheProject()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = MeasurementCache(project: project, limitBytes: 512 * 1024 * 1024)
        let source = try #require(try project.discoverSources().first)
        let measurement = try await loadMeasurement(source, project: project)
        try storeViaDescriptor(cache, measurement: measurement, source: source, project: project, fingerprint: "fp-1")
        #expect(try cache.measurement(for: source, project: project, profileFingerprint: "fp-1") != nil)
        #expect(try cache.measurement(for: source, project: project, profileFingerprint: "fp-2") == nil)
    }

    @Test func corruptCacheEntryIsAMissAndCanBeRebuilt() async throws {
        let (root, project) = try makeCacheProject()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = MeasurementCache(project: project, limitBytes: 512 * 1024 * 1024)
        let source = try #require(try project.discoverSources().first)
        let measurement = try await loadMeasurement(source, project: project)
        try storeViaDescriptor(cache, measurement: measurement, source: source, project: project, fingerprint: "fp-1")

        // Entries are two files (meta + payload) inside a key directory.
        let cacheRoot = try URL(fileURLWithPath: cache.usage().root, isDirectory: true)
        var keyDirs: [String] = []
        for prefix in try FileManager.default.contentsOfDirectory(atPath: cacheRoot.path) {
            keyDirs.append(contentsOf: try FileManager.default.contentsOfDirectory(atPath: cacheRoot.appendingPathComponent(prefix).path).map { "\(prefix)/\($0)" })
        }
        #expect(!keyDirs.isEmpty)
        let victim = cacheRoot.appendingPathComponent(keyDirs[0]).appendingPathComponent("payload")
        let existing = try Data(contentsOf: victim)
        try existing.prefix(max(0, existing.count - 3)).write(to: victim)

        #expect(try cache.measurement(for: source, project: project, profileFingerprint: "fp-1") == nil)
        // Rebuild overwrites the corrupt entry; the next lookup hits.
        try storeViaDescriptor(cache, measurement: measurement, source: source, project: project, fingerprint: "fp-1")
        #expect(try cache.measurement(for: source, project: project, profileFingerprint: "fp-1") != nil)
    }

    // MARK: Slice 5 — containment

    @Test func projectCacheSymlinkIsIgnoredWhileAppLocalCacheWorks() async throws {
        let (root, project) = try makeCacheProject()
        defer { try? FileManager.default.removeItem(at: root) }
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("rawview-cache-outside-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outside) }
        // data/.cache is a symlink pointing outside the project: it must never be written through.
        let cacheDir = root.appendingPathComponent("data/.cache")
        try FileManager.default.createSymbolicLink(at: cacheDir, withDestinationURL: outside)

        let resolution = MeasurementCache.resolveRoot(project: project)
        guard case .appLocal = resolution else {
            Issue.record("symlinked project cache root was accepted")
            return
        }
        let cache = MeasurementCache(project: project, limitBytes: 512 * 1024 * 1024, rootResolution: resolution)
        let source = try #require(try project.discoverSources().first)
        let measurement = try await loadMeasurement(source, project: project)
        try storeViaDescriptor(cache, measurement: measurement, source: source, project: project, fingerprint: "fp-1")
        #expect(try cache.measurement(for: source, project: project, profileFingerprint: "fp-1") != nil)
        // Nothing leaked through the symlink into the outside directory.
        #expect(try FileManager.default.subpathsOfDirectory(atPath: outside.path).isEmpty)
    }

    // MARK: Slice 6 — read-only projects use the same app-local cache

    @Test func readOnlyProjectUsesAppLocalCacheAndStores() async throws {
        let (root, project) = try makeCacheProject()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: root.appendingPathComponent("data").path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.appendingPathComponent("data").path) }

        let resolution = MeasurementCache.resolveRoot(project: project)
        guard case .appLocal = resolution else {
            Issue.record("read-only project must use the app-local cache")
            return
        }
        let cache = MeasurementCache(project: project, limitBytes: 512 * 1024 * 1024, rootResolution: resolution)
        let source = try #require(try project.discoverSources().first)
        let measurement = try await loadMeasurement(source, project: project)
        try storeViaDescriptor(cache, measurement: measurement, source: source, project: project, fingerprint: "fp-1")
        #expect(try cache.measurement(for: source, project: project, profileFingerprint: "fp-1") != nil)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("data/.cache").path))
    }

    // MARK: Slice 7 — limit, LRU, clear

    @Test func lruEvictionHonorsLimitAndClearRemovesOnlyCacheFiles() async throws {
        let (root, project) = try makeCacheProject(rowCount: 9000)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = MeasurementCache(project: project, limitBytes: 512 * 1024 * 1024)
        let source = try #require(try project.discoverSources().first)
        let measurement = try await loadMeasurement(source, project: project)
        try storeViaDescriptor(cache, measurement: measurement, source: source, project: project, fingerprint: "fp-1")

        // Real eviction: the limit holds exactly ONE entry. After the second
        // store the LRU-oldest entry must be evicted, leaving exactly one.
        let encodedSize = try MeasurementCache.encode(measurement: measurement).count
        let oneEntryLimit = Int64(encodedSize + 4096)
        let limited = MeasurementCache(project: project, limitBytes: oneEntryLimit, rootResolution: cache.rootResolution)
        try storeViaDescriptor(limited, measurement: measurement, source: source, project: project, fingerprint: "fp-1")
        #expect(try limited.usage().entryCount == 1)
        // The first entry's LRU clock runs on the lookup touch.
        _ = try limited.measurement(for: source, project: project, profileFingerprint: "fp-1")
        try storeViaDescriptor(limited, measurement: measurement, source: source, project: project, fingerprint: "fp-2")
        let afterEvict = try limited.usage()
        #expect(afterEvict.entryCount == 1, "LRU eviction did not keep exactly one entry")
        #expect(afterEvict.usedBytes <= oneEntryLimit)
        // The surviving (newest) entry is reachable under its own fingerprint.
        #expect(try limited.measurement(for: source, project: project, profileFingerprint: "fp-2") != nil)
        // The evicted one is gone.
        #expect(try limited.measurement(for: source, project: project, profileFingerprint: "fp-1") == nil)

        // Clear removes exactly the cache entry directories (the rawview root
        // itself stays in place); raw source and profiles are untouched.
        try limited.clear()
        let cleared = try limited.usage()
        #expect(cleared.usedBytes == 0 && cleared.entryCount == 0)
        // Raw source and profiles untouched.
        #expect(FileManager.default.fileExists(atPath: source.url.path))
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("data/instruments/keysight-b1500a.yaml").path))
    }

    // MARK: Slice 8 — cancellation/transient errors never cached

    @Test func readerCancellationDoesNotStoreMeasurement() async throws {
        let (root, project) = try makeCacheProject()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = MeasurementCache(project: project, limitBytes: 512 * 1024 * 1024)
        let source = try #require(try project.discoverSources().first)
        // A pre-cancelled reader task throws before its first checkpoint and
        // must store nothing.
        let task = Task { () throws -> NormalizedMeasurement in
            try await InstrumentReader.load(source.url, project: project, cache: cache)
        }
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("a pre-cancelled reader task should not complete")
        } catch {}
        #expect(try cache.usage().entryCount == 0)
    }

    // MARK: Slice 9 — .spe/.affm zero-open at the cache seam

    @Test func speAndAffmSourcesNeverReachTheCache() async throws {
        let (root, project) = try makeCacheProject()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = MeasurementCache(project: project, limitBytes: 512 * 1024 * 1024)
        let rawRoot = root.appendingPathComponent("data/raw")
        for name in ["forbidden.spe", "FORBIDDEN.AFFM"] {
            let url = rawRoot.appendingPathComponent(name)
            let source = RawSource(relativePath: "data/raw/\(name)", url: url, byteSize: 0)
            // No entry exists and no identity key can even be computed without an open.
            #expect(try cache.measurement(for: source, project: project, profileFingerprint: "fp-1") == nil)
        }
        let usage = try cache.usage()
        #expect(usage.entryCount == 0)
        #expect(!FileManager.default.fileExists(atPath: rawRoot.appendingPathComponent("forbidden.spe").path))
        #expect(!FileManager.default.fileExists(atPath: rawRoot.appendingPathComponent("FORBIDDEN.AFFM").path))
    }

    // MARK: Slice 2/3 — inspection cache seam (typed deterministic outcomes)

    @Test func inspectionCacheReusesDeterministicOutcomeAfterRowOnlyEdit() async throws {
        let (root, project) = try makeCacheProject(rowCount: 12000)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = MeasurementCache(project: project, limitBytes: 512 * 1024 * 1024)
        let source = try #require(try project.discoverSources().first)
        let catalogFingerprint = "fp-1"

        let first = try await cache.inspection(for: source, project: project, catalogFingerprint: catalogFingerprint) { (pinnedPrefix: Data, descriptorSize: Int64, actualURL: URL) throws -> MeasurementCache.CachedInspection in
            try InstrumentReader.inspectPinned(source: source, project: project, catalog: ProfileCatalog.load(project: project), prefix: pinnedPrefix, descriptorSize: descriptorSize, actualURL: actualURL)
        }
        guard case .supported(let coldInspection) = first.outcome else {
            Issue.record("clean fixture should resolve to a supported inspection")
            return
        }
        #expect(first.fromCache == false)

        // Row-only edit (same header prefix/size/mtime): inspection may be
        // reused after prefix verification — the changed rows sit outside the
        // 64 KiB header prefix.
        try rewriteRowsChangingOneValue(source)

        let second = try await cache.inspection(for: source, project: project, catalogFingerprint: catalogFingerprint) { (pinnedPrefix: Data, descriptorSize: Int64, actualURL: URL) throws -> MeasurementCache.CachedInspection in
            try InstrumentReader.inspectPinned(source: source, project: project, catalog: ProfileCatalog.load(project: project), prefix: pinnedPrefix, descriptorSize: descriptorSize, actualURL: actualURL)
        }
        #expect(second.fromCache == true)
        guard case .supported(let warmInspection) = second.outcome else {
            Issue.record("warm outcome lost the supported inspection")
            return
        }
        #expect(warmInspection.instrumentID == coldInspection.instrumentID)

        // A different catalog fingerprint misses (profile-catalog invalidation).
        let third = try await cache.inspection(for: source, project: project, catalogFingerprint: "fp-2") { (pinnedPrefix: Data, descriptorSize: Int64, actualURL: URL) throws -> MeasurementCache.CachedInspection in
            try InstrumentReader.inspectPinned(source: source, project: project, catalog: ProfileCatalog.load(project: project), prefix: pinnedPrefix, descriptorSize: descriptorSize, actualURL: actualURL)
        }
        #expect(third.fromCache == false)
    }

    @Test func inspectionCacheMissesOnSameSizeSameMtimeHeaderEdit() async throws {
        let (root, project) = try makeCacheProject()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = MeasurementCache(project: project, limitBytes: 512 * 1024 * 1024)
        let source = try #require(try project.discoverSources().first)

        _ = try await cache.inspection(for: source, project: project, catalogFingerprint: "fp-1") { (pinnedPrefix: Data, descriptorSize: Int64, actualURL: URL) throws -> MeasurementCache.CachedInspection in
            try InstrumentReader.inspectPinned(source: source, project: project, catalog: ProfileCatalog.load(project: project), prefix: pinnedPrefix, descriptorSize: descriptorSize, actualURL: actualURL)
        }

        // Header edit inside the 64 KiB prefix, same size, same mtime: the exact prefix digest changes -> miss.
        let url = source.url
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let originalMtime = attributes[.modificationDate] as! Date
        let replacement = "SetupTitle, 2-terminal dual Vsweep (edited)\nDataName, V1, I1\nDataValue, 0, 1E-12\nDataValue, 0.1, 2E-12\nDataValue, 0.2, 3E-12\nDataValue, 0.1, 4E-12\nDataValue, 0, 5E-12\n"
        try Data(replacement.utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: originalMtime], ofItemAtPath: url.path)

        let second = try await cache.inspection(for: source, project: project, catalogFingerprint: "fp-1") { (pinnedPrefix: Data, descriptorSize: Int64, actualURL: URL) throws -> MeasurementCache.CachedInspection in
            try InstrumentReader.inspectPinned(source: source, project: project, catalog: ProfileCatalog.load(project: project), prefix: pinnedPrefix, descriptorSize: descriptorSize, actualURL: actualURL)
        }
        #expect(second.fromCache == false)
    }

    @Test func deterministicBlockedOutcomeIsCachedUntilInvalidated() async throws {
        // A valid profile whose detect never matches: inspectAccess returns a
        // deterministic blocked diagnostic, and the seam caches it.
        let (root, project) = try makeCacheProject()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = MeasurementCache(project: project, limitBytes: 512 * 1024 * 1024)
        let source = try #require(try project.discoverSources().first)
        // Rewrite the header so the profile's detect misses; header bytes then
        // keystamp the identity, and the failure is deterministic.
        let original = try String(contentsOf: source.url, encoding: .utf8)
        let unmatchable = original.replacingOccurrences(of: "2-terminal dual Vsweep", with: "UNMATCHABLE-HEADER-\(UUID().uuidString.prefix(8))")
        try Data(unmatchable.utf8).write(to: source.url)

        let firstProducerRan = InspectionRunCounter()
        let first = try await cache.inspection(for: source, project: project, catalogFingerprint: "fp-1") { (pinnedPrefix: Data, descriptorSize: Int64, actualURL: URL) throws -> MeasurementCache.CachedInspection in
            firstProducerRan.count += 1
            return try InstrumentReader.inspectPinned(source: source, project: project, catalog: ProfileCatalog.load(project: project), prefix: pinnedPrefix, descriptorSize: descriptorSize, actualURL: actualURL)
        }
        guard case .blocked(let message) = first.outcome else {
            Issue.record("unmatchable header should produce a blocked outcome: \(first.outcome)")
            return
        }
        #expect(first.fromCache == false)
        #expect(message.contains("detect") || message.contains("No profile mode matched"))
        // Warm run serves the cached deterministic diagnostic without rerunning the producer.
        let warmProducerRan = InspectionRunCounter()
        let second = try await cache.inspection(for: source, project: project, catalogFingerprint: "fp-1") { (pinnedPrefix: Data, descriptorSize: Int64, actualURL: URL) throws -> MeasurementCache.CachedInspection in
            warmProducerRan.count += 1
            return try InstrumentReader.inspectPinned(source: source, project: project, catalog: ProfileCatalog.load(project: project), prefix: pinnedPrefix, descriptorSize: descriptorSize, actualURL: actualURL)
        }
        #expect(second.fromCache == true)
        #expect(second.outcome == first.outcome)
        #expect(firstProducerRan.count == 1)
        #expect(warmProducerRan.count == 0)
    }

    @Test func cancelledAndTransientOutcomesThrowAndRetry() async throws {
        let (root, project) = try makeCacheProject()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = MeasurementCache(project: project, limitBytes: 512 * 1024 * 1024)
        let source = try #require(try project.discoverSources().first)

        // Cancellation throws through the seam: nothing cached, nothing served.
        do {
            _ = try await cache.inspection(for: source, project: project, catalogFingerprint: "fp-1") { (_: Data, _: Int64, _: URL) throws -> MeasurementCache.CachedInspection in
                throw CancellationError()
            }
            Issue.record("cancellation should propagate")
        } catch {}
        #expect(try cache.usage().entryCount == 0)

        // A transient open/read failure throws as well and retries.
        do {
            _ = try await cache.inspection(for: source, project: project, catalogFingerprint: "fp-1") { (_: Data, _: Int64, _: URL) throws -> MeasurementCache.CachedInspection in
                throw ReaderError.invalidSource("data/raw/dual-sweep.csv: could not read the source file: transient I/O error")
            }
            Issue.record("transient failure should propagate")
        } catch {}
        #expect(try cache.usage().entryCount == 0)

        // The next call runs the producer again (a thrown outcome left no entry).
        let ran = InspectionRunCounter()
        let retried = try await cache.inspection(for: source, project: project, catalogFingerprint: "fp-1") { (_: Data, _: Int64, _: URL) throws -> MeasurementCache.CachedInspection in
            ran.count += 1
            return .blocked("data/raw/dual-sweep.csv: deterministic diagnostic")
        }
        #expect(ran.count == 1)
        #expect(retried.fromCache == false)
        #expect(try cache.usage().entryCount == 1, "only the deterministic outcome is stored")
        // And it hits afterwards.
        let warm = try await cache.inspection(for: source, project: project, catalogFingerprint: "fp-1") { (_: Data, _: Int64, _: URL) throws -> MeasurementCache.CachedInspection in
            Issue.record("deterministic outcome was not served from cache")
            return .blocked("unreachable")
        }
        #expect(warm.fromCache == true)
    }

    @Test func missingSourceOpenFailsInsteadOfCaching() async throws {
        let (root, project) = try makeCacheProject()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = MeasurementCache(project: project, limitBytes: 512 * 1024 * 1024)
        let ghost = RawSource(relativePath: "data/raw/ghost.csv",
                              url: root.appendingPathComponent("data/raw/ghost.csv"), byteSize: 10)
        #expect(try cache.measurement(for: ghost, project: project, profileFingerprint: "fp-1") == nil)
        let usage = try cache.usage()
        #expect(usage.entryCount == 0)
    }

    // MARK: Slice 10 — reader integration: warm load comes from the cache

    @Test func readerLoadStoresThenServesWarmLoadsFromCache() async throws {
        let (root, project) = try makeCacheProject(rowCount: 9000)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = MeasurementCache(project: project, limitBytes: 512 * 1024 * 1024)
        let source = try #require(try project.discoverSources().first)

        let cold = try await InstrumentReader.load(source.url, project: project, cache: cache)
        let usage = try cache.usage()
        #expect(usage.entryCount == 1)

        // Warm load: the cache serves the identical measurement after full-digest verification.
        let warm = try await InstrumentReader.load(source.url, project: project, cache: cache)
        #expect(warm.source.sha256 == cold.source.sha256)
        #expect(warm.channels.map(\.name) == cold.channels.map(\.name))
        #expect(warm.channels.map(\.values) == cold.channels.map(\.values))

        // Without a cache the reader keeps its single-pass behavior.
        let uncached = try await InstrumentReader.load(source.url, project: project)
        #expect(uncached.source.sha256 == cold.source.sha256)
    }

    // MARK: Slice 10b — catalog fingerprint stability and invalidation

    /// UNCHECKED-SINGLE-THREAD COUNT: the test producer runs strictly serially
    /// (one seam call at a time); plain int field, no actor needed.
    private final class InspectionRunCounter: @unchecked Sendable {
        var count = 0
    }

    @Test func catalogFingerprintChangesWithProfileBytes() async throws {
        let (root, project) = try makeCacheProject()
        defer { try? FileManager.default.removeItem(at: root) }
        let before = ProfileCatalog.load(project: project).fingerprint
        let profileURL = root.appendingPathComponent("data/instruments/keysight-b1500a.yaml")
        let edited = try String(contentsOf: profileURL, encoding: .utf8)
            .replacingOccurrences(of: "name: Keysight B1500A Semiconductor Device Parameter Analyzer",
                                  with: "name: Keysight B1500A Renamed")
        try Data(edited.utf8).write(to: profileURL)
        let after = ProfileCatalog.load(project: project).fingerprint
        #expect(before != after)
        #expect(after.count == 64)
    }

    // MARK: Slice 11 — inspection cache via inspectMany (app seam)

    @Test func inspectManyUsesCacheAndWarmRunsSkipProfileWork() async throws {
        let (root, project) = try makeCacheProject(rowCount: 200)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = MeasurementCache(project: project, limitBytes: 512 * 1024 * 1024)
        let sources = try project.discoverSources()

        let report1 = await InstrumentReader.inspectMany(sources, project: project, cache: cache)
        let cold = try #require(report1.results.first)
        #expect(cold.inspection?.instrumentID == "keysight-b1500a")
        #expect(try cache.usage().entryCount >= 1)

        // Warm run: same deterministic outcome served from the entry — the
        // producer (inspect) never runs because the lookup hits.
        let report2 = await InstrumentReader.inspectMany(sources, project: project, cache: cache)
        let warm = try #require(report2.results.first)
        #expect(warm.inspection?.instrumentID == cold.inspection?.instrumentID)
        // No additional entry was created by the warm run.
        #expect(try cache.usage().entryCount == 1)
    }

    // MARK: Correction pass — fingerprint completeness, namespace gates, shape misses

    @Test func brokenProfileBytesDriveCatalogFingerprintDifferently() async throws {
        func brokenProfile(prefixComment: String) -> String {
            "\(prefixComment)schema_version: 1\ninstrument:\n  id: broken\n  name: Broken\nformats:\n  - id: csv\n    kind: tabular\n    extensions: [\".csv\"]\n    rows:\n      names_prefix: \"DataName\"\n      data_prefix: \"DataValue\"\n    columns:\n      voltage:\n        header: \"V1\"\n        quantity: voltage\nmodes:\n  - id: broken-mode\n    format: csv\n    detect: [\"NEVER-SEEN-SIGNATURE\"]\n    extract:\n      x: voltage\n      y: [current]\n"
        }
        func projectWith(_ profileYaml: String) throws -> URL {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("rawview-fibrate-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root.appendingPathComponent("data/instruments"), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: root.appendingPathComponent("data/raw"), withIntermediateDirectories: true)
            try Data(profileYaml.utf8).write(to: root.appendingPathComponent("data/instruments/broken.yaml"))
            try Data("SetupTitle, 2-terminal dual Vsweep\n".utf8).write(to: root.appendingPathComponent("data/raw/thing.csv"))
            return root
        }
        let rootA = try projectWith(brokenProfile(prefixComment: ""))
        let rootB = try projectWith(brokenProfile(prefixComment: "# byte-only adjustment, same parse\n"))
        defer { try? FileManager.default.removeItem(at: rootA); try? FileManager.default.removeItem(at: rootB) }

        let projectA = try ProjectContext.open(rootA)
        let projectB = try ProjectContext.open(rootB)
        let catalogA = ProfileCatalog.load(project: projectA)
        let catalogB = ProfileCatalog.load(project: projectB)

        // Same parsed selectors/diagnostic state...
        #expect(catalogA.profiles.isEmpty == catalogB.profiles.isEmpty)
        #expect(catalogA.issues == catalogB.issues)
        #expect(catalogA.brokenClaims.count == 1 && catalogB.brokenClaims.count == 1)
        #expect(catalogA.brokenClaims[0].extensions == catalogB.brokenClaims[0].extensions)
        #expect(catalogA.brokenClaims[0].blocks(sample: "", basename: "thing.csv") ==
                catalogB.brokenClaims[0].blocks(sample: "", basename: "thing.csv"))
        // ...but the invalid profile bytes differ, so the fingerprints differ.
        #expect(catalogA.fingerprint != catalogB.fingerprint)
        // And the raw byte digest is present on the broken claim.
        #expect(catalogA.brokenClaims[0].contentSHA256.count == 64)
    }

    @Test func symlinkedRawviewNamespaceIsRejectedWithoutTraversal() async throws {
        let (root, project) = try makeCacheProject(rowCount: 300)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = MeasurementCache(project: project, limitBytes: 512 * 1024 * 1024)
        let source = try #require(try project.discoverSources().first)
        let measurement = try await loadMeasurement(source, project: project)
        try storeViaDescriptor(cache, measurement: measurement, source: source, project: project, fingerprint: "fp-1")
        #expect(try cache.usage().entryCount == 1)

        // Replace the whole rawview namespace with a link out of the project;
        // an outside sentinel must survive untouched.
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("rawview-escape-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("sentinel".utf8).write(to: outside.appendingPathComponent("sentinel.txt"))
        let rawview = try URL(fileURLWithPath: cache.usage().root, isDirectory: true)
        try FileManager.default.removeItem(at: rawview)
        try FileManager.default.createSymbolicLink(at: rawview, withDestinationURL: outside)

        // Lookup, usage, clear, and further writes are no-ops; nothing traverses.
        #expect(try cache.measurement(for: source, project: project, profileFingerprint: "fp-1") == nil)
        let brokenUsage = try cache.usage()
        #expect(brokenUsage.entryCount == 0 && brokenUsage.usedBytes == 0)
        try cache.clear()
        try storeViaDescriptor(cache, measurement: measurement, source: source, project: project, fingerprint: "fp-2")
        #expect(try FileManager.default.subpathsOfDirectory(atPath: outside.path) == ["sentinel.txt"],
                "cache operations traversed the symlinked namespace")
    }

    @Test func unsafeExistingCacheDirectoryFailsClosedWithoutRepair() async throws {
        let (root, project) = try makeCacheProject(rowCount: 300)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = MeasurementCache(project: project, limitBytes: 512 * 1024 * 1024)
        let source = try #require(try project.discoverSources().first)
        let measurement = try await loadMeasurement(source, project: project)
        try storeViaDescriptor(cache, measurement: measurement, source: source, project: project, fingerprint: "fp-1")
        #expect(try cache.usage().entryCount == 1)
        let cacheRoot = URL(fileURLWithPath: try cache.usage().root, isDirectory: true)
        let prefix = try #require(try FileManager.default.contentsOfDirectory(atPath: cacheRoot.path).first)
        let prefixURL = cacheRoot.appendingPathComponent(prefix)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: prefixURL.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: prefixURL.path) }
        // A pre-existing permissive RawView-owned directory fails closed: no
        // chmod repair, no lookup hit; usage still accounts the entry on disk.
        #expect(try cache.measurement(for: source, project: project, profileFingerprint: "fp-1") == nil)
        let perms = (try FileManager.default.attributesOfItem(atPath: prefixURL.path)[.posixPermissions] as? NSNumber)?.intValue ?? 0
        #expect(perms & 0o077 != 0)
        try storeViaDescriptor(cache, measurement: measurement, source: source, project: project, fingerprint: "fp-2")
        #expect((try FileManager.default.attributesOfItem(atPath: prefixURL.path)[.posixPermissions] as? NSNumber)?.intValue ?? 0 & 0o077 != 0)
        #expect(try cache.measurement(for: source, project: project, profileFingerprint: "fp-2") == nil)
    }

    @Test func symlinkedPayloadIsNotFollowed() async throws {
        let (root, project) = try makeCacheProject(rowCount: 300)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = MeasurementCache(project: project, limitBytes: 512 * 1024 * 1024)
        let source = try #require(try project.discoverSources().first)
        let measurement = try await loadMeasurement(source, project: project)
        try storeViaDescriptor(cache, measurement: measurement, source: source, project: project, fingerprint: "fp-1")
        #expect(try cache.measurement(for: source, project: project, profileFingerprint: "fp-1") != nil)
        let cacheRoot = URL(fileURLWithPath: try cache.usage().root, isDirectory: true)
        var payloadURL: URL?
        for prefix in try FileManager.default.contentsOfDirectory(atPath: cacheRoot.path) {
            let prefixURL = cacheRoot.appendingPathComponent(prefix)
            for key in (try? FileManager.default.contentsOfDirectory(atPath: prefixURL.path)) ?? [] {
                let candidate = prefixURL.appendingPathComponent(key).appendingPathComponent("payload")
                if FileManager.default.fileExists(atPath: candidate.path) { payloadURL = candidate }
            }
        }
        let victim = try #require(payloadURL)
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("rawview-payload-escape-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outside) }
        try Data("sentinel".utf8).write(to: outside.appendingPathComponent("sentinel.txt"))
        try FileManager.default.removeItem(at: victim)
        try FileManager.default.createSymbolicLink(at: victim, withDestinationURL: outside.appendingPathComponent("sentinel.txt"))
        // Lookup misses and a rebuild never writes through the link.
        #expect(try cache.measurement(for: source, project: project, profileFingerprint: "fp-1") == nil)
        try storeViaDescriptor(cache, measurement: measurement, source: source, project: project, fingerprint: "fp-1")
        #expect(try Data(contentsOf: outside.appendingPathComponent("sentinel.txt")) == Data("sentinel".utf8))
    }

    @Test func corruptPayloadShapeIsAMissNotATrap() async throws {
        let (root, project) = try makeCacheProject()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try #require(try project.discoverSources().first)
        let measurement = try await loadMeasurement(source, project: project)

        // Misshape the payload after a valid encode: 2 channels declared, 1 value array.
        var payload = MeasurementCache.MeasurementPayload(measurement: measurement)
        payload.channelValueBytes = [payload.channelValueBytes[0]]
        let encoded = try PropertyListEncoder().encode(payload)
        #expect(throws: ContractError.self) {
            try MeasurementCache.decode(measurement: encoded)
        }
    }

    @Test func malformedPackedPayloadFailsClosed() throws {
        let original = syntheticMeasurement
        func encodedPayload(_ mutate: (inout MeasurementCache.MeasurementPayload) -> Void) throws -> Data {
            var payload = MeasurementCache.MeasurementPayload(measurement: original)
            mutate(&payload)
            return try PropertyListEncoder().encode(payload)
        }
        // Truncated value bytes: length is no longer a multiple of 8.
        #expect(throws: ContractError.self) {
            try MeasurementCache.decode(measurement: try encodedPayload { $0.channelValueBytes[0].removeLast() })
        }
        // Mismatched lengths: value bytes and gap codes disagree on the row count.
        #expect(throws: ContractError.self) {
            try MeasurementCache.decode(measurement: try encodedPayload { $0.channelGapCodes[0].removeLast() })
        }
        // Invalid gap code is rejected instead of guessing a reason.
        #expect(throws: ContractError.self) {
            try MeasurementCache.decode(measurement: try encodedPayload { $0.channelGapCodes[0][4] = 99 })
        }
        // Gap slots must use zero bytes: non-zero bytes for a gap fail closed.
        #expect(throws: ContractError.self) {
            try MeasurementCache.decode(measurement: try encodedPayload { $0.channelValueBytes[0][4 * 8] = 1 })
        }
    }

    @Test func packedCodecKeepsNilGapReasonDistinctFromUnknown() throws {
        let original = syntheticMeasurement
        let restored = try MeasurementCache.decode(measurement: try MeasurementCache.encode(measurement: original))
        // Voltage row 5 is a nil gap reason; current row 7 is `.unknown`: they
        // must not collapse (the benchmark shared one code for both).
        #expect(restored.channels[0].values[5] == nil && restored.channels[0].gapReasons[5] == nil)
        #expect(restored.channels[1].values[7] == nil && restored.channels[1].gapReasons[7] == .unknown)
    }

    @Test func presentNonFiniteSamplesAreInvalid() throws {
        // Present NaN/infinity are never valid present samples; recorded
        // non-finite source cells are gaps.
        for value in [Double.nan, Double.infinity, -Double.infinity] {
            let measurement = NormalizedMeasurement(
                source: SourceIdentity(path: "data/raw/synth.csv", sha256: String(repeating: "a", count: 64)),
                instrument: InstrumentIdentity(id: "synth", name: "Synth"),
                applicationMode: "dual-sweep",
                view: MeasurementView(kind: "xy", x: "voltage", y: ["current"], preserveOrder: true),
                channels: [MeasurementChannel(name: "voltage", label: "Voltage", unit: "V", quantity: "voltage",
                                              values: [value], gapReasons: [nil])],
                metadataSections: [], warnings: [], supportStatus: "supported", provenance: [:])
            #expect(throws: ContractError.self) { try MeasurementCache.encode(measurement: measurement) }
        }
    }

    @Test func forgedNonFinitePresentSampleFailsClosed() throws {
        var payload = MeasurementCache.MeasurementPayload(measurement: syntheticMeasurement)
        let bits = Double.nan.bitPattern
        for offset in 0..<8 { payload.channelValueBytes[0][offset] = UInt8((bits >> (offset * 8)) & 0xFF) }
        payload.channelGapCodes[0][0] = 0
        let encoded = try PropertyListEncoder().encode(payload)
        #expect(throws: ContractError.self) { try MeasurementCache.decode(measurement: encoded) }
    }
}
