#if os(iOS)
import Nuke
import NukeUI
import Observation
import SwiftUI
import UniformTypeIdentifiers

// Build 135: Podcast Discover and Library as artwork-led, red-and-black
// browsing pages. Data comes from the listener's own library and Apple's
// public top-podcast charts (`PodcastCharts`); nothing here is hard-coded or
// invented. Shelves are lazy; empty personal shelves are hidden.

// MARK: - Charts model

/// Discover's chart state. Loads only what is on screen: the overall chart
/// when Discover appears, a category's chart when the listener picks it, and a
/// longer list only for See All.
@MainActor @Observable
final class KyroPodcastChartsModel {
    static let rowLimit = 25
    static let fullLimit = 100

    private(set) var top: PodcastChart?
    private(set) var byCategory: [PodcastCategory: PodcastChart] = [:]
    private(set) var loadingTop = false
    private(set) var loadingCategory: PodcastCategory?
    private(set) var failed = false
    var category: PodcastCategory?
    var opening: String?

    @ObservationIgnored private let charts: PodcastCharts
    @ObservationIgnored let country: String

    init(charts: PodcastCharts = .shared, country: String = Locale.current.region?.identifier ?? "US") {
        self.charts = charts
        self.country = country
    }

    func loadTop() async {
        if top == nil { top = await charts.cached(category: nil, limit: Self.rowLimit, country: country) }
        loadingTop = top == nil
        defer { loadingTop = false }
        do {
            let chart = try await charts.chart(category: nil, limit: Self.rowLimit, country: country)
            if !Task.isCancelled { top = chart; failed = false }
        } catch {
            if !Task.isCancelled, top == nil { failed = true }
        }
    }

    func loadCategory(_ category: PodcastCategory) async {
        if byCategory[category] == nil,
           let cached = await charts.cached(category: category, limit: Self.rowLimit, country: country) {
            byCategory[category] = cached
        }
        loadingCategory = byCategory[category] == nil ? category : nil
        defer { if loadingCategory == category { loadingCategory = nil } }
        if let chart = try? await charts.chart(category: category, limit: Self.rowLimit, country: country), !Task.isCancelled {
            byCategory[category] = chart
        }
    }

    func full(_ category: PodcastCategory?) async throws -> PodcastChart {
        try await charts.chart(category: category, limit: Self.fullLimit, country: country)
    }

    /// Finds the show's public feed and hands it to the existing preview flow.
    func feed(for entry: PodcastChartEntry) async -> URL? {
        opening = entry.appleID
        defer { if opening == entry.appleID { opening = nil } }
        return try? await charts.feed(appleID: entry.appleID, country: country)
    }
}

// MARK: - Shared pieces

enum KyroPodcastPalette {
    static let accent = KyroModernStyle.crimson
    static let chip = Color.white.opacity(0.06)
    static let chipStroke = Color.white.opacity(0.14)
}

struct KyroPodcastShelfHeader: View {
    let title: String
    var caption: String?
    var seeAll: (() -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.title3.weight(.bold)).accessibilityAddTraits(.isHeader)
                if let caption { Text(caption).font(.caption).foregroundStyle(KyroModernStyle.tertiary) }
            }
            Spacer()
            if let seeAll {
                Button(action: seeAll) {
                    HStack(spacing: 3) { Text("See All"); Image(systemName: "chevron.right") }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(KyroModernStyle.secondary)
                        .frame(minHeight: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("See All \(title)")
            }
        }
        .padding(.horizontal, 20)
    }
}

/// A square show tile for horizontal shelves and grids.
struct KyroPodcastShowTile: View {
    let title: String
    let subtitle: String
    let artwork: URL?
    var size: CGFloat = 140
    var badge: Bool = false
    var busy: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            KyroPodcastArtwork(url: artwork, size: size, decodeSize: 280)
                .overlay(alignment: .topTrailing) {
                    if badge {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 20, weight: .semibold))
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, KyroPodcastPalette.accent)
                            .padding(6)
                            .accessibilityLabel("Subscribed")
                    }
                }
                .overlay { if busy { ProgressView().tint(.white).padding(10).background(.black.opacity(0.5), in: Circle()) } }
                .shadow(color: .black.opacity(0.4), radius: 8, y: 5)
            Text(title).font(.subheadline.weight(.semibold)).lineLimit(2, reservesSpace: true)
            if !subtitle.isEmpty {
                Text(subtitle).font(.caption).foregroundStyle(KyroModernStyle.secondary).lineLimit(1)
            }
        }
        .frame(width: size, alignment: .leading)
        .contentShape(Rectangle())
    }
}

