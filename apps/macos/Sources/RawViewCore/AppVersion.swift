import Foundation

/// Robust Semantic Versioning model supporting standard `vX.Y.Z` and `X.Y.Z` comparison
/// with SemVer 2.0.0 pre-release precedence.
public struct SemanticVersion: Comparable, Equatable, Sendable, CustomStringConvertible {
    public let major: Int
    public let minor: Int
    public let patch: Int
    public let prerelease: String?
    public let raw: String

    public init(_ string: String) {
        self.raw = string
        let clean = string.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
        let mainAndPre = clean.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        let mainPart = mainAndPre.first.map(String.init) ?? clean
        self.prerelease = mainAndPre.count > 1 ? String(mainAndPre[1]) : nil

        let parts = mainPart.split(separator: ".").compactMap { Int($0.prefix(while: { $0.isNumber })) }
        self.major = parts.count > 0 ? parts[0] : 0
        self.minor = parts.count > 1 ? parts[1] : 0
        self.patch = parts.count > 2 ? parts[2] : 0
    }

    public var description: String {
        if let prerelease {
            return "\(major).\(minor).\(patch)-\(prerelease)"
        }
        return "\(major).\(minor).\(patch)"
    }

    public static func == (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        lhs.major == rhs.major && lhs.minor == rhs.minor && lhs.patch == rhs.patch && lhs.prerelease == rhs.prerelease
    }

    public static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        if lhs.patch != rhs.patch { return lhs.patch < rhs.patch }

        // SemVer 2.0.0: A normal version has greater precedence than a pre-release version
        // (i.e. 0.4.0-rc.1 < 0.4.0)
        switch (lhs.prerelease, rhs.prerelease) {
        case (.some(let lPre), .some(let rPre)):
            return lPre < rPre
        case (.some, .none):
            return true
        case (.none, .some):
            return false
        case (.none, .none):
            return false
        }
    }

    public static func isNewer(latest: String, current: String) -> Bool {
        SemanticVersion(latest) > SemanticVersion(current)
    }
}
