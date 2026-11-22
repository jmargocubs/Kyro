import Foundation

public protocol KyroIdentifier: Hashable, Codable, Sendable, CustomStringConvertible {
    var rawValue: UUID { get }
    init(_ rawValue: UUID)
}
public extension KyroIdentifier {
    var description: String { rawValue.uuidString.lowercased() }
}
public struct HouseholdID: KyroIdentifier { public let rawValue: UUID; public init(_ rawValue: UUID = UUID()) { self.rawValue = rawValue } }
public struct KyroProfileID: KyroIdentifier { public let rawValue: UUID; public init(_ rawValue: UUID = UUID()) { self.rawValue = rawValue } }
public struct DeviceID: KyroIdentifier { public let rawValue: UUID; public init(_ rawValue: UUID = UUID()) { self.rawValue = rawValue } }
public struct ProviderAccountID: KyroIdentifier { public let rawValue: UUID; public init(_ rawValue: UUID = UUID()) { self.rawValue = rawValue } }

public struct HybridLogicalClock: Codable, Hashable, Sendable, Comparable {
    public let physicalMilliseconds: Int64
    public let logical: UInt32
    public let node: String
    public init(physicalMilliseconds: Int64, logical: UInt32, node: String) {
        self.physicalMilliseconds = physicalMilliseconds; self.logical = logical; self.node = node
    }
    public static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.physicalMilliseconds, lhs.logical, lhs.node) < (rhs.physicalMilliseconds, rhs.logical, rhs.node)
    }
    public func advanced(now: Int64, maximumFutureSkew: Int64 = 300_000) -> Self {
        let clamped = min(now, physicalMilliseconds + max(0, maximumFutureSkew))
        return clamped > physicalMilliseconds ? Self(physicalMilliseconds: clamped, logical: 0, node: node) : Self(physicalMilliseconds: physicalMilliseconds, logical: logical &+ 1, node: node)
    }
    public static func merge(local: Self, remote: Self, now: Int64, maximumFutureSkew: Int64 = 300_000) -> Self {
        let ceiling = now + max(0, maximumFutureSkew)
        let l = min(local.physicalMilliseconds, ceiling), r = min(remote.physicalMilliseconds, ceiling)
        let p = max(now, l, r)
        let c: UInt32 = p == l && p == r ? max(local.logical, remote.logical) &+ 1 : p == l ? local.logical &+ 1 : p == r ? remote.logical &+ 1 : 0
        return Self(physicalMilliseconds: p, logical: c, node: min(local.node, remote.node))
    }
}

public enum Redactor {
    public static func redact(_ string: String) -> String {
        var value = string
        for pattern in ["(?i)(password|token|secret|api[_-]?key|pin)(\\s*[=:]\\s*)[^\\s&,;]+", "(?i)(https?://)[^/@\\s]+:[^/@\\s]+@"] {
            if let regex = try? NSRegularExpression(pattern: pattern) {
                let range = NSRange(value.startIndex..., in: value)
                value = regex.stringByReplacingMatches(in: value, range: range, withTemplate: "$1$2[REDACTED]")
            }
        }
        return value
    }
}

public struct StorageLocation: Sendable { public let url: URL; public init(url: URL) { self.url = url } }