/// Played, progress and download state for an episode, in one line.
private struct KyroEpisodeMeta: View {
    let entry: PodcastEntry
    private let library = KyroPodcastLibrary.shared

    var body: some View {
        HStack(spacing: 5) {
            if library.progress[entry.id]?.played == true {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(KyroPodcastPalette.accent).accessibilityLabel("Played")
            } else if (library.progress[entry.id]?.resumable ?? 0) == 0 {
                Circle().fill(KyroPodcastPalette.accent).frame(width: 7, height: 7).accessibilityLabel("Unplayed")
            }
            if let date = entry.episode.published { Text(date, format: .dateTime.month(.abbreviated).day()) }
            if let duration = entry.episode.duration, duration > 0 {
                Text("·"); Text(KyroModernStyle.time(duration))
            }
        }
        .font(.caption)
        .foregroundStyle(KyroModernStyle.tertiary)
    }
}

/// A latest-episode card: artwork, title, show, date, duration, play and download.
struct KyroPodcastEpisodeCard: View {
    let entry: PodcastEntry
    private let player = KyroPodcastPlayer.shared
    private let library = KyroPodcastLibrary.shared
    private let downloads = KyroPodcastDownloads.shared

    var body: some View {
        HStack(spacing: 12) {
            KyroPodcastArtwork(url: entry.artwork, size: 64, decodeSize: 128)
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.episode.title).font(.subheadline.weight(.semibold)).lineLimit(2)
                Text(entry.showTitle).font(.caption).foregroundStyle(KyroModernStyle.secondary).lineLimit(1)
                KyroEpisodeMeta(entry: entry)
                if let progress = library.progress[entry.id], progress.resumable > 0 {
                    ProgressView(value: progress.fraction).tint(KyroPodcastPalette.accent).accessibilityLabel("Listening progress")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            downloadButton
            Button { player.play(entry) } label: {
                Image(systemName: player.current?.id == entry.id && player.state == .playing ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 34))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(KyroModernStyle.night, .white)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(player.current?.id == entry.id && player.state == .playing ? "Pause" : "Play \(entry.episode.title)")
        }
        .padding(12)
        .background(KyroModernStyle.card(cornerRadius: 16))
        .contextMenu { KyroPodcastEpisodeMenuItems(entry: entry) }
    }

    @ViewBuilder
    private var downloadButton: some View {
        switch downloads.status[entry.id] {
        case .downloading(let fraction):
            Button { downloads.cancel(entry) } label: {
                ZStack {
                    Circle().stroke(Color.white.opacity(0.2), lineWidth: 3)
                    Circle().trim(from: 0, to: fraction ?? 0.1).stroke(KyroPodcastPalette.accent, lineWidth: 3).rotationEffect(.degrees(-90))
                    Image(systemName: "stop.fill").font(.system(size: 9))
                }
                .frame(width: 26, height: 26).frame(width: 40, height: 44)
            }
            .buttonStyle(.plain).accessibilityLabel("Cancel Download")
        case .failed:
            Button { downloads.start(entry, wifiOnly: library.preferences.wifiOnly) } label: {
                Image(systemName: "exclamationmark.arrow.circlepath").frame(width: 40, height: 44)
            }
            .buttonStyle(.plain).accessibilityLabel("Retry Download")
        case nil:
            if downloads.hasDownload(entry) {
                Image(systemName: "arrow.down.circle.fill").foregroundStyle(KyroPodcastPalette.accent)
                    .frame(width: 40, height: 44).accessibilityLabel("Downloaded")
            } else {
                Button { downloads.start(entry, wifiOnly: library.preferences.wifiOnly) } label: {
                    Image(systemName: "arrow.down.circle").frame(width: 40, height: 44)
                }
                .buttonStyle(.plain).accessibilityLabel("Download Episode")
            }
        }
    }
}

/// The same actions as an episode row's menu.
struct KyroPodcastEpisodeMenuItems: View {
    let entry: PodcastEntry
    private let player = KyroPodcastPlayer.shared
    private let library = KyroPodcastLibrary.shared
    private let downloads = KyroPodcastDownloads.shared

