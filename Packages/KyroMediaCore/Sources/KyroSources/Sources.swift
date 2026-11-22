import Foundation
import KyroFoundation
import KyroCatalog

public struct SourceCapabilities: OptionSet, Codable, Sendable { public let rawValue: UInt16; public init(rawValue:UInt16){self.rawValue=rawValue}; public static let catalog=Self(rawValue:1); public static let playback=Self(rawValue:2); public static let progressWrite=Self(rawValue:4); public static let liveTV=Self(rawValue:8) }
public protocol MediaSourceAdapter: Sendable { var capabilities: SourceCapabilities { get }; func fetchCatalog() async throws -> [CanonicalMedia] }
public struct HTTPRateLimiter: Sendable {
    public let minimumInterval: Duration; public init(requestsPerSecond:Double){minimumInterval = .milliseconds(Int64(1000/max(0.01,requestsPerSecond)))}
    public func wait() async throws { try await Task.sleep(for:minimumInterval) }
}
public struct RetryPolicy: Sendable { public let maximumAttempts:Int; public let baseDelay:Duration; public init(maximumAttempts:Int=4,baseDelay:Duration = .milliseconds(150)){self.maximumAttempts=max(1,maximumAttempts);self.baseDelay=baseDelay} }
public actor CircuitBreaker {
    public enum State: Sendable { case closed, open(until: ContinuousClock.Instant), halfOpen }
    private(set) var state:State = .closed; private var failures=0; private let threshold:Int; private let cooldown:Duration
    public init(threshold:Int=3,cooldown:Duration = .seconds(15)){self.threshold=max(1,threshold);self.cooldown=cooldown}
    public func allow(now:ContinuousClock.Instant = .now) -> Bool { if case .open(let until)=state, now >= until {state = .halfOpen}; if case .open=state{return false}; return true }
    public func recordSuccess(){failures=0;state = .closed}
    public func recordFailure(now:ContinuousClock.Instant = .now){failures += 1;if failures >= threshold {state = .open(until:now.advanced(by:cooldown))}}
}
public actor SyncCoordinator {
    private let limiter:HTTPRateLimiter; private let breaker:CircuitBreaker; private let policy:RetryPolicy
    public init(limiter:HTTPRateLimiter = .init(requestsPerSecond:2),breaker:CircuitBreaker = .init(),policy:RetryPolicy = .init()){self.limiter=limiter;self.breaker=breaker;self.policy=policy}
    public func fetch(from adapter:any MediaSourceAdapter) async throws -> [CanonicalMedia] {
        var last:Error = SyncError.circuitOpen
        for attempt in 0..<policy.maximumAttempts {
            guard await breaker.allow() else {throw SyncError.circuitOpen}
            try await limiter.wait()
            do {let result=try await adapter.fetchCatalog();await breaker.recordSuccess();return result}
            catch {last=error;await breaker.recordFailure();if attempt+1<policy.maximumAttempts {try await Task.sleep(for:policy.baseDelay * (1 << attempt))}}
        }
        throw last
    }
}
public enum SyncError:Error,Sendable {case circuitOpen}
public struct JellyfinCatalogParser: Sendable {
    public init() {}
    public func parse(_ data:Data) throws -> [CanonicalMedia] {
        let root=try JSONSerialization.jsonObject(with:data) as? [String:Any] ?? [:];let items=root["Items"] as? [[String:Any]] ?? []
        return items.compactMap { item in guard let title=item["Name"] as? String, let type=item["Type"] as? String else{return nil}; let kind:MediaKind = type == "Movie" ? .movie : type == "Series" ? .series : type == "Season" ? .season : type == "Episode" ? .episode : .movie;let year=item["ProductionYear"] as? Int;let id=item["Id"] as? String;return CanonicalMedia(kind:kind,title:title,year:year,externalIDs:id.map{["jellyfin":$0]} ?? [:]) }
    }
}
public struct XtreamVODParser: Sendable {
    public init() {}
    public func parse(_ data:Data) throws -> [CanonicalMedia] {
        let items=try JSONSerialization.jsonObject(with:data) as? [[String:Any]] ?? []
        return items.compactMap { item in guard let title=(item["name"] as? String) ?? (item["stream_name"] as? String) else{return nil};let id=(item["stream_id"] as? CustomStringConvertible)?.description;let year=item["year"] as? Int;return CanonicalMedia(kind:.movie,title:title,year:year,externalIDs:id.map{["xtream":$0]} ?? [:]) }
    }
}
