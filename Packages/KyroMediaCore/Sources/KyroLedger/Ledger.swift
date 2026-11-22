import Foundation
import KyroFoundation

public enum LedgerValue: Codable, Hashable, Sendable { case favorite(Bool), watchlist(Bool), watched(Bool), progress(Double), collection(String, Bool), preference(String, String) }
public struct LedgerOperation: Codable, Hashable, Sendable, Identifiable {
    public let id: UUID; public let profileID: KyroProfileID; public let itemKey: String; public let value: LedgerValue; public let clock: HybridLogicalClock
    public init(id: UUID = UUID(), profileID: KyroProfileID, itemKey: String, value: LedgerValue, clock: HybridLogicalClock) { self.id=id; self.profileID=profileID; self.itemKey=itemKey; self.value=value; self.clock=clock }
}
public struct ContinueWatchingItem: Sendable, Equatable { public let itemKey: String; public let progress: Double }
public struct Ledger {
    public private(set) var operations: Set<LedgerOperation> = []
    public init() {}
    public mutating func append(_ operation: LedgerOperation) { operations.insert(operation) }
    public func merged(with other: Self) -> Self { var x=self; x.operations.formUnion(other.operations); return x }
    public func value(profileID: KyroProfileID, itemKey: String) -> LedgerValue? { operations.filter{$0.profileID == profileID && $0.itemKey == itemKey}.max { a,b in a.clock == b.clock ? a.id.uuidString < b.id.uuidString : a.clock < b.clock }?.value }
    public func continueWatching(profileID: KyroProfileID) -> [ContinueWatchingItem] {
        let keys=Set(operations.filter{$0.profileID == profileID}.map{$0.itemKey})
        return keys.compactMap { key in guard case let .progress(p)?=value(profileID:profileID,itemKey:key), p > 0, p < 1 else{return nil}; return ContinueWatchingItem(itemKey:key,progress:p) }.sorted{$0.itemKey < $1.itemKey}
    }
}
