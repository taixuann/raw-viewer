import Foundation
import Testing
@testable import RawViewCore

struct KeithleyMetadataTests {
    @Test func sweepPathDerivationFindsTurningPoints() {
        // Linear rise, fall to negative, return to zero
        let sweep: [Double] = [0.0, 0.5, 1.0, 1.5, 1.0, 0.5, 0.0, -0.5, -1.0, -1.5, -1.0, -0.5, 0.0]
        let path = KeithleyMetadataParser.deriveSweepPath(from: sweep)
        #expect(path == "0 → +1.5 → -1.5 → 0 V")
    }

    @Test func sweepPathHandlesMultiPeak() {
        let sweep: [Double] = [0.0, 1.0, 2.0, 0.0, 3.0, 0.0]
        let path = KeithleyMetadataParser.deriveSweepPath(from: sweep)
        #expect(path == "0 → +2 → 0 → +3 → 0 V")
    }

    @Test func voltageStepUniformAndVariable() {
        let uniform: [Double] = [0.0, 0.05, 0.10, 0.15, 0.20]
        #expect(KeithleyMetadataParser.deriveVoltageStep(from: uniform) == "0.05 V")

        let variable: [Double] = [0.0, 0.05, 0.15, 0.20]
        let varStep = KeithleyMetadataParser.deriveVoltageStep(from: variable)
        #expect(varStep.hasPrefix("Variable"))
    }

    @Test func complianceFormattingWithDeclaredUnits() {
        #expect(KeithleyMetadataParser.formatCompliance(0.000100) == "100 µA")
        #expect(KeithleyMetadataParser.formatCompliance(0.001) == "1 mA")
        #expect(KeithleyMetadataParser.formatCompliance(1.0) == "1.00 A")
        #expect(KeithleyMetadataParser.formatCompliance(0.00000005) == "50.0 nA")
    }

    @Test func parsesKeithleyCommentLineCorrectly() {
        let line = "Voltage list: 0.00;0.05;0.10;1.50;1.45;0.00;-1.50;-1.45;0.00 | Compliance level: 0.000100"
        let meta = KeithleyMetadataParser.parseLine(line)
        #expect(meta.isValid == true)
        #expect(meta.sweepPath == "0 → +1.5 → -1.5 → 0 V")
        #expect(meta.compliance == "100 µA")
        #expect(meta.warning == nil)
    }

    @Test func malformedCommentWarnsAndMarksInvalid() {
        let line = "Voltage list: 0.00;abc;1.00 | Compliance level: xyz"
        let meta = KeithleyMetadataParser.parseLine(line)
        #expect(meta.isValid == false)
        #expect(meta.warning != nil)
        #expect(meta.sweepPath == "Invalid path")
    }

    @Test func usthKeithleyFixtureExtractsCorrectSweepMetadata() async throws {
        // Resolve from this source file. A relative path ran from apps/macos and skipped the check silently.
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let fixtureURL = repoRoot.appendingPathComponent("fixtures/workspaces/usth-lab/data/raw/2026-10-07/071026-143703_keithley-2400.dual-sweep_[cu-ec-pda.q14-ito.2_r2-c6]_iv.dual-sweep_r.[reproducible]_010.txt")
        try #require(FileManager.default.fileExists(atPath: fixtureURL.path))
        let meta = try #require(KeithleyMetadataParser.extract(from: fixtureURL))
        #expect(meta.isValid == true)
        #expect(meta.sweepPath == "0 → +1.5 → -1.5 → 0 V")
        #expect(meta.voltageStep == "0.05 V")
        #expect(meta.compliance == "100 µA")
        #expect(meta.rawVoltageCount == 121)
    }

    @Test func longSweepFiveThousandPointsKeepsPathStepCountAndCompliance() throws {
        let comment = KeithleySweepFixtures.comment(tokens: KeithleySweepFixtures.longVoltageTokens())
        let url = try KeithleySweepFixtures.writeTemp(KeithleySweepFixtures.lvmText(comment: comment))
        defer { try? FileManager.default.removeItem(at: url) }

        let meta = try #require(KeithleyMetadataParser.extract(from: url))
        #expect(meta.isValid == true)
        #expect(meta.warning == nil)
        #expect(meta.sweepPath == "0 → +25 → -25 → 0 V")
        #expect(meta.voltageStep == "0.02 V")
        #expect(meta.rawVoltageCount == 5001)
        #expect(meta.compliance == "100 µA")
    }

