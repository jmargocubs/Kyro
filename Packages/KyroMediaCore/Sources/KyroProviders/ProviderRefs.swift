import Crypto
import Foundation

@_exported import KyroCapabilities
@_exported import KyroCatalog
@_exported import KyroFoundation

/// The kinds of content provider Kyro can hold. The raw value is what the household registry
/// stores in `ProviderAccount.provider`.
public enum ProviderKind: String, Codable, Sendable, CaseIterable {
  case silo, jellyfin, emby, plex, xtream, m3u

  public var isMediaServer: Bool {
    switch self {
    case .silo, .jellyfin, .emby, .plex: true
    case .xtream, .m3u: false
    }
  }
  public var isIPTV: Bool { !isMediaServer }
  /// Silo and IPTV accounts already live in their own stores (the Silo server registry and the
  /// Live TV provider store, each with its own credentials). The registry never persists or
  /// copies them; they are read-only projections of those stores.
  public var isProjected: Bool { self == .silo || isIPTV }
}

/// A provider account, qualified by kind so two providers can never share an identity.
public struct ProviderAccountRef: Hashable, Codable, Sendable, CustomStringConvertible {
  public let id: ProviderAccountID
  public let kind: ProviderKind
  public init(id: ProviderAccountID, kind: ProviderKind) {
    self.id = id
    self.kind = kind
  }
  public var description: String { kind.rawValue + ":" + id.description }

  /// A stable ID derived from the identifier the provider's own store already uses (a Silo
  /// server ID), so the same server always projects to the same account.
  public static func derived(kind: ProviderKind, key: String) -> Self {
    let digest = Array(SHA256.hash(data: Data("kyro:provider-account:v1:\(kind.rawValue):\(key)".utf8)).prefix(16))
    var bytes = digest
    bytes[6] = (bytes[6] & 0x0F) | 0x50
    bytes[8] = (bytes[8] & 0x3F) | 0x80
    let uuid = bytes.withUnsafeBytes { $0.load(as: uuid_t.self) }
    return Self(id: ProviderAccountID(rawValue: UUID(uuid: uuid)), kind: kind)
  }
}

private enum RefCoding {
  static func escape(_ text: String) -> String {
    text.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
  }
  static func encode(entity: String, account: ProviderAccountRef, remoteID: String) -> String {
    "kyro:ref:v1:\(entity):\(account.kind.rawValue):\(account.id.description):\(escape(remoteID))"
  }
  static func decode(_ text: String, entity: String) -> (ProviderAccountRef, String)? {
    let parts = text.split(separator: ":", maxSplits: 6, omittingEmptySubsequences: false)
    guard parts.count == 7, parts[0] == "kyro", parts[1] == "ref", parts[2] == "v1",
      parts[3] == Substring(entity), let kind = ProviderKind(rawValue: String(parts[4])),
      let uuid = UUID(uuidString: String(parts[5])),
      let remote = String(parts[6]).removingPercentEncoding, !remote.isEmpty
    else { return nil }
    let account = ProviderAccountRef(id: ProviderAccountID(rawValue: uuid), kind: kind)
    // Only the canonical spelling is accepted, so one reference has one encoded form.
    guard encode(entity: entity, account: account, remoteID: remote) == text else { return nil }
    return (account, remote)
  }
}

/// A title, episode or other item on one provider. A bare provider ID is never enough to open
/// something: Silo content IDs, Jellyfin GUIDs and Plex rating keys can collide.
public struct ContentRef: Hashable, Codable, Sendable, CustomStringConvertible {
  public let account: ProviderAccountRef
  public let remoteID: String
  public init(account: ProviderAccountRef, remoteID: String) throws {
    guard !remoteID.isEmpty else { throw ProviderError.emptyRemoteID }
    self.account = account
    self.remoteID = remoteID
  }
  public var encoded: String { RefCoding.encode(entity: "content", account: account, remoteID: remoteID) }
  public init?(encoded: String) {
    guard let (account, remote) = RefCoding.decode(encoded, entity: "content") else { return nil }
    self.account = account
    remoteID = remote
  }
  public var description: String { encoded }
  /// The content ID the existing Silo screens and routes use, for a Silo reference only.
  public var siloContentID: String? { account.kind == .silo ? remoteID : nil }
}

/// A library or folder on one provider. Silo's integer library ID is carried as text so other
/// providers' string identifiers fit the same type.
public struct LibraryRef: Hashable, Codable, Sendable, CustomStringConvertible {
  public let account: ProviderAccountRef
  public let remoteID: String
  public init(account: ProviderAccountRef, remoteID: String) throws {
    guard !remoteID.isEmpty else { throw ProviderError.emptyRemoteID }
    self.account = account
    self.remoteID = remoteID
  }
  public init(account: ProviderAccountRef, siloLibraryID: Int) throws {
    try self.init(account: account, remoteID: String(siloLibraryID))
  }
  public var encoded: String { RefCoding.encode(entity: "library", account: account, remoteID: remoteID) }
  public init?(encoded: String) {
    guard let (account, remote) = RefCoding.decode(encoded, entity: "library") else { return nil }
    self.account = account
    remoteID = remote
  }
  public var description: String { encoded }
  /// The integer library ID the existing Silo screens use, for a Silo reference only.
  public var siloLibraryID: Int? { account.kind == .silo ? Int(remoteID) : nil }
}

public enum ProviderError: Error, Equatable {
  case emptyRemoteID
  /// Silo and IPTV accounts are projections of their own stores and cannot be registered.
  case projectedKind
  case missingAccount
  case notConnected
}
