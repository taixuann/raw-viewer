import CryptoKit
import Foundation
import Testing
@testable import RawViewCore

struct InstrumentReaderTests {
    @Test func loadsKeysightDualSweepPreservingEveryPointInFileOrder() async throws {
        let profile = Fixtures.keysightProfile
        let csv = Fixtures.dualSweepCSV
        let root = try makeProject(profiles: ["keysight-b1500a.yaml": profile], sources: ["data/raw/2026-06-24/dual-sweep.csv": Data(csv.utf8)])
        defer { try? FileManager.default.removeItem(at: root) }

        let project = try ProjectContext.open(root)
        let sources = try project.discoverSources()
        #expect(sources.map(\.relativePath) == ["data/raw/2026-06-24/dual-sweep.csv"])

        let report = await InstrumentReader.inspectMany(sources, project: project)
        #expect(report.profileIssues.isEmpty)
        let result = try #require(report.results.first)
        let inspection = try #require(result.inspection)
        #expect(result.error == nil)
        #expect(inspection.instrumentID == "keysight-b1500a")
        #expect(inspection.instrumentName == "Keysight B1500A Semiconductor Device Parameter Analyzer")
        #expect(inspection.applicationMode == "dual-sweep")
        #expect(inspection.supportStatus == "supported")
        #expect(inspection.profileHash == sha256Hex(Data(profile.utf8)))

        let measurement = try await InstrumentReader.load(sources[0].url, project: project)
        let voltage = try #require(measurement.channel(named: "voltage"))
        let current = try #require(measurement.channel(named: "current"))

        // Every DataValue row appears exactly once, in file order; the reversal is not sorted.
        #expect(voltage.values == [0, 0.1, 0.2, 0.1, 0])
        #expect(current.values == [1e-12, 2e-12, 3e-12, 4e-12, 5e-12])
        #expect(voltage.quantity == "voltage")
        #expect(voltage.unit == "V")
        #expect(current.quantity == "current")
        #expect(current.unit == "A")
        #expect(measurement.view.kind == "xy")
        #expect(measurement.view.x == "voltage")
        #expect(measurement.view.y == ["current"])
        #expect(measurement.view.preserveOrder)
        #expect(measurement.source.path == "data/raw/2026-06-24/dual-sweep.csv")
        #expect(measurement.source.sha256 == sha256Hex(Data(csv.utf8)))
        #expect(measurement.provenance["profile_id"] == "keysight-b1500a")
        #expect(measurement.provenance["profile_hash"] == sha256Hex(Data(profile.utf8)))
        #expect(measurement.provenance["reader_version"] == InstrumentReader.version)
        #expect(measurement.supportStatus == "supported")
    }

    @Test func handlesCRLFLineEndingsInSourceAndProfile() async throws {
        let profile = Fixtures.keysightProfile.replacingOccurrences(of: "\n", with: "\r\n")
        let csv = Fixtures.dualSweepCSV.replacingOccurrences(of: "\n", with: "\r\n")
        let root = try makeProject(profiles: ["keysight-b1500a.yaml": profile], sources: ["data/raw/dual.csv": Data(csv.utf8)])
        defer { try? FileManager.default.removeItem(at: root) }
        let project = try ProjectContext.open(root)
        let sources = try project.discoverSources()
        let report = await InstrumentReader.inspectMany(sources, project: project)
        #expect(report.results.first?.inspection?.applicationMode == "dual-sweep")
        let measurement = try await InstrumentReader.load(sources[0].url, project: project)
        #expect(measurement.channel(named: "voltage")?.values == [0, 0.1, 0.2, 0.1, 0])
        #expect(measurement.channel(named: "current")?.values == [1e-12, 2e-12, 3e-12, 4e-12, 5e-12])
    }

