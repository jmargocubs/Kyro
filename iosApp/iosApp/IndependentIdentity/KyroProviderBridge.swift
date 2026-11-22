import Foundation
import KyroProviders

/// Read-only bridge from the existing Silo and Live TV stores to Kyro's provider types. It reads
/// the server list, whether the active server has a session, and the Live TV provider list. It
/// never reads or copies a token, and it writes to none of those stores.
enum KyroProviderBridge {
    static func siloSnapshot(
        entries: [ServerEntry], activeServerID: String?, isActiveServerSignedIn: Bool
    ) -> SiloServerSnapshot {
        SiloServerSnapshot(
            servers: entries.map { .init(id: $0.id, name: $0.displayName) },
            activeServerID: activeServerID,
            isActiveServerSignedIn: isActiveServerSignedIn
        )
    }

    static func iptvSnapshot(_ providers: [LiveTVProvider]) -> [IPTVProviderSnapshot] {
        providers.map { .init(id: $0.id, name: $0.name, isXtream: $0.kind == .xtream) }
    }

    /// One Silo row per library the existing Silo API returned, in Silo's order.
    static func siloRows(_ libraries: [Library]) -> [SiloLibraryRow] {
        libraries.map { library in
            var kinds: [MediaKind] = []
            if library.isMovieLibrary || library.isMixedLibrary { kinds.append(.movie) }
            if library.isSeriesLibrary || library.isMixedLibrary { kinds.append(.series) }
            return SiloLibraryRow(id: library.id, name: library.name, kinds: kinds, sortOrder: library.sortOrder)
        }
    }

    @MainActor
    static var accounts: [ProviderAccountRecord] {
        let registry = ServerRegistry.shared
        let silo = siloSnapshot(
            entries: registry.entries, activeServerID: registry.activeServerId,
            isActiveServerSignedIn: AuthService.shared.isLoggedIn)
        return ProviderProjection.silo(silo)
            + ProviderProjection.iptv(iptvSnapshot(LiveTVService.shared.providers))
    }
}

/// The existing Silo library read, unchanged: same request, owner fence and error handling.
struct SiloAPILibraryReader: SiloLibraryReading {
    func readLibraries() async throws -> [SiloLibraryRow] {
        KyroProviderBridge.siloRows(try await SiloAPI.shared.libraries().libraries)
    }
}
