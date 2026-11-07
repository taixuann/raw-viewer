import Testing
@testable import RawViewCore

struct AppVersionTests {
    @Test func versionParsingStripsPrefixAndExtractsComponents() {
        let v1 = SemanticVersion("v0.3.2")
        #expect(v1.major == 0)
        #expect(v1.minor == 3)
        #expect(v1.patch == 2)
        #expect(v1.description == "0.3.2")

        let v2 = SemanticVersion("1.0.0")
        #expect(v2.major == 1)
        #expect(v2.minor == 0)
        #expect(v2.patch == 0)

        let v3 = SemanticVersion("V2.14.8-beta")
        #expect(v3.major == 2)
        #expect(v3.minor == 14)
        #expect(v3.patch == 8)
    }

    @Test func versionComparisonAndUpToDateSemantics() {
        // Equal versions with/without 'v' prefix are equal (up to date)
        #expect(SemanticVersion("v0.3.2") == SemanticVersion("0.3.2"))
        #expect(!SemanticVersion.isNewer(latest: "v0.3.2", current: "0.3.2"))
        #expect(!SemanticVersion.isNewer(latest: "0.3.2", current: "v0.3.2"))

        // Newer remote version
        #expect(SemanticVersion.isNewer(latest: "v0.3.3", current: "0.3.2"))
        #expect(SemanticVersion.isNewer(latest: "0.4.0", current: "0.3.2"))
        #expect(SemanticVersion.isNewer(latest: "1.0.0", current: "0.3.2"))

        // Older remote version (local is ahead or development build)
        #expect(!SemanticVersion.isNewer(latest: "0.2.0", current: "0.3.2"))
        #expect(!SemanticVersion.isNewer(latest: "v0.3.1", current: "0.3.2"))
    }
}
