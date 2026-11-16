import XCTest
@testable import RawViewCore

/// Revision-bump check for the bundled USTH profiles (issue #121, acceptance case 7).
final class BundledRevisionTableTests: XCTestCase {
    private struct CommittedTable: Decodable {
        let package_id: String
        let version: String
        let profiles: [Row]
    }

    private struct Row: Decodable {
        let id: String
        let revision: Int
        let sha256: String
    }

    /// Swift copies that differ from `assets/profiles/usth/` today. Each entry is drift the table
    /// cannot express yet. Remove the entry when the copy is synced in a revision-bumped change.
    private let knownDrift: Set<String> = ["usth/autolab-usth"]

    private static func repoRoot() -> URL {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 {
            url.deleteLastPathComponent()
        }
        return url
    }

    /// Violations of the rule: a changed profile must bump its revision and update the table.
    private func violations(table: [Row], bundled: [(id: String, text: String)]) -> [String] {
        var out: [String] = []
        for row in table {
            guard let entry = bundled.first(where: { $0.id == row.id }) else {
                out.append("\(row.id): no bundled profile text")
                continue
            }
            let sha = sha256Hex(Data(entry.text.utf8))
            let revision = LabPackageManager.profileRevision(in: entry.text)
            if sha == row.sha256 && revision == row.revision {
                continue
            }
            if sha != row.sha256 && revision == row.revision {
                out.append("\(row.id): changed without a revision bump")
            } else {
                out.append("\(row.id): committed table is stale")
            }
        }
        return out
    }

    private func loadCommittedTable() throws -> CommittedTable {
        let url = Self.repoRoot().appendingPathComponent("fixtures/packages/usth-lab/bundled-profiles.json")
        return try JSONDecoder().decode(CommittedTable.self, from: Data(contentsOf: url))
    }

    func testBundledSwiftProfilesMatchCommittedRevisionTable() throws {
        let table = try loadCommittedTable()
        XCTAssertEqual(table.package_id, "usth-lab")
        XCTAssertEqual(table.version, LabPackageManager.usthPackageVersion)

        let bundled = BuiltinAssets.builtinProfiles.map { (id: $0.id, text: LabPackageManager.bundledText($0.yaml)) }
        let found = violations(table: table.profiles, bundled: bundled)
        let unexpected = found.filter { line in !knownDrift.contains(String(line.prefix { $0 != ":" })) }
        XCTAssertEqual(unexpected, [], "bundled profiles drifted from the committed table")

        let drifted = Set(table.profiles.filter { row in
            let text = bundled.first(where: { $0.id == row.id })?.text ?? ""
            return sha256Hex(Data(text.utf8)) != row.sha256
        }.map(\.id))
        XCTAssertEqual(drifted, knownDrift, "the waiver must list exactly the current drift")
    }

    func testChangedProfileWithUnchangedRevisionIsReported() throws {
        let table = try loadCommittedTable()
        let keithley = LabPackageManager.bundledText(BuiltinAssets.keithley2400YAML)
        let bundled = BuiltinAssets.builtinProfiles.map { item -> (id: String, text: String) in
            let text = LabPackageManager.bundledText(item.yaml)
            return (id: item.id, text: item.id == "usth/keithley-2400" ? text + "# edited\n" : text)
        }
        XCTAssertNotEqual(keithley, bundled[0].text)

        let found = violations(table: table.profiles, bundled: bundled)

        XCTAssertEqual(found.count, 1 + knownDrift.count, found.description)
        XCTAssertTrue(found.contains("usth/keithley-2400: changed without a revision bump"), found.description)
    }
}
