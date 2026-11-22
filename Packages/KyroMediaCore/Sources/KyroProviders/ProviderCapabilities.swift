import Foundation

/// What a provider can do for Kyro. Not every server supports every feature; screens ask for a
/// feature and the state says whether it is available, unsupported or needs a sign-in.
public enum ProviderFeature: String, Codable, Sendable, CaseIterable {
  case browse, search, resume, nextUp, favorites, watched, collections
  case requests, downloads, watchParty, trickplay, liveTV

  public var capabilityID: String { "provider." + rawValue }
}

public enum ProviderConnection: String, Codable, Sendable, Equatable {
  /// A saved account with no usable sign-in (a Silo server that is signed out).
  case signedOut
  /// A saved account Kyro has no session information for (a non-active Silo server).
  case saved
  case connected
}

public enum ProviderCapabilities {
  /// Features each kind supports, from the migration design. Silo's list is today's behavior
  /// and the others are conservative defaults that later milestones refine per server.
  public static func supported(by kind: ProviderKind) -> Set<ProviderFeature> {
    switch kind {
    case .silo:
      Set(ProviderFeature.allCases).subtracting([.liveTV])
    case .jellyfin, .emby:
      [.browse, .search, .resume, .nextUp, .favorites, .watched, .collections, .trickplay]
    case .plex:
      [.browse, .search, .resume, .nextUp, .watched, .collections]
    case .xtream:
      [.browse, .search, .resume, .favorites, .liveTV]
    case .m3u:
      [.liveTV]
    }
  }

  /// One capability per feature for an account. IPTV has no account sign-in to wait for;
  /// media servers need a connection. `isReachable` stays nil until something has probed it.
  public static func capabilities(
    for account: ProviderAccountRef, connection: ProviderConnection, isReachable: Bool? = nil
  ) -> [Capability] {
    let supported = supported(by: account.kind)
    let authenticated = account.kind.isIPTV || connection == .connected
    return ProviderFeature.allCases.map { feature in
      let requirements = CapabilityRequirements(
        supported: supported.contains(feature), authenticated: authenticated, granted: true,
        reachable: isReachable)
      return Capability(
        id: feature.capabilityID, state: requirements.state, account: account.id,
        reason: requirements.state == .unsupported ? "\(account.kind.rawValue) does not offer this" : nil)
    }
  }

  public static func state(of feature: ProviderFeature, in capabilities: [Capability]) -> CapabilityState {
    capabilities.first { $0.id == feature.capabilityID }?.state ?? .unsupported
  }
}