    var body: some View {
        Button("Play", systemImage: "play.fill") { player.play(entry) }
        Button("Add to Queue", systemImage: "text.badge.plus") { library.enqueue(entry, currentID: player.current?.id) }
        Button(library.saved.contains(entry.id) ? "Unsave Episode" : "Save Episode", systemImage: "bookmark") { library.toggleSaved(entry) }
        Button(library.progress[entry.id]?.played == true ? "Mark Unplayed" : "Mark Played", systemImage: "checkmark.circle") {
            library.mark(entry, played: library.progress[entry.id]?.played != true)
        }
        if downloads.hasDownload(entry) {
            Button("Remove Download", systemImage: "trash", role: .destructive) { downloads.remove(entry) }
        }
    }
}

// MARK: - Discover

struct KyroPodcastDiscoverHome: View {
    @Bindable var discovery: KyroPodcastDiscoveryState
    let charts: KyroPodcastChartsModel
    let showLibrary: () -> Void
    let openSettings: () -> Void
    let openFeedEntry: () -> Void
    @FocusState private var searchFocused: Bool
    @State private var fullChart: KyroPodcastFullChart.Selection?
    private let library = KyroPodcastLibrary.shared

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 28) {
            header
            if discovery.isShowingResults {
                searchResults
            } else {
                featured
                categories
                if let category = charts.category { categoryShelf(category) }
                popular
                continueListening
                subscriptions
                latest
                if charts.failed && charts.top == nil {
                    Text("Apple Podcasts charts are unavailable right now. Search by title or add a public RSS feed.")
                        .font(.footnote).foregroundStyle(KyroModernStyle.secondary).padding(.horizontal, 20)
                }
            }
        }
        .padding(.bottom, 24)
        .task { await charts.loadTop() }
        .task(id: charts.category) { if let category = charts.category { await charts.loadCategory(category) } }
        .task(id: discovery.query) {
            // Debounced: typing pauses before Apple is asked, and each keystroke cancels the last wait.
            let term = discovery.query.trimmingCharacters(in: .whitespacesAndNewlines)
            guard term.count >= 3 else { return }
            try? await Task.sleep(for: .milliseconds(900))
            guard !Task.isCancelled else { return }
            discovery.submit()
        }
        .navigationDestination(item: $fullChart) { selection in
            KyroPodcastFullChart(selection: selection, charts: charts, discovery: discovery)
        }
    }

    // MARK: Header and search

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Podcasts").font(.largeTitle.weight(.heavy)).accessibilityAddTraits(.isHeader)
                Text("Discover, follow and stream podcasts on Kyro X.")
                    .font(.subheadline).foregroundStyle(KyroModernStyle.secondary)
            }
            HStack(spacing: 10) {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass").foregroundStyle(KyroModernStyle.secondary)
                    TextField("Search podcasts or creators", text: $discovery.query)
                        .submitLabel(.search)
                        .focused($searchFocused)
                        .onSubmit { searchFocused = false; discovery.submit() }
                        .autocorrectionDisabled()
                    if !discovery.query.isEmpty {
                        Button { discovery.clearSearch() } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(KyroModernStyle.secondary)
                        }
                        .buttonStyle(.plain).accessibilityLabel("Clear search")
                    }
                }
                .padding(.horizontal, 14).frame(minHeight: 48)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(KyroPodcastPalette.chip))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(KyroPodcastPalette.chipStroke))
                Menu {
                    Button("Add RSS Feed", systemImage: "link.badge.plus", action: openFeedEntry)
                    Button("Podcast Settings", systemImage: "slider.horizontal.3", action: openSettings)
                } label: {
                    Image(systemName: "slider.horizontal.3")
                        .font(.body.weight(.semibold))
                        .frame(width: 48, height: 48)
                        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(KyroPodcastPalette.chip))
                        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(KyroPodcastPalette.chipStroke))
                }
                .accessibilityLabel("Podcast settings and RSS")
            }
            if let problem = discovery.problem {
                Text(problem).font(.footnote).foregroundStyle(KyroModernStyle.secondary)
            }
            if discovery.opening { ProgressView("Opening feed…").tint(.white) }
        }
        .padding(.horizontal, 20)
    }

    @ViewBuilder
    private var searchResults: some View {
        VStack(alignment: .leading, spacing: 12) {
            KyroPodcastShelfHeader(title: "Results", caption: "From Apple Podcasts search")
            if discovery.searching {
                ProgressView("Searching Apple Podcasts…").tint(.white).padding(.horizontal, 20)
            } else if discovery.submitted != nil, discovery.results.isEmpty, discovery.problem == nil {
                Text("No public feeds found. Try another title or creator, or add a feed address.")
                    .font(.subheadline).foregroundStyle(KyroModernStyle.secondary).padding(.horizontal, 20)
            }
            LazyVStack(spacing: 10) {
                ForEach(discovery.results) { result in
                    Button {
                        searchFocused = false
                        discovery.open(result.feed)
                    } label: {
                        HStack(spacing: 12) {
                            KyroPodcastArtwork(url: result.artwork, size: 64, decodeSize: 128)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(result.title).font(.headline).lineLimit(2)
                                if !result.publisher.isEmpty {
                                    Text(result.publisher).font(.subheadline).foregroundStyle(KyroModernStyle.secondary).lineLimit(1)
                                }
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right").foregroundStyle(KyroModernStyle.tertiary)
                        }
                        .padding(12)
                        .background(KyroModernStyle.card(cornerRadius: 16))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 20)
            Link("Search results from Apple Podcasts", destination: URL(string: "https://podcasts.apple.com/")!)
                .font(.caption).foregroundStyle(KyroModernStyle.tertiary).padding(.horizontal, 20)
        }
    }

    // MARK: Featured

    @ViewBuilder
    private var featured: some View {
        let entries = Array((charts.top?.entries ?? []).prefix(5))
        if !entries.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 14) {
                    ForEach(Array(entries.enumerated()), id: \.element.id) { rank, entry in
                        KyroPodcastFeatureCard(entry: entry, rank: rank + 1, busy: charts.opening == entry.appleID) { open(entry) }
                            .containerRelativeFrame(.horizontal) { width, _ in max(260, width - 40) }
                    }
                }
                .scrollTargetLayout()
            }
            .contentMargins(.horizontal, 20, for: .scrollContent)
            .scrollTargetBehavior(.viewAligned)
        } else if charts.loadingTop {
            RoundedRectangle(cornerRadius: 22).fill(KyroPodcastPalette.chip).frame(height: 210)
                .overlay(ProgressView().tint(.white)).padding(.horizontal, 20)
        }
    }

    // MARK: Categories

    private var categories: some View {
        VStack(alignment: .leading, spacing: 12) {
            KyroPodcastShelfHeader(title: "Browse by Category")
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHGrid(rows: [GridItem(.fixed(44), spacing: 10), GridItem(.fixed(44))], spacing: 10) {
                    ForEach(PodcastCategory.allCases) { category in
                        let selected = charts.category == category
                        Button {
                            charts.category = selected ? nil : category
                        } label: {
                            Label(category.title, systemImage: category.symbol)
                                .font(.subheadline.weight(.semibold))
                                .padding(.horizontal, 16)
                                .frame(height: 44)
                                .background(Capsule().fill(selected ? KyroPodcastPalette.accent.opacity(0.22) : KyroPodcastPalette.chip))
                                .overlay(Capsule().strokeBorder(selected ? KyroPodcastPalette.accent : KyroPodcastPalette.chipStroke,
                                                                lineWidth: selected ? 1.5 : 1))
                                .shadow(color: selected ? KyroPodcastPalette.accent.opacity(0.4) : .clear, radius: 8)
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(selected ? .isSelected : [])
                    }
                }
                .padding(.horizontal, 20)
            }
        }
    }

    @ViewBuilder
    private func categoryShelf(_ category: PodcastCategory) -> some View {
        let entries = charts.byCategory[category]?.entries ?? []
        VStack(alignment: .leading, spacing: 12) {
            KyroPodcastShelfHeader(title: "Top in \(category.title)", caption: "Apple Podcasts chart",
                                   seeAll: entries.isEmpty ? nil : { fullChart = .init(category: category) })
            if entries.isEmpty {
                if charts.loadingCategory == category {
                    ProgressView().tint(.white).padding(.horizontal, 20)
                } else {
                    Text("This chart is unavailable right now.").font(.subheadline)
                        .foregroundStyle(KyroModernStyle.secondary).padding(.horizontal, 20)
                }
            } else {
                chartShelf(entries)
            }
        }
    }

    // MARK: Popular

    @ViewBuilder
    private var popular: some View {
        let entries = charts.top?.entries ?? []
        if !entries.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                KyroPodcastShelfHeader(title: "Popular Podcasts", caption: "Apple Podcasts Top Shows",
                                       seeAll: { fullChart = .init(category: nil) })
                chartShelf(entries)
            }
        }
    }

    private func chartShelf(_ entries: [PodcastChartEntry]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: .top, spacing: 14) {
                ForEach(entries) { entry in
                    Button { open(entry) } label: {
                        KyroPodcastShowTile(title: entry.title, subtitle: entry.creator, artwork: entry.artwork,
                                            busy: charts.opening == entry.appleID)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 20)
        }
    }

    private func open(_ entry: PodcastChartEntry) {
        Task {
            if let feed = await charts.feed(for: entry) {
                discovery.open(feed)
            } else {
                discovery.problem = "“\(entry.title)” has no public RSS feed Kyro can open."
            }
        }
    }

    // MARK: Personal shelves

    @ViewBuilder
    private var continueListening: some View {
        let entries = Array(library.continuing().prefix(12))
        if !entries.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                KyroPodcastShelfHeader(title: "Continue Listening")
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 12) {
                        ForEach(entries) { entry in KyroPodcastContinueCard(entry: entry) }
                    }
                    .padding(.horizontal, 20)
                }
            }
        }
    }

    @ViewBuilder
    private var subscriptions: some View {
        let shows = Array(library.shows.reversed().prefix(20))
        if !shows.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                KyroPodcastShelfHeader(title: "Subscriptions", seeAll: showLibrary)
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 14) {
                        ForEach(shows) { show in
                            NavigationLink { KyroPodcastShowView(initialShow: show) } label: {
                                KyroPodcastShowTile(title: show.title, subtitle: "", artwork: show.artwork, size: 112, badge: true)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 20)
                }
            }
        }
    }

    @ViewBuilder
    private var latest: some View {
        let entries = library.latest(limit: 8)
        if !entries.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                KyroPodcastShelfHeader(title: "Latest Episodes", seeAll: showLibrary)
                LazyVStack(spacing: 10) {
                    ForEach(entries) { KyroPodcastEpisodeCard(entry: $0) }
                }
                .padding(.horizontal, 20)
            }
        }
    }
}

