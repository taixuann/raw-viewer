import Foundation

/// Visual family of a grammar token. One family per hue in the shared token style.
/// Chosen from the field's type and role only, never from the token's name.
public enum GrammarTokenFamily: String, Sendable, CaseIterable {
    case time
    case instrument
    case method
    case sample
    case remarks
    case neutral

    public init(role: String?, type: GrammarFieldType?) {
        if type == .datetime {
            self = .time
            return
        }
        switch role?.trimmingCharacters(in: .whitespaces).lowercased() {
        case "instrument", "device": self = .instrument
        case "mode", "application-mode", "category": self = .method
        case "batch": self = .sample
        case "remarks", "remark": self = .remarks
        default: self = type == .number ? .sample : .neutral
        }
    }
}
