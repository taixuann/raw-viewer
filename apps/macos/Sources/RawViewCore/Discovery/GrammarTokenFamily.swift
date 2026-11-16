import Foundation

/// Visual family of a grammar token. One family per hue in the shared token style.
/// Chosen from the field's type and role only, never from the token's name.
public enum GrammarTokenFamily: String, Sendable, CaseIterable {
    case time
    case instrument
    case device
    case mode
    case category
    case batch
    case remarks
    case neutral

    public init(role: String?, type: GrammarFieldType?) {
        if type == .datetime {
            self = .time
            return
        }
        // Stored roles are labels such as "Device ID"; the engine maps them to stable keys.
        let key = role.map { FilenameGrammarEngine.canonicalRoleKey(for: $0.trimmingCharacters(in: .whitespaces)) }
        switch key {
        case "instrument": self = .instrument
        case "device": self = .device
        case "mode", "application-mode": self = .mode
        case "category": self = .category
        case "batch": self = .batch
        case "remarks", "remark": self = .remarks
        default: self = type == .number ? .batch : .neutral
        }
    }
}
