import Foundation

public struct ProviderLibrary: Sendable, Equatable, Identifiable {
  public let ref: LibraryRef
  public let name: String
  /// What the library holds. Empty for a library type Kyro does not browse.
  public let kinds: [MediaKind]
  public let sortOrder: Int?
  public var id: LibraryRef { ref }
  public init(ref: LibraryRef, name: String, kinds: [MediaKind], sortOrder: Int?) {
    self.ref = ref
    self.name = name
    self.kinds = kinds
    self.sortOrder = sortOrder
  }
}

/// The read-only surface every provider offers in M1. Browsing, detail and playback join it in
/// later milestones, one at a time.
public protocol MediaProvider: Sendable {
  var account: ProviderAccountRef { get }
  func capabilities() async -> [Capability]
  func libraries() async throws -> [ProviderLibrary]
}

/// One Silo library as the existing Silo API returns it.
public struct SiloLibraryRow: Sendable, Equatable {
  public let id: Int
  public let name: String
  public let kinds: [MediaKind]
  public let sortOrder: Int?
  public init(id: Int, name: String, kinds: [MediaKind], sortOrder: Int?) {
    self.id = id
    self.name = name
    self.kinds = kinds
    self.sortOrder = sortOrder
  }
}

/// The existing Silo library read. The app implements it with `SiloAPI.libraries()`, so Silo's
/// authentication, request fencing and error handling stay exactly where they are.
public protocol SiloLibraryReading: Sendable {
  func readLibraries() async throws -> [SiloLibraryRow]
}

/// A façade over the existing Silo API. It adds no requests, caches nothing and writes nothing.
/// It asks Silo nothing while the account is not connected, because the request would be
/// refused (no session) and a cached answer would belong to another identity.
public struct SiloProviderAdapter: MediaProvider {
  public let account: ProviderAccountRef
  private let reader: any SiloLibraryReading
  private let connection: @Sendable () async -> ProviderConnection

  public init(
    account: ProviderAccountRef, reader: any SiloLibraryReading,
    connection: @escaping @Sendable () async -> ProviderConnection
  ) throws {
    guard account.kind == .silo else { throw ProviderError.projectedKind }
    self.account = account
    self.reader = reader
    self.connection = connection
  }

  public func capabilities() async -> [Capability] {
    ProviderCapabilities.capabilities(for: account, connection: await connection())
  }

  public func libraries() async throws -> [ProviderLibrary] {
    guard await connection() == .connected else { throw ProviderError.notConnected }
    return try await reader.readLibraries().map { row in
      ProviderLibrary(
        ref: try LibraryRef(account: account, siloLibraryID: row.id), name: row.name,
        kinds: row.kinds, sortOrder: row.sortOrder)
    }
  }
}
