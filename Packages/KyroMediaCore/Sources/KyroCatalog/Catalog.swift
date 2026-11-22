import Foundation
import KyroFoundation

public enum MediaKind: String, Codable, Sendable { case movie, series, season, episode }
public struct CanonicalMedia: Codable, Hashable, Sendable, Identifiable {
    public let id: String; public let kind: MediaKind; public let title: String; public let year: Int?; public let parentID: String?; public let edition: String?; public let externalIDs: [String:String]
    public init(kind: MediaKind,title: String,year: Int? = nil,parentID: String? = nil,edition: String? = nil,externalIDs: [String:String] = [:]) { self.kind=kind; self.title=title; self.year=year; self.parentID=parentID; self.edition=edition; self.externalIDs=externalIDs; id=Self.portableKey(kind:kind,title:title,year:year,parentID:parentID,edition:edition) }
    public static func portableKey(kind: MediaKind,title: String,year: Int?,parentID: String? = nil,edition: String? = nil) -> String { [kind.rawValue, normalize(title),year.map(String.init) ?? "",parentID ?? "",normalize(edition ?? "")].joined(separator:"|") }
    public static func normalize(_ value: String) -> String { value.folding(options:[.diacriticInsensitive,.caseInsensitive],locale:Locale(identifier:"en_US_POSIX")).split(whereSeparator:{$0.isWhitespace}).joined(separator:" ") }
}
public struct SourcePartition: Codable, Hashable, Sendable { public let accountID: ProviderAccountID; public let itemID: String; public init(accountID: ProviderAccountID,itemID:String){self.accountID=accountID;self.itemID=itemID} }
public struct MediaVersion: Codable, Hashable, Sendable { public let source: SourcePartition; public let edition: String?; public let quality: String?; public init(source:SourcePartition,edition:String?=nil,quality:String?=nil){self.source=source;self.edition=edition;self.quality=quality} }
public struct MetadataValue: Codable, Hashable, Sendable { public let value: String; public let source: String; public let confidence: Double; public init(value:String,source:String,confidence:Double){self.value=value;self.source=source;self.confidence=confidence} }
public struct CatalogIndex: Sendable {
    private var records: [String:CanonicalMedia] = [:]; private var searchText: [String:String] = [:]; public private(set) var generation: UInt64 = 0
    public init() {}
    public mutating func promote(_ records: [CanonicalMedia]) { self.records=Dictionary(uniqueKeysWithValues:records.map{($0.id,$0)}); searchText=Dictionary(uniqueKeysWithValues:records.map{($0.id,CanonicalMedia.normalize($0.title))}); generation &+= 1 }
    public func page(after key: String? = nil, limit: Int) -> [CanonicalMedia] { records.keys.sorted().filter{key == nil || $0 > key!}.prefix(max(0,limit)).compactMap{records[$0]} }
    public func search(_ query: String, after key: String? = nil, limit: Int) -> [CanonicalMedia] { let q=CanonicalMedia.normalize(query); return page(after:key,limit:max(1,records.count)).filter{searchText[$0.id,default:""].contains(q)}.prefix(max(0,limit)).map{$0} }
    public func count() -> Int { records.count }
}
