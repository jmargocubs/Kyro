#if os(iOS)
import SwiftUI

/// Build 139: Home's audio shelf sizes, observed so a change in Customize Home
/// applies at once. Values are bounded choices (`KyroAudioShelfLimit.choices`).
@MainActor @Observable
final class KyroAudioShelfLimits {
    static let shared = KyroAudioShelfLimits()
    private(set) var values: [String: Int] = [:]
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        reload()
        NotificationCenter.default.addObserver(forName: .kyroSettingsDidRestore, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
    }

    func value(_ limit: KyroAudioShelfLimit) -> Int { values[limit.key] ?? limit.defaultValue }

    func set(_ value: Int, for limit: KyroAudioShelfLimit) {
        KyroAudioShelfLimit.set(value, for: limit, in: defaults)
        reload()
    }

    func reload() {
        values = Dictionary(uniqueKeysWithValues: KyroAudioShelfLimit.all.map { ($0.key, KyroAudioShelfLimit.value($0, in: defaults)) })
    }
}

/// Customize Home → Audio Shelf Sizes.
struct KyroAudioShelfLimitsSection: View {
    private let limits = KyroAudioShelfLimits.shared

    var body: some View {
        Section {
            ForEach(KyroAudioShelfLimit.all, id: \.key) { limit in
                Picker(limit.title, selection: Binding(get: { limits.value(limit) }, set: { limits.set($0, for: limit) })) {
                    ForEach(KyroAudioShelfLimit.choices, id: \.self) { Text("\($0) items").tag($0) }
                }
            }
        } header: {
            Text("Audio Shelf Sizes")
        } footer: {
            Text("The most items each audio shelf on Home shows. Radio shelves default to 20, podcast shelves to 12.")
        }
    }
}

/// Instantiated only for an enabled shelf. No player observation and no feed
/// network work on Home; playback checkpoints and cached entries drive cards.
struct KyroHomePodcastRail: View {
    let shelf: KyroHomeShelf
    @Environment(AppRouter.self) private var router
    @State private var selectedShow: PodcastShow?
    private let library = KyroPodcastLibrary.shared

    /// Build 139: the shelf's size from Customize Home (Build 138 drew 12).
    @MainActor static func limit(for shelf: KyroHomeShelf) -> Int {
        switch shelf {
        case .favoritePodcasts: KyroAudioShelfLimits.shared.value(.favoritePodcasts)
        case .latestPodcasts: KyroAudioShelfLimits.shared.value(.latestEpisodes)
        default: KyroAudioShelfLimits.shared.value(.continueListening)
        }
    }

    private var entries: [PodcastEntry] {
        let limit = Self.limit(for: shelf)
        return shelf == .latestPodcasts ? library.latest(limit: limit) : Array(library.continuing().prefix(limit))
    }
    private var favorites: [PodcastShow] {
        Array(library.shows.filter { library.favoriteShows.contains($0.id) }.prefix(Self.limit(for: shelf)))
    }

    static func itemCount(for shelf: KyroHomeShelf) -> Int {
        let library = KyroPodcastLibrary.shared
        let limit = limit(for: shelf)
        switch shelf {
        case .favoritePodcasts: return min(limit, library.favoriteShows.count)
        case .latestPodcasts: return library.cachedLatestCount(upTo: limit)
        default: return min(limit, library.continuing().count)
        }
    }

    var body: some View {
        let _ = KyroPerformanceDiagnostics.count(.homePodcastRailBody)
        if shelf == .favoritePodcasts {
            let shows = favorites
            if !shows.isEmpty {
                KyroHomeRail(title: shelf.title, sizing: .lazy, openHeader: openPodcasts) {
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
            if !episodes.isEmpty {
                KyroHomeRail(title: shelf.title, sizing: .lazy, openHeader: openPodcasts) {
                    ForEach(episodes) { entry in
                        Button { KyroPodcastPlayer.shared.play(entry) } label: {
                            if shelf == .continuePodcasts {
                                KyroHomeListeningCard(entry: entry, progress: library.progress[entry.id])
                            } else {
                                KyroHomePodcastCard(title: entry.episode.title, subtitle: entry.showTitle, artwork: entry.artwork, progress: nil)
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(shelf == .continuePodcasts ? "Resume \(entry.episode.title)" : "Play \(entry.episode.title)")
                    }
                }
            }
        }
    }

    private func openPodcasts() { KyroAudioDestination.podcasts.open(router: router) }
}

/// Build 139: Continue Listening, distinct from Continue Watching's wide
/// video cards: square art with a headphones mark, title, show, progress,
/// time left and a resume glyph.
private struct KyroHomeListeningCard: View {
    let entry: PodcastEntry
    let progress: PodcastProgress?
    private static let size: CGFloat = 132

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            KyroPodcastArtwork(url: entry.artwork, size: Self.size, decodeSize: 264)
                .overlay(alignment: .topLeading) {
                    Image(systemName: "headphones")
                        .font(.caption.weight(.bold)).foregroundStyle(.white)
                        .padding(6).background(KyroSignature.crimsonDeep.opacity(0.9), in: Circle())
                        .padding(6)
                        .accessibilityHidden(true)
                }
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 30)).symbolRenderingMode(.palette)
                        .foregroundStyle(KyroSignature.night, .white)
                        .shadow(color: .black.opacity(0.4), radius: 4, y: 2)
                        .padding(6)
                        .accessibilityHidden(true)
                }
            Text(entry.episode.title).font(.caption.weight(.semibold)).lineLimit(2, reservesSpace: true)
            Text(entry.showTitle).font(.caption2).foregroundStyle(KyroSignature.secondary).lineLimit(1)
            if let progress {
                ProgressView(value: progress.fraction).tint(KyroSignature.crimson).accessibilityLabel("Listening progress")
                Text(Self.remaining(progress)).font(.caption2.monospacedDigit()).foregroundStyle(KyroSignature.secondary)
            }
        }
        .frame(width: Self.size, alignment: .leading)
    }

    static func remaining(_ progress: PodcastProgress) -> String {
        let seconds = max(0, progress.duration - progress.position)
        guard progress.duration > 0 else { return "In progress" }
        let minutes = Int(seconds / 60)
        return minutes >= 60 ? "\(minutes / 60) hr \(minutes % 60) min left" : "\(max(1, minutes)) min left"
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
