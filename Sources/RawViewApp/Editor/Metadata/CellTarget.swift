import SwiftUI
import RawViewCore

/// A targeted cell coordinates and token value for metadata tagging interactions.
public struct CellTarget: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let lineIdx: Int
    public let tokenIdx: Int
    public let token: String

    public init(id: UUID = UUID(), lineIdx: Int, tokenIdx: Int, token: String) {
        self.id = id
        self.lineIdx = lineIdx
        self.tokenIdx = tokenIdx
        self.token = token
    }
}
