import Foundation

/// Keep cross-device changes bounded while reducing idle polling.
public enum RefreshPolicy {
    public static func interval(lastActivity: Date?, lastChange: Date?, isLowPower: Bool = false, now: Date) -> TimeInterval {
        if isLowPower { return 300 }
        let recent = [lastActivity, lastChange].compactMap { $0 }.max()
        guard let recent, now.timeIntervalSince(recent) < 600 else { return 300 }
        return 60
    }
}

/// An unknown or changed account must not inherit another account's baseline.
public struct RecoveryAccountGate: Sendable {
    private var identity: String?

    public init() {}

    public mutating func canCompare(identity next: String?) -> Bool {
        guard let next, !next.isEmpty else {
            identity = nil
            return false
        }
        let matches = identity == next
        identity = next
        return matches
    }
}
