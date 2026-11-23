import SwiftUI
#if os(iOS)
import KyroProviders
import KyroSourceJellyfin
#endif

/// Kyro's Home while no Silo session is signed in: zero providers, IPTV only, or a saved Silo
/// server that is signed out. Silo's Home rows belong to a signed-in Silo profile, so none are
/// requested here. The page offers the providers Kyro can use and, with IPTV, Live TV.
struct KyroHomeView: View {
    @Environment(AppRouter.self) private var router
    #if os(iOS)
    @Environment(\.kyroShellHeader) private var shellHeader
    #endif
    private let liveTV = LiveTVService.shared
    private let profileStore = CurrentProfileStore.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                #if os(iOS)
                if shellHeader == nil {
                    AppWordmarkView(placement: .compactHeader)
                        .frame(height: SiloTheme.topBarIconHitSize)
                }
                #endif
                VStack(alignment: .leading, spacing: 6) {
                    Text(greeting)
                        .font(.system(size: 30, weight: .heavy))
                        .foregroundStyle(Color.siloOnSurface)
                        .accessibilityAddTraits(.isHeader)
                    Text(homeLead)
                        .font(.subheadline)
                        .foregroundStyle(Color.siloOnSurface.opacity(0.62))
                        .fixedSize(horizontal: false, vertical: true)
                }
                #if os(iOS)
                KyroJellyfinContinueWatching()
                KyroUniversalHomeCatalog()
                #endif
                KyroAddSourcesPanel()
            }
            .frame(maxWidth: 640, alignment: .leading)
            .padding(.horizontal, SiloTheme.padding)
            .padding(.vertical, SiloTheme.padding)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        #if os(iOS)
        .safeAreaPadding(.top, shellHeader?.runway ?? 0)
        .reportsPageChromeScroll()
        .toolbar(.hidden, for: .navigationBar)
        #endif
        .siloPageBackground()
        .task {
            await KyroLocalIdentityRuntime.shared.reconcilePendingRemovals(
                availableAccounts: KyroProviderBridge.accounts)
            #if os(iOS)
            await KyroJellyfinConnections.shared.restore()
            #endif
            await profileStore.refresh()
        }
    }

    private var greeting: String {
        profileStore.profile.map { "Hi, \($0.name)" } ?? "Welcome to Kyro"
    }

    private var homeLead: String {
        #if os(iOS)
        if !KyroJellyfinConnections.shared.connectedAccounts.isEmpty {
            return "Your movies and shows are ready across your connected sources."
        }
        #endif
        return KyroHomeCopy.lead(KyroProviderState(
            isSiloConnected: false, iptvProviderCount: liveTV.providers.count))
    }
}

#if os(iOS)
/// A compact Home projection of the same active unified index used by Movies and Series.
/// Silo's signed-in Home keeps its server rows; this adds provider and IPTV catalog titles.
struct KyroUniversalHomeCatalog: View {
    private struct Entry: Identifiable {
        let card: UnifiedCatalogCard
        let kind: XtreamVODKind
        var id: String { kind.rawValue + ":" + card.id }
    }

    @Environment(AppRouter.self) private var router
    @State private var entries: [Entry] = []
    private let service = XtreamVODService.shared
    private let liveTV = LiveTVService.shared
    private let connections = KyroJellyfinConnections.shared

    var body: some View {
        Group {
            if !entries.isEmpty {
                VStack(alignment: .leading, spacing: 14) {
                    PhoneSectionHeader(title: "From Your Sources")
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 12) {
                            ForEach(entries) { entry in
                                MediaCard(title: entry.card.title, posterUrl: entry.card.poster ?? "",
                                    mediaType: entry.kind == .movie ? "movie" : "series",
                                    year: entry.card.year, action: { open(entry) })
                                    .frame(width: 150)
                            }
                        }
                    }
                }
            }
        }
        .task(id: "\(service.catalogRevision):\(ProviderCatalogMirror.shared.revision):\(connections.connectedAccounts.map(\.description).sorted()):\(KyroLocalIdentityDefaults.activeProfileID ?? "none")") {
            await load()
        }
    }

    private func load() async {
        guard let store = await service.unifiedStore() else { entries = []; return }
        let accounts = await KyroProviderCatalogBridge.registeredAccounts()
        let providerIDs = IPTVVODPreference.isEnabled()
            ? liveTV.providers.filter { $0.kind == .xtream }.map(\.id) : []
        var found: [Entry] = []
        for kind in XtreamVODKind.allCases {
            let scope = UnifiedIndexScope(kind: kind, siloScope: nil, siloLibraryIDs: [],
                providerIDs: providerIDs, providerSources: KyroProviderCatalogBridge.sources(accounts))
            let page = await store.unifiedPage(scope, direction: .forward(after: nil), limit: 12)
            found += UnifiedCatalogGrouping.cards(from: page.rows).prefix(12).map { Entry(card: $0, kind: kind) }
        }
        guard !Task.isCancelled else { return }
        entries = found
    }

    private func open(_ entry: Entry) {
        switch UnifiedDetailTarget(card: entry.card) {
        case let .provider(account, _, contentID, _, _):
            if let ref = KyroProviderCatalogBridge.contentRef(account: account, contentID: contentID),
               ref.account.kind == .jellyfin {
                router.presentJellyfinDetail(ref, isSeries: entry.kind == .series)
            }
        case let .iptv(item, _):
            let name = liveTV.providers.first { $0.id == item.providerID }?.name ?? "IPTV"
            router.presentIPTVDetail(KyroIPTVDetailRequest(item: item, providerName: name))
        case .silo:
            break
        }
    }
}