/// A large feature card from the top of the chart. Swiped by the listener;
/// nothing advances on its own.
private struct KyroPodcastFeatureCard: View {
    let entry: PodcastChartEntry
    let rank: Int
    let busy: Bool
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(alignment: .center, spacing: 14) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("TOP \(rank) · APPLE PODCASTS")
                        .font(.caption2.weight(.heavy)).tracking(1.5)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Capsule().fill(KyroPodcastPalette.accent))
                    Text(entry.title).font(.title3.weight(.heavy)).lineLimit(2)
                    if !entry.summary.isEmpty {
                        Text(entry.summary).font(.footnote).foregroundStyle(KyroModernStyle.secondary).lineLimit(3)
                    } else if !entry.creator.isEmpty {
                        Text(entry.creator).font(.footnote).foregroundStyle(KyroModernStyle.secondary).lineLimit(2)
                    }
                    Spacer(minLength: 0)
                    Label(busy ? "Opening…" : "Open Show", systemImage: "play.fill")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(KyroModernStyle.night)
                        .padding(.horizontal, 14).padding(.vertical, 9)
                        .background(Capsule().fill(.white))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                KyroPodcastArtwork(url: entry.artwork, size: 128, decodeSize: 256)
                    .shadow(color: .black.opacity(0.5), radius: 12, y: 6)
            }
            .padding(18)
            .frame(height: 210)
            .background {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(LinearGradient(colors: [KyroModernStyle.crimsonDeep, KyroModernStyle.night],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                    .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(KyroPodcastPalette.chipStroke))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens the show")
    }
}

