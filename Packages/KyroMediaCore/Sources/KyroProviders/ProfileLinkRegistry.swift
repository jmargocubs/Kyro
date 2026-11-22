import KyroIdentity

/// Household-scoped profile links backed by the existing identity database. Provider account
/// references, rather than provider kinds or server URLs, distinguish multiple accounts.
public struct ProfileLinkRegistry: Sendable {
  private let identity: IdentityStore
  public init(identity: IdentityStore) { self.identity = identity }

  /// The caller supplies the current provider registry snapshot. A projected account must be
  /// connected before linking; a registered server's authentication is checked by its adapter.
  public func link(
    profile: KyroProfileID, to account: ProviderAccountRef, remoteUserID: String,
    availableAccounts: [ProviderAccountRecord]
  ) async throws {
    guard let record = availableAccounts.first(where: { $0.ref == account }) else {
      throw ProviderError.missingAccount
    }
    guard record.origin == (account.kind.isProjected ? .projected : .registered) else {
      throw ProviderError.missingAccount
    }
    if account.kind.isProjected && record.connection != .connected {
      throw ProviderError.notConnected
    }
    try await identity.link(
      ProviderUserLink(profile: profile, account: account.id, provider: account.kind.rawValue,
                       remoteUserID: remoteUserID), projected: account.kind.isProjected)
  }

  public func links(for profile: KyroProfileID) async throws -> [ProviderUserLink] {
    try await identity.links(for: profile)
  }

  public func profile(for account: ProviderAccountRef, remoteUserID: String) async throws -> KyroProfileID? {
    try await identity.link(account: account.id, provider: account.kind.rawValue,
                            remoteUserID: remoteUserID)?.profile
  }

  public func unlink(profile: KyroProfileID, from account: ProviderAccountRef) async throws {
    try await identity.unlink(profile: profile, account: account.id, provider: account.kind.rawValue)
  }

  /// Use after the owning Silo or IPTV store removes an account. It never touches credentials,
  /// profiles, PINs, favorites or progress. Registered accounts use ProviderRegistry.remove.
  public func removedProjectedAccount(_ account: ProviderAccountRef) async throws {
    guard account.kind.isProjected else { throw ProviderError.projectedKind }
    try await identity.unlinkAccount(account.id, provider: account.kind.rawValue)
  }
}