    @Test func commentLongerThanSafetyLimitWarnsInsteadOfWrongValue() throws {
        // About 4.5 MB on one line, above the 4 MB per-line limit.
        let oversized = "Voltage list: " + String(repeating: "0.00;", count: 900_000) + "0.00 | Compliance level: 0.000100"
        let url = try KeithleySweepFixtures.writeTemp(KeithleySweepFixtures.lvmText(comment: oversized))
        defer { try? FileManager.default.removeItem(at: url) }

        let meta = try #require(KeithleyMetadataParser.extract(from: url))
        #expect(meta.isValid == false)
        #expect(meta.sweepPath == nil)
        #expect(meta.voltageStep == nil)
        #expect(meta.compliance == nil)
        #expect(meta.rawVoltageCount == 0)
        #expect(meta.warning == "Keithley comment line exceeds 4 MB; sweep not read")
    }

    @Test func cacheReadsSourceOnceAcrossRepeatedLookups() async throws {
        let comment = KeithleySweepFixtures.comment(tokens: KeithleySweepFixtures.sampleVoltageTokens())
        let url = try KeithleySweepFixtures.writeTemp(KeithleySweepFixtures.lvmText(comment: comment))
        defer { try? FileManager.default.removeItem(at: url) }
        let cache = KeithleyMetadataCache()

        // Five lookups stand in for repeated view body evaluations.
        var results: [KeithleyMetadata] = []
        for _ in 0..<5 {
            let meta = await cache.metadata(sourceID: url.path, url: url)
            results.append(try #require(meta))
        }

        let reads = await cache.extractionCount
        #expect(reads == 1)
        for meta in results {
            #expect(meta.sweepPath == "0 → +1.5 → -1.5 → 0 V")
            #expect(meta.voltageStep == "0.02 V")
            #expect(meta.compliance == "100 µA")
            #expect(meta.rawVoltageCount == 301)
            #expect(meta.isValid == true)
            #expect(meta.warning == nil)
        }
    }

    @Test func changedModificationTimeInvalidatesCachedSweep() async throws {
        let tokens = KeithleySweepFixtures.sampleVoltageTokens()
        let url = try KeithleySweepFixtures.writeTemp(KeithleySweepFixtures.lvmText(comment: KeithleySweepFixtures.comment(tokens: tokens)))
        defer { try? FileManager.default.removeItem(at: url) }
        let cache = KeithleyMetadataCache()

        let before = try #require(await cache.metadata(sourceID: url.path, url: url))
        #expect(before.compliance == "100 µA")

        // Rewrite the export with a new compliance and a later modification time.
        let edited = KeithleySweepFixtures.comment(tokens: tokens, compliance: "0.001")
        try KeithleySweepFixtures.lvmText(comment: edited).write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: url.path)

        let after = try #require(await cache.metadata(sourceID: url.path, url: url))
        let reads = await cache.extractionCount
        #expect(reads == 2)
        #expect(after.sweepPath == "0 → +1.5 → -1.5 → 0 V")
        #expect(after.voltageStep == "0.02 V")
        #expect(after.compliance == "1 mA")
        #expect(after.rawVoltageCount == 301)
    }

    @Test func sampleFileGivesPathStepAndCompliance() throws {
        let comment = KeithleySweepFixtures.comment(tokens: KeithleySweepFixtures.sampleVoltageTokens())
        let url = try KeithleySweepFixtures.writeTemp(KeithleySweepFixtures.lvmText(comment: comment))
        defer { try? FileManager.default.removeItem(at: url) }

        let meta = try #require(KeithleyMetadataParser.extract(from: url))
        #expect(meta.sweepPath == "0 → +1.5 → -1.5 → 0 V")
        #expect(meta.voltageStep == "0.02 V")
        #expect(meta.compliance == "100 µA")
        #expect(meta.rawVoltageCount == 301)
        #expect(meta.isValid == true)
        #expect(meta.warning == nil)
    }