/// Provider-qualified resume cards, independent of Silo's Home endpoint. Each item is loaded
/// from the linked Jellyfin account for the currently selected local profile.
struct KyroJellyfinContinueWatching: View {
    private struct Entry: Identifiable {
        let ref: ContentRef
        let item: JellyfinMediaItem
        let poster: String
        var id: String { ref.account.description + ":" + ref.remoteID }
    }

    @Environment(AppRouter.self) private var router
    @State private var entries: [Entry] = []
    private let connections = KyroJellyfinConnections.shared

    var body: some View {
        Group {
            if !entries.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    PhoneSectionHeader(title: "Continue Watching")
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 12) {
                            ForEach(entries) { entry in
                                MediaCard(title: entry.item.title, posterUrl: entry.poster,
                                          mediaType: entry.item.kind == .movie ? "movie" : "episode",
                                          year: entry.item.year, action: {
                                    if entry.item.kind == .movie {
                                        router.presentJellyfinDetail(entry.ref, isSeries: false)
                                    } else if let seriesID = entry.item.seriesID,
                                              let seriesRef = try? ContentRef(account: entry.ref.account,
                                                                               remoteID: seriesID) {
                                        router.presentJellyfinDetail(seriesRef, isSeries: true)
                                    }
                                })
                                .frame(width: 150)
                            }
                        }
                    }
                }
            }
        }
        .task(id: connections.connectedAccounts.map(\.description).sorted().joined(separator: ",")) {
            await load()
        }
        .onReceive(NotificationCenter.default.publisher(for: .homeSectionsShouldRefresh)) { _ in
            Task { await load() }
        }
    }

    private func load() async {
        var found: [Entry] = []
        let accounts = await KyroProviderCatalogBridge.registeredAccounts()
        for account in accounts where account.kind == .jellyfin {
            guard let client = connections.client(for: account),
                  let items = try? await client.resumeItems() else { continue }
            for item in items where (item.userState?.resumePositionSeconds ?? 0) > 0 {
                guard let ref = try? ContentRef(account: account, remoteID: item.contentID.itemID) else { continue }
                let poster = client.imageURL(itemID: item.contentID.itemID, kind: .primary,
                    tag: item.artwork.primaryTag)?.absoluteString ?? ""
                found.append(Entry(ref: ref, item: item, poster: poster))
            }
        }
        guard !Task.isCancelled else { return }
        entries = found
    }
}
#endif

enum KyroHomeCopy {
    static func lead(_ state: KyroProviderState) -> String {
        state.hasIPTV
            ? "Watch Live TV now, or connect a media server for your movies and shows."
            : "Connect a media server or an IPTV provider to start watching."
    }

    /// The media-server row: a saved Silo server that is signed out is offered for sign-in by
    /// name, so reconnecting never looks like starting over.
    static func mediaServerTitle(savedServerName: String?) -> String {
        savedServerName.map { "Sign in to \($0)" } ?? "Add Media Server"
    }

    static func mediaServerSubtitle(savedServerName: String?) -> String {
        savedServerName == nil ? "Connect your Silo server" : "Your Silo server is signed out"
    }
}

/// The providers Kyro can use, as actions: watch Live TV (with IPTV), connect a media server, and
/// add IPTV. Used by Kyro's Home and by Movies and Series when they have nothing to show.
struct KyroAddSourcesPanel: View {
    @Environment(AppRouter.self) private var router
    private let liveTV = LiveTVService.shared
    #if os(iOS)
    @State private var showIPTVSetup = false
    @State private var showMediaServerSetup = false
    #endif

    var body: some View {
        VStack(spacing: 12) {
            #if os(iOS)
            if !liveTV.providers.isEmpty {
                row(title: "Watch Live TV",
                    subtitle: KyroLiveTVSettingsEntry.summary(providers: liveTV.providers,
                                                              selectedProviderID: liveTV.selectedProviderID),
                    symbol: "play.tv", id: "kyroHomeWatchLiveTV") {
                    KyroUnifiedNavigation.bringLiveTVForward(router: router)
                }
            }
            #endif
            row(title: "Add Media Server",
                subtitle: "Connect Jellyfin or Silo",
                symbol: "server.rack", id: "kyroHomeAddMediaServer") {
                #if os(iOS)
                showMediaServerSetup = true
                #else
                router.navigate(to: .serverList)
                #endif
            }
            #if os(iOS)
            row(title: liveTV.providers.isEmpty ? "Add IPTV" : "Manage IPTV",
                subtitle: "Xtream Codes or an M3U playlist",
                symbol: "dot.radiowaves.left.and.right", id: "kyroHomeAddIPTV") {
                showIPTVSetup = true
            }
            #endif
        }
        #if os(iOS)
        .sheet(isPresented: $showIPTVSetup) {
            NavigationStack {
                LiveTVSettingsView(service: liveTV, presentation: .sheet)
            }
        }
        .sheet(isPresented: $showMediaServerSetup) { KyroJellyfinSetupView() }
        #endif
    }

    private func row(title: String, subtitle: String, symbol: String, id: String,
                     action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: symbol)
                    .font(.title3)
                    .frame(width: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).fontWeight(.semibold)
                    Text(subtitle)
                        .font(.footnote)
                        .foregroundStyle(Color.siloOnSurface.opacity(0.62))
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Color.siloOnSurface.opacity(0.5))
            }
            .multilineTextAlignment(.leading)
            .accessibilityElement(children: .combine)
        }
        .buttonStyle(.marquee(.glass))
        .accessibilityIdentifier(id)
    }
}