/// An episode in progress, with a resume action.
private struct KyroPodcastContinueCard: View {
    let entry: PodcastEntry
    private let player = KyroPodcastPlayer.shared
    private let library = KyroPodcastLibrary.shared

    var body: some View {
        let progress = library.progress[entry.id]
        Button { player.play(entry) } label: {
            HStack(spacing: 12) {
                KyroPodcastArtwork(url: entry.artwork, size: 64, decodeSize: 128)
                VStack(alignment: .leading, spacing: 5) {
                    Text(entry.episode.title).font(.subheadline.weight(.semibold)).lineLimit(2)
                    Text(entry.showTitle).font(.caption).foregroundStyle(KyroModernStyle.secondary).lineLimit(1)
                    if let progress {
                        ProgressView(value: progress.fraction).tint(KyroPodcastPalette.accent)
                        Text(remaining(progress)).font(.caption2.monospacedDigit()).foregroundStyle(KyroModernStyle.tertiary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "play.circle.fill").font(.system(size: 32))
                    .symbolRenderingMode(.palette).foregroundStyle(KyroModernStyle.night, .white)
            }
            .padding(12)
            .frame(width: 300)
            .background(KyroModernStyle.card(cornerRadius: 16))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Resume \(entry.episode.title)")
        .contextMenu { KyroPodcastEpisodeMenuItems(entry: entry) }
    }

    private func remaining(_ progress: PodcastProgress) -> String {
        guard progress.duration > 0 else { return KyroModernStyle.time(progress.position) + " played" }
        return KyroModernStyle.time(max(0, progress.duration - progress.position)) + " left"
    }
}

/// See All for a chart: a ranked list, loaded only when opened.
struct KyroPodcastFullChart: View {
    struct Selection: Hashable, Identifiable {
        let category: PodcastCategory?
        var id: String { category?.rawValue ?? "top" }
    }
    let selection: Selection
    let charts: KyroPodcastChartsModel
    let discovery: KyroPodcastDiscoveryState
    @State private var chart: PodcastChart?
    @State private var failed = false

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                if let chart {
                    ForEach(Array(chart.entries.enumerated()), id: \.element.id) { index, entry in
                        Button {
                            Task {
                                if let feed = await charts.feed(for: entry) { discovery.open(feed) }
                                else { discovery.problem = "“\(entry.title)” has no public RSS feed Kyro can open." }
                            }
                        } label: {
                            HStack(spacing: 12) {
                                Text("\(index + 1)").font(.headline.monospacedDigit()).foregroundStyle(KyroModernStyle.secondary)
                                    .frame(width: 30)
                                KyroPodcastArtwork(url: entry.artwork, size: 60, decodeSize: 120)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(entry.title).font(.subheadline.weight(.semibold)).lineLimit(2)
                                    Text(entry.creator).font(.caption).foregroundStyle(KyroModernStyle.secondary).lineLimit(1)
                                }
                                Spacer(minLength: 0)
                                if charts.opening == entry.appleID { ProgressView().tint(.white) }
                            }
                            .padding(10)
                            .background(KyroModernStyle.card(cornerRadius: 14))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                } else if failed {
                    Text("This chart is unavailable right now.").foregroundStyle(KyroModernStyle.secondary).padding(.top, 40)
                } else {
                    ProgressView().tint(.white).padding(.top, 40)
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 24)
        }
        .background(KyroModernStyle.background.ignoresSafeArea())
        .environment(\.colorScheme, .dark)
        .navigationTitle(selection.category.map { "Top \($0.title)" } ?? "Top Podcasts")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            do { chart = try await charts.full(selection.category) } catch { failed = chart == nil }
        }
    }
}

// MARK: - Library

struct KyroPodcastLibraryHome: View {
    enum Shelf: String, CaseIterable, Identifiable {
        case shows = "Shows", latest = "Latest", saved = "Saved", downloads = "Downloads", history = "History"
        var id: String { rawValue }
        var symbol: String {
            switch self {
            case .shows: "square.grid.2x2"
            case .latest: "clock.badge"
            case .saved: "bookmark"
            case .downloads: "arrow.down.circle"
            case .history: "clock.arrow.circlepath"
            }
        }
    }

