import CryptoKit
import Foundation
import Testing
@testable import RawViewCore

/// Overlay eligibility boundary: selected project -> versioned profiles ->
/// full normalized arrays -> exact-manifest membership + quantity/unit match.
/// Synthetic fixtures only; category labels never establish membership.
struct OverlayEligibilityTests {
    @Test func manifestAcceptsSourcesListAtParentIndent() throws {
        let root = try makeOverlayProject(
            profiles: ["keysight-b1500a.yaml": Fixtures.keysightProfile],
            sources: ["data/raw/a.csv": Data(syntheticCSV(values: [(0, 1e-12)]).utf8)],
            manifests: ["study.yaml": "study_id: synth-study-1\nsources:\n- path: data/raw/a.csv\n"]
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let project = try ProjectContext.open(root)
        let index = ManifestIndex.load(project: project)

        #expect(index.issues.isEmpty)
        #expect(index.manifests.count == 1)
        #expect(index.manifests.first?.members == ["data/raw/a.csv"])
    }

    @Test func manifestDiscoveryIgnoresDerivedCacheYAML() async throws {
        let source = Data(syntheticCSV(values: [(0, 1e-12)]).utf8)
        let root = try makeOverlayProject(
            profiles: ["keysight-b1500a.yaml": Fixtures.keysightProfile],
            sources: ["data/raw/a.csv": source],
            manifests: ["data/.cache/rawview/forged.yaml": manifest(studyID: "cache-only", paths: ["data/raw/a.csv"])]
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let project = try ProjectContext.open(root)
        let index = ManifestIndex.load(project: project)

        #expect(index.manifests.isEmpty, "derived cache files must not establish overlay membership")
    }

    @Test func unrelatedProjectYAMLDoesNotCreateManifestWarnings() throws {
        let root = try makeOverlayProject(
            profiles: ["keysight-b1500a.yaml": Fixtures.keysightProfile],
            sources: ["data/raw/a.csv": Data(syntheticCSV(values: [(0, 1e-12)]).utf8)],
            manifests: ["history/study.yaml": "study_id: archived-study\nstatus: completed\n",
                        "metadata/sources.yaml": "sources:\n  - id: legacy\n"]
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let index = ManifestIndex.load(project: try ProjectContext.open(root))

        #expect(index.manifests.isEmpty)
        #expect(index.issues.isEmpty)
    }

    @Test func sameManifestAcceptsCompatibleSourcesPreservingFullArrays() async throws {
        let csvA = syntheticCSV(values: [(0, 1e-12), (0.1, 2e-12), (0.2, nil)])
        let csvB = syntheticCSV(values: [(0, 3e-12), (0.1, 4e-12), (0.2, 5e-12)])
        let root = try makeOverlayProject(
            profiles: ["keysight-b1500a.yaml": Fixtures.keysightProfile],
            sources: ["data/raw/a.csv": Data(csvA.utf8), "data/raw/b.csv": Data(csvB.utf8)],
            manifests: ["study.yaml": manifest(studyID: "synth-study-1", paths: ["data/raw/a.csv", "data/raw/b.csv"])]
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let project = try ProjectContext.open(root)
        let sources = try project.discoverSources()
        let measurements = try await loadAll(sources, project: project)
        #expect(measurements.count == 2)
        let index = ManifestIndex.load(project: project)
        #expect(index.issues.isEmpty)
        let result = OverlayEvaluator.evaluate(measurements: measurements, manifests: index.manifests)
        guard case .eligible(let manifestPath) = result else {
            Issue.record("same-manifest pair blocked: \(result)")
            return
        }
        #expect(manifestPath == "study.yaml")
        // Full arrays preserved in acquisition order, gaps kept, no transforms.
        let a = try #require(measurements.first { $0.source.path == "data/raw/a.csv" })
        #expect(a.channel(named: "voltage")?.values == [0, 0.1, 0.2])
        #expect(a.channel(named: "current")?.values == [1e-12, 2e-12, nil])
        #expect(a.channel(named: "current")?.gapCount == 1)
        let b = try #require(measurements.first { $0.source.path == "data/raw/b.csv" })
        #expect(b.channel(named: "voltage")?.values == [0, 0.1, 0.2])
        // Visibility filters presentation only; measurements unchanged.
        let visible = OverlayEvaluator.visible(measurements: measurements, hidden: ["data/raw/b.csv"])
        #expect(visible.count == 1 && visible[0].source.path == "data/raw/a.csv")
        #expect(measurements.count == 2)
    }

    @Test func sameStudyIDDifferentManifestsRejects() async throws {
        let root = try makeOverlayProject(
            profiles: ["keysight-b1500a.yaml": Fixtures.keysightProfile],
            sources: ["data/raw/a.csv": Data(syntheticCSV(values: [(0, 1e-12)]).utf8),
                      "data/raw/b.csv": Data(syntheticCSV(values: [(0, 2e-12)]).utf8)],
            manifests: ["one.yaml": manifest(studyID: "synth-study-1", paths: ["data/raw/a.csv"]),
                        "two.yaml": manifest(studyID: "synth-study-1", paths: ["data/raw/b.csv"])]
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let project = try ProjectContext.open(root)
        let measurements = try await loadAll(try project.discoverSources(), project: project)
        let result = OverlayEvaluator.evaluate(measurements: measurements, manifests: ManifestIndex.load(project: project).manifests)
        guard case .blocked(let reason) = result else {
            Issue.record("same-ID different manifests accepted")
            return
        }
        #expect(reason.contains("different manifests"))
        // Focused valid source is retained for single-source display.
        #expect(OverlaySelection.focused(selected: ["data/raw/a.csv", "data/raw/b.csv"], current: "data/raw/b.csv") == "data/raw/b.csv")
        #expect(OverlaySelection.focused(selected: ["data/raw/b.csv"], current: nil) == "data/raw/b.csv")
    }

    @Test func missingMembershipBlocksWholeComparison() async throws {
        let root = try makeOverlayProject(
            profiles: ["keysight-b1500a.yaml": Fixtures.keysightProfile],
            sources: ["data/raw/a.csv": Data(syntheticCSV(values: [(0, 1e-12)]).utf8),
                      "data/raw/b.csv": Data(syntheticCSV(values: [(0, 2e-12)]).utf8)],
            manifests: ["study.yaml": manifest(studyID: "synth-study-1", paths: ["data/raw/a.csv"])]
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let project = try ProjectContext.open(root)
        let measurements = try await loadAll(try project.discoverSources(), project: project)
        let result = OverlayEvaluator.evaluate(measurements: measurements, manifests: ManifestIndex.load(project: project).manifests)
        guard case .blocked(let reason) = result else {
            Issue.record("missing membership accepted")
            return
        }
        #expect(reason.contains("data/raw/b.csv"))
    }

    @Test func ambiguousMembershipBlocks() async throws {
        let root = try makeOverlayProject(
            profiles: ["keysight-b1500a.yaml": Fixtures.keysightProfile],
            sources: ["data/raw/a.csv": Data(syntheticCSV(values: [(0, 1e-12)]).utf8),
                      "data/raw/b.csv": Data(syntheticCSV(values: [(0, 2e-12)]).utf8)],
            manifests: ["one.yaml": manifest(studyID: "synth-study-1", paths: ["data/raw/a.csv", "data/raw/b.csv"]),
                        "two.yaml": manifest(studyID: "synth-study-2", paths: ["data/raw/b.csv"])]
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let project = try ProjectContext.open(root)
        let measurements = try await loadAll(try project.discoverSources(), project: project)
        let result = OverlayEvaluator.evaluate(measurements: measurements, manifests: ManifestIndex.load(project: project).manifests)
        guard case .blocked(let reason) = result else {
            Issue.record("ambiguous membership accepted")
            return
        }
        #expect(reason.contains("data/raw/b.csv"))
    }

    @Test func readerDrivenQuantityMismatchBlocks() async throws {
        let root = try makeOverlayProject(
            profiles: ["keysight-b1500a.yaml": Fixtures.keysightProfile, "fixture-dat.yaml": Fixtures.dataProfile],
            sources: ["data/raw/a.csv": Data(syntheticCSV(values: [(0, 1e-12)]).utf8),
                      "data/raw/b.dat": Data(Fixtures.dataCSV.utf8)],
            manifests: ["study.yaml": manifest(studyID: "synth-study-1", paths: ["data/raw/a.csv", "data/raw/b.dat"])]
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let project = try ProjectContext.open(root)
        let measurements = try await loadAll(try project.discoverSources(), project: project)
        #expect(measurements.count == 2)
        let result = OverlayEvaluator.evaluate(measurements: measurements, manifests: ManifestIndex.load(project: project).manifests)
        guard case .blocked(let reason) = result else {
            Issue.record("reader-driven quantity mismatch accepted")
            return
        }
        #expect(reason.contains("X mismatch") || reason.contains("Y mismatch") || reason.contains("quantity") || reason.contains("unit"))
    }

    @Test func unitAndQuantityMismatchBlocks() async throws {
        // Direct quantity/unit mismatch through decoded measurements (synthetic,
        // no raw identifiers): exact units required, no conversion.
        let mA = syntheticMeasurement(path: "data/raw/a.csv", xQty: "voltage", xUnit: "V", yQty: "current", yUnit: "A")
        let mB = syntheticMeasurement(path: "data/raw/b.csv", xQty: "voltage", xUnit: "mV", yQty: "current", yUnit: "A")
        let blockedUnits = OverlayEvaluator.evaluate(
            measurements: [mA, mB],
            manifests: [StudyManifest(relativePath: "study.yaml", studyID: "synth-study-1",
                                      members: ["data/raw/a.csv", "data/raw/b.csv"])]
        )
        guard case .blocked(let reason) = blockedUnits else {
            Issue.record("unit mismatch accepted")
            return
        }
        #expect(reason.contains("unit") || reason.contains("Unit"))
        let unspecifiedA = syntheticMeasurement(path: "data/raw/u1.csv", xQty: "time", xUnit: "s", yQty: "signal_1", yUnit: "unspecified")
        let unspecifiedB = syntheticMeasurement(path: "data/raw/u2.csv", xQty: "time", xUnit: "s", yQty: "signal_1", yUnit: "unspecified")
        let blockedUnspecified = OverlayEvaluator.evaluate(
            measurements: [unspecifiedA, unspecifiedB],
            manifests: [StudyManifest(relativePath: "study.yaml", studyID: "synth-study-1",
                                      members: ["data/raw/u1.csv", "data/raw/u2.csv"])]
        )
        guard case .blocked(let unspecifiedReason) = blockedUnspecified else {
            Issue.record("unspecified units accepted")
            return
        }
        #expect(unspecifiedReason.lowercased().contains("unspecified"))
        let mC = syntheticMeasurement(path: "data/raw/c.csv", xQty: "voltage", xUnit: "V", yQty: "charge", yUnit: "A")
        let blockedQty = OverlayEvaluator.evaluate(
            measurements: [mA, mC],
            manifests: [StudyManifest(relativePath: "study.yaml", studyID: "synth-study-1",
                                      members: ["data/raw/a.csv", "data/raw/c.csv"])]
        )
        guard case .blocked(let qtyReason) = blockedQty else {
            Issue.record("quantity mismatch accepted")
            return
        }
        #expect(qtyReason.contains("quantity") || qtyReason.contains("Quantity"))
        // Missing declarations block.
        let mMissing = syntheticMeasurement(path: "data/raw/d.csv", xQty: nil, xUnit: "V", yQty: "current", yUnit: "A")
        let blockedMissing = OverlayEvaluator.evaluate(
            measurements: [mA, mMissing],
            manifests: [StudyManifest(relativePath: "study.yaml", studyID: "synth-study-1",
                                      members: ["data/raw/a.csv", "data/raw/d.csv"])]
        )
        #expect(ifBlocked(blockedMissing))
    }

    @Test func manifestRelativePathsResolveAndMalformedFailsClosed() async throws {
        let root = try makeOverlayProject(
            profiles: ["keysight-b1500a.yaml": Fixtures.keysightProfile],
            sources: ["data/raw/a.csv": Data(syntheticCSV(values: [(0, 1e-12)]).utf8),
                      "data/raw/b.csv": Data(syntheticCSV(values: [(0, 2e-12)]).utf8)],
            manifests: ["manifests/study.yaml": manifest(studyID: "synth-study-1",
                                                         paths: ["../data/raw/a.csv", "../data/raw/b.csv"])]
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let project = try ProjectContext.open(root)
        let index = ManifestIndex.load(project: project)
        #expect(index.manifests.count == 1)
        #expect(index.manifests[0].members == ["data/raw/a.csv", "data/raw/b.csv"])
        let measurements = try await loadAll(try project.discoverSources(), project: project)
        #expect(ifEligible(OverlayEvaluator.evaluate(measurements: measurements, manifests: index.manifests)))

        // Malformed manifest (missing study_id) is skipped fail-closed.
        let badRoot = try makeOverlayProject(
            profiles: ["keysight-b1500a.yaml": Fixtures.keysightProfile],
            sources: ["data/raw/a.csv": Data(syntheticCSV(values: [(0, 1e-12)]).utf8)],
            manifests: ["bad.yaml": "study_id:\nsources:\n  - path: data/raw/a.csv\n"]
        )
        defer { try? FileManager.default.removeItem(at: badRoot) }
        let badProject = try ProjectContext.open(badRoot)
        let badIndex = ManifestIndex.load(project: badProject)
        #expect(badIndex.manifests.isEmpty)
        #expect(badIndex.issues.contains { $0.contains("bad.yaml") })
    }

    @Test func categoryLabelsNeverEstablishMembership() async throws {
        // Two sources share a filename category token but no manifest lists both.
        let csv = syntheticCSV(values: [(0, 1e-12)])
        let root = try makeOverlayProject(
            profiles: ["keysight-b1500a.yaml": Fixtures.keysightProfile],
            sources: ["data/raw/run_[dev]_iv.dual-sweep.csv": Data(csv.utf8),
                      "data/raw/other_[dev]_iv.dual-sweep.csv": Data(csv.utf8)],
            manifests: ["study.yaml": manifest(studyID: "synth-study-1", paths: ["data/raw/run_[dev]_iv.dual-sweep.csv"])]
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let project = try ProjectContext.open(root)
        let measurements = try await loadAll(try project.discoverSources(), project: project)
        #expect(measurements.count == 2)
        let result = OverlayEvaluator.evaluate(measurements: measurements, manifests: ManifestIndex.load(project: project).manifests)
        #expect(ifBlocked(result))
    }
}

private func ifBlocked(_ value: OverlayEligibility) -> Bool {
    if case .blocked = value { return true }
    return false
}

private func ifEligible(_ value: OverlayEligibility) -> Bool {
    if case .eligible = value { return true }
    return false
}

private func syntheticCSV(values: [(Double, Double?)]) -> String {
    var lines = ["SetupTitle, 2-terminal dual Vsweep", "DataName, V1, I1"]
    for (v, i) in values {
        if let i { lines.append("DataValue, \(v), \(i)") }
        else { lines.append("DataValue, \(v), ") }
    }
    return lines.joined(separator: "\n") + "\n"
}

private func manifest(studyID: String, paths: [String]) -> String {
    "study_id: \(studyID)\nsources:\n" + paths.map { "  - path: \($0)\n" }.joined()
}

private func syntheticMeasurement(path: String, xQty: String?, xUnit: String, yQty: String?, yUnit: String) -> NormalizedMeasurement {
    NormalizedMeasurement(
        source: SourceIdentity(path: path, sha256: String(repeating: "a", count: 64)),
        instrument: InstrumentIdentity(id: "synth", name: "Synth"),
        applicationMode: "dual-sweep",
        view: MeasurementView(kind: "xy", x: "voltage", y: ["current"], preserveOrder: true),
        channels: [
            MeasurementChannel(name: "voltage", label: "Voltage", unit: xUnit, quantity: xQty, values: [0, 0.1]),
            MeasurementChannel(name: "current", label: "Current", unit: yUnit, quantity: yQty, values: [1e-12, 2e-12]),
        ],
        metadataSections: [], warnings: [], supportStatus: "supported", provenance: [:]
    )
}

private func loadAll(_ sources: [RawSource], project: ProjectContext) async throws -> [NormalizedMeasurement] {
    var out: [NormalizedMeasurement] = []
    for source in sources.sorted(by: { $0.relativePath < $1.relativePath }) {
        out.append(try await InstrumentReader.load(source.url, project: project))
    }
    return out
}

private func makeOverlayProject(profiles: [String: String], sources: [String: Data], manifests: [String: String]) throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("rawview-overlay-\(UUID().uuidString)")
    for (relativePath, data) in sources {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }
    for (name, contents) in profiles {
        let url = root.appendingPathComponent("data/instruments/\(name)")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url)
    }
    for (relativePath, contents) in manifests {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url)
    }
    return root
}
