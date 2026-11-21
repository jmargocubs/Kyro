#if os(iOS)
import SwiftUI

struct KyroUnifiedBrowseView: View {
    let kind: XtreamVODKind
    let libraries: [Library]

    @AppStorage(IPTVVODPreference.key) private var vodEnabled = false
    @State private var model = KyroUnifiedBrowseModel()
    @State private var gridWidth: CGFloat = 0
    @State private var uiCustomization = UICustomizationPreferences.shared
    @Environment(\.horizontalSizeClass) private var hSize
    @Environment(\.verticalSizeClass) private var vSize
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(AppRouter.self) private var router

    private let liveTV = LiveTVService.shared
    private let service = XtreamVODService.shared

    private var refreshIdentity: String {
        "\(kind.rawValue):\(libraries.map(\.id)):\(liveTV.providers.map(\.id)):\(vodEnabled):\(service.catalogRevision)"
    }

    var body: some View {
        LibraryPageScrollContainer {
            VStack(spacing: SiloTheme.padding) {
                if model.hadSourceFailure {
                    Text("Some Silo libraries are unavailable. Available titles are shown.")
                        .font(.siloCaption)
                        .foregroundColor(.siloSecondaryText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if model.windowWasTrimmed {
                    Text("Showing the newest browsing window. Reopen Library to start again.")
                        .font(.siloCaption)
                        .foregroundColor(.siloSecondaryText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if model.titles.isEmpty && model.hasLoaded {
                    EmptyStateView(icon: kind == .movie ? "film" : "tv",
                                   title: "No titles available",
                                   subtitle: "Check your Silo libraries or IPTV catalog settings.")
                        .frame(minHeight: 280)
                } else {
                    grid
                }
            }
            .padding(.horizontal, SiloTheme.padding)
        }
        .siloPageBackground()
        .task(id: refreshIdentity) {
            await model.configure(kind: kind, libraries: libraries,
                                  providers: liveTV.providers, vodEnabled: vodEnabled,
                                  catalogRevision: service.catalogRevision)
        }
        .refreshable {
            await model.refresh(kind: kind, libraries: libraries,
                                providers: liveTV.providers, vodEnabled: vodEnabled,
                                catalogRevision: service.catalogRevision)
        }
    }

    private var grid: some View {
        let layout = PosterGridLayout(
            gridWidth: gridWidth,
            horizontalSizeClass: hSize,
            verticalSizeClass: vSize,
            isAccessibilitySize: dynamicTypeSize.isAccessibilitySize,
            posterSize: uiCustomization.cardPresentation.posterSize,
            forcesThreeColumnsOnPhone: true
        )
        let titles = model.titles
        return VStack(spacing: 0) {
            LazyVGrid(columns: layout.columns, spacing: PosterGridLayout.rowSpacing) {
                if titles.isEmpty && !model.hasLoaded {
                    ForEach(0..<(layout.columns.count * 4), id: \.self) { _ in PosterSkeletonCard() }
                }
                ForEach(UnifiedIndexedTitles(titles: titles)) { entry in
                    card(entry.title, width: layout.cardWidthOverride,
                         rowTitles: rowTitles(at: entry.index, columns: layout.columns.count, titles: titles))
                        .frame(maxWidth: .infinity)
                        .onAppear {
                            if entry.index >= titles.count - 6 && model.hasMore {
                                Task { await model.loadMore() }
                            }
                        }
                }
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
                if abs(width - gridWidth) >= 0.5 { gridWidth = width }
            }
            if model.isLoading && !titles.isEmpty {
                ProgressView().tint(.siloOnSurface).padding()
            }
        }
    }

    private func card(_ title: UnifiedVODTitle, width: CGFloat?, rowTitles: [String]?) -> some View {
        let silo = title.siloItem
        let iptv = title.iptvItems.first
        let provider = iptv.flatMap { item in liveTV.providers.first { $0.id == item.providerID } }
        return MediaCard(
            title: title.title,
            posterUrl: silo?.posterUrl ?? iptv?.poster ?? "",
            thumbhash: silo?.posterThumbhash,
            mediaType: kind == .movie ? "movie" : "series",
            year: silo?.year ?? title.entries.first?.year,
            userState: silo?.userState,
            action: {
                if let silo {
                    router.navigate(to: .itemDetail(browseItem: silo, libraryId: model.libraryID(for: silo)))
                } else if let iptv, let provider {
                    router.presentIPTVDetail(KyroIPTVDetailRequest(item: iptv, providerName: provider.name))
                }
            },
            cardWidthOverride: width,
            rowTitles: rowTitles
        )
        // Keep MediaCard's favorite/watch-state context menu intact. This small, interim
        // secondary action exposes retained IPTV identities without changing playback routing.
        .overlay(alignment: .topTrailing) {
            if silo != nil && !title.iptvItems.isEmpty {
                Menu {
                    ForEach(title.iptvItems) { item in
                        if let provider = liveTV.providers.first(where: { $0.id == item.providerID }) {
                            Button("Open IPTV · \(provider.name)") {
                                router.presentIPTVDetail(KyroIPTVDetailRequest(item: item, providerName: provider.name))
                            }
                        }
                    }
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.title3)
                        .foregroundColor(.siloOnSurface)
                        .padding(6)
                        .background(.ultraThinMaterial, in: Circle())
                }
                .accessibilityLabel("IPTV details for \(title.title)")
                .padding(6)
            }
        }
    }

    private func rowTitles(at index: Int, columns: Int, titles: [UnifiedVODTitle]) -> [String] {
        let start = index - index % columns
        return titles[start..<min(start + columns, titles.count)].map(\.title)
    }
}

private struct UnifiedIndexedTitles: RandomAccessCollection {
    struct Entry: Identifiable {
        let index: Int
        let title: UnifiedVODTitle
        var id: String { title.id }
    }
    let titles: [UnifiedVODTitle]
    var startIndex: Int { titles.startIndex }
    var endIndex: Int { titles.endIndex }
    subscript(position: Int) -> Entry { Entry(index: position, title: titles[position]) }
}
#endif