    @Binding var shelf: Shelf
    let openFeedEntry: () -> Void
    @AppStorage("kyrox.podcasts.libraryGrid") private var grid = true
    @State private var query = ""
    @State private var sort = PodcastLibrarySort.recentlyUpdated
    @State private var importing = false
    @State private var exporting = false
    @State private var exportDocument: KyroPodcastOPMLFile?
    @State private var message: String?
    @State private var confirmClear = false
    private let library = KyroPodcastLibrary.shared
    private let downloads = KyroPodcastDownloads.shared

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("Library").font(.largeTitle.weight(.heavy)).accessibilityAddTraits(.isHeader)
                Spacer()
                manageMenu
            }
            .padding(.horizontal, 20)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Shelf.allCases) { item in
                        Button { shelf = item } label: {
                            Label(item.rawValue, systemImage: item.symbol)
                                .font(.subheadline.weight(.semibold))
                                .padding(.horizontal, 14).frame(height: 40)
                                .background(Capsule().fill(shelf == item ? KyroPodcastPalette.accent : KyroPodcastPalette.chip))
                                .overlay(Capsule().strokeBorder(shelf == item ? .clear : KyroPodcastPalette.chipStroke))
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(shelf == item ? .isSelected : [])
                    }
                }
                .padding(.horizontal, 20)
            }
            if library.isRefreshing { ProgressView("Refreshing feeds…").tint(.white).padding(.horizontal, 20) }
            if let message { Text(message).font(.footnote).foregroundStyle(KyroModernStyle.secondary).padding(.horizontal, 20) }
            switch shelf {
            case .shows: shows
            case .latest: episodes(library.latest(), empty: "Subscribe to a podcast to see its latest episodes.")
            case .saved: episodes(savedEntries, empty: "Save episodes from their menus or the player.")
            case .downloads: downloadsShelf
            case .history: historyShelf
            }
        }
        .padding(.bottom, 24)
        .fileImporter(isPresented: $importing, allowedContentTypes: [.xml, .kyroPodcastOPML, .data], onCompletion: importFile)
        .fileExporter(isPresented: $exporting, document: exportDocument, contentType: .kyroPodcastOPML,
                      defaultFilename: "Kyro Podcasts") { result in
            if case .failure(let error) = result { message = error.localizedDescription }
        }
    }

    private var manageMenu: some View {
        Menu {
            Button("Add RSS Feed", systemImage: "link.badge.plus", action: openFeedEntry)
            Button("Refresh All Feeds", systemImage: "arrow.clockwise") {
                Task {
                    let failures = await library.refreshAll(automatic: false)
                    message = failures > 0 ? "Couldn’t refresh \(failures) feeds. Cached episodes are still available." : nil
                }
            }
            Button("Import OPML", systemImage: "square.and.arrow.down") { importing = true }
            Button("Export OPML", systemImage: "square.and.arrow.up") {
                exportDocument = KyroPodcastOPMLFile(data: PodcastOPML.write(library.shows))
                exporting = true
            }
        } label: {
            Image(systemName: "ellipsis.circle").font(.title2).frame(width: 44, height: 44)
        }
        .accessibilityLabel("Manage Library")
    }

    // MARK: Shows

    private var latestDates: [String: Date] {
        var dates: [String: Date] = [:]
        for show in library.shows {
            if let date = library.entries(for: show, limit: 5).compactMap(\.episode.published).max() { dates[show.id] = date }
        }
        return dates
    }

    @ViewBuilder
    private var shows: some View {
        let sorted = PodcastLibrarySort.sorted(library.shows, by: sort, latest: sort == .recentlyUpdated ? latestDates : [:], matching: query)
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(KyroModernStyle.secondary)
                    TextField("Search your shows", text: $query).autocorrectionDisabled()
                }
                .padding(.horizontal, 12).frame(minHeight: 44)
                .background(RoundedRectangle(cornerRadius: 12).fill(KyroPodcastPalette.chip))
                Menu {
                    Picker("Sort", selection: $sort) {
                        ForEach(PodcastLibrarySort.allCases) { Text($0.rawValue).tag($0) }
                    }
                } label: {
                    Image(systemName: "arrow.up.arrow.down").frame(width: 44, height: 44)
                        .background(RoundedRectangle(cornerRadius: 12).fill(KyroPodcastPalette.chip))
                }
                .accessibilityLabel("Sort")
                .accessibilityValue(sort.rawValue)
                Button { grid.toggle() } label: {
                    Image(systemName: grid ? "list.bullet" : "square.grid.2x2").frame(width: 44, height: 44)
                        .background(RoundedRectangle(cornerRadius: 12).fill(KyroPodcastPalette.chip))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(grid ? "Show as List" : "Show as Grid")
            }
            .padding(.horizontal, 20)
            if sorted.isEmpty {
                Text(library.shows.isEmpty ? "Subscribe in Discover, add an RSS feed, or import OPML." : "No matching shows.")
                    .font(.subheadline).foregroundStyle(KyroModernStyle.secondary).padding(.horizontal, 20)
            } else if grid {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 104, maximum: 160), spacing: 14, alignment: .top)], spacing: 18) {
                    ForEach(sorted) { show in
                        NavigationLink { KyroPodcastShowView(initialShow: show) } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                KyroPodcastGridArtwork(url: show.artwork)
                                Text(show.title).font(.caption.weight(.semibold)).lineLimit(2, reservesSpace: true)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 20)
            } else {
                LazyVStack(spacing: 10) {
                    ForEach(sorted) { show in
                        NavigationLink { KyroPodcastShowView(initialShow: show) } label: {
                            HStack(spacing: 12) {
                                KyroPodcastArtwork(url: show.artwork, size: 64, decodeSize: 128)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(show.title).font(.headline).lineLimit(2)
                                    if !show.publisher.isEmpty {
                                        Text(show.publisher).font(.caption).foregroundStyle(KyroModernStyle.secondary).lineLimit(1)
                                    }
                                }
                                Spacer(minLength: 0)
                                Image(systemName: "chevron.right").foregroundStyle(KyroModernStyle.tertiary)
                            }
                            .padding(10)
                            .background(KyroModernStyle.card(cornerRadius: 14))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 20)
            }
        }
    }

    // MARK: Episodes

    private var savedEntries: [PodcastEntry] {
        var seen = Set<String>()
        return (library.retainedEntries + library.latest()).filter { library.saved.contains($0.id) && seen.insert($0.id).inserted }
    }

    @ViewBuilder
    private func episodes(_ entries: [PodcastEntry], empty: String) -> some View {
        if entries.isEmpty {
            Text(empty).font(.subheadline).foregroundStyle(KyroModernStyle.secondary).padding(.horizontal, 20)
        } else {
            LazyVStack(spacing: 10) { ForEach(entries) { KyroPodcastEpisodeCard(entry: $0) } }
                .padding(.horizontal, 20)
        }
    }

    @ViewBuilder
    private var downloadsShelf: some View {
        let entries = library.retainedEntries.filter { downloads.hasDownload($0) || downloads.status[$0.id] != nil }
            .sorted { $0.episode.title.localizedStandardCompare($1.episode.title) == .orderedAscending }
        Text("On this device: " + ByteCountFormatter.string(fromByteCount: downloads.storage, countStyle: .file))
            .font(.subheadline).foregroundStyle(KyroModernStyle.secondary).padding(.horizontal, 20)
        episodes(entries, empty: "Download an episode to listen offline.")
    }

    @ViewBuilder
    private var historyShelf: some View {
        if !library.history.isEmpty {
            Button("Clear Listening History", role: .destructive) { confirmClear = true }
                .font(.subheadline.weight(.semibold)).padding(.horizontal, 20)
                .confirmationDialog("Clear podcast listening history?", isPresented: $confirmClear) {
                    Button("Clear History", role: .destructive) { library.clearHistory() }
                }
        }
        episodes(library.history, empty: "No episodes played yet.")
    }

    private func importFile(_ result: Result<URL, Error>) {
        Task {
            do {
                let url = try result.get()
                let feeds = try await Task.detached(priority: .userInitiated) {
                    let permitted = url.startAccessingSecurityScopedResource()
                    defer { if permitted { url.stopAccessingSecurityScopedResource() } }
                    let file = try FileHandle(forReadingFrom: url)
                    defer { try? file.close() }
                    return try PodcastOPML.read(file.read(upToCount: PodcastOPML.byteLimit + 1) ?? Data())
                }.value
                let before = library.shows.count
                library.importFeeds(feeds)
                message = "Added \(library.shows.count - before) subscriptions. Refresh to load their episodes."
            } catch { message = error.localizedDescription }
        }
    }
}

