import Foundation
import KyroCredentials
import KyroFoundation

public struct ProviderAccount: Codable, Sendable, Identifiable, Equatable {
  public let id: ProviderAccountID
  public let provider: String
  public let label: String
  /// Nonsecret server endpoint. Legacy accounts decode with nil; tokens never belong here.
  public let endpoint: String?
  public init(id: ProviderAccountID = .init(), provider: String, label: String, endpoint: String? = nil) {
    self.id = id
    self.provider = provider
    self.label = label
    self.endpoint = endpoint
  }
}
public struct SourceGrant: Codable, Sendable, Equatable {
  public let profile: KyroProfileID
  public let account: ProviderAccountID
  public let subject: String
  public let writable: Bool
  public init(profile: KyroProfileID, account: ProviderAccountID, subject: String, writable: Bool) {
    self.profile = profile
    self.account = account
    self.subject = subject
    self.writable = writable
  }
}

/// A Kyro profile's association with a user on one specific provider account. The remote ID
/// is never a Kyro profile ID; credentials and session state remain in the provider's store.
public struct ProviderUserLink: Codable, Sendable, Equatable {
  public let profile: KyroProfileID
  public let account: ProviderAccountID
  public let provider: String
  public let remoteUserID: String
  public init(profile: KyroProfileID, account: ProviderAccountID, provider: String, remoteUserID: String) {
    self.profile = profile
    self.account = account
    self.provider = provider
    self.remoteUserID = remoteUserID
  }
}

public struct IdentityStore: Sendable {
  private let database: SQLiteDatabase
  private let key: String
  public init(database: SQLiteDatabase, household: HouseholdID) {
    self.database = database
    key = "identity:" + household.description
  }
  private struct State: Codable, Sendable {
    var profiles: [KyroProfile] = []
    var accounts: [ProviderAccount] = []
    var grants: [SourceGrant] = []
    var pins: [String: ProfilePIN] = [:]
    var failures: [String: Int] = [:]
    var blockedUntil: [String: Date] = [:]
    var links: [ProviderUserLink] = []

