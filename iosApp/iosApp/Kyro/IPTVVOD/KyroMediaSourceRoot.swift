#if os(iOS)
import SwiftUI

/// Silo remains the default for each media tab. The two choices are persisted independently and
/// never change the Silo library ID, history, or player session.
struct KyroMediaSourceRoot: View {
    let category: PrimaryMenuBuiltin
    let libraryAuthority: MainTabLibraryAuthority?
    let onLibrariesLoaded: ((MainTabLibraryAuthority?, [Library]) -> Void)?

    @AppStorage(IPTVVODPreference.key) private var vodEnabled = false
    @AppStorage("kyro.movies.source.v1") private var movieSource = "silo"
    @AppStorage("kyro.series.source.v1") private var seriesSource = "silo"
    @State private var movieCategory: String?
    @State private var movieQuery = ""
    @State private var seriesCategory: String?
    @State private var seriesQuery = ""
    private let liveTV = LiveTVService.shared

    private var kind: XtreamVODKind { category == .movies ? .movie : .series }
    private var provider: LiveTVProvider? {
        guard let id = liveTV.selectedProviderID else { return nil }
        return liveTV.providers.first { $0.id == id && $0.kind == .xtream }
    }
    private var canShowIPTV: Bool { vodEnabled && provider != nil }
    private var source: String {
        category == .movies ? movieSource : seriesSource
    }
    private var isIPTVSelected: Bool { canShowIPTV && source == "iptv" }

    var body: some View {
        VStack(spacing: 0) {
            if canShowIPTV {
                VStack(alignment: .leading, spacing: 7) {
                    Text(isIPTVSelected ? "Browsing IPTV · \(provider?.name ?? "Provider")" : "Browsing Silo libraries")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    Picker("Source", selection: sourceBinding) {
                        Text("Silo").tag("silo")
                        Text("IPTV").tag("iptv")
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("kyro\(kind.title)SourcePicker")
                }
                .padding(.horizontal, SiloTheme.padding)
                .padding(.top, SiloTheme.smallPadding)
            }
            Group {
                if isIPTVSelected, let provider {
                    KyroIPTVVODCatalogView(
                        provider: provider,
                        kind: kind,
                        category: categoryBinding,
                        query: queryBinding
                    )
                } else {
                    LibrariesTabView(category: category, libraryAuthority: libraryAuthority,
                                     onLibrariesLoaded: onLibrariesLoaded)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var sourceBinding: Binding<String> {
        Binding(get: { source }, set: { selected in
            let safe = selected == "iptv" ? "iptv" : "silo"
            if category == .movies { movieSource = safe } else { seriesSource = safe }
        })
    }

    private var categoryBinding: Binding<String?> {
        category == .movies ? $movieCategory : $seriesCategory
    }

    private var queryBinding: Binding<String> {
        category == .movies ? $movieQuery : $seriesQuery
    }
}
#endif
