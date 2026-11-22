import Foundation
import KyroIdentity

public struct ProviderAccountRecord: Sendable, Equatable, Identifiable {
  public enum Origin: Sendable, Equatable {
    /// Stored in the Kyro household registry.
    case registered
    /// Read from the provider's own store (Silo server list, Live TV providers).
    case projected
  }
  public let ref: ProviderAccountRef
  public let label: String
  public let origin: Origin
  public let connection: ProviderConnection
  public var id: ProviderAccountRef { ref }
  public init(ref: ProviderAccountRef, label: String, origin: Origin, connection: ProviderConnection) {
    self.ref = ref
    self.label = label
    self.origin = origin
    self.connection = connection
  }
}

/// Provider accounts for one Kyro household. It is a typed view over `IdentityStore`'s
/// household-scoped account list, so the accounts share its database, its isolation between
/// households and its persistence. Secrets never live here: each provider keeps its own
/// credentials (Silo's token store, Live TV's Keychain items, KyroCredentials for new servers).
public struct ProviderRegistry: Sendable {
  private let identity: IdentityStore
  public init(identity: IdentityStore) { self.identity = identity }

  /// Registers a Jellyfin, Emby or Plex account. Silo and IPTV are projections, not registered.
  @discardableResult
  public func register(kind: ProviderKind, label: String, endpoint: String? = nil,
                       id: ProviderAccountID = .init()) async throws -> ProviderAccountRef {
    guard !kind.isProjected else { throw ProviderError.projectedKind }
    let account = ProviderAccount(id: id, provider: kind.rawValue, label: label, endpoint: endpoint)
    try await identity.register(account)
    return ProviderAccountRef(id: account.id, kind: kind)
  }

  public func remove(_ ref: ProviderAccountRef) async throws {
    do {
      try await identity.removeAccount(ref.id)
    } catch IdentityStore.IdentityError.missing {
      throw ProviderError.missingAccount
    }
  }

  /// Registered accounts of kinds this build understands. A kind from a newer build is kept in
  /// storage and skipped here, never deleted or reinterpreted.
  public func accounts() async throws -> [ProviderAccountRecord] {
    try await identity.accounts().compactMap { account in
      guard let kind = ProviderKind(rawValue: account.provider), !kind.isProjected else { return nil }
      return ProviderAccountRecord(
        ref: ProviderAccountRef(id: account.id, kind: kind), label: account.label,
        origin: .registered, connection: .saved)
    }
  }

  /// Includes endpoint metadata for restoration, scoped to this registry's household.
  public func storedAccounts() async throws -> [ProviderAccount] { try await identity.accounts() }

  /// Registered accounts followed by the projections, without duplicates.
  public func allAccounts(projected: [ProviderAccountRecord]) async throws -> [ProviderAccountRecord] {
    var seen = Set<ProviderAccountRef>()
    return (try await accounts() + projected).filter { seen.insert($0.ref).inserted }
  }
}
