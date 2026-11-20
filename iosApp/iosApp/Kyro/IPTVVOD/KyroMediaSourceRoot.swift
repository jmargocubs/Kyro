#if os(iOS)
import SwiftUI

/// The Movies or Series tab. Silo's library page is the only page design; when IPTV VOD is on and
/// an Xtream provider is selected, the provider appears as one more entry in that page's library
/// selector and its catalog renders inside the same header, selector and Recommended / Library /
/// Collections bar.
///
/// Build 98/99 put a segmented Silo/IPTV picker in a VStack above the page. The shell draws the
/// Kyro header as an overlay without a runway for that picker, so its "Silo" and "IPTV" labels
/// landed beside the wordmark and search button, and choosing IPTV swapped in a second page
/// design with its own large title and system search bar. The choice is still persisted per tab,
/// and Silo's library ID, history and player session are never changed by it.
struct KyroMediaSourceRoot: View {
    let category: PrimaryMenuBuiltin
    let libraryAuthority: MainTabLibraryAuthority?
    let onLibrariesLoaded: ((MainTabLibraryAuthority?, [Library]) -> Void)?

    @AppStorage(IPTVVODPreference.key) private var vodEnabled = false
    @AppStorage("kyro.movies.source.v1") private var movieSource = "silo"
    @AppStorage("kyro.series.source.v1") private var seriesSource = "silo"
    private let liveTV = LiveTVService.shared

    private var kind: XtreamVODKind { category == .movies ? .movie : .series }
    private var provider: LiveTVProvider? {
        guard let id = liveTV.selectedProviderID else { return nil }
        return liveTV.providers.first { $0.id == id && $0.kind == .xtream }
    }
    private var source: String { category == .movies ? movieSource : seriesSource }

    var body: some View {
        LibrariesTabView(
            category: category,
            libraryAuthority: libraryAuthority,
            onLibrariesLoaded: onLibrariesLoaded,
            alternateSource: alternateSource
        )
    }

    private var alternateSource: LibraryAlternateSource? {
        guard vodEnabled, let provider else { return nil }
        let model = KyroIPTVBrowseModel.model(providerID: provider.id, kind: kind)
        return LibraryAlternateSource(
            id: "iptv.\(provider.id.uuidString)",
            name: provider.name,
            selectorCaption: "IPTV · \(kind.title)",
            pickerCaption: "IPTV \(kind.title.lowercased()) from your Xtream provider",
            systemImage: "antenna.radiowaves.left.and.right",
            isSelected: source == "iptv",
            tab: Binding(get: { model.tab }, set: { model.tab = $0 }),
            select: { selected in
                let value = selected ? "iptv" : "silo"
                if category == .movies { movieSource = value } else { seriesSource = value }
            },
            content: { AnyView(KyroIPTVLibraryContent(provider: provider, model: model)) }
        )
    }
}
#endif
