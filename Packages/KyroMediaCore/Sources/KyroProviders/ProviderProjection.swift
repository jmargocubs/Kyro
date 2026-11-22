import Foundation

/// What Kyro may read of the Silo server registry. Built by the app from `ServerRegistry` and
/// the app's session owner; it carries no tokens, only whether the active server has a session.
public struct SiloServerSnapshot: Sendable, Equatable {
  public struct Server: Sendable, Equatable {
    public let id: String
    public let name: String
    public init(id: String, name: String) {
      self.id = id
      self.name = name
    }
  }
  public let servers: [Server]
  public let activeServerID: String?
  public let isActiveServerSignedIn: Bool
  public init(servers: [Server], activeServerID: String?, isActiveServerSignedIn: Bool) {
    self.servers = servers
    self.activeServerID = activeServerID
    self.isActiveServerSignedIn = isActiveServerSignedIn
  }
}

/// A Live TV provider as the Live TV store holds it.
public struct IPTVProviderSnapshot: Sendable, Equatable {
  public let id: UUID
  public let name: String
  public let isXtream: Bool
  public init(id: UUID, name: String, isXtream: Bool) {
    self.id = id
    self.name = name
    self.isXtream = isXtream
  }
}

/// Read-only views of stores that already exist. Nothing is written, migrated or copied: the
/// accounts are recomputed from the snapshot each time.
public enum ProviderProjection {
  /// One account per saved Silo server, with a stable ID derived from the server ID. Only the
  /// active server has session information; the others are `saved`.
  public static func silo(_ snapshot: SiloServerSnapshot) -> [ProviderAccountRecord] {
    snapshot.servers.map { server in
      let connection: ProviderConnection
      if server.id == snapshot.activeServerID {
        connection = snapshot.isActiveServerSignedIn ? .connected : .signedOut
      } else {
        connection = .saved
      }
      return ProviderAccountRecord(
        ref: .derived(kind: .silo, key: server.id), label: server.name, origin: .projected,
        connection: connection)
    }
  }

  /// One account per Live TV provider. The Live TV provider's own UUID is the account ID, so
  /// the identity never changes and no credential is involved.
  public static func iptv(_ providers: [IPTVProviderSnapshot]) -> [ProviderAccountRecord] {
    providers.map { provider in
      ProviderAccountRecord(
        ref: ProviderAccountRef(
          id: ProviderAccountID(rawValue: provider.id), kind: provider.isXtream ? .xtream : .m3u),
        label: provider.name, origin: .projected, connection: .connected)
    }
  }
}