    @Test func unversionedProfileBlocksAffectedSourceWithoutRewritingProfile() async throws {
        let profile = Fixtures.unversionedKeysightProfile
        let root = try makeProject(profiles: ["keysight-b1500a.yaml": profile], sources: ["data/raw/dual.csv": Data(Fixtures.dualSweepCSV.utf8)])
        defer { try? FileManager.default.removeItem(at: root) }
        let profileURL = root.appendingPathComponent("data/instruments/keysight-b1500a.yaml")
        let before = try Data(contentsOf: profileURL)

        let project = try ProjectContext.open(root)
        let sources = try project.discoverSources()
        let report = await InstrumentReader.inspectMany(sources, project: project)
        let error = try #require(report.results.first?.error)
        #expect(error.contains("data/instruments/keysight-b1500a.yaml"))
        #expect(error.contains("unversioned"))
        #expect(error.contains("schema_version: 1"))
        #expect(report.results.first?.inspection == nil)
        await #expect(throws: ReaderError.self) {
            try await InstrumentReader.load(sources[0].url, project: project)
        }
        #expect(try Data(contentsOf: profileURL) == before)
    }

    @Test func unversionedDiagnosticWinsOverEncodingFailure() async throws {
        var bytes = Data("DataName, V1, I1\nDataValue, 0, 1\n".utf8)
        bytes.append(0xE9) // cp1252-only byte; not valid UTF-8
        let root = try makeProject(profiles: ["keysight-b1500a.yaml": Fixtures.unversionedKeysightProfile], sources: ["data/raw/dual.csv": bytes])
        defer { try? FileManager.default.removeItem(at: root) }
        let project = try ProjectContext.open(root)
        let sources = try project.discoverSources()
        let report = await InstrumentReader.inspectMany(sources, project: project)
        let error = try #require(report.results.first?.error)
        #expect(error.contains("unversioned"))
        await #expect(throws: ReaderError.self) {
            try await InstrumentReader.load(sources[0].url, project: project)
        }
    }

    @Test func sameIndentListMarkersFailWithLinePreciseDiagnostic() async throws {
        let profile = """
        schema_version: 1
        instrument:
          id: keysight-b1500a
          name: Keysight B1500A
        formats:
        - id: csv
          kind: tabular
        """
        let root = try makeProject(profiles: ["keysight-b1500a.yaml": profile], sources: ["data/raw/a.csv": Data(Fixtures.dualSweepCSV.utf8)])
        defer { try? FileManager.default.removeItem(at: root) }
        let project = try ProjectContext.open(root)
        let report = await InstrumentReader.inspectMany(try project.discoverSources(), project: project)
        // No selectors are recoverable, so the profile stays visible globally with
        // a line-precise error while the source reports no usable profile.
        #expect(report.profileIssues.contains { $0.contains("data/instruments/keysight-b1500a.yaml") && $0.contains("line 6") && $0.contains("list") })
        let result = try #require(report.results.first)
        #expect(result.inspection == nil)
        #expect(result.error != nil)
    }

    @Test func schemaRejectsUnknownKeysAtEveryScope() async throws {
        let scopes: [(name: String, anchor: String, insert: String, fragment: String)] = [
            ("root.yaml", "model: B1500A\n", "description: extra root key\n", "unknown key \"description\""),
            ("instrument.yaml", "  model: B1500A\n", "  nickname: b1500\n", "instrument.nickname"),
            ("format.yaml", "    kind: tabular\n", "    support: validated\n", "formats[0].support"),
            ("rows.yaml", "      data_prefix: \"DataValue\"\n", "      comment: sizes\n", "formats[0].rows.comment"),
            ("column.yaml", "        unit: \"V\"\n", "        required: true\n", "formats[0].columns.voltage.required"),
            ("mode.yaml", "    format: csv\n", "    summary: iv\n", "modes[0].summary"),
        ]
        for scope in scopes {
            let profile = Fixtures.keysightProfile.replacingOccurrences(of: scope.anchor, with: scope.anchor + scope.insert)
            let root = try makeProject(profiles: [scope.name: profile], sources: ["data/raw/a.csv": Data(Fixtures.dualSweepCSV.utf8)])
            defer { try? FileManager.default.removeItem(at: root) }
            let project = try ProjectContext.open(root)
            let report = await InstrumentReader.inspectMany(try project.discoverSources(), project: project)
            #expect(report.results.first?.inspection == nil, "profile \(scope.name) was accepted")
            #expect(report.results.first?.error?.contains(scope.fragment) == true, "profile \(scope.name) should report \(scope.fragment)")
        }
    }

    @Test func unsupportedSchemaVersionIsRejectedWithActionableDiagnostic() async throws {
        let profile = Fixtures.keysightProfile.replacingOccurrences(of: "schema_version: 1", with: "schema_version: 2")
        let root = try makeProject(profiles: ["keysight-b1500a.yaml": profile], sources: ["data/raw/dual.csv": Data(Fixtures.dualSweepCSV.utf8)])
        defer { try? FileManager.default.removeItem(at: root) }
        let report = await InstrumentReader.inspectMany(try ProjectContext.open(root).discoverSources(), project: try ProjectContext.open(root))
        let error = try #require(report.results.first?.error)
        #expect(error.contains("unsupported schema_version 2"))
        #expect(error.contains("supports schema_version 1"))
    }

    @Test func invalidProfileFieldNamesTheProfileAndField() async throws {
        let root = try makeProject(profiles: ["missing-unit.yaml": Fixtures.missingUnitProfile], sources: ["data/raw/dual.csv": Data(Fixtures.dualSweepCSV.utf8)])
        defer { try? FileManager.default.removeItem(at: root) }
        let project = try ProjectContext.open(root)
        let report = await InstrumentReader.inspectMany(try project.discoverSources(), project: project)
        let error = try #require(report.results.first?.error)
        #expect(error.contains("data/instruments/missing-unit.yaml"))
        #expect(error.contains("formats[0].columns.voltage.unit is required"))
    }

    @Test func malformedProfileIsVisibleWithoutBlockingOtherSources() async throws {
        let root = try makeProject(
            profiles: ["broken.yaml": Fixtures.malformedProfile, "fixture-dat.yaml": Fixtures.dataProfile],
            sources: ["data/raw/a.csv": Data(Fixtures.dualSweepCSV.utf8), "data/raw/b.dat": Data(Fixtures.dataCSV.utf8)]
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let project = try ProjectContext.open(root)
        let sources = try project.discoverSources()
        let report = await InstrumentReader.inspectMany(sources, project: project)
        #expect(report.profileIssues.contains { $0.contains("data/instruments/broken.yaml") && $0.contains("YAML parse error") })
        let datResult = try #require(report.results.first { $0.source.relativePath == "data/raw/b.dat" })
        #expect(datResult.inspection?.instrumentID == "fixture-dat")
        let measurement = try await InstrumentReader.load(datResult.source.url, project: project)
        #expect(measurement.channel(named: "x")?.values == [1, 2])
    }

    @Test func brokenProfileBlocksOnlyItsExtension() async throws {
        let root = try makeProject(
            profiles: ["keysight-b1500a.yaml": Fixtures.unversionedKeysightProfile, "fixture-dat.yaml": Fixtures.dataProfile],
            sources: ["data/raw/a.csv": Data(Fixtures.dualSweepCSV.utf8), "data/raw/b.dat": Data(Fixtures.dataCSV.utf8)]
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let project = try ProjectContext.open(root)
        let report = await InstrumentReader.inspectMany(try project.discoverSources(), project: project)
        let csvResult = try #require(report.results.first { $0.source.relativePath == "data/raw/a.csv" })
        #expect(csvResult.error?.contains("unversioned") == true)
        let datResult = try #require(report.results.first { $0.source.relativePath == "data/raw/b.dat" })
        #expect(datResult.inspection?.supportStatus == "supported")
    }

    @Test func ambiguousProfilesBlockOnlyTheAffectedSource() async throws {
        let root = try makeProject(
            profiles: [
                "keysight-b1500a.yaml": Fixtures.keysightProfile,
                "duplicate-keysight.yaml": Fixtures.keysightProfile.replacingOccurrences(of: "keysight-b1500a", with: "keysight-b1500a-copy"),
                "fixture-dat.yaml": Fixtures.dataProfile
            ],
            sources: ["data/raw/a.csv": Data(Fixtures.dualSweepCSV.utf8), "data/raw/b.dat": Data(Fixtures.dataCSV.utf8)]
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let project = try ProjectContext.open(root)
        let report = await InstrumentReader.inspectMany(try project.discoverSources(), project: project)
        let error = try #require(report.results.first { $0.source.relativePath == "data/raw/a.csv" }?.error)
        #expect(error.contains("Ambiguous"))
        #expect(error.contains("keysight-b1500a.yaml"))
        #expect(error.contains("duplicate-keysight.yaml"))
        #expect(report.results.first { $0.source.relativePath == "data/raw/b.dat" }?.inspection != nil)
    }

    @Test func unsupportedExtensionStaysVisible() async throws {
        let root = try makeProject(
            profiles: ["keysight-b1500a.yaml": Fixtures.keysightProfile],
            sources: ["data/raw/scan.ibw": Data("binary-ish".utf8)]
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let project = try ProjectContext.open(root)
        let report = await InstrumentReader.inspectMany(try project.discoverSources(), project: project)
        #expect(report.results.count == 1)
        #expect(report.results.first?.inspection == nil)
        #expect(report.results.first?.error?.contains("No instrument profile supports \".ibw\"") == true)
    }

    @Test func modeSignatureMismatchListsDeclaredModes() async throws {
        let root = try makeProject(
            profiles: ["keysight-b1500a.yaml": Fixtures.keysightProfile],
            sources: ["data/raw/other.csv": Data("SetupTitle, something else\nDataName, V1, I1\nDataValue, 0, 1E-12\n".utf8)]
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let project = try ProjectContext.open(root)
        let report = await InstrumentReader.inspectMany(try project.discoverSources(), project: project)
        let error = try #require(report.results.first?.error)
        #expect(error.contains("No mode signature matched"))
        #expect(error.contains("dual-sweep"))
    }

    @Test func extractionFailuresStayLocalToTheirSource() async throws {
        let root = try makeProject(
            profiles: ["keysight-b1500a.yaml": Fixtures.keysightProfile],
            sources: [
                "data/raw/good.csv": Data(Fixtures.dualSweepCSV.utf8),
                "data/raw/no-header.csv": Data("SetupTitle, 2-terminal dual Vsweep\nMetaData, x, y\n".utf8),
                "data/raw/bad-cell.csv": Data("SetupTitle, 2-terminal dual Vsweep\nDataName, V1, I1\nDataValue, 0, --\n".utf8)
            ]
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let project = try ProjectContext.open(root)
        let sources = try project.discoverSources()
        for source in sources {
            switch source.relativePath {
            case "data/raw/good.csv":
                let measurement = try await InstrumentReader.load(source.url, project: project)
                #expect(measurement.channel(named: "current")?.values.count == 5)
            case "data/raw/no-header.csv":
                await #expect(throws: ReaderError.self) {
                    try await InstrumentReader.load(source.url, project: project)
                }
                do {
                    _ = try await InstrumentReader.load(source.url, project: project)
                } catch {
                    #expect(error.localizedDescription.contains("no \"DataName\" header row"))
                }
            default:
                // Corrupt text ("--") is not a gap: the source must block with a
                // diagnostic naming file, line, column, and value.
                await #expect(throws: ReaderError.self) {
                    try await InstrumentReader.load(source.url, project: project)
                }
                do {
                    _ = try await InstrumentReader.load(source.url, project: project)
                    Issue.record("bad-cell.csv with corrupt text was loaded instead of blocked")
                } catch {
                    let message = error.localizedDescription
                    #expect(message.contains("line 3"))
                    #expect(message.contains("current"))
                    #expect(message.contains("--"))
                }
            }
        }
    }

    @Test func gapCellsPreserveAcquisitionRowsWithTraceableDiagnostics() async throws {
        let csv = """
        SetupTitle, 2-terminal dual Vsweep
        Dimension1, 5, 5
        DataName, V1, I1
        DataValue, 0, 1E-12
        DataValue, 0.1,
        DataValue, 0.2, NaN
        DataValue, 0.1, inf
        DataValue, 0, 5E-12
        """
        let root = try makeProject(profiles: ["keysight-b1500a.yaml": Fixtures.keysightProfile], sources: ["data/raw/gaps.csv": Data(csv.utf8)])
        defer { try? FileManager.default.removeItem(at: root) }
        let project = try ProjectContext.open(root)
        let sources = try project.discoverSources()
        let measurement = try await InstrumentReader.load(sources[0].url, project: project)
        let voltage = try #require(measurement.channel(named: "voltage"))
        let current = try #require(measurement.channel(named: "current"))
        // Every DataValue row is kept in file order; finite values are exact.
        #expect(voltage.values.count == 5)
        #expect(current.values.count == 5)
        #expect(voltage.values == [0, 0.1, 0.2, 0.1, 0])
        #expect(current.values[0] == 1e-12)
        #expect(current.values[4] == 5e-12)
        // Gaps are explicit nils, not invented numbers or dropped rows.
        #expect(current.values[1] == nil)
        #expect(current.values[2] == nil)
        #expect(current.values[3] == nil)
        #expect(voltage.gapCount == 0)
        #expect(current.gapCount == 3)
        // Raw invalid tokens stay traceable in warnings.
        #expect(measurement.warnings.contains { $0.contains("line 5") && $0.contains("current") })
        #expect(measurement.warnings.contains { $0.contains("NaN") || $0.contains("line 6") })
        // Plot segmentation breaks at gaps without interpolation.
        let x = voltage.values
        let y = current.values
        let runs = AxisTransform.segments(x: x, y: y)
        #expect(runs == [[0], [4]])
    }

    @Test func plotSegmentsBreakOnEitherChannelGap() {
        #expect(AxisTransform.segments(x: [0, 1, 2], y: [1.0, nil, 3.0]) == [[0], [2]])
        #expect(AxisTransform.segments(x: [0, nil, 2], y: [1.0, 2.0, 3.0]) == [[0], [2]])
        #expect(AxisTransform.segments(x: [nil, nil], y: [nil, nil]) == [])
        #expect(AxisTransform.segments(x: [0, 1], y: [1.0, 2.0]) == [[0, 1]])
    }

    @Test func gapIsolatedSingletonPointFormsItsOwnSegment() {
        // One finite row surrounded by gaps, and a one-row source: both yield a
        // singleton run that the plot must draw as a visible marker, not an
        // invisible zero-length line, while the gaps stay breaks.
        #expect(AxisTransform.segments(x: [nil, 0.5, nil], y: [nil, 2.0, nil]) == [[1]])
        #expect(AxisTransform.segments(x: [0.5], y: [2.0]) == [[0]])
    }

    @Test func headerAndFilenameMetadataArePreserved() async throws {
        let csv = """
        SetupTitle, 2-terminal dual Vsweep
        Dimension1, 61, 61
        MetaData, TestRecord.RecordTime, 06/24/2026 09:14:25
        DataName, V1, I1
        DataValue, 0, 1E-12
        DataValue, 0.1, 2E-12
        """
        let root = try makeProject(
            profiles: ["keysight-b1500a.yaml": Fixtures.keysightProfile],
            sources: ["data/raw/240626-091425_keysight-b1500a.dual-sweep_[cu-c-pda.q5-ito.2_r4-c5]_iv.dual-sweep.csv": Data(csv.utf8)]
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let project = try ProjectContext.open(root)
        let sources = try project.discoverSources()
        let report = await InstrumentReader.inspectMany(sources, project: project)
        let inspection = try #require(report.results.first?.inspection)
        // Filename-derived identity (read-only convention, unknown stays nil).
        #expect(inspection.timestamp == "240626-091425")
        #expect(inspection.deviceID == "cu-c-pda.q5-ito.2_r4-c5")
        #expect(inspection.category == "iv.dual-sweep")
        let measurement = try await InstrumentReader.load(sources[0].url, project: project)
        let acquisition = measurement.metadataSections.first { $0.title == "Acquisition" }
        #expect(acquisition?.fields.contains { $0.key == "SetupTitle" && $0.value.displayText.contains("2-terminal dual Vsweep") } == true)
        #expect(acquisition?.fields.contains { $0.key == "Dimension1" } == true)
        #expect(acquisition?.fields.contains { $0.value.displayText.contains("06/24/2026") } == true)
        let identity = measurement.metadataSections.first { $0.title == "Identity" }
        #expect(identity?.fields.contains { $0.key == "device_id" } == true)
        #expect(measurement.metadataSections.first { $0.title == "Data" } != nil)
    }

    @Test func validSourceStaysUsableBesideInvalidProfileWithSameExtension() async throws {
        // Same extension (.csv) claimed by both a valid and an unversioned profile
        // with provably DISTINCT detect signatures: the uniquely matched source
        // stays usable while the unmatched source reports the upgrade diagnostic.
        // The broken profile remains visible.
        let distinctBroken = Fixtures.unversionedKeysightProfile.replacingOccurrences(
            of: "detect: [\"2-terminal dual Vsweep\"]", with: "detect: [\"LEGACY-ONLY-SIG\"]")
        let root = try makeProject(
            profiles: ["keysight-b1500a.yaml": Fixtures.keysightProfile, "legacy.yaml": distinctBroken],
            sources: [
                "data/raw/good.csv": Data(Fixtures.dualSweepCSV.utf8),
                "data/raw/other.csv": Data("SetupTitle, something else\nDataName, V1, I1\nDataValue, 0, 1E-12\n".utf8)
            ]
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let project = try ProjectContext.open(root)
        let report = await InstrumentReader.inspectMany(try project.discoverSources(), project: project)
        #expect(report.profileIssues.contains { $0.contains("legacy.yaml") && $0.contains("unversioned") })
        let good = try #require(report.results.first { $0.source.relativePath == "data/raw/good.csv" })
        #expect(good.inspection?.instrumentID == "keysight-b1500a")
        let measurement = try await InstrumentReader.load(good.source.url, project: project)
        #expect(measurement.channel(named: "voltage")?.values.count == 5)
        let other = try #require(report.results.first { $0.source.relativePath == "data/raw/other.csv" })
        #expect(other.inspection == nil)
        #expect(other.error?.contains("unversioned") == true)
    }

    @Test func brokenProfileWithSameSignatureBlocksUniquelyMatchedSource() async throws {
        // The invalid profile declares the SAME detect signature the valid match
        // uses (legacy application_modes.detect.signatures shape, as in the real
        // unversioned Keysight profile): the conflict must stay blocked and
        // actionable with the profile/field path, never silently ignored.
        let root = try makeProject(
            profiles: ["keysight-b1500a.yaml": Fixtures.keysightProfile, "legacy.yaml": Fixtures.legacyUnversionedProfile],
            sources: ["data/raw/good.csv": Data(Fixtures.dualSweepCSV.utf8)]
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let project = try ProjectContext.open(root)
        let report = await InstrumentReader.inspectMany(try project.discoverSources(), project: project)
        #expect(report.profileIssues.contains { $0.contains("legacy.yaml") && $0.contains("unversioned") })
        let result = try #require(report.results.first)
        #expect(result.inspection == nil)
        #expect(result.error?.contains("data/instruments/legacy.yaml") == true)
        #expect(result.error?.contains("unversioned") == true)
        #expect(result.error?.contains("blocked until the invalid profile is fixed or removed") == true)
        await #expect(throws: ReaderError.self) {
            try await InstrumentReader.load(result.source.url, project: project)
        }
    }

    @Test func brokenProfilesDoNotBorrowEachOthersSignatures() async throws {
        let unrelatedBroken = Fixtures.unversionedKeysightProfile.replacingOccurrences(
            of: "detect: [\"2-terminal dual Vsweep\"]", with: "detect: [\"UNRELATED-SIG\"]")
        let root = try makeProject(
            profiles: [
                "keysight-b1500a.yaml": Fixtures.keysightProfile,
                "conflicting.yaml": Fixtures.unversionedKeysightProfile,
                "unrelated.yaml": unrelatedBroken,
            ],
            sources: ["data/raw/good.csv": Data(Fixtures.dualSweepCSV.utf8)]
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let project = try ProjectContext.open(root)
        let report = await InstrumentReader.inspectMany(try project.discoverSources(), project: project)
        // Both broken profiles stay visible globally.
        #expect(report.profileIssues.contains { $0.contains("conflicting.yaml") })
        #expect(report.profileIssues.contains { $0.contains("unrelated.yaml") })
        // The source conflict comes only from the profile whose own signatures
        // match it; the unrelated profile's diagnostic must not be borrowed.
        let result = try #require(report.results.first)
        #expect(result.inspection == nil)
        #expect(result.error?.contains("data/instruments/conflicting.yaml") == true)
        #expect(result.error?.contains("unrelated.yaml") == false)
    }

    @Test func unsupportedExtensionDiagnosticPrecedesDecoding() async throws {
        var bytes = Data("not utf8: ".utf8)
        bytes.append(contentsOf: [0xFF, 0xFE, 0xFD])
        let root = try makeProject(
            profiles: ["keysight-b1500a.yaml": Fixtures.keysightProfile],
            sources: ["data/raw/scan.ibw": bytes]
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let project = try ProjectContext.open(root)
        let report = await InstrumentReader.inspectMany(try project.discoverSources(), project: project)
        #expect(report.results.first?.error?.contains("No instrument profile supports \".ibw\"") == true)
    }

    @Test func schemaRejectsTransformsUnknownExtractAndNonScalarLists() async throws {
        let transformsProfile = Fixtures.keysightProfile.replacingOccurrences(
            of: "    extract:\n      x: voltage\n      y: [current]",
            with: "    extract:\n      x: voltage\n      y: [current]\n    transforms:\n      - field: current\n        operation: multiply\n        factor: -1.0"
        )
        let unknownExtractProfile = Fixtures.keysightProfile.replacingOccurrences(
            of: "      x: voltage", with: "      x: voltage\n      layout: tabular_columns")
        let nonScalarListProfile = Fixtures.keysightProfile.replacingOccurrences(
            of: "    extensions: [\".csv\"]", with: "    extensions:\n      - \".csv\"\n      - bad: map")
        for (name, profile, fragment) in [
            ("transforms.yaml", transformsProfile, "transforms"),
            ("unknown-extract.yaml", unknownExtractProfile, "extract.layout"),
            ("non-scalar.yaml", nonScalarListProfile, "must contain only strings"),
        ] {
            let root = try makeProject(profiles: [name: profile], sources: ["data/raw/a.csv": Data(Fixtures.dualSweepCSV.utf8)])
            defer { try? FileManager.default.removeItem(at: root) }
            let project = try ProjectContext.open(root)
            let report = await InstrumentReader.inspectMany(try project.discoverSources(), project: project)
            #expect(report.results.first?.error?.contains(fragment) == true, "profile \(name) should report \(fragment)")
        }
    }

    @Test func discoveryRunsOffMainThread() async throws {
        let root = try makeProject(profiles: ["keysight-b1500a.yaml": Fixtures.keysightProfile], sources: ["data/raw/a.csv": Data(Fixtures.dualSweepCSV.utf8)])
        defer { try? FileManager.default.removeItem(at: root) }
        let project = try ProjectContext.open(root)
        let direct = try project.discoverSources()
        // Exercise the production seam (cancellable, off-main) rather than a
        // test-authored detached wrapper around the sync call.
        let viaSeam = try await project.discoverSourcesAsync()
        #expect(viaSeam.map(\.relativePath) == direct.map(\.relativePath))
    }

    @Test func primaryHeaderWinsOverEarlierAlias() async throws {
        // The alias "V ALT" sits left of the primary "V1": exact primary wins.
        let profile = Fixtures.keysightProfile.replacingOccurrences(
            of: "        header: \"V1\"", with: "        header: \"V1\"\n        aliases: [\"V ALT\"]")
        let csv = """
        SetupTitle, 2-terminal dual Vsweep
        DataName, V ALT, V1, I1
        DataValue, 9, 0, 1E-12
        DataValue, 9, 0.1, 2E-12
        """
        let root = try makeProject(profiles: ["keysight-b1500a.yaml": profile], sources: ["data/raw/rank.csv": Data(csv.utf8)])
        defer { try? FileManager.default.removeItem(at: root) }
        let project = try ProjectContext.open(root)
        let measurement = try await InstrumentReader.load(try project.discoverSources()[0].url, project: project)
        #expect(measurement.channel(named: "voltage")?.values == [0, 0.1])
    }

    @Test func twoChannelsResolvingToOneColumnBlock() async throws {
        let profile = Fixtures.keysightProfile.replacingOccurrences(
            of: "      current:\n        header: \"I2\"\n        aliases: [\"I1\"]", with: "      current:\n        header: \"V1\"")
        let root = try makeProject(profiles: ["keysight-b1500a.yaml": profile], sources: ["data/raw/clash.csv": Data(Fixtures.dualSweepCSV.utf8)])
        defer { try? FileManager.default.removeItem(at: root) }
        let project = try ProjectContext.open(root)
        let report = await InstrumentReader.inspectMany(try project.discoverSources(), project: project)
        #expect(report.results.first?.inspection != nil)
        await #expect(throws: ReaderError.self) {
            try await InstrumentReader.load(try project.discoverSources()[0].url, project: project)
        }
        do {
            _ = try await InstrumentReader.load(try project.discoverSources()[0].url, project: project)
            Issue.record("two channels sharing one column loaded instead of blocked")
        } catch {
            #expect(error.localizedDescription.contains("same source column"))
        }
    }

    @Test func tableKeepsEveryDeclaredChannelWhilePlotUsesModeAxes() async throws {
        let profile = Fixtures.keysightProfile.replacingOccurrences(
            of: "      current:\n        header: \"I2\"",
            with: "      compliance:\n        header: \"C1\"\n        quantity: current\n        unit: \"A\"\n        label: \"Compliance\"\n      current:\n        header: \"I2\"")
        let csv = """
        SetupTitle, 2-terminal dual Vsweep
        DataName, V1, I1, C1
        DataValue, 0, 1E-12, 1E-6
        DataValue, 0.1, 2E-12, 2E-6
        """
        let root = try makeProject(profiles: ["keysight-b1500a.yaml": profile], sources: ["data/raw/extra.csv": Data(csv.utf8)])
        defer { try? FileManager.default.removeItem(at: root) }
        let project = try ProjectContext.open(root)
        let measurement = try await InstrumentReader.load(try project.discoverSources()[0].url, project: project)
        #expect(measurement.channels.map(\.name) == ["voltage", "compliance", "current"])
        #expect(measurement.channel(named: "compliance")?.values == [1e-6, 2e-6])
        #expect(measurement.view.x == "voltage")
        #expect(measurement.view.y == ["current"])
    }

    @Test func repeatedMetadataKeysStayUniqueWithoutDroppingValues() async throws {
        let csv = """
        SetupTitle, 2-terminal dual Vsweep
        Note, first remark
        Note, second remark
        DataName, V1, I1
        DataValue, 0, 1E-12
        """
        let root = try makeProject(profiles: ["keysight-b1500a.yaml": Fixtures.keysightProfile], sources: ["data/raw/notes.csv": Data(csv.utf8)])
        defer { try? FileManager.default.removeItem(at: root) }
        let project = try ProjectContext.open(root)
        let measurement = try await InstrumentReader.load(try project.discoverSources()[0].url, project: project)
        let acquisition = try #require(measurement.metadataSections.first { $0.title == "Acquisition" })
        let notes = acquisition.fields.filter { $0.value.displayText.contains("remark") }
        #expect(notes.count == 2)
        #expect(Set(notes.map(\.id)).count == 2)
        #expect(Set(acquisition.fields.map(\.id)).count == acquisition.fields.count)
    }

    @Test func quotedDelimiterStaysInsideOneCell() async throws {
        let csv = """
        SetupTitle, 2-terminal dual Vsweep
        Note, "said ""hi"", ok"
        DataName, V1, I1
        DataValue, "0,0", 1E-12
        DataValue, 0.1, 2E-12
        """
        let root = try makeProject(profiles: ["keysight-b1500a.yaml": Fixtures.keysightProfile], sources: ["data/raw/quoted.csv": Data(csv.utf8)])
        defer { try? FileManager.default.removeItem(at: root) }
        let project = try ProjectContext.open(root)
        await #expect(throws: ReaderError.self) {
            try await InstrumentReader.load(try project.discoverSources()[0].url, project: project)
        }
        do {
            _ = try await InstrumentReader.load(try project.discoverSources()[0].url, project: project)
            Issue.record("quoted numeric cell was silently accepted")
        } catch {
            // "0,0" is one cell whose text is not a finite number: corrupt, not a shift.
            #expect(error.localizedDescription.contains("line 4"))
            #expect(error.localizedDescription.contains("0,0"))
        }
    }

    @Test func escapedQuotesUnescapeInsideMetadata() async throws {
        let csv = """
        SetupTitle, 2-terminal dual Vsweep
        Note, "said ""hi"", ok"
        DataName, V1, I1
        DataValue, 0, 1E-12
        """
        let root = try makeProject(profiles: ["keysight-b1500a.yaml": Fixtures.keysightProfile], sources: ["data/raw/esc.csv": Data(csv.utf8)])
        defer { try? FileManager.default.removeItem(at: root) }
        let project = try ProjectContext.open(root)
        let measurement = try await InstrumentReader.load(try project.discoverSources()[0].url, project: project)
        let acquisition = try #require(measurement.metadataSections.first { $0.title == "Acquisition" })
        #expect(acquisition.fields.contains { $0.key == "Note" && $0.value.displayText == "said \"hi\", ok" })
        #expect(measurement.channel(named: "voltage")?.values == [0])
    }

    @Test func malformedQuotesBlockWithLineDiagnostic() async throws {
        let csv = """
        SetupTitle, 2-terminal dual Vsweep
        DataName, V1, I1
        DataValue, "0, 1E-12
        """
        let root = try makeProject(profiles: ["keysight-b1500a.yaml": Fixtures.keysightProfile], sources: ["data/raw/broken.csv": Data(csv.utf8)])
        defer { try? FileManager.default.removeItem(at: root) }
        let project = try ProjectContext.open(root)
        await #expect(throws: ReaderError.self) {
            try await InstrumentReader.load(try project.discoverSources()[0].url, project: project)
        }
        do {
            _ = try await InstrumentReader.load(try project.discoverSources()[0].url, project: project)
            Issue.record("unterminated quote was silently accepted")
        } catch {
            #expect(error.localizedDescription.contains("line 3"))
            #expect(error.localizedDescription.contains("unterminated quote"))
        }
    }

    @Test func gapReasonsDistinguishBlankNanInfiniteAndSaturation() async throws {
        let csv = """
        SetupTitle, 2-terminal dual Vsweep
        DataName, V1, I1
        DataValue, 0, 1E-12
        DataValue, 0.1,
        DataValue, 0.2, NaN
        DataValue, 0.3, inf
        DataValue, 0.4, 1e999
        DataValue, 0.5, 5E-12
        """
        let root = try makeProject(profiles: ["keysight-b1500a.yaml": Fixtures.keysightProfile], sources: ["data/raw/reasons.csv": Data(csv.utf8)])
        defer { try? FileManager.default.removeItem(at: root) }
        let project = try ProjectContext.open(root)
        let measurement = try await InstrumentReader.load(try project.discoverSources()[0].url, project: project)
        let current = try #require(measurement.channel(named: "current"))
        // Every row stays; finite values stay exact.
        #expect(current.values.count == 6)
        #expect(current.values[0] == 1e-12)
        #expect(current.values[5] == 5e-12)
        // Blank, recorded NaN/infinity, and overflow saturation stay distinct.
        #expect(current.gapReasons == [nil, .blank, .nan, .infinite, .saturated, nil])
        #expect(current.text(at: 1) == "—")
        #expect(current.text(at: 2) == "NaN")
        #expect(current.text(at: 3) == "∞")
        #expect(current.text(at: 4) == "sat")
        // Plot still breaks at every gap row.
        let x = try #require(measurement.channel(named: "voltage")).values
        #expect(AxisTransform.segments(x: x, y: current.values) == [[0], [5]])
    }

    @Test func missingSourceIsNotMislabeledAsOutside() async throws {
        let root = try makeProject(
            profiles: ["keysight-b1500a.yaml": Fixtures.keysightProfile],
            sources: ["data/raw/gone.csv": Data(Fixtures.dualSweepCSV.utf8)]
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let project = try ProjectContext.open(root)
        let sources = try project.discoverSources()
        try FileManager.default.removeItem(at: sources[0].url)
        await #expect(throws: ReaderError.self) {
            try await InstrumentReader.load(sources[0].url, project: project)
        }
        do {
            _ = try await InstrumentReader.load(sources[0].url, project: project)
            Issue.record("missing source loaded instead of reported")
        } catch {
            let message = error.localizedDescription
            #expect(message.contains("data/raw/gone.csv"))
            #expect(!message.contains("outside"))
        }
        let report = await InstrumentReader.inspectMany(sources, project: project)
        let message = try #require(report.results.first?.error)
        #expect(message.contains("data/raw/gone.csv"))
        #expect(!message.contains("outside"))
    }

    @Test func unreadableSourceReportsReadabilityNotOutside() async throws {
        let root = try makeProject(
            profiles: ["keysight-b1500a.yaml": Fixtures.keysightProfile],
            sources: ["data/raw/locked.csv": Data(Fixtures.dualSweepCSV.utf8)]
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let project = try ProjectContext.open(root)
        let sources = try project.discoverSources()
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: sources[0].url.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: sources[0].url.path) }
        do {
            _ = try await InstrumentReader.load(sources[0].url, project: project)
            Issue.record("unreadable source loaded instead of reported")
        } catch {
            let message = error.localizedDescription
            #expect(message.contains("data/raw/locked.csv"))
            #expect(!message.contains("outside"))
        }
    }

    @Test func headerSampleSurvivesSplitUTF8Scalar() async throws {
        // The 64 KiB sample cut lands inside a multibyte scalar: decoding must
        // back off to the scalar boundary instead of falling back to mojibake,
        // so the non-ASCII detect signature still matches.
        let profile = Fixtures.keysightProfile.replacingOccurrences(
            of: "detect: [\"2-terminal dual Vsweep\", \"dual Vsweep\"]", with: "detect: [\"café-sweep\"]")
        var head = Data("SetupTitle, café-sweep\nDataName, V1, I1\n".utf8)
        let padCount = 65536 - head.count - 1
        head.append(contentsOf: [UInt8](repeating: UInt8(ascii: "P"), count: padCount))
        head.append(contentsOf: "é\n".utf8) // é first byte lands at prefix index 65535
        let body = Data("DataValue, 0, 1E-12\nDataValue, 0.1, 2E-12\n".utf8)
        var bytes = head
        bytes.append(contentsOf: body)
        #expect(bytes.count > 65536)
        let root = try makeProject(profiles: ["keysight-b1500a.yaml": profile], sources: ["data/raw/wide.csv": bytes])
        defer { try? FileManager.default.removeItem(at: root) }
        let project = try ProjectContext.open(root)
        let sources = try project.discoverSources()
        let report = await InstrumentReader.inspectMany(sources, project: project)
        #expect(report.results.first?.inspection?.applicationMode == "dual-sweep")
        let measurement = try await InstrumentReader.load(sources[0].url, project: project)
        #expect(measurement.channel(named: "voltage")?.values == [0, 0.1])
    }

    @Test func decodingTriesOnlyDeclaredEncodings() async throws {
        // The profile declares ascii only; the valid-UTF-8 multibyte content
        // must not be rescued by an undeclared utf-8 fallback.
        let profile = Fixtures.keysightProfile.replacingOccurrences(
            of: "encoding: [utf-8, windows-1252, iso-8859-1]", with: "encoding: [ascii]")
        let bytes = Data("SetupTitle, café-sweep\nDataName, V1, I1\nDataValue, 0, 1\n".utf8)
        let root = try makeProject(profiles: ["keysight-b1500a.yaml": profile], sources: ["data/raw/enc.csv": bytes])
        defer { try? FileManager.default.removeItem(at: root) }
        let project = try ProjectContext.open(root)
        let report = await InstrumentReader.inspectMany(try project.discoverSources(), project: project)
        let error = try #require(report.results.first?.error)
        #expect(error.contains("could not be decoded"))
    }

    @Test func largeFileStreamsFullyWithoutCaps() async throws {
        var csv = "SetupTitle, 2-terminal dual Vsweep\nDataName, V1, I1\n"
        for index in 0..<200_000 {
            csv += "DataValue, \(Double(index) * 0.001), 1E-12\n"
        }
        let payload = Data(csv.utf8)
        let root = try makeProject(profiles: ["keysight-b1500a.yaml": Fixtures.keysightProfile], sources: ["data/raw/big.csv": payload])
        defer { try? FileManager.default.removeItem(at: root) }
        let project = try ProjectContext.open(root)
        let sources = try project.discoverSources()
        let measurement = try await InstrumentReader.load(sources[0].url, project: project)
        #expect(measurement.channel(named: "voltage")?.values.count == 200_000)
        #expect(measurement.channel(named: "voltage")?.values.first == 0.0)
        #expect(measurement.channel(named: "voltage")?.values.last == 199.999)
        #expect(measurement.source.sha256 == sha256Hex(payload))
    }

    @Test func loadHashesAndReadsTheSameOpenedObject() async throws {
        // The file is replaced between discovery and load: the measurement
        // must carry the replaced content together with its hash, never a mix.
        let root = try makeProject(
            profiles: ["keysight-b1500a.yaml": Fixtures.keysightProfile],
            sources: ["data/raw/swap.csv": Data(Fixtures.dualSweepCSV.utf8)]
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let project = try ProjectContext.open(root)
        let sources = try project.discoverSources()
        let replacement = Data("SetupTitle, 2-terminal dual Vsweep\nDataName, V1, I1\nDataValue, 7, 8E-12\n".utf8)
        try replacement.write(to: sources[0].url)
        let measurement = try await InstrumentReader.load(sources[0].url, project: project)
        #expect(measurement.channel(named: "voltage")?.values == [7])
        #expect(measurement.source.sha256 == sha256Hex(replacement))
    }

    @Test func relocationPreservesExtractionAndProvenance() async throws {
        let rootA = try makeProject(
            profiles: ["keysight-b1500a.yaml": Fixtures.keysightProfile],
            sources: ["data/raw/2026-06-24/dual-sweep.csv": Data(Fixtures.dualSweepCSV.utf8)]
        )
        defer { try? FileManager.default.removeItem(at: rootA) }
        let rootB = FileManager.default.temporaryDirectory.appendingPathComponent("rawview-relocated-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: rootB) }
        try FileManager.default.copyItem(at: rootA, to: rootB)

        let projectA = try ProjectContext.open(rootA)
        let projectB = try ProjectContext.open(rootB)
        let measurementA = try await InstrumentReader.load(try projectA.discoverSources()[0].url, project: projectA)
        let measurementB = try await InstrumentReader.load(try projectB.discoverSources()[0].url, project: projectB)

        #expect(measurementA.channels.map(\.name) == measurementB.channels.map(\.name))
        #expect(measurementA.channels.map(\.values) == measurementB.channels.map(\.values))
        #expect(measurementA.channels.map(\.quantity) == measurementB.channels.map(\.quantity))
        #expect(measurementA.channels.map(\.unit) == measurementB.channels.map(\.unit))
        #expect(measurementA.source.path == measurementB.source.path)
        #expect(measurementA.source.sha256 == measurementB.source.sha256)
        #expect(measurementA.provenance == measurementB.provenance)
    }

    @Test func inspectionResumeMergesBatchesWithoutLoss() async throws {
        // Models RawViewModel.resumeInspection: a cancelled run keeps its first
        // batch, and inspecting only the remainder completes every source.
        var files: [String: Data] = [:]
        for index in 0..<5 {
            files["data/raw/s\(index).csv"] = Data(Fixtures.dualSweepCSV.utf8)
        }
        let root = try makeProject(profiles: ["keysight-b1500a.yaml": Fixtures.keysightProfile], sources: files)
        defer { try? FileManager.default.removeItem(at: root) }
        let project = try ProjectContext.open(root)
        let sources = try project.discoverSources()
        let first = await InstrumentReader.inspectMany(Array(sources.prefix(2)), project: project)
        let rest = await InstrumentReader.inspectMany(Array(sources.dropFirst(2)), project: project)
        var merged: [String: SourceInspectionResult] = [:]
        for result in first.results + rest.results { merged[result.id] = result }
        #expect(merged.count == 5)
        #expect(merged.values.allSatisfy { $0.inspection != nil && $0.error == nil })
    }

    @Test func inspectionReportsProgressAndMarksRemainingSourcesCancelled() async throws {
        var sources: [String: Data] = [:]
        for index in 0..<129 {
            sources["data/raw/s\(index).dat"] = Data(Fixtures.dataCSV.utf8)
        }
        let root = try makeProject(profiles: ["fixture-dat.yaml": Fixtures.dataProfile], sources: sources)
        defer { try? FileManager.default.removeItem(at: root) }
        let project = try ProjectContext.open(root)
        let allSources = try project.discoverSources()
        #expect(allSources.count == 129)

        let recorder = ProgressRecorder()
        let handle = CancellationHandle()
        let inspection = Task {
            await InstrumentReader.inspectMany(allSources, project: project, onProgress: { _, completed in
                await recorder.record(completed)
                if completed == 64 { await handle.cancel() }
            })
        }
        await handle.set(inspection)
        let report = await inspection.value

        #expect(report.results.count == 129)
        #expect(report.results.filter { $0.error == ReaderError.cancelled.localizedDescription }.count == 65)
        #expect(await recorder.values == [64, 129])
    }

    @Test func loadIsRetryableAfterTheFailureCauseIsFixed() async throws {
        let root = try makeProject(
            profiles: ["keysight-b1500a.yaml": Fixtures.keysightProfile],
            sources: ["data/raw/retry.csv": Data("SetupTitle, 2-terminal dual Vsweep\nDataName, V1, I1\nDataValue, 0, --\n".utf8)]
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let project = try ProjectContext.open(root)
        let source = try project.discoverSources()[0]

        await #expect(throws: ReaderError.self) {
            _ = try await InstrumentReader.load(source.url, project: project)
        }
        try Data(Fixtures.dualSweepCSV.utf8).write(to: source.url)
        let measurement = try await InstrumentReader.load(source.url, project: project)
        #expect(measurement.channel(named: "current")?.values == [1e-12, 2e-12, 3e-12, 4e-12, 5e-12])
    }
}

private actor ProgressRecorder {
    private(set) var values: [Int] = []
    func record(_ value: Int) { values.append(value) }
}

private actor CancellationHandle {
    private var task: Task<ReaderInspectionReport, Never>?
    func set(_ task: Task<ReaderInspectionReport, Never>) { self.task = task }
    func cancel() { task?.cancel() }
}

enum Fixtures {
    static let keysightProfile = """
    schema_version: 1
    instrument:
      id: keysight-b1500a
      name: Keysight B1500A Semiconductor Device Parameter Analyzer
      vendor: Keysight Technologies
      model: B1500A
    formats:
      - id: csv
        kind: tabular
        extensions: [".csv"]
        delimiter: ","
        encoding: [utf-8, windows-1252, iso-8859-1]
        rows:
          names_prefix: "DataName"
          data_prefix: "DataValue"
        columns:
          voltage:
            header: "V1"
            quantity: voltage
            unit: "V"
            label: "Voltage"
          current:
            header: "I2"
            aliases: ["I1"]
            quantity: current
            unit: "A"
            label: "Current"
    modes:
      - id: dual-sweep
        format: csv
        detect: ["2-terminal dual Vsweep", "dual Vsweep"]
        extract:
          x: voltage
          y: [current]
    """

    static let dualSweepCSV = """
    \u{FEFF}SetupTitle, 2-terminal dual Vsweep
    ApplicationTest, 2-terminal dual Vsweep, Public
    Dimension1, 5, 5
    DataName, V1, I1
    DataValue, 0, 1E-12
    DataValue, 0.1, 2E-12
    DataValue, 0.2, 3E-12
    DataValue, 0.1, 4E-12
    DataValue, 0, 5E-12
    """

    static let unversionedKeysightProfile = """
    instrument:
      id: keysight-b1500a
      name: Keysight B1500A Semiconductor Device Parameter Analyzer
    formats:
      - id: csv
        extensions: [".csv"]
        delimiter: ","
        rows:
          names_prefix: "DataName"
          data_prefix: "DataValue"
        columns:
          voltage:
            header: "V1"
            unit: "V"
          current:
            header: "I2"
            aliases: ["I1"]
            unit: "A"
    modes:
      - id: dual-sweep
        format: csv
        detect: ["2-terminal dual Vsweep"]
        extract:
          x: voltage
          y: [current]
    """

    static let missingUnitProfile = keysightProfile.replacingOccurrences(of: "unit: \"V\"", with: "unit_label: \"V\"")

    /// Legacy real-project shape: no schema_version, `application_modes` with
    /// `detect.signatures`, `formats` with extensions. Must stay actionable
    /// (unversioned diagnostic) with its signatures preserved as evidence.
    static let legacyUnversionedProfile = """
    instrument:
      id: keysight-legacy
      name: Keysight Legacy
    formats:
      - id: csv
        extensions: [".csv"]
        delimiter: ","
        rows:
          names_prefix: "DataName"
          data_prefix: "DataValue"
        columns:
          voltage:
            header: "V1"
            unit: "V"
          current:
            header: "I1"
            unit: "A"
    application_modes:
      - id: dual-sweep
        detect:
          method: header-keyword
          signatures: ["2-terminal dual Vsweep"]
        extract:
          x: voltage
          y: [current]
    """

    static let malformedProfile = """
    schema_version: 1
    instrument:
      id: broken
       name: Bad indentation
    formats: [".csv", ".dat"
    """

    static let dataProfile = """
    schema_version: 1
    instrument:
      id: fixture-dat
      name: Fixture DAT
    formats:
      - id: dat
        kind: tabular
        extensions: [".dat"]
        delimiter: ","
        rows:
          names_prefix: "DATNAME"
          data_prefix: "DATROW"
        columns:
          x:
            header: "X"
            quantity: time
            unit: "s"
          y:
            header: "Y"
            quantity: signal
            unit: "V"
    modes:
      - id: default
        format: dat
        detect: ["FIXTURE.DAT"]
        extract:
          x: x
          y: [y]
    """

    static let dataCSV = """
    FIXTURE.DAT export
    DATNAME, X, Y
    DATROW, 1, 2
    DATROW, 2, 4
    """
}

private func makeProject(profiles: [String: String], sources: [String: Data]) throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("rawview-test-\(UUID().uuidString)")
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
    return root
}

private func sha256Hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}
