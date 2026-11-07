import Foundation

/// Robust Semantic Versioning model supporting standard `vX.Y.Z` and `X.Y.Z` comparison.
public struct SemanticVersion: Comparable, Equatable, Sendable, CustomStringConvertible {
    public let major: Int
    public let minor: Int
    public let patch: Int
    public let raw: String

    public init(_ string: String) {
        self.raw = string
        let clean = string.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
        let parts = clean.split(separator: ".").compactMap { Int($0.prefix(while: { $0.isNumber })) }
        self.major = parts.count > 0 ? parts[0] : 0
        self.minor = parts.count > 1 ? parts[1] : 0
        self.patch = parts.count > 2 ? parts[2] : 0
    }

    public var description: String {
        "\(major).\(minor).\(patch)"
    }

    public static func == (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        lhs.major == rhs.major && lhs.minor == rhs.minor && lhs.patch == rhs.patch
    }

    public static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        return lhs.patch < rhs.patch
    }

    public static func isNewer(latest: String, current: String) -> Bool {
        SemanticVersion(latest) > SemanticVersion(current)
    }
}
