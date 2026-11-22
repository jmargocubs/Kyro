import Foundation
import KyroSourceJellyfin

/// Bridges one authenticated Jellyfin client into the provider-qualified M2 catalog. The client
/// owns its per-account credential key; this adapter stores neither a token nor a Kyro profile ID.
public struct JellyfinProviderAdapter: CatalogProviding {
  public let account: ProviderAccountRef
  private let client: JellyfinClient

  public init(account: ProviderAccountRef, client: JellyfinClient) throws {
    guard account.kind == .jellyfin else { throw ProviderError.accountMismatch }
    self.account = account
    self.client = client
  }

  public func capabilities() async -> [Capability] {
    let connected = await client.currentSession != nil
    return ProviderCapabilities.capabilities(
      for: account, connection: connected ? .connected : .signedOut)
  }

  public func libraries() async throws -> [ProviderLibrary] {
    try await client.libraries().compactMap { library in
      let kinds: [MediaKind]
      switch library.collectionType?.lowercased() {
      case "movies": kinds = [.movie]
      case "tvshows": kinds = [.series]
      case "mixed": kinds = [.movie, .series]
      default: return nil
      }
      return ProviderLibrary(
        ref: try LibraryRef(account: account, remoteID: library.contentID.itemID),
        name: library.title, kinds: kinds, sortOrder: nil)
    }
  }

  public func catalogPage(
    library: LibraryRef, kind: MediaKind, cursor: String?
  ) async throws -> ProviderCatalogPage {
    guard library.account == account else { throw ProviderError.accountMismatch }
    guard kind == .movie || kind == .series else { throw ProviderError.unsupportedCatalogKind }
    let start: Int
    if let cursor {
      guard let value = Int(cursor), value >= 0 else { throw ProviderError.invalidCursor }
      start = value
    } else { start = 0 }
    let requested: JellyfinItemKind = kind == .movie ? .movie : .series
    let page = try await client.items(.init(
      parentID: library.remoteID, kinds: [requested], startIndex: start, limit: 100))
    let records = try page.items.compactMap { item -> ProviderCatalogRecord? in
      guard item.kind == requested else { return nil }
      return try ProviderCatalogRecord(
        ref: ContentRef(account: account, remoteID: item.contentID.itemID),
        library: library, kind: kind, title: item.title, year: item.year,
        posterURL: client.imageURL(itemID: item.contentID.itemID, kind: .primary,
                                   tag: item.artwork.primaryTag)?.absoluteString)
    }
    return ProviderCatalogPage(records: records, next: page.nextStartIndex.map(String.init))
  }
}
