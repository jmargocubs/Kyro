import Foundation
import KyroFoundation
import KyroCatalog

public enum MatchTier: Int, Codable, Sendable { case externalID=3, titleYear=2, titleOnly=1 }
public struct MatchCandidate: Sendable { public let id:String; public let kind:MediaKind; public let title:String; public let year:Int?; public let edition:String?; public let externalIDs:[String:String]; public init(id:String,kind:MediaKind,title:String,year:Int?=nil,edition:String?=nil,externalIDs:[String:String]=[:]){self.id=id;self.kind=kind;self.title=title;self.year=year;self.edition=edition;self.externalIDs=externalIDs} }
public enum MatchDecision: Sendable, Equatable { case matched(String,MatchTier), conflict(String), unmatched }
public struct MediaMatcher {
    public init() {}
    public func match(_ candidate: MatchCandidate, against records: [MatchCandidate]) -> MatchDecision {
        let sameKind=records.filter{$0.kind == candidate.kind}
        for (namespace,value) in candidate.externalIDs {
            let hits=sameKind.filter{$0.externalIDs[namespace] == value}
            if hits.count > 1 { return .conflict("duplicate external identifier \(namespace)") }
            if let hit=hits.first { if hit.year != candidate.year && hit.year != nil && candidate.year != nil { return .conflict("external identifier disagrees with year") }; if hit.edition != candidate.edition { return .conflict("edition mismatch") }; return .matched(hit.id,.externalID) }
        }
        let title=CanonicalMedia.normalize(candidate.title)
        let hits=sameKind.filter{CanonicalMedia.normalize($0.title) == title && $0.year == candidate.year && $0.edition == candidate.edition}
        if hits.count == 1, let hit=hits.first { return .matched(hit.id,.titleYear) }
        if hits.count > 1 { return .conflict("ambiguous title/year/edition") }
        return .unmatched
    }
}