    private enum CodingKeys: String, CodingKey {
      case profiles, accounts, grants, pins, failures, blockedUntil, links
    }
    init() {}
    init(from decoder: Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      profiles = try container.decodeIfPresent([KyroProfile].self, forKey: .profiles) ?? []
      accounts = try container.decodeIfPresent([ProviderAccount].self, forKey: .accounts) ?? []
      grants = try container.decodeIfPresent([SourceGrant].self, forKey: .grants) ?? []
      pins = try container.decodeIfPresent([String: ProfilePIN].self, forKey: .pins) ?? [:]
      failures = try container.decodeIfPresent([String: Int].self, forKey: .failures) ?? [:]
      blockedUntil = try container.decodeIfPresent([String: Date].self, forKey: .blockedUntil) ?? [:]
      links = try container.decodeIfPresent([ProviderUserLink].self, forKey: .links) ?? []
    }
  }
  private func update<T: Sendable>(_ body: @Sendable (inout State) throws -> T) async throws -> T {
    try await database.transaction { db in
      var state = try db.load(State.self, key: key) ?? State()
      let result = try body(&state)
      try db.save(state, key: key)
      return result
    }
  }
  public func create(_ profile: KyroProfile) async throws {
    try await update { state in
      guard !state.profiles.contains(where: { $0.id == profile.id }) else {
        throw IdentityError.duplicate
      }
      guard profile.tombstonedAt == nil else { throw IdentityError.deleted }
      state.profiles.append(profile)
    }
  }
  public func profiles(includeDeleted: Bool = false) async throws -> [KyroProfile] {
    let state = try await database.load(State.self, key: key) ?? State()
    return state.profiles.filter { includeDeleted || $0.tombstonedAt == nil }
  }
  public func hasPIN(for profile: KyroProfileID) async throws -> Bool {
    let state = try await database.load(State.self, key: key) ?? State()
    return state.pins[profile.description] != nil
  }
  public func delete(_ id: KyroProfileID, at date: Date = Date()) async throws {
    try await update { state in
      guard let index = state.profiles.firstIndex(where: { $0.id == id }) else {
        throw IdentityError.missing
      }
      state.profiles[index].tombstonedAt = state.profiles[index].tombstonedAt ?? date
      state.grants.removeAll { $0.profile == id }
      state.links.removeAll { $0.profile == id }
      state.pins[id.description] = nil
    }
  }
  public func register(_ account: ProviderAccount) async throws {
    try await update { state in
      guard !state.accounts.contains(where: { $0.id == account.id }) else {
        throw IdentityError.duplicate
      }
      state.accounts.append(account)
    }
  }
  /// Removes one provider account and the grants that referenced it. Profiles, PINs and every
  /// other account are untouched: a provider coming and going never deletes a Kyro profile.
  public func removeAccount(_ id: ProviderAccountID) async throws {
    try await update { state in
      guard state.accounts.contains(where: { $0.id == id }) else { throw IdentityError.missing }
      state.accounts.removeAll { $0.id == id }
      state.grants.removeAll { $0.account == id }
      state.links.removeAll { $0.account == id }
    }
  }
  public func accounts() async throws -> [ProviderAccount] {
    try await database.load(State.self, key: key)?.accounts ?? []
  }
  public func grant(_ grant: SourceGrant) async throws {
    try await update { state in
      guard state.profiles.contains(where: { $0.id == grant.profile && $0.tombstonedAt == nil }),
        state.accounts.contains(where: { $0.id == grant.account })
      else { throw IdentityError.missing }
      if grant.writable,
        state.grants.contains(where: {
          $0.account == grant.account && $0.subject == grant.subject && $0.writable
            && $0.profile != grant.profile
        })
      {
        throw IdentityError.subjectAlreadyWritable
      }
      state.grants.removeAll {
        $0.profile == grant.profile && $0.account == grant.account && $0.subject == grant.subject
      }
      state.grants.append(grant)
    }
  }
  public func grants(for profile: KyroProfileID) async throws -> [SourceGrant] {
    try await database.load(State.self, key: key)?.grants.filter { $0.profile == profile } ?? []
  }
  /// Linking replaces only this profile's association to this account. A remote user can have
  /// only one Kyro owner within a household, preventing ambiguous progress writes.
  public func link(_ link: ProviderUserLink, projected: Bool = false) async throws {
    try await update { state in
      guard !link.provider.isEmpty, !link.remoteUserID.isEmpty,
        !state.profiles.contains(where: { $0.id.description == link.remoteUserID })
      else { throw IdentityError.invalidLink }
      guard state.profiles.contains(where: { $0.id == link.profile && $0.tombstonedAt == nil }) else {
        throw IdentityError.missing
      }
      if !projected {
        guard state.accounts.contains(where: { $0.id == link.account && $0.provider == link.provider }) else {
          throw IdentityError.missing
        }
      }
      guard !state.links.contains(where: {
        $0.account == link.account && $0.provider == link.provider
          && $0.remoteUserID == link.remoteUserID && $0.profile != link.profile
      }) else { throw IdentityError.subjectAlreadyWritable }
      state.links.removeAll {
        $0.profile == link.profile && $0.account == link.account && $0.provider == link.provider
      }
      state.links.append(link)
    }
  }
  public func links(for profile: KyroProfileID) async throws -> [ProviderUserLink] {
    let state = try await database.load(State.self, key: key) ?? State()
    guard state.profiles.contains(where: { $0.id == profile && $0.tombstonedAt == nil }) else { return [] }
    return state.links.filter { $0.profile == profile }
  }
  public func link(account: ProviderAccountID, provider: String, remoteUserID: String) async throws -> ProviderUserLink? {
    try await database.load(State.self, key: key)?.links.first {
      $0.account == account && $0.provider == provider && $0.remoteUserID == remoteUserID
    }
  }
  public func unlink(profile: KyroProfileID, account: ProviderAccountID, provider: String) async throws {
    try await update { state in
      state.links.removeAll { $0.profile == profile && $0.account == account && $0.provider == provider }
    }
  }
  /// Call when removing a projected account from its owning store. No profile or other data is removed.
  public func unlinkAccount(_ account: ProviderAccountID, provider: String) async throws {
    try await update { state in
      state.links.removeAll { $0.account == account && $0.provider == provider }
    }
  }
  public func setPIN(_ pin: String, for profile: KyroProfileID) async throws {
    let derived = try ProfilePIN(pin: pin)
    try await update { state in
      guard state.profiles.contains(where: { $0.id == profile && $0.tombstonedAt == nil }) else {
        throw IdentityError.deleted
      }
      state.pins[profile.description] = derived
      state.failures[profile.description] = 0
      state.blockedUntil[profile.description] = nil
    }
  }
  public func verifyPIN(_ pin: String, for profile: KyroProfileID, now: Date = Date()) async throws
    -> Bool
  {
    try await update { state in
      let id = profile.description
      guard let record = state.pins[id] else { throw IdentityError.missing }
      if let until = state.blockedUntil[id], now < until { return false }
      let valid = try record.verify(pin)
      state.failures[id] = valid ? 0 : (state.failures[id] ?? 0) + 1
      if !valid, state.failures[id, default: 0] >= 5 {
        state.blockedUntil[id] = now.addingTimeInterval(60)
      }
      return valid
    }
  }
  public enum IdentityError: Error { case missing, duplicate, deleted, subjectAlreadyWritable, invalidLink }
}