/// Grid artwork that fills its column at any width.
private struct KyroPodcastGridArtwork: View {
    let url: URL?
    @Environment(\.displayScale) private var scale

    var body: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                LazyImage(request: url.flatMap {
                    PosterImageCache.displayRequest(url: $0, pointSize: CGSize(width: 160, height: 160), scale: scale)
                }) { state in
                    if let image = state.image { image.resizable().scaledToFill() }
                    else {
                        ZStack {
                            KyroModernStyle.surface
                            Image(systemName: "waveform").foregroundStyle(KyroPodcastPalette.accent)
                        }
                    }
                }
                .onDisappear(.cancel)
            }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .shadow(color: .black.opacity(0.35), radius: 6, y: 4)
            .accessibilityHidden(true)
    }
}

extension UTType {
    static var kyroPodcastOPML: UTType { UTType(filenameExtension: "opml", conformingTo: .xml) ?? .xml }
}

struct KyroPodcastOPMLFile: FileDocument {
    static let readableContentTypes: [UTType] = [.kyroPodcastOPML]
    let data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { .init(regularFileWithContents: data) }
}

/// Direct RSS entry, from Discover's menu or the Library menu.
struct KyroPodcastFeedEntrySheet: View {
    @Bindable var discovery: KyroPodcastDiscoveryState
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: Bool

    var body: some View {
        Form {
            Section {
                TextField("https://example.com/feed.xml", text: $discovery.address)
                    .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .focused($focused).submitLabel(.go).onSubmit(open)
            } header: {
                Text("Public RSS Feed")
            } footer: {
                Text("Kyro opens public podcast feeds directly. Private or authenticated feeds aren’t supported.")
            }
            if let problem = discovery.problem { Text(problem).font(.footnote).foregroundStyle(.secondary) }
        }
        .navigationTitle("Add RSS Feed").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) { Button("Open", action: open).disabled(discovery.address.isEmpty) }
        }
        .onAppear { focused = true }
    }

    private func open() {
        discovery.openFeed()
        if discovery.problem == nil { dismiss() }
    }
}
#endif