    @Test func nonUniformVoltageListShowsVariableStep() {
        let meta = KeithleyMetadataParser.parseLine("Voltage list: 0.00;0.02;0.06;0.08 | Compliance level: 0.000100")
        #expect(meta.sweepPath == "0 → +0.08 V")
        #expect(meta.voltageStep == "Variable (0.02 – 0.04 V)")
        #expect(meta.compliance == "100 µA")
        #expect(meta.rawVoltageCount == 4)
        #expect(meta.isValid == true)
        #expect(meta.warning == nil)
    }

    @Test func emptyCommentCellShowsNullForEveryField() throws {
        let url = try KeithleySweepFixtures.writeTemp(KeithleySweepFixtures.lvmText(comment: ""))
        defer { try? FileManager.default.removeItem(at: url) }

        let meta = try #require(KeithleyMetadataParser.extract(from: url))
        #expect(meta.sweepPath == nil)
        #expect(meta.voltageStep == nil)
        #expect(meta.compliance == nil)
        #expect(meta.rawVoltageCount == 0)
        #expect(meta.isValid == true)
        #expect(meta.warning == nil)
    }

    @Test func complianceOnlyShowsNullVoltageAndStepWithCompliance() {
        let meta = KeithleyMetadataParser.parseLine("Compliance level: 0.000100")
        #expect(meta.sweepPath == nil)
        #expect(meta.voltageStep == nil)
        #expect(meta.compliance == "100 µA")
        #expect(meta.rawVoltageCount == 0)
        #expect(meta.isValid == true)
        #expect(meta.warning == nil)
    }

    @Test func malformedVoltageTokenKeepsWarning() {
        let meta = KeithleyMetadataParser.parseLine("Voltage list: 0.00;abc;1.00 | Compliance level: 0.000100")
        #expect(meta.sweepPath == "Invalid path")
        #expect(meta.voltageStep == "Invalid step")
        #expect(meta.compliance == "100 µA")
        #expect(meta.rawVoltageCount == 0)
        #expect(meta.isValid == false)
        #expect(meta.warning == "Malformed Voltage list tokens in comment")
    }

    @Test func fileMatchedOtherProfileNeverShowsKeithleyBlock() {
        // The gate reads the matched profile id only. A comment with "Voltage list:" does not open it.
        let text = "Voltage list: 0.00;0.02;0.00 | Compliance level: 0.000100"
        #expect(KeithleyMetadataParser.parseLine(text).sweepPath == "0 → +0.02 → 0 V")
        #expect(KeithleyMetadataParser.isKeithley2400(profileID: "usth/autolab-usth") == false)
        #expect(KeithleyMetadataParser.isKeithley2400(profileID: nil) == false)
        #expect(KeithleyMetadataParser.isKeithley2400(profileID: "usth/keithley-2400") == true)
    }

    @Test func multiSelectCompareSharesPathAndStepAndFlagsCompliance() {
        let tokens = KeithleySweepFixtures.sampleVoltageTokens()
        let first = KeithleyMetadataParser.parseLine(KeithleySweepFixtures.comment(tokens: tokens, compliance: "0.000100"))
        let second = KeithleyMetadataParser.parseLine(KeithleySweepFixtures.comment(tokens: tokens, compliance: "0.001"))
        let metas = [first, second]

        #expect(metas.map(\.sweepPath) == ["0 → +1.5 → -1.5 → 0 V", "0 → +1.5 → -1.5 → 0 V"])
        #expect(metas.map(\.voltageStep) == ["0.02 V", "0.02 V"])
        #expect(metas.map(\.compliance) == ["100 µA", "1 mA"])
        #expect(KeithleyMetadataParser.allSame(metas.map(\.sweepPath)) == true)
        #expect(KeithleyMetadataParser.allSame(metas.map(\.voltageStep)) == true)
        #expect(KeithleyMetadataParser.allSame(metas.map(\.compliance)) == false)
        // A file with no sweep (Null) differs from one that has a sweep.
        #expect(KeithleyMetadataParser.allSame([first.sweepPath, KeithleyMetadata.absent.sweepPath]) == false)
    }
}
