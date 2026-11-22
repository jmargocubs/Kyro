import Foundation

/// One movie or series from one provider account, as the Movies and Series catalog stores it.
/// `payload` is the provider's own opaque detail data, kept so a later detail screen can open the
/// title without another request; the catalog never interprets it.
public struct ProviderCatalogRecord: Sendable, Equatable {
  public let ref: ContentRef
  public let library: LibraryRef
  public let kind: MediaKind
  public let title: String
  public let year: Int?
  public let posterURL: String?
  public let payload: Data

  public init(
    ref: ContentRef, library: LibraryRef, kind: MediaKind, title: String, year: Int? = nil,
    posterURL: String? = nil, payload: Data = Data()
  ) throws {
    guard ref.account == library.account else { throw ProviderError.accountMismatch }
    guard kind == .movie || kind == .series else { throw ProviderError.unsupportedCatalogKind }
    self.ref = ref
    self.library = library
    self.kind = kind
    self.title = title
    self.year = year
    self.posterURL = posterURL
    self.payload = payload
  }
}

public struct ProviderCatalogPage: Sendable, Equatable {
  public let records: [ProviderCatalogRecord]
  /// Nil on the last page.
  public let next: String?
  /// The provider rejected the previous cursor and this is a fresh first page.
  public let startsOver: Bool
  public init(records: [ProviderCatalogRecord], next: String?, startsOver: Bool = false) {
    self.records = records
    self.next = next
    self.startsOver = startsOver
  }
}

/// A provider that can list its movies and series for the unified catalog. Jellyfin, Emby and
/// Plex adapt to this in later milestones; the catalog needs nothing else from them.
public protocol CatalogProviding: MediaProvider {
  func catalogPage(library: LibraryRef, kind: MediaKind, cursor: String?) async throws
    -> ProviderCatalogPage
}
