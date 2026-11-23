#if os(iOS)
import SwiftUI
import KyroProviders

/// The one Movies or Series library grid (Build 110): Silo and IPTV titles in one catalog-wide
/// alphabetical order, confident matches shown once. See `KyroUnifiedBrowseModel`.
struct KyroUnifiedBrowseView: View {
    let kind: XtreamVODKind
    let libraries: [Library]

    @AppStorage(IPTVVODPreference.key) private var vodEnabled = false
    @State private var model = KyroUnifiedBrowseModel()
    @State private var gridWidth: CGFloat = 0
    @State private var scrolledCardID: String?
    @State private var uiCustomization = UICustomizationPreferences.shared
    @Environment(\.horizontalSizeClass) private var hSize
    @Environment(\.verticalSizeClass) private var vSize
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.libraryPageScrollControls) private var controls
    @Environment(AppRouter.self) private var router

    private let liveTV = LiveTVService.shared
    private let service = XtreamVODService.shared
    private let mirror = SiloCatalogMirror.shared
    private let providerMirror = ProviderCatalogMirror.shared

    private var configurationIdentity: String {
        "\(kind.rawValue):\(libraries.map(\.id)):\(liveTV.providers.filter { $0.kind == .xtream }.map(\.id)):\(vodEnabled):\(providerMirror.accountsRevision)"
    }

    /// Changes when an IPTV generation or a Silo snapshot was published or removed.
    private var indexRevision: String { "\(service.catalogRevision):\(mirror.revision):\(providerMirror.revision)" }

    var body: some View {
        // The page's own scroll container (like `LibraryPageScrollContainer`, which it cannot
        // extend without touching shared code) so the grid can keep its scroll position by card
        // identity while pages are added or trimmed at either end.
        ScrollView(.vertical) {
            VStack(spacing: 0) {
                if let controls { controls }
                VStack(spacing: SiloTheme.padding) {
                    Text(kind == .movie ? "Movies" : "Series")
                        .font(.largeTitle.bold())
                        .foregroundStyle(Color.siloOnSurface)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityAddTraits(.isHeader)
                    status
                    if model.cards.isEmpty && model.hasLoaded && !model.isLoading && !model.isFillingLibrary {
                        if KyroProviderState.current.isSiloConnected || model.hasProviderSources {
                            EmptyStateView(icon: kind == .movie ? "film" : "tv",
                                           title: "No titles available",
                                           subtitle: "Check your connected media servers or IPTV catalog settings.")
                                .frame(minHeight: 280)
                        } else {
                            // No media server: offer one, or IPTV (whose Movies & Series switch
                            // is in its settings), instead of a dead end.
                            VStack(spacing: 20) {
                                EmptyStateView(icon: kind == .movie ? "film" : "tv",
                                               title: "No \(kind == .movie ? "movies" : "series") yet",
                                               subtitle: "Connect a media server, or turn on IPTV Movies & Series in IPTV settings.")
                                KyroAddSourcesPanel()
                            }
                            .padding(.top, 24)
                        }
                    } else {
                        grid
                    }
                }
                .padding(.horizontal, SiloTheme.padding)
                .environment(\.libraryPageScrollControls, nil)
            }
        }
        .scrollPosition(id: $scrolledCardID, anchor: .top)
        .reportsPageChromeScroll()
        .siloPageBackground()
        .onChange(of: scrolledCardID) { _, id in model.anchorCardID = id }
        .task(id: configurationIdentity) {
            await KyroJellyfinConnections.shared.restore()
            await model.configure(kind: kind, libraries: libraries,
                                  providers: liveTV.providers, vodEnabled: vodEnabled)
        }
        .onChange(of: indexRevision) { _, _ in
            Task { await model.indexDidChange() }
        }
        .refreshable { await model.refresh() }
    }

    /// Only problems are reported here. Syncing and indexing run quietly behind the cached grid;
    /// an empty grid that is still filling shows the poster placeholders instead.
    @ViewBuilder
    private var status: some View {
        if model.storeUnavailable {
            statusLine("The local catalog is unavailable. Pull to retry.", progress: false)
        } else if model.siloSyncFailed {
            statusLine("Some Silo titles could not be updated. Showing the last synced catalog.", progress: false)
        } else if model.providerSyncFailed {
            statusLine("Some media server titles could not be updated. Showing the last synced catalog.", progress: false)
        }
    }

    private func statusLine(_ text: String, progress: Bool) -> some View {
        HStack(spacing: 8) {
            if progress { ProgressView().controlSize(.small).tint(.siloSecondaryText) }
            Text(text)
                .font(.siloCaption)
                .foregroundColor(.siloSecondaryText)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
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
        let cards = model.cards
        let columns = layout.columns.count
        return VStack(spacing: 0) {
            if model.hasMoreBefore {
                ProgressView().tint(.siloOnSurface).padding()
                    .onAppear { Task { await model.loadPrevious() } }
            }
            LazyVGrid(columns: layout.columns, spacing: PosterGridLayout.rowSpacing) {
                if cards.isEmpty && (!model.hasLoaded || model.isFillingLibrary) {
                    ForEach(0..<(columns * 4), id: \.self) { _ in PosterSkeletonCard() }
                }
                ForEach(UnifiedIndexedCards(cards: cards)) { entry in
                    card(entry.card, width: layout.cardWidthOverride,
                         rowTitles: rowTitles(at: entry.index, columns: columns, cards: cards))
                        .frame(maxWidth: .infinity)
                        .onAppear {
                            if entry.index >= cards.count - columns * 4 && model.hasMoreAfter {
                                Task { await model.loadMore() }
                            } else if entry.index < columns * 4 && model.hasMoreBefore {
                                Task { await model.loadPrevious() }
                            }
                        }
                }
            }
            .scrollTargetLayout()
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
                if abs(width - gridWidth) >= 0.5 { gridWidth = width }
            }
            .onChange(of: columns, initial: true) { _, count in model.setColumns(count) }
            if model.hasMoreAfter && !cards.isEmpty {
                ProgressView().tint(.siloOnSurface).padding()
            }
        }
    }

    private func card(_ card: UnifiedCatalogCard, width: CGFloat?, rowTitles: [String]?) -> some View {
        let silo = model.siloItem(for: card)
        return MediaCard(
            title: silo?.title ?? card.title,
            posterUrl: silo?.posterUrl ?? card.poster ?? "",
            thumbhash: silo?.posterThumbhash,
            mediaType: kind == .movie ? "movie" : "series",
            year: silo?.year ?? card.year,
            userState: silo?.userState,
            action: { open(card) },
            cardWidthOverride: width,
            rowTitles: rowTitles
        )
        .accessibilityHint(card.members.count > 1 ? "Available from \(card.members.count) sources" : "")
    }

    private func open(_ card: UnifiedCatalogCard) {
        func request(_ item: XtreamVODItem) -> KyroIPTVDetailRequest {
            let name = liveTV.providers.first { $0.id == item.providerID }?.name ?? "Unavailable provider"
            return KyroIPTVDetailRequest(item: item, providerName: name)
        }
        let providerRefs = card.members.compactMap { member -> ContentRef? in
            guard case let .provider(account, _, contentID, _) = member.source else { return nil }
            return KyroProviderCatalogBridge.contentRef(account: account, contentID: contentID)
        }
        switch UnifiedDetailTarget(card: card) {
        case let .silo(contentID, libraryID, _, alternates):
            router.presentUnifiedSiloDetail(contentId: contentID, libraryId: libraryID,
                                            alternates: alternates.map(request),
                                            providerAlternates: providerRefs, isSeries: kind == .series)
        case let .iptv(item, alternates):
            router.presentIPTVDetail(request(item), alternates: alternates.map(request))
        case let .provider(account, _, contentID, _, alternates):
            if let ref = KyroProviderCatalogBridge.contentRef(account: account, contentID: contentID),
               ref.account.kind == .jellyfin {
                router.presentJellyfinDetail(ref, isSeries: kind == .series,
                    providerAlternates: providerRefs.filter { $0 != ref },
                    iptvAlternates: alternates.map(request))
            } else if let first = alternates.first {
                router.presentIPTVDetail(request(first), alternates: alternates.dropFirst().map(request))
            }
        }
    }

    private func rowTitles(at index: Int, columns: Int, cards: [UnifiedCatalogCard]) -> [String] {
        let start = index - index % max(columns, 1)
        return cards[start..<min(start + columns, cards.count)].map(\.title)
    }
}

private struct UnifiedIndexedCards: RandomAccessCollection {
    struct Entry: Identifiable {
        let index: Int
        let card: UnifiedCatalogCard
        var id: String { card.id }
    }
    let cards: [UnifiedCatalogCard]
    var startIndex: Int { cards.startIndex }
    var endIndex: Int { cards.endIndex }
    subscript(position: Int) -> Entry { Entry(index: position, card: cards[position]) }
}
#endif
