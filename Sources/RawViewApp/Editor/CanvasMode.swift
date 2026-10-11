import SwiftUI
import RawViewCore

public enum CanvasMode: String, CaseIterable, Identifiable {
    case matrix = "Data Matrix"
    case stream = "Raw Stream & Parser"
    public var id: String { rawValue }
}

