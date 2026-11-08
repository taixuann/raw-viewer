import Foundation
import Testing
@testable import RawViewCore

struct KeithleyMetadataTests {
    @Test func sweepPathDerivationFindsTurningPoints() {
        // Linear rise, fall to negative, return to zero
        let sweep: [Double] = [0.0, 0.5, 1.0, 1.5, 1.0, 0.5, 0.0, -0.5, -1.0, -1.5, -1.0, -0.5, 0.0]
        let path = KeithleyMetadataParser.deriveSweepPath(from: sweep)
        #expect(path == "0 → 1.5 → -1.5 → 0 V")
    }

    @Test func sweepPathHandlesMultiPeak() {
        let sweep: [Double] = [0.0, 1.0, 2.0, 0.0, 3.0, 0.0]
        let path = KeithleyMetadataParser.deriveSweepPath(from: sweep)
        #expect(path == "0 → 2 → 0 → 3 → 0 V")
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
        #expect(meta.sweepPath == "0 → 1.5 → -1.5 → 0 V")
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
        let fixtureURL = URL(fileURLWithPath: "fixtures/workspaces/usth-lab/data/raw/2026-10-07/071026-143703_keithley-2400.dual-sweep_[cu-ec-pda.q14-ito.2_r2-c6]_iv.dual-sweep_r.[reproducible]_010.txt")
        guard FileManager.default.fileExists(atPath: fixtureURL.path) else { return }
        let meta = try #require(KeithleyMetadataParser.extract(from: fixtureURL))
        #expect(meta.isValid == true)
        #expect(meta.sweepPath == "0 → 1.5 → -1.5 → 0 V")
        #expect(meta.voltageStep == "0.05 V")
        #expect(meta.compliance == "100 µA")
        #expect(meta.rawVoltageCount == 121)
    }
}
