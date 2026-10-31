import Foundation
import Testing
@testable import RawViewCore

struct WhenMatcherTests {
    private func writeMinimalProject(at root: URL) throws {
        let setting = """
        schema_version: 1
        data_root: data/raw
        """
        let url = root.appendingPathComponent(".rawviewer/setting.yaml")
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try setting.write(to: url, atomically: true, encoding: .utf8)
    }

    @Test func tokenExactMatchRejectsNearMissSubstring() {
        let merged = ProfileWhenMatcher.whenFromLegacy(
            detect: ["SIG"], filenameContainsAll: ["needle"])
        let hit = ProfileWhenMatcher.tokenizeBasename("my_needle_extra.csv")
        #expect(
            ProfileWhenMatcher.matchesWhen(
                merged, grammarFields: nil, basenameTokens: hit, headerSample: "SIG",
                basenameForContent: "my_needle_extra.csv"))
        let miss = ProfileWhenMatcher.tokenizeBasename("my_needlefish.csv")
        #expect(
            !ProfileWhenMatcher.matchesWhen(
                merged, grammarFields: nil, basenameTokens: miss, headerSample: "SIG",
                basenameForContent: "my_needlefish.csv"))
    }

    @Test func contentContainsAnyMatchesHeader() {
        let merged = ProfileWhenMatcher.whenFromLegacy(
            detect: ["alpha-header", "beta-header"], filenameContainsAll: nil)
        #expect(
            ProfileWhenMatcher.matchesWhen(
                merged, grammarFields: nil, basenameTokens: [], headerSample: "prefix alpha-header suffix",
                basenameForContent: "file.csv"))
    }

    @Test func contentAndFilenameRequiresBoth() {
        let merged = ProfileWhenMatcher.whenFromLegacy(detect: ["HDR"], filenameContainsAll: ["tok"])
        let tokens = ProfileWhenMatcher.tokenizeBasename("tok.csv")
        #expect(
            ProfileWhenMatcher.matchesWhen(
                merged, grammarFields: nil, basenameTokens: tokens, headerSample: "HDR",
                basenameForContent: "tok.csv"))
        #expect(
            !ProfileWhenMatcher.matchesWhen(
                merged, grammarFields: nil, basenameTokens: tokens, headerSample: "no-header",
                basenameForContent: "tok.csv"))
    }

    @Test func noGrammarContentOnlyPath() {
        let grammar = ProfileWhenMatcher.GrammarMatchContext(catalogLoaded: true, matchedFields: nil)
        let contentOnly = ProfileWhenMatcher.whenFromLegacy(detect: ["HDR"], filenameContainsAll: nil)
        let filenameGated = ProfileWhenMatcher.whenFromLegacy(detect: ["HDR"], filenameContainsAll: ["gate"])
        #expect(ProfileWhenMatcher.modeIsCandidate(contentOnly, grammar: grammar))
        #expect(!ProfileWhenMatcher.modeIsCandidate(filenameGated, grammar: grammar))
    }

    @Test func grammarMatchZeroHitsIsError() throws {
        let yaml = """
        schema_version: 4
        id: test/grammar-miss
        instrument:
          id: synth
          name: Synth
        when:
          mode: list-sweep
        variants:
          dual-sweep:
            when:
              content_contains_any: [SYNTH-SPECIFIC-HEADER]
              filename_contains_all: [synth-token, dual-sweep]
            format:
              kind: tabular
              extensions: [.csv]
              delimiter: ","
              encoding: [utf-8]
            rows:
              names_prefix: DataName
              data_prefix: DataValue
            metadata: []
            columns:
              voltage:
                role: channel
                header: V1
                quantity: voltage
                unit: V
              current:
                role: channel
                header: I1
                quantity: current
                unit: A
            plot:
              x: voltage
              y: [current]
        """
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "rawview-when-swift-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("data/instruments"), withIntermediateDirectories: true)
        try yaml.write(to: root.appendingPathComponent("data/instruments/x.yaml"), atomically: true, encoding: .utf8)
        try writeMinimalProject(at: root)
        let project = try ProjectContext.open(root)
        let catalog = ProfileCatalog.load(project: project)
        let grammar = ProfileWhenMatcher.GrammarMatchContext(
            catalogLoaded: true, matchedFields: ["mode": "cv"])
        let resolution = catalog.resolve(
            extension: ".csv", headerSample: "SYNTH-SPECIFIC-HEADER",
            basename: "run_synth-token_dual-sweep.csv", grammar: grammar)
        #expect(resolution.resolveCode == .grammarMatchedNoProfile)
    }

    @Test func twoHitsAmbiguousProfileSortedCandidates() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "rawview-when-amb-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("data/instruments"), withIntermediateDirectories: true)
        let base = """
        schema_version: 2
        instrument:
          id: synth
          name: Synth
        formats:
          - id: csv
            kind: tabular
            extensions: [".csv"]
            delimiter: ","
            encoding: [utf-8]
            rows:
              names_prefix: DataName
              data_prefix: DataValue
            columns:
              voltage:
                header: V1
                quantity: voltage
                unit: V
              current:
                header: I1
                quantity: current
                unit: A
        modes:
          - id: dual-sweep
            format: csv
            detect: [SYNTH-SPECIFIC-HEADER]
            filename_contains_all: [synth-token, dual-sweep]
            extract:
              x: voltage
              y: [current]
        """
        try base.write(to: root.appendingPathComponent("data/instruments/a.yaml"), atomically: true, encoding: .utf8)
        try base.replacingOccurrences(of: "id: synth", with: "id: synth-alt").write(
            to: root.appendingPathComponent("data/instruments/b.yaml"), atomically: true, encoding: .utf8)
        try writeMinimalProject(at: root)
        let project = try ProjectContext.open(root)
        let catalog = ProfileCatalog.load(project: project)
        let resolution = catalog.resolve(
            extension: ".csv", headerSample: "SYNTH-SPECIFIC-HEADER",
            basename: "run_synth-token_dual-sweep.csv",
            grammar: .withoutCatalog())
        guard case .ambiguousProfile(let ids) = resolution else {
            Issue.record("expected ambiguous_profile")
            return
        }
        #expect(ids == ["synth", "synth-alt"])
    }

    @Test func variantAndProfileWhenBothRequired() {
        var profileWhen = ProfileWhenMatcher.WhenClause(
            grammarTokens: ["mode": "cv"], contentContainsAny: ["HDR"])
        let variantWhen = ProfileWhenMatcher.WhenClause(grammarTokens: ["instrument": "autolab"])
        let merged = ProfileWhenMatcher.mergeWhen(profile: profileWhen, variant: variantWhen)
        let fields = ["mode": "cv", "instrument": "autolab"]
        #expect(
            ProfileWhenMatcher.matchesWhen(
                merged, grammarFields: fields, basenameTokens: [], headerSample: "HDR",
                basenameForContent: "x.csv"))
        profileWhen.grammarTokens["mode"] = "wrong"
        let mergedBad = ProfileWhenMatcher.mergeWhen(profile: profileWhen, variant: variantWhen)
        #expect(
            !ProfileWhenMatcher.matchesWhen(
                mergedBad, grammarFields: fields, basenameTokens: [], headerSample: "HDR",
                basenameForContent: "x.csv"))
    }

    @Test func variantWhenWithoutContentCompiles() throws {
        let yaml = """
        schema_version: 4
        id: test/token-only
        instrument:
          id: synth
          name: Synth
        variants:
          token-only:
            when:
              filename_contains_all: [synth-token]
            format:
              kind: tabular
              extensions: [.csv]
              delimiter: ","
              encoding: [utf-8]
            rows:
              names_prefix: DataName
              data_prefix: DataValue
            metadata: []
            columns:
              voltage:
                role: channel
                header: V1
                quantity: voltage
                unit: V
              current:
                role: channel
                header: I1
                quantity: current
                unit: A
            plot:
              x: voltage
              y: [current]
        """
        let outcome = ProfileSchema.load(
            text: yaml, relativePath: "data/instruments/token-only.yaml", sha256: "test")
        #expect(outcome.profile != nil)
    }

    @Test func legacyFilenameContainsAllTranslation() {
        let when = ProfileWhenMatcher.whenFromLegacy(
            detect: [], filenameContainsAll: ["synth-token", "dual-sweep"])
        #expect(when.filenameTokens == ["synth", "token", "dual", "sweep"])
    }
}
