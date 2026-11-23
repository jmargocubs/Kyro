#if os(iOS)
import SwiftUI

/// The canonical Movies or Series destination. Silo libraries are an optional input to the
/// same index as Jellyfin and IPTV; their old Recommended/Library/Collections page is not a
/// second route into these destinations.
struct KyroMediaSourceRoot: View {
    let category: PrimaryMenuBuiltin
    let libraryAuthority: MainTabLibraryAuthority?
    let onLibrariesLoaded: ((MainTabLibraryAuthority?, [Library]) -> Void)?

    @State private var siloLibraries: [Library] = []
    @Environment(\.kyroShellHeader) private var shellHeader
    @Environment(\.secondaryDestinationTitle) private var secondaryTitle

    private var destination: KyroGlobalDestination {
        category == .movies ? .movies : .series
    }

    private var hostedHeader: KyroShellHeaderContext? {
        KyroShellHeader.hosted(shellHeader, secondaryTitle: secondaryTitle)
    }

    var body: some View {
        KyroUnifiedBrowseView(kind: category == .movies ? .movie : .series,
                              libraries: siloLibraries)
            .safeAreaPadding(.top, hostedHeader?.runway ?? 0)
            .environment(hostedHeader?.scrollState(for: destination))
            .task(id: "\(libraryAuthority?.serverId ?? "none"):\(libraryAuthority?.profileId ?? "none")") {
                // Never ask Silo when there is no signed-in Silo profile. Jellyfin and IPTV
                // continue to browse even if this optional request fails.
                guard KyroProviderState.current.loadsSiloLibraries else {
                    siloLibraries = []
                    return
                }
                do {
                    let response = try await StartupContentPrefetcher.fetchUserLibraries()
                    guard !Task.isCancelled else { return }
                    siloLibraries = response.libraries.filter {
                        libraryMatchesPrimaryMenuCategory($0, category: category)
                    }
                    onLibrariesLoaded?(libraryAuthority, response.libraries)
                } catch {
                    // Preserve any already visible catalog while Silo is offline.
                }
            }
    }
}
#endif
