#if os(iOS)
import SwiftUI
import KyroProviders
import KyroSourceJellyfin

/// The existing detail card's Jellyfin root. It never routes a Jellyfin ID through Silo's detail
/// endpoint, and deliberately offers no playback control until that integration is validated.
struct KyroJellyfinDetailView: View {
    let ref: ContentRef
    let isSeries: Bool
    let onClose: () -> Void

    @State private var item: JellyfinMediaItem?
    @State private var seasons: [JellyfinMediaItem] = []
    @State private var episodes: [JellyfinMediaItem] = []
    @State private var selectedSeasonID: String?
    @State private var errorText: String?
    @State private var scrollState = PhoneDetailScrollState()

    private var client: JellyfinClient? { KyroJellyfinConnections.shared.client(for: ref.account) }
    private var posterURL: String? {
        guard let item, let client else { return nil }
        return client.imageURL(itemID: item.contentID.itemID, kind: .primary,
                               tag: item.artwork.primaryTag)?.absoluteString
    }
    private var backdropURL: String? {
        guard let item, let client else { return nil }
        return client.imageURL(itemID: item.contentID.itemID, kind: .backdrop,
                               tag: item.artwork.backdropTag)?.absoluteString
    }

    var body: some View {
        PhoneDetailPageSurface(backdropURL: backdropURL, backdropThumbhash: nil,
                               enablesArtworkGlass: true) {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 30) {
                    if let item {
                        PhoneDetailHero(
                            title: item.title, logoUrl: nil, posterUrl: posterURL,
                            posterThumbhash: nil, backdropUrl: backdropURL, backdropThumbhash: nil,
                            eyebrow: "Jellyfin", sourceTokens: [], ratingChip: nil,
                            overview: item.overview,
                            factsLine: [], overlayData: nil,
                            artworkStyle: backdropURL == nil
                                ? .cover(aspectRatio: 2.0 / 3.0,
                                         placeholderSymbol: isSeries ? "tv" : "film") : .backdrop,
                            actions: {
                                Text("Playback is not available yet")
                                    .font(.siloCaption)
                                    .foregroundStyle(Color.siloSecondaryText)
                            }, belowOverview: { EmptyView() }
                        )
                        if isSeries { episodeSection.padding(.horizontal, SiloTheme.safePadding) }
                    } else if let errorText {
                        ContentUnavailableView("Jellyfin details unavailable", systemImage: "wifi.exclamationmark",
                                               description: Text(errorText))
                            .padding(.top, 100)
                    } else {
                        ProgressView().frame(maxWidth: .infinity, minHeight: 300)
                    }
                }
                .padding(.bottom, 40)
            }
            .ignoresSafeArea(edges: .top)
            .coordinateSpace(name: PhoneDetailScrollCoordinateSpace.name)
            .phoneDetailScrollTracking(scrollState)
        }
        .toolbar(.hidden, for: .navigationBar)
        .overlay(alignment: .top) {
            PhoneDetailTopChrome(
                title: item?.title ?? "Jellyfin", isScrollGlassEnabled: true,
                scrollState: scrollState, leadingSystemName: "xmark",
                leadingAccessibilityLabel: "Close details", onLeadingTap: onClose,
                trailingSystemName: nil, onTrailingTap: nil)
        }
        .task(id: ref) { await load() }
    }

    @ViewBuilder private var episodeSection: some View {
        if !seasons.isEmpty {
            VStack(alignment: .leading, spacing: 16) {
                PhoneSectionHeader(title: "Episodes")
                Picker("Season", selection: $selectedSeasonID) {
                    ForEach(seasons, id: \.contentID.itemID) { season in
                        Text(season.title).tag(Optional(season.contentID.itemID))
                    }
                }
                .onChange(of: selectedSeasonID) { _, _ in Task { await loadEpisodes() } }
                ForEach(episodes, id: \.contentID.itemID) { episode in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(episode.title).font(.headline)
                        if let overview = episode.overview {
                            Text(overview).font(.footnote).foregroundStyle(.secondary).lineLimit(3)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
                }
            }
        }
    }

    private func load() async {
        guard let client else {
            errorText = "Reconnect this Jellyfin server to view details."
            return
        }
        do {
            item = try await (isSeries ? client.series(id: ref.remoteID) : client.movie(id: ref.remoteID))
            if isSeries {
                seasons = try await client.seasons(seriesID: ref.remoteID).items
                selectedSeasonID = seasons.first?.contentID.itemID
                await loadEpisodes()
            }
        } catch {
            errorText = "Check the server connection and try again."
        }
    }

    private func loadEpisodes() async {
        guard let client, let selectedSeasonID else { episodes = []; return }
        do {
            episodes = try await client.episodes(seriesID: ref.remoteID,
                                                 seasonID: selectedSeasonID).items
        } catch { episodes = [] }
    }
}
#endif
