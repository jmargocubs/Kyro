#if os(iOS)
import SwiftUI

/// Instantiated only for an enabled shelf. No player observation and no feed
/// network work on Home; playback checkpoints and cached entries drive cards.
struct KyroHomePodcastRail: View {
    let shelf: KyroHomeShelf
    @State private var selectedShow: PodcastShow?
    private let library = KyroPodcastLibrary.shared
    private static let limit = 12

    private var entries: [PodcastEntry] {
        shelf == .latestPodcasts ? library.latest(limit: Self.limit) : Array(library.continuing().prefix(Self.limit))
    }
    private var favorites: [PodcastShow] {
        Array(library.shows.filter { library.favoriteShows.contains($0.id) }.prefix(Self.limit))
    }

    static func itemCount(for shelf: KyroHomeShelf) -> Int {
        let library = KyroPodcastLibrary.shared
        if shelf == .favoritePodcasts { return min(limit, library.favoriteShows.count) }
        return shelf == .latestPodcasts ? library.latest(limit: limit).count : min(limit, library.continuing().count)
    }

    var body: some View {
        if shelf == .favoritePodcasts {
            let shows = favorites
            if !shows.isEmpty {
                KyroHomeRail(title: shelf.title, sizing: .lazy) {
                    ForEach(shows) { show in
                        Button { selectedShow = show } label: {
                            KyroHomePodcastCard(title: show.title, subtitle: show.publisher, artwork: show.artwork, progress: nil)
                        }.buttonStyle(.plain)
                    }
                }
                .sheet(item: $selectedShow) { show in NavigationStack { KyroPodcastShowView(initialShow: show) } }
            }
        } else {
            let episodes = entries
            VStack(spacing: 0) {
                if !episodes.isEmpty {
                    KyroHomeRail(title: shelf.title, sizing: .lazy) {
                        ForEach(episodes) { entry in
                            Button { KyroPodcastPlayer.shared.play(entry) } label: {
                                KyroHomePodcastCard(title: entry.episode.title, subtitle: entry.showTitle, artwork: entry.artwork,
                                    progress: shelf == .continuePodcasts ? library.progress[entry.id]?.fraction : nil)
                            }.buttonStyle(.plain)
                        }
                    }
                }
            }
            .task(id: shelf) {
                if shelf == .latestPodcasts || shelf == .continuePodcasts { await library.restoreAll() }
            }
        }
    }
}

private struct KyroHomePodcastCard: View {
    let title: String
    let subtitle: String
    let artwork: URL?
    let progress: Double?
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            KyroPodcastArtwork(url: artwork, size: 114)
                .overlay(alignment: .bottom) {
                    if let progress {
                        ProgressView(value: progress).padding(6).background(.black.opacity(0.65))
                            .clipShape(.rect(bottomLeadingRadius: 12, bottomTrailingRadius: 12))
                            .accessibilityLabel("Listening Progress")
                    }
                }
            Text(title).font(.caption.weight(.semibold)).lineLimit(2, reservesSpace: true)
            Text(subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(width: 114, alignment: .leading)
    }
}
#endif
