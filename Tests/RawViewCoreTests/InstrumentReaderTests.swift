import CryptoKit
import Foundation
import Testing
@testable import RawViewCore

struct InstrumentReaderTests {
    @Test func directReaderCallsRejectSPEAndAFFMBeforeOpeningFiles() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let raw = root.appendingPathComponent("data/raw")
        try FileManager.default.createDirectory(at: raw, withIntermediateDirectories: true)
        let project = try ProjectContext.open(root)
        let urls = [raw.appendingPathComponent("missing.sPe"), raw.appendingPathComponent("missing.AFFM")]
        let sources = urls.map { RawSource(relativePath: "data/raw/\($0.lastPathComponent)", url: $0, byteSize: 0) }

        let report = await InstrumentReader.inspectMany(sources, project: project)
        #expect(report.results.count == 2)
        #expect(report.results.allSatisfy { $0.error?.contains("RawView skips .spe and .affm") == true })

        for url in urls {
            await #expect(throws: ReaderError.self) {
                try await InstrumentReader.load(url, project: project)
            }
        }
    }

    @Test func loadsKeysightDualSweepPreservingEveryPointInFileOrder() async throws {
        let profile = Fixtures.keysightProfile
        let csv = Fixtures.dualSweepCSV
        let root = try makeProject(profiles: ["keysight-b1500a.yaml": profile], sources: ["data/raw/fixture-run/dual-sweep.csv": Data(csv.utf8)])
        defer { try? FileManager.default.removeItem(at: root) }

        let project = try ProjectContext.open(root)
        let sources = try project.discoverSources()
        #expect(sources.map(\.relativePath) == ["data/raw/fixture-run/dual-sweep.csv"])

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
        #expect(measurement.source.path == "data/raw/fixture-run/dual-sweep.csv")
        #expect(measurement.source.sha256 == sha256Hex(Data(csv.utf8)))
        #expect(measurement.provenance["profile_id"] == "keysight-b1500a")
        #expect(measurement.provenance["profile_hash"] == sha256Hex(Data(profile.utf8)))
        #expect(measurement.provenance["reader_version"] == "1.1.0")
        #expect(measurement.instrument.vendor == "Keysight Technologies")
        #expect(measurement.instrument.model == "B1500A")
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
        let profile = Fixtures.keysightProfile.replacingOccurrences(of: "schema_version: 1", with: "schema_version: 3")
        let root = try makeProject(profiles: ["keysight-b1500a.yaml": profile], sources: ["data/raw/dual.csv": Data(Fixtures.dualSweepCSV.utf8)])
        defer { try? FileManager.default.removeItem(at: root) }
        let report = await InstrumentReader.inspectMany(try ProjectContext.open(root).discoverSources(), project: try ProjectContext.open(root))
        let error = try #require(report.results.first?.error)
        #expect(error.contains("unsupported schema_version 3"))
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
        #expect(error.contains("No profile mode matched"))
        #expect(error.contains("dual-sweep"))
        #expect(error.contains("not in header sample"))
        #expect(!error.contains("filename_contains_all"))
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
        Dimension1, 2, 2
        MetaData, TestRecord.RecordTime, 12/31/2024 23:59:58
        DataName, V1, I1
        DataValue, 0, 1E-3
        DataValue, 0.1, 2E-3
        """
        let root = try makeProject(
            profiles: ["keysight-b1500a.yaml": Fixtures.keysightProfile],
            sources: ["data/raw/241231-235958_keysight-b1500a.dual-sweep_[fixture-device]_iv.dual-sweep.csv": Data(csv.utf8)]
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let project = try ProjectContext.open(root)
        let sources = try project.discoverSources()
        let report = await InstrumentReader.inspectMany(sources, project: project)
        let inspection = try #require(report.results.first?.inspection)
        // Filename-derived identity (read-only convention, unknown stays nil).
        #expect(inspection.timestamp == "241231-235958")
        #expect(inspection.deviceID == "fixture-device")
        #expect(inspection.category == "iv.dual-sweep")
        let measurement = try await InstrumentReader.load(sources[0].url, project: project)
        let acquisition = measurement.metadataSections.first { $0.title == "Acquisition" }
        #expect(acquisition?.fields.contains { $0.key == "SetupTitle" && $0.value.displayText.contains("2-terminal dual Vsweep") } == true)
        #expect(acquisition?.fields.contains { $0.key == "Dimension1" } == true)
        #expect(acquisition?.fields.contains { $0.value.displayText.contains("12/31/2024") } == true)
        let identity = measurement.metadataSections.first { $0.title == "Identity" }
        #expect(identity?.fields.contains { $0.key == "device_id" } == true)
        #expect(measurement.metadataSections.first { $0.title == "Data" } != nil)
    }

    @Test func filenameTimestampAcceptsValidLeapDay() async throws {
        let csv = """
        SetupTitle, 2-terminal dual Vsweep
        DataName, V1, I1
        DataValue, 0, 1E-12
        """
        // 29 Feb 2024 is a real Gregorian leap day (years pivot to 2000–2099).
        let name = "290224-120000_keysight-b1500a.dual-sweep_[dev1]_iv.dual-sweep.csv"
        let root = try makeProject(
            profiles: ["keysight-b1500a.yaml": Fixtures.keysightProfile],
            sources: ["data/raw/\(name)": Data(csv.utf8)]
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let project = try ProjectContext.open(root)
        let sources = try project.discoverSources()
        let report = await InstrumentReader.inspectMany(sources, project: project)
        let inspection = try #require(report.results.first?.inspection)
        #expect(inspection.timestamp == "290224-120000")
        #expect(inspection.deviceID == "dev1")
        #expect(inspection.category == "iv.dual-sweep")
    }

    @Test func filenameTimestampRejectsImpossibleDatesAndTimes() async throws {
        let csv = """
        SetupTitle, 2-terminal dual Vsweep
        DataName, V1, I1
        DataValue, 0, 1E-12
        """
        // 2025 is not a leap year; hour 25 and month 13 are invalid. Each
        // token stays unknown while device, category, and filename survive.
        for (token, device) in [
            ("290225-120000", "dev-nonleap"),
            ("241231-250000", "dev-badtime"),
            ("321306-120000", "dev-badmonth"),
        ] {
            let name = "\(token)_keysight-b1500a.dual-sweep_[\(device)]_iv.dual-sweep.csv"
            let root = try makeProject(
                profiles: ["keysight-b1500a.yaml": Fixtures.keysightProfile],
                sources: ["data/raw/\(name)": Data(csv.utf8)]
            )
            defer { try? FileManager.default.removeItem(at: root) }
            let project = try ProjectContext.open(root)
            let sources = try project.discoverSources()
            let report = await InstrumentReader.inspectMany(sources, project: project)
            let inspection = try #require(report.results.first?.inspection)
            #expect(inspection.timestamp == nil, "token \(token) should stay unknown")
            #expect(inspection.deviceID == device)
            #expect(inspection.category == "iv.dual-sweep")
            let measurement = try await InstrumentReader.load(sources[0].url, project: project)
            let identity = try #require(measurement.metadataSections.first { $0.title == "Identity" })
            #expect(identity.fields.contains { $0.key == "timestamp" } == false)
            #expect(identity.fields.contains { $0.key == "filename" && $0.value.displayText == name } == true)
        }
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
            sources: ["data/raw/fixture-run/dual-sweep.csv": Data(Fixtures.dualSweepCSV.utf8)]
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

    @Test func nestedRawViewerProfileBlockIsRejected() async throws {
        // A top-level v2 document carrying a nested raw_viewer block must fail
        // closed: viewer profiles are standalone top-level documents, and
        // companion profiles live under data/instruments/rawview/.
        let profile = Fixtures.keysightV2.replacingOccurrences(
            of: "modes:\n",
            with: "raw_viewer:\n  schema_version: 2\n  instrument:\n    id: study-owned\n    name: Study Owned\nmodes:\n"
        )
        let root = try makeProject(profiles: ["keysight-b1500a.yaml": profile], sources: ["data/raw/dual.csv": Data(Fixtures.dualSweepCSV.utf8)])
        defer { try? FileManager.default.removeItem(at: root) }
        let project = try ProjectContext.open(root)
        let report = await InstrumentReader.inspectMany(try project.discoverSources(), project: project)
        #expect(report.results.first?.inspection == nil)
        let error = try #require(report.results.first?.error)
        #expect(error.contains("data/instruments/keysight-b1500a.yaml"))
        #expect(error.contains("raw_viewer"))
        #expect(error.contains("standalone"))
        await #expect(throws: ReaderError.self) {
            try await InstrumentReader.load(try project.discoverSources()[0].url, project: project)
        }
    }

    @Test func keithleyLvmLoadsEveryPairInFileOrder() async throws {
        let root = try makeProject(profiles: ["keithley-2400.yaml": Fixtures.keithleyLvm], sources: ["data/raw/sweep.txt": Data(Fixtures.lvmSweep.utf8)])
        defer { try? FileManager.default.removeItem(at: root) }
        let project = try ProjectContext.open(root)
        let sources = try project.discoverSources()
        let report = await InstrumentReader.inspectMany(sources, project: project)
        #expect(report.profileIssues.isEmpty)
        #expect(report.results.first?.inspection?.applicationMode == "dual-sweep")
        let measurement = try await InstrumentReader.load(sources[0].url, project: project)
        let voltage = try #require(measurement.channel(named: "voltage"))
        let current = try #require(measurement.channel(named: "current"))
        // Every row after the X_Value header is kept in file order; the
        // trailing blank line is skipped, not parsed as a gap row.
        #expect(voltage.values == [-0.2, 0.15, 0.5, 0.85])
        #expect(current.values == [1.25e-6, 2.5e-6, -3.75e-6, 5e-6])
        #expect(voltage.unit == "V")
        #expect(current.unit == "A")
        #expect(voltage.quantity == "voltage")
        #expect(current.quantity == "current")
        #expect(measurement.view.x == "voltage")
        #expect(measurement.view.y == ["current"])
        #expect(measurement.provenance["profile_schema_version"] == "2")
        #expect(measurement.source.sha256 == sha256Hex(Data(Fixtures.lvmSweep.utf8)))
        let acquisition = try #require(measurement.metadataSections.first { $0.title == "Acquisition" })
        #expect(acquisition.fields.contains { $0.key == "Separator" && $0.value.displayText == "Tab" })
        #expect(acquisition.fields.contains { $0.key == "Channels" })
        // The optional timestamp channel is present, so its complete
        // row-aligned values ride along without touching the X/Y arrays.
        let elapsed = try #require(measurement.channel(named: "timestamp"))
        #expect(elapsed.values == [1, 2, 3, 4])
        #expect(elapsed.unit == "s")
        #expect(elapsed.quantity == "time")
        #expect(elapsed.label == "Time")
        #expect(measurement.channels.map(\.name) == ["voltage", "current", "timestamp"])
    }

    @Test func lvmAbsentOptionalColumnLoadsRequiredChannelsUnchanged() async throws {
        let root = try makeProject(profiles: ["keithley-2400.yaml": Fixtures.keithleyLvm], sources: ["data/raw/notime.txt": Data(Fixtures.lvmSweepNoTimestamp.utf8)])
        defer { try? FileManager.default.removeItem(at: root) }
        let project = try ProjectContext.open(root)
        let sources = try project.discoverSources()
        let report = await InstrumentReader.inspectMany(sources, project: project)
        #expect(report.profileIssues.isEmpty)
        #expect(report.results.first?.inspection?.applicationMode == "dual-sweep")
        let measurement = try await InstrumentReader.load(sources[0].url, project: project)
        // Required channels keep exact values/order/count; nothing is
        // invented for the absent optional header.
        #expect(measurement.channel(named: "voltage")?.values == [-2.25, 2.25])
        #expect(measurement.channel(named: "current")?.values == [11e-6, -11e-6])
        #expect(measurement.channel(named: "timestamp") == nil)
        #expect(measurement.channels.map(\.name) == ["voltage", "current"])
        #expect(measurement.view.x == "voltage")
        #expect(measurement.view.y == ["current"])
        #expect(measurement.source.sha256 == sha256Hex(Data(Fixtures.lvmSweepNoTimestamp.utf8)))
    }

    @Test func lvmMissingRequiredChannelStillBlocksWhenOptionalPresent() async throws {
        // The required current header is gone while the optional timestamp
        // header stays: the source must block naming the required channel.
        let text = Fixtures.lvmSweep.replacingOccurrences(of: "Untitled 1", with: "Bogus")
        let root = try makeProject(profiles: ["keithley-2400.yaml": Fixtures.keithleyLvm], sources: ["data/raw/nocurrent.txt": Data(text.utf8)])
        defer { try? FileManager.default.removeItem(at: root) }
        let project = try ProjectContext.open(root)
        do {
            _ = try await InstrumentReader.load(try project.discoverSources()[0].url, project: project)
            Issue.record("source with missing required channel loaded instead of blocked")
        } catch {
            #expect(error.localizedDescription.contains("current"))
        }
    }

    @Test func optionalColumnSchemaIsFailClosed() async throws {
        let nonBoolean = Fixtures.keithleyLvm.replacingOccurrences(
            of: "required: false", with: "required: maybe")
        let optionalAxis = Fixtures.keithleyLvm.replacingOccurrences(
            of: "x: voltage", with: "x: timestamp")
        for (name, profile, fragment) in [
            ("nonboolean.yaml", nonBoolean, "columns.timestamp.required"),
            ("optional-axis.yaml", optionalAxis, "extract.x"),
        ] {
            let root = try makeProject(profiles: [name: profile], sources: ["data/raw/sweep.txt": Data(Fixtures.lvmSweep.utf8)])
            defer { try? FileManager.default.removeItem(at: root) }
            let project = try ProjectContext.open(root)
            let report = await InstrumentReader.inspectMany(try project.discoverSources(), project: project)
            let combined = (report.results.first?.error ?? "") + report.profileIssues.joined()
            #expect(combined.contains(fragment), "profile \(name) should report \(fragment)")
        }
    }

    @Test func lvmBlockedStatesAreActionable() async throws {
        let missingHeader = Fixtures.lvmSweep.replacingOccurrences(of: "X_Value\tUntitled", with: "Nope\tUntitled")
        let corruptCell = Fixtures.lvmSweep.replacingOccurrences(of: "-3.75E-6", with: "--")
        for (name, text, fragment) in [
            ("missing.txt", missingHeader, "no \"X_Value\" header row"),
            ("corrupt.txt", corruptCell, "--"),
        ] {
            let root = try makeProject(profiles: ["keithley-2400.yaml": Fixtures.keithleyLvm], sources: ["data/raw/\(name)": Data(text.utf8)])
            defer { try? FileManager.default.removeItem(at: root) }
            let project = try ProjectContext.open(root)
            do {
                _ = try await InstrumentReader.load(try project.discoverSources()[0].url, project: project)
                Issue.record("\(name) loaded instead of blocked")
            } catch {
                #expect(error.localizedDescription.contains(fragment), "\(name) should report \(fragment)")
            }
        }
    }

    @Test func lvmShortRowIsABlankGapNotCorrupt() async throws {
        let short = Fixtures.lvmSweep.replacingOccurrences(of: "\t0.5\t-3.75E-6\t3", with: "\t0.5")
        let root = try makeProject(profiles: ["keithley-2400.yaml": Fixtures.keithleyLvm], sources: ["data/raw/short.txt": Data(short.utf8)])
        defer { try? FileManager.default.removeItem(at: root) }
        let project = try ProjectContext.open(root)
        let measurement = try await InstrumentReader.load(try project.discoverSources()[0].url, project: project)
        let current = try #require(measurement.channel(named: "current"))
        #expect(current.values.count == 4)
        #expect(current.values[2] == nil)
        #expect(current.gapReasons[2] == .blank)
    }

    @Test func decimalCommaConflictingWithCommaDelimiterIsRejected() async throws {
        let profile = Fixtures.keysightV2.replacingOccurrences(
            of: "    delimiter: \",\"\n", with: "    delimiter: \",\"\n    decimal: \",\"\n")
        let root = try makeProject(profiles: ["nested.yaml": profile], sources: ["data/raw/dual.csv": Data(Fixtures.dualSweepCSV.utf8)])
        defer { try? FileManager.default.removeItem(at: root) }
        let project = try ProjectContext.open(root)
        let report = await InstrumentReader.inspectMany(try project.discoverSources(), project: project)
        #expect(report.results.first?.error?.contains("decimal") == true)
    }

    @Test func horibaLabramLoadsBothLayoutsInFileOrder() async throws {
        let root = try makeProject(
            profiles: ["horiba-labram.yaml": Fixtures.horibaLabram],
            sources: [
                "data/raw/sers.txt": Data(Fixtures.ramanTsv.utf8),
                "data/raw/characterization.txt": Data(Fixtures.ramanSemicolon.utf8),
            ]
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let project = try ProjectContext.open(root)
        let sources = try project.discoverSources()
        let report = await InstrumentReader.inspectMany(sources, project: project)
        #expect(report.profileIssues.isEmpty)
        // Same ".txt" extension, two formats: each file matches exactly one mode.
        #expect(report.results.first { $0.source.relativePath.hasSuffix("sers.txt") }?.inspection?.applicationMode == "raman-tsv")
        #expect(report.results.first { $0.source.relativePath.hasSuffix("characterization.txt") }?.inspection?.applicationMode == "raman-semicolon")
        for source in sources {
            let measurement = try await InstrumentReader.load(source.url, project: project)
            let x = try #require(measurement.channel(named: "wavenumber"))
            let y = try #require(measurement.channel(named: "intensity"))
            #expect(x.unit == "cm-1")
            #expect(y.unit == "counts")
            #expect(measurement.view.x == "wavenumber")
            #expect(measurement.view.y == ["intensity"])
            #expect(measurement.view.preserveOrder)
            #expect(measurement.provenance["profile_schema_version"] == "2")
            if source.relativePath.hasSuffix("sers.txt") {
                #expect(x.values == [125.5, 126.75, 128.0])
                #expect(y.values[0] == 3.25)
                #expect(y.values[1] == 4.5)
                #expect(y.values[2] == nil)
                #expect(y.gapReasons[2] == .nan)
                let acquisition = try #require(measurement.metadataSections.first { $0.title == "Acquisition" })
                #expect(acquisition.fields.contains { $0.key == "Laser" && $0.value.displayText == "532nm" })
            } else {
                #expect(x.values == [201.25, 202.5, 203.75])
                #expect(y.values == [3.5, 4.75, -2.25])
            }
        }
    }

    @Test func ramanTsvSurvivesLatin1CommentBytes() async throws {
        var bytes = Data("#Instrument=\tLabRAM HR Evol\n#Range (cm-".utf8)
        bytes.append(0xB9) // latin-1-only byte: not valid UTF-8
        bytes.append(contentsOf: Data(")=\t100...300\n#Laser=\t532nm\n125,500\t3,25\n".utf8))
        let root = try makeProject(profiles: ["horiba-labram.yaml": Fixtures.horibaLabram], sources: ["data/raw/latin1.txt": bytes])
        defer { try? FileManager.default.removeItem(at: root) }
        let project = try ProjectContext.open(root)
        let measurement = try await InstrumentReader.load(try project.discoverSources()[0].url, project: project)
        #expect(measurement.channel(named: "wavenumber")?.values == [125.5])
        #expect(measurement.channel(named: "intensity")?.values == [3.25])
    }

    @Test func ramanBlockedStatesAreActionable() async throws {
        // Comment-only TSV has no data rows; a semicolon file with corrupt
        // text blocks naming file, line, column, and value.
        let empty = "#Instrument=\tLabRAM HR Evol\n#Laser=\t532nm\n\n"
        let corrupt = Fixtures.ramanSemicolon.replacingOccurrences(of: "4.75", with: "bad")
        for (name, text, fragment) in [
            ("empty.txt", empty, "no data rows"),
            ("corrupt.txt", corrupt, "bad"),
        ] {
            let root = try makeProject(profiles: ["horiba-labram.yaml": Fixtures.horibaLabram], sources: ["data/raw/\(name)": Data(text.utf8)])
            defer { try? FileManager.default.removeItem(at: root) }
            let project = try ProjectContext.open(root)
            do {
                _ = try await InstrumentReader.load(try project.discoverSources()[0].url, project: project)
                Issue.record("\(name) loaded instead of blocked")
            } catch {
                #expect(error.localizedDescription.contains(fragment), "\(name) should report \(fragment)")
            }
        }
    }

    @Test func commentTsvSchemaIsFailClosed() async throws {
        let rowsAdded = Fixtures.horibaLabram.replacingOccurrences(
            of: "    kind: comment-tsv", with: "    kind: comment-tsv\n    rows:\n      names_prefix: \"X\"")
        let headerColumn = Fixtures.horibaLabram.replacingOccurrences(
            of: "        column_index: 0", with: "        header: \"X\"")
        let duplicateIndex = Fixtures.horibaLabram.replacingOccurrences(
            of: "        column_index: 1", with: "        column_index: 0")
        let unknownKind = Fixtures.horibaLabram.replacingOccurrences(
            of: "    kind: comment-tsv", with: "    kind: native")
        for (name, profile, fragment) in [
            ("rows.yaml", rowsAdded, "formats[0].rows"),
            ("header.yaml", headerColumn, "formats[0].columns.wavenumber.header"),
            ("dupindex.yaml", duplicateIndex, "same source column"),
            ("kind.yaml", unknownKind, "kind \"native\""),
        ] {
            let root = try makeProject(profiles: [name: profile], sources: ["data/raw/sers.txt": Data(Fixtures.ramanTsv.utf8)])
            defer { try? FileManager.default.removeItem(at: root) }
            let project = try ProjectContext.open(root)
            let report = await InstrumentReader.inspectMany(try project.discoverSources(), project: project)
            let combined = (report.results.first?.error ?? "") + report.profileIssues.joined()
            #expect(combined.contains(fragment), "profile \(name) should report \(fragment)")
        }
    }

    @Test func v2FilenameSelectorGatesMatchingOnBasenameOnly() async throws {
        let csv = "SetupTitle, SYNTH-SPECIFIC-HEADER\nDataName, V1, I1\nDataValue, 0, 1E-12\nDataValue, 0.1, 2E-12\nDataValue, 0.2, 3E-12\n"
        let root = try makeProject(
            profiles: ["synth.yaml": Fixtures.filenameV2],
            sources: [
                "data/raw/RUN_SYNTH-TOKEN_DUAL-SWEEP.csv": Data(csv.utf8),
                "data/raw/run_synth-token_only.csv": Data(csv.utf8),
                "data/raw/synth-token_dual-sweep/nested.csv": Data(csv.utf8),
            ]
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let project = try ProjectContext.open(root)
        let sources = try project.discoverSources()
        let report = await InstrumentReader.inspectMany(sources, project: project)
        // Both basename tokens (case-insensitive) plus header loads exact arrays in order.
        let good = try #require(report.results.first { $0.source.relativePath == "data/raw/RUN_SYNTH-TOKEN_DUAL-SWEEP.csv" })
        #expect(good.inspection?.applicationMode == "dual-sweep")
        let measurement = try await InstrumentReader.load(good.source.url, project: project)
        #expect(measurement.channel(named: "voltage")?.values == [0, 0.1, 0.2])
        #expect(measurement.channel(named: "current")?.values == [1e-12, 2e-12, 3e-12])
        // One of two required tokens with the same header stays visible and
        // blocked: the diagnostic names the missing filename token, not the
        // header (which matched via the second detect alternative, proving
        // detect keeps OR semantics).
        let partial = try #require(report.results.first { $0.source.relativePath == "data/raw/run_synth-token_only.csv" })
        let partialError = try #require(partial.error)
        #expect(partial.inspection == nil)
        #expect(partialError.contains("filename_contains_all tokens \"dual-sweep\" not in basename \"run_synth-token_only.csv\""))
        #expect(partialError.contains("detect matched header sample"))
        #expect(!partialError.contains("not in header sample"))
        await #expect(throws: ReaderError.self) {
            try await InstrumentReader.load(partial.source.url, project: project)
        }
        // Parent directories never satisfy the selector: both tokens live only
        // in the directory, not the basename.
        let nested = try #require(report.results.first { $0.source.relativePath == "data/raw/synth-token_dual-sweep/nested.csv" })
        let nestedError = try #require(nested.error)
        #expect(nested.inspection == nil)
        #expect(nestedError.contains("not in basename \"nested.csv\""))
        #expect(!nestedError.contains("not in header sample"))
    }

    @Test func profileWithoutFilenameSelectorKeepsLegacyMatching() async throws {
        let csv = "SetupTitle, SYNTH-SPECIFIC-HEADER\nDataName, V1, I1\nDataValue, 0, 1E-12\n"
        let root = try makeProject(
            profiles: ["synth.yaml": Fixtures.filenameV2NoSelector],
            sources: ["data/raw/unrelated.csv": Data(csv.utf8)]
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let project = try ProjectContext.open(root)
        let report = await InstrumentReader.inspectMany(try project.discoverSources(), project: project)
        #expect(report.results.first?.inspection?.applicationMode == "dual-sweep")
        let measurement = try await InstrumentReader.load(try project.discoverSources()[0].url, project: project)
        #expect(measurement.channel(named: "voltage")?.values == [0])
    }

    @Test func brokenFilenameSelectorIsolationUsesItsOwnSelectors() async throws {
        let csv = "SetupTitle, SYNTH-SPECIFIC-HEADER\nDataName, V1, I1\nDataValue, 0, 1E-12\n"
        // Unrelated broken filename must not poison a uniquely valid match.
        let unrelated = try makeProject(
            profiles: ["synth.yaml": Fixtures.filenameV2, "broken.yaml": Fixtures.brokenUnrelatedFilename],
            sources: ["data/raw/run_synth-token_dual-sweep.csv": Data(csv.utf8)]
        )
        defer { try? FileManager.default.removeItem(at: unrelated) }
        let unrelatedProject = try ProjectContext.open(unrelated)
        let unrelatedReport = await InstrumentReader.inspectMany(try unrelatedProject.discoverSources(), project: unrelatedProject)
        #expect(unrelatedReport.results.first?.inspection?.applicationMode == "dual-sweep")
        let measurement = try await InstrumentReader.load(try unrelatedProject.discoverSources()[0].url, project: unrelatedProject)
        #expect(measurement.channel(named: "voltage")?.values == [0])
        // A genuinely matching broken selector stays fail-closed.
        let matching = try makeProject(
            profiles: ["synth.yaml": Fixtures.filenameV2, "broken.yaml": Fixtures.brokenMatchingFilename],
            sources: ["data/raw/run_synth-token_dual-sweep.csv": Data(csv.utf8)]
        )
        defer { try? FileManager.default.removeItem(at: matching) }
        let matchingProject = try ProjectContext.open(matching)
        let matchingReport = await InstrumentReader.inspectMany(try matchingProject.discoverSources(), project: matchingProject)
        let result = try #require(matchingReport.results.first)
        #expect(result.inspection == nil)
        #expect(result.error?.contains("broken.yaml") == true)
        await #expect(throws: ReaderError.self) {
            try await InstrumentReader.load(result.source.url, project: matchingProject)
        }
    }

    @Test func filenameSelectorIsV2Only() async throws {
        let v1 = Fixtures.keysightProfile.replacingOccurrences(
            of: "    detect: [\"2-terminal dual Vsweep\", \"dual Vsweep\"]",
            with: "    filename_contains_all: [\"keysight-b1500a.dual-sweep\"]\n    detect: [\"2-terminal dual Vsweep\", \"dual Vsweep\"]")
        let root = try makeProject(profiles: ["keysight-b1500a.yaml": v1], sources: ["data/raw/a.csv": Data(Fixtures.dualSweepCSV.utf8)])
        defer { try? FileManager.default.removeItem(at: root) }
        let project = try ProjectContext.open(root)
        let report = await InstrumentReader.inspectMany(try project.discoverSources(), project: project)
        // The header would match absent the field, so the block proves the
        // exact unknown-key rejection rather than a no-match diagnostic.
        #expect(report.profileIssues.contains { $0.contains("modes[0].filename_contains_all is not part of schema v1 (unknown key)") })
        #expect(report.results.first?.inspection == nil)
        // Control: the same header matches the same v1 profile without the field.
        let control = try makeProject(profiles: ["keysight-b1500a.yaml": Fixtures.keysightProfile], sources: ["data/raw/a.csv": Data(Fixtures.dualSweepCSV.utf8)])
        defer { try? FileManager.default.removeItem(at: control) }
        let controlProject = try ProjectContext.open(control)
        let controlReport = await InstrumentReader.inspectMany(try controlProject.discoverSources(), project: controlProject)
        #expect(controlReport.results.first?.inspection?.applicationMode == "dual-sweep")
    }

    @Test func filenameSelectorPreservesAmbiguity() async throws {
        let csv = "SetupTitle, SYNTH-SPECIFIC-HEADER\nDataName, V1, I1\nDataValue, 0, 1E-12\n"
        let copy = Fixtures.filenameV2.replacingOccurrences(of: "id: synth", with: "id: synth-copy")
        let root = try makeProject(
            profiles: ["a.yaml": Fixtures.filenameV2, "b.yaml": copy],
            sources: ["data/raw/run_synth-token_dual-sweep.csv": Data(csv.utf8)]
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let project = try ProjectContext.open(root)
        let report = await InstrumentReader.inspectMany(try project.discoverSources(), project: project)
        let error = try #require(report.results.first?.error)
        #expect(error.contains("Ambiguous"))
        #expect(error.contains("a.yaml"))
        #expect(error.contains("b.yaml"))
    }

    @Test func malformedFilenameSelectorIsFailClosed() async throws {
        let csv = "SetupTitle, SYNTH-SPECIFIC-HEADER\nDataName, V1, I1\nDataValue, 0, 1E-12\n"
        // An empty selector list is schema-invalid: the source stays blocked
        // with a diagnostic naming the exact field.
        let empty = Fixtures.filenameV2.replacingOccurrences(
            of: "filename_contains_all: [\"synth-token\", \"dual-sweep\"]",
            with: "filename_contains_all: []")
        let invalid = try makeProject(
            profiles: ["synth.yaml": empty],
            sources: ["data/raw/run_synth-token_dual-sweep.csv": Data(csv.utf8)]
        )
        defer { try? FileManager.default.removeItem(at: invalid) }
        let invalidProject = try ProjectContext.open(invalid)
        let invalidReport = await InstrumentReader.inspectMany(try invalidProject.discoverSources(), project: invalidProject)
        let invalidResult = try #require(invalidReport.results.first)
        #expect(invalidResult.inspection == nil)
        #expect(((invalidResult.error ?? "") + invalidReport.profileIssues.joined()).contains("modes[0].filename_contains_all must be a non-empty list of non-empty strings."))
        // A malformed broken claim keeps no trustworthy selectors, so it still
        // blocks a uniquely valid match with its own diagnostic.
        let malformed = try makeProject(
            profiles: ["synth.yaml": Fixtures.filenameV2, "broken.yaml": Fixtures.brokenMalformedFilename],
            sources: ["data/raw/run_synth-token_dual-sweep.csv": Data(csv.utf8)]
        )
        defer { try? FileManager.default.removeItem(at: malformed) }
        let malformedProject = try ProjectContext.open(malformed)
        let malformedReport = await InstrumentReader.inspectMany(try malformedProject.discoverSources(), project: malformedProject)
        let malformedResult = try #require(malformedReport.results.first)
        #expect(malformedResult.inspection == nil)
        #expect(malformedResult.error?.contains("broken.yaml") == true)
        await #expect(throws: ReaderError.self) {
            try await InstrumentReader.load(malformedResult.source.url, project: malformedProject)
        }
        // A malformed filename plus a trustworthy nonmatching header proves the
        // broken mode unrelated, so the valid match stands.
        let headerMiss = Fixtures.brokenMalformedFilename.replacingOccurrences(
            of: "SYNTH-SPECIFIC-HEADER", with: "SYNTH-OTHER-HEADER")
        let unrelated = try makeProject(
            profiles: ["synth.yaml": Fixtures.filenameV2, "broken.yaml": headerMiss],
            sources: ["data/raw/run_synth-token_dual-sweep.csv": Data(csv.utf8)]
        )
        defer { try? FileManager.default.removeItem(at: unrelated) }
        let unrelatedProject = try ProjectContext.open(unrelated)
        let unrelatedReport = await InstrumentReader.inspectMany(try unrelatedProject.discoverSources(), project: unrelatedProject)
        #expect(unrelatedReport.results.first?.inspection?.applicationMode == "dual-sweep")
    }

    @Test func filenameMatchHeaderMissStaysUnmatchedAndUnblocking() async throws {
        // Filename tokens match but both detect alternatives miss: the valid
        // mode stays unmatched with a header cause, never a filename cause.
        let other = "SetupTitle, SYNTH-OTHER-HEADER\nDataName, V1, I1\nDataValue, 0, 1E-12\n"
        let root = try makeProject(
            profiles: ["synth.yaml": Fixtures.filenameV2],
            sources: ["data/raw/run_synth-token_dual-sweep.csv": Data(other.utf8)]
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let project = try ProjectContext.open(root)
        let report = await InstrumentReader.inspectMany(try project.discoverSources(), project: project)
        let result = try #require(report.results.first)
        let error = try #require(result.error)
        #expect(result.inspection == nil)
        #expect(error.contains("filename_contains_all matched basename \"run_synth-token_dual-sweep.csv\""))
        #expect(error.contains("detect \"SYNTH-MISSING-HEADER\", \"SYNTH-SPECIFIC-HEADER\" not in header sample"))
        #expect(!error.contains("not in basename"))
        // A broken mode whose trustworthy header selector misses does not block
        // a uniquely valid match, even with a matching filename selector.
        let headerMiss = Fixtures.brokenMatchingFilename.replacingOccurrences(
            of: "SYNTH-SPECIFIC-HEADER", with: "SYNTH-OTHER-HEADER")
        let csv = "SetupTitle, SYNTH-SPECIFIC-HEADER\nDataName, V1, I1\nDataValue, 0, 1E-12\n"
        let pair = try makeProject(
            profiles: ["synth.yaml": Fixtures.filenameV2, "broken.yaml": headerMiss],
            sources: ["data/raw/run_synth-token_dual-sweep.csv": Data(csv.utf8)]
        )
        defer { try? FileManager.default.removeItem(at: pair) }
        let pairProject = try ProjectContext.open(pair)
        let pairReport = await InstrumentReader.inspectMany(try pairProject.discoverSources(), project: pairProject)
        #expect(pairReport.results.first?.inspection?.applicationMode == "dual-sweep")
    }

    @Test func mixedDetectListCannotExonerateBrokenClaim() async throws {
        // A detect list mixing a nonmatching scalar with a non-scalar mapping
        // is malformed as a whole: its surviving string must not count as
        // trustworthy header evidence exonerating the source, so the uniquely
        // valid match stays blocked with the broken profile identified.
        let mixed = Fixtures.filenameV2
            .replacingOccurrences(of: "    detect: [\"SYNTH-MISSING-HEADER\", \"SYNTH-SPECIFIC-HEADER\"]", with: "    detect:\n      - UNRELATED-HEADER\n      - bad: map")
        let csv = "SetupTitle, SYNTH-SPECIFIC-HEADER\nDataName, V1, I1\nDataValue, 0, 1E-12\n"
        let root = try makeProject(
            profiles: ["synth.yaml": Fixtures.filenameV2, "broken.yaml": mixed],
            sources: ["data/raw/run_synth-token_dual-sweep.csv": Data(csv.utf8)]
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let project = try ProjectContext.open(root)
        let report = await InstrumentReader.inspectMany(try project.discoverSources(), project: project)
        let result = try #require(report.results.first)
        #expect(result.inspection == nil)
        #expect(result.error?.contains("data/instruments/broken.yaml") == true)
        #expect(result.error?.contains("modes[0].detect must contain only strings") == true)
        await #expect(throws: ReaderError.self) {
            try await InstrumentReader.load(result.source.url, project: project)
        }
        // A trustworthy filename miss still clears the malformed-detect mode:
        // the same mixed list paired with an unrelated token does not block.
        let cleared = mixed.replacingOccurrences(
            of: "filename_contains_all: [\"synth-token\", \"dual-sweep\"]",
            with: "filename_contains_all: [\"unrelated-token\"]")
        let freed = try makeProject(
            profiles: ["synth.yaml": Fixtures.filenameV2, "broken.yaml": cleared],
            sources: ["data/raw/run_synth-token_dual-sweep.csv": Data(csv.utf8)]
        )
        defer { try? FileManager.default.removeItem(at: freed) }
        let freedProject = try ProjectContext.open(freed)
        let freedReport = await InstrumentReader.inspectMany(try freedProject.discoverSources(), project: freedProject)
        #expect(freedReport.results.first?.inspection?.applicationMode == "dual-sweep")
    }

    @Test func uncertainBrokenClaimBlocks() async throws {
        // The broken profile pairs a matching filename with a missing detect
        // list (uncertain) alongside an unrelated valid signature: the
        // uncertain mode keeps the source blocked with its own diagnostic.
        let csv = "SetupTitle, SYNTH-SPECIFIC-HEADER\nDataName, V1, I1\nDataValue, 0, 1E-12\n"
        let root = try makeProject(
            profiles: ["synth.yaml": Fixtures.filenameV2, "broken.yaml": Fixtures.brokenUncertainFilename],
            sources: ["data/raw/run_synth-token_dual-sweep.csv": Data(csv.utf8)]
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let project = try ProjectContext.open(root)
        let report = await InstrumentReader.inspectMany(try project.discoverSources(), project: project)
        let result = try #require(report.results.first)
        #expect(result.inspection == nil)
        #expect(result.error?.contains("data/instruments/broken.yaml") == true)
        #expect(result.error?.contains("modes[0].detect must list at least one header signature string.") == true)
        await #expect(throws: ReaderError.self) {
            try await InstrumentReader.load(result.source.url, project: project)
        }
    }

    @Test func v1FilenameFieldCannotExonerateBrokenClaim() async throws {
        // A schema-v1 broken claim carrying the unknown filename field plus a
        // matching header still blocks: the field is ignored as evidence
        // outside schema v2 and the header match stands.
        let broken = Fixtures.unversionedKeysightProfile.replacingOccurrences(
            of: "    detect: [\"2-terminal dual Vsweep\"]",
            with: "    filename_contains_all: [\"v1check\"]\n    detect: [\"2-terminal dual Vsweep\"]")
        let root = try makeProject(
            profiles: ["keysight-b1500a.yaml": Fixtures.keysightProfile, "broken.yaml": broken],
            sources: ["data/raw/v1check.csv": Data(Fixtures.dualSweepCSV.utf8)]
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let project = try ProjectContext.open(root)
        let report = await InstrumentReader.inspectMany(try project.discoverSources(), project: project)
        let result = try #require(report.results.first)
        #expect(result.inspection == nil)
        #expect(result.error?.contains("data/instruments/broken.yaml") == true)
        #expect(result.error?.contains("unversioned") == true)
        await #expect(throws: ReaderError.self) {
            try await InstrumentReader.load(result.source.url, project: project)
        }
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
    /// Standalone viewer profile schema v2: the only supported document
    /// shape for viewer profiles. Study metadata is not part of it.
    static let keysightV2 = """
    schema_version: 2
    instrument:
      id: keysight-b1500a
      name: Keysight B1500A Semiconductor Device Parameter Analyzer
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
        detect: ["2-terminal dual Vsweep"]
        extract:
          x: voltage
          y: [current]
    """

    /// Keithley 2400 LVM layout as a standalone v2 profile: tab-separated,
    /// two `***End_of_Header***` blocks, an `X_Value` names row, and data
    /// rows with an empty leading cell (empty `data_prefix` matches every
    /// non-blank line after the header).
    static let keithleyLvm = """
    schema_version: 2
    instrument:
      id: keithley-2400
      name: Keithley 2400 SourceMeter
    formats:
      - id: lvm
        kind: tabular
        extensions: [".txt", ".lvm"]
        delimiter: "\\t"
        rows:
          names_prefix: "X_Value"
          data_prefix: ""
        columns:
          voltage:
            header: "Untitled"
            quantity: voltage
            unit: "V"
            label: "Voltage"
          current:
            header: "Untitled 1"
            quantity: current
            unit: "A"
            label: "Current"
          timestamp:
            header: "Untitled 2"
            quantity: time
            unit: "s"
            label: "Time"
            required: false
    modes:
      - id: dual-sweep
        format: lvm
        detect: ["LabVIEW Measurement"]
        extract:
          x: voltage
          y: [current]
    """

    /// Keithley LVM sweep without the optional `Untitled 2` time column:
    /// required voltage/current headers resolve; the absent optional header
    /// is skipped without inventing values.
    static let lvmSweepNoTimestamp = "LabVIEW Measurement\t\n***End_of_Header***\t\n***End_of_Header***\t\t\t\nX_Value\tUntitled\tUntitled 1\tComment\n\t-2.25\t11E-6\n\t2.25\t-11E-6\n\n"

    static let lvmSweep = "LabVIEW Measurement\t\nWriter_Version\t2\nSeparator\tTab\n***End_of_Header***\t\nChannels\t3\nSamples\t4\t4\t4\n***End_of_Header***\t\t\t\nX_Value\tUntitled\tUntitled 1\tUntitled 2\tComment\n\t-0.2\t1.25E-6\t1\n\t0.15\t2.5E-6\t2\n\t0.5\t-3.75E-6\t3\n\t0.85\t5E-6\t4\n\n"

    /// Horiba LabRAM Raman as a standalone v2 profile in both existing
    /// layouts: a comment-header TSV with a European decimal comma, and a
    /// legacy semicolon table with period decimals. Both share one ".txt"
    /// extension and are told apart by their detect signatures.
    static let horibaLabram = """
    schema_version: 2
    instrument:
      id: horiba-labram
      name: Horiba LabRAM HR Evolution Raman Spectrometer
    formats:
      - id: tab_comma
        kind: comment-tsv
        extensions: [".txt"]
        delimiter: "\\t"
        decimal: ","
        encoding: [utf-8, windows-1252, iso-8859-1]
        columns:
          wavenumber:
            column_index: 0
            quantity: wavenumber
            unit: "cm-1"
            label: "Raman shift"
          intensity:
            column_index: 1
            quantity: intensity
            unit: "counts"
            label: "Intensity"
      - id: header_semicolon
        kind: tabular
        extensions: [".txt"]
        delimiter: ";"
        rows:
          names_prefix: "raman_shift"
          data_prefix: ""
        columns:
          wavenumber:
            header: "raman_shift"
            quantity: wavenumber
            unit: "cm-1"
            label: "Raman shift"
          intensity:
            header: "intensity"
            quantity: intensity
            unit: "counts"
            label: "Intensity"
    modes:
      - id: raman-tsv
        format: tab_comma
        detect: ["#Laser="]
        extract:
          x: wavenumber
          y: [intensity]
      - id: raman-semicolon
        format: header_semicolon
        detect: ["raman_shift;intensity"]
        extract:
          x: wavenumber
          y: [intensity]
    """

    static let ramanTsv = "#Instrument=\tLabRAM HR Evol\n#Laser=\t532nm\n#Acq. time (s)=\t5\n125,500\t3,25\n126,750\t4,5\n128,000\tNaN\n\n"

    static let ramanSemicolon = "raman_shift;intensity\n201.25;3.5\n202.5;4.75\n203.75;-2.25\n\n"

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

    static let filenameV2 = """
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

    /// No filename gate: filenameV2 with only that field removed; both detect
    /// alternatives are preserved.
    static let filenameV2NoSelector = filenameV2.replacingOccurrences(
        of: "    filename_contains_all: [\"synth-token\", \"dual-sweep\"]\n", with: "")

    /// Schema v2 shape broken by one unknown key, so its well-formed filename
    /// selector stays trustworthy evidence while the profile stays invalid.
    static let brokenUnrelatedFilename = filenameV2
        .replacingOccurrences(of: "id: synth", with: "id: broken")
        .replacingOccurrences(of: "name: Synth", with: "name: Broken")
        .replacingOccurrences(of: "filename_contains_all: [\"synth-token\", \"dual-sweep\"]", with: "filename_contains_all: [\"unrelated-token\"]")
        .replacingOccurrences(of: "detect: [\"SYNTH-MISSING-HEADER\", \"SYNTH-SPECIFIC-HEADER\"]", with: "detect: [\"SYNTH-SPECIFIC-HEADER\"]\n    summary: synthetic")

    static let brokenMatchingFilename = filenameV2
        .replacingOccurrences(of: "id: synth", with: "id: broken")
        .replacingOccurrences(of: "name: Synth", with: "name: Broken")
        .replacingOccurrences(of: "detect: [\"SYNTH-MISSING-HEADER\", \"SYNTH-SPECIFIC-HEADER\"]", with: "detect: [\"SYNTH-SPECIFIC-HEADER\"]\n    summary: synthetic")

    static let brokenMalformedFilename = filenameV2
        .replacingOccurrences(of: "id: synth", with: "id: broken")
        .replacingOccurrences(of: "name: Synth", with: "name: Broken")
        .replacingOccurrences(of: "filename_contains_all: [\"synth-token\", \"dual-sweep\"]", with: "filename_contains_all: []")

    /// Schema v2 shape with two modes: the first pairs a matching filename
    /// selector with a missing detect list (uncertain, must block); the second
    /// carries an unrelated valid signature (proven unrelated on its own).
    static let brokenUncertainFilename = """
    schema_version: 2
    instrument:
      id: broken
      name: Broken
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
      - id: uncertain
        format: csv
        filename_contains_all: ["synth-token", "dual-sweep"]
        detect: []
        extract:
          x: voltage
          y: [current]
      - id: elsewhere
        format: csv
        detect: ["SYNTH-ELSEWHERE-HEADER"]
        extract:
          x: voltage
          y: [current]
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
