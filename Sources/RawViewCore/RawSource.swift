import Foundation

public struct RawSource: Identifiable, Hashable, Sendable {
    public let relativePath: String
    public let url: URL
    public let byteSize: Int64
    public let mtime: Int64

    public var id: String { relativePath }

    public init(relativePath: String, url: URL, byteSize: Int64, mtime: Int64 = 0) {
        self.relativePath = relativePath
        self.url = url
        self.byteSize = byteSize
        self.mtime = mtime
    }
}
