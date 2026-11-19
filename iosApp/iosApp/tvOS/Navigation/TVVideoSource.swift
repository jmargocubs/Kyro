#if os(tvOS)
import Foundation

/// What a Movies or Series tab shows: one Silo library (the existing Skyline page) or one IPTV
/// provider's catalog. A tab shows exactly one source at a time, chosen in the tab's top-bar
/// dropdown next to the Silo libraries, the same way a multi-library type is scoped to one
/// library (§3.1).
///
/// Build 92–94 put an All / Silo / provider chip row and an IPTV rail inside the page. That
/// squeezed the full-screen Skyline feed, gave Up two owners, and left the IPTV page without a
/// focus owner, so the default (All) view changed for every user with a provider.
enum TVVideoSource: Hashable, Sendable {
    case silo
    case provider(UUID)

    var providerID: UUID? {
        if case .provider(let id) = self { return id }
        return nil
    }

    /// Persisted form: `silo`, or the provider UUID.
    var storageValue: String {
        switch self {
        case .silo: return "silo"
        case .provider(let id): return id.uuidString
        }
    }

    init?(storageValue: String) {
        if storageValue == "silo" { self = .silo; return }
        guard let id = UUID(uuidString: storageValue) else { return nil }
        self = .provider(id)
    }
}

enum TVVideoSourceResolver {
    /// The provider catalog kind a library tab can show, if any.
    static func vodKind(for type: TVLibraryTabType) -> XtreamVODKind? {
        switch type {
        case .movies: return .movie
        case .series: return .series
        case .music, .audiobooks: return nil
        }
    }

    /// Xtream providers with this tab's catalog turned on, in provider order.
    static func providers(for type: TVLibraryTabType, in providers: [LiveTVProvider]) -> [LiveTVProvider] {
        guard let kind = vodKind(for: type) else { return [] }
        return providers.filter {
            $0.kind == .xtream && (kind == .movie ? $0.vodMoviesEnabled : $0.vodSeriesEnabled)
        }
    }

    /// Tab types that have at least one IPTV catalog, so IPTV-only users still get the tab.
    static func vodTypes(in providers: [LiveTVProvider]) -> Set<TVLibraryTabType> {
        Set([TVLibraryTabType.movies, .series].filter { !self.providers(for: $0, in: providers).isEmpty })
    }

    /// The source a tab shows. A remembered choice wins while it is still available; otherwise
    /// Silo comes first, so adding a provider never replaces the Silo page a user already had.
    static func resolve(selected: TVVideoSource?, hasSiloLibrary: Bool,
                        providers: [LiveTVProvider]) -> TVVideoSource {
        switch selected {
        case .provider(let id)? where providers.contains(where: { $0.id == id }):
            return .provider(id)
        case .silo? where hasSiloLibrary:
            return .silo
        default:
            if hasSiloLibrary { return .silo }
            if let first = providers.first { return .provider(first.id) }
            return .silo // the Silo page's own empty state
        }
    }
}

/// Remembers each tab's source per server and profile, like `TVLibraryScopeStore` remembers the
/// library. IPTV providers are device-wide, so a signed-out device uses a `local` profile key.
@MainActor
final class TVVideoSourceStore {
    static let shared = TVVideoSourceStore()

    private let defaults: UserDefaults
    private let scopeKey: @MainActor () -> String

    init(defaults: UserDefaults = .standard,
         scopeKey: @escaping @MainActor () -> String = TVVideoSourceStore.activeScopeKey) {
        self.defaults = defaults
        self.scopeKey = scopeKey
    }

    func source(for type: TVLibraryTabType) -> TVVideoSource? {
        defaults.string(forKey: key(for: type)).flatMap(TVVideoSource.init(storageValue:))
    }

    func setSource(_ source: TVVideoSource, for type: TVLibraryTabType) {
        defaults.set(source.storageValue, forKey: key(for: type))
    }

    private func key(for type: TVLibraryTabType) -> String {
        "kyro.videoSource.\(scopeKey()).\(type.rawValue)"
    }

    static func activeScopeKey() -> String {
        let server = ServerRegistry.shared.activeServerId ?? "default"
        let profile = AuthService.shared.profileId.flatMap { $0.isEmpty ? nil : $0 } ?? "local"
        return "\(server).\(profile)"
    }
}
#endif
