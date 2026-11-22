import Foundation

/// Keeps the value for the last key it saw. A read with an equal key returns the
/// cached value, so SwiftUI body re-evaluations (for example, on hover) skip the work.
public final class PlotMemo<Key: Equatable, Value> {
    private var cached: (key: Key, value: Value)?
    public private(set) var computeCount = 0

    public init() {}

    public func value(for key: Key, compute: () -> Value) -> Value {
        if let cached, cached.key == key { return cached.value }
        computeCount += 1
        let value = compute()
        cached = (key, value)
        return value
    }
}
