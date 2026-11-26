#if os(iOS)
import Nuke
import NukeUI
import Observation
import SwiftUI
import UniformTypeIdentifiers

enum KyroAudioDestination: String, CaseIterable {
    case radio = "Radio", podcasts = "Podcasts"
    static let title = "Radio & Podcasts"
}

struct KyroAudioHeader<Actions: View>: View {
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        HStack {
            Text(KyroAudioDestination.title)
                .font(.title2.bold()).foregroundStyle(KyroSignature.primary)
                .accessibilityAddTraits(.isHeader)
            Spacer()
            actions()
        }
    }
}

struct KyroAudioPageHeading: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.largeTitle.weight(.heavy)).accessibilityAddTraits(.isHeader)
            Text(subtitle).font(.subheadline).foregroundStyle(KyroSignature.secondary)
        }
    }
}

struct KyroAudioSelector: View {
    @Binding var selection: KyroAudioDestination
    var body: some View {
        Picker("Audio destination", selection: $selection) {
            ForEach(KyroAudioDestination.allCases, id: \.self) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.segmented)
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        .accessibilityIdentifier("kyroAudioDestination")
    }
}

struct KyroAudioHub: View {
    let isSecondaryDestination: Bool
    @State private var selection: KyroAudioDestination

    init(isSecondaryDestination: Bool = false, initialSelection: KyroAudioDestination = .radio) {
        self.isSecondaryDestination = isSecondaryDestination
        _selection = State(initialValue: initialSelection)
    }

    var body: some View {
        switch selection {
        case .radio:
            KyroRadioView(isSecondaryDestination: isSecondaryDestination, audioDestination: $selection)
        case .podcasts:
            KyroPodcastBrowser(isSecondaryDestination: isSecondaryDestination, selection: $selection)
        }
    }
}

/// Local audio is usable before server setup or sign-in. This does not
/// navigate, authenticate or change state in the Silo server flow.
struct KyroAudioGuestAccess: ViewModifier {
    @State private var presented = false
    func body(content: Content) -> some View {
        content.safeAreaInset(edge: .bottom) {
            Button("Browse Podcasts Without Signing In", systemImage: "headphones") { presented = true }
                .font(.subheadline.weight(.semibold))
                .padding(.vertical, 8)
        }
        .sheet(isPresented: $presented) {
            NavigationStack {
                KyroAudioHub(isSecondaryDestination: true, initialSelection: .podcasts)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button("Done") { presented = false } }
                    }
            }
            .modifier(KyroPodcastPresentation())
            .modifier(KyroRadioNowPlayingPresentation())
        }
    }
}

@MainActor
private struct KyroPodcastBrowser: View {
    /// Build 135: Discover and Library. Library holds Shows, Latest, Saved,
    /// Downloads and History, so the page has two clear destinations.
    enum Section: String, CaseIterable {
        case discover = "Discover", library = "Library"
    }
    let isSecondaryDestination: Bool
    @Binding var selection: KyroAudioDestination
    @Environment(\.kyroShellHeader) private var shellHeader
    @Environment(\.nowPlayingShelfCoversPushedPages) private var shelfCoversPushedPages
    @Environment(\.scenePhase) private var scenePhase
    @State private var section: Section = .discover
    @State private var libraryShelf: KyroPodcastLibraryHome.Shelf = .shows
    @State private var fallbackScroll = PageChromeScrollState()
    @State private var showSettings = false
    @State private var showQueue = false
    @State private var showFeedEntry = false
    @State private var isDisplayed = false
    @State private var discovery = KyroPodcastDiscoveryState()
    @State private var charts = KyroPodcastChartsModel()
    private var runway: CGFloat? { isSecondaryDestination ? nil : shellHeader?.runway }
    private var hosted: Bool { runway != nil }
    private let library = KyroPodcastLibrary.shared
    private let appearance = KyroAppAppearanceStore.shared

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 12) {
                    if hosted {
                        KyroAudioHeader { actions }
                    }
                    KyroAudioSelector(selection: $selection)
                    Picker("Podcast section", selection: $section) {
                        ForEach(Section.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("kyroPodcastSection")
                }
                .padding(.horizontal, 20)
                switch section {
                case .discover:
                    KyroPodcastDiscoverHome(discovery: discovery, charts: charts,
                                            showLibrary: { libraryShelf = .shows; section = .library },
                                            openSettings: { showSettings = true },
                                            openFeedEntry: { showFeedEntry = true })
                case .library:
                    KyroPodcastLibraryHome(shelf: $libraryShelf, openFeedEntry: { showFeedEntry = true })
                }
            }
            .padding(.top, 8)
        }
        .scrollDismissesKeyboard(.interactively)
        .foregroundStyle(.white)
        .tint(KyroModernStyle.crimson)
        .background {
            if appearance.selection == .signature {
                KyroSignatureBackdrop(finish: section == .discover ? .discovery : .dense)
            } else {
                SiloPageBackdrop()
            }
        }
        .environment(\.colorScheme, .dark)
        .safeAreaInset(edge: .top, spacing: 0) {
            if let runway { Color.clear.frame(height: runway) }
        }
        .reportsPageChromeScroll(to: shellHeader?.scrollState(for: .radio) ?? fallbackScroll)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if KyroRadioNavigationPolicy.pageHostsNowPlayingBar(isSecondaryDestination: isSecondaryDestination,
                                                                shelfCoversPushedPages: shelfCoversPushedPages) {
                KyroRadioPageNowPlayingBar()
            }
        }
        .navigationTitle(hosted ? "" : KyroAudioDestination.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(hosted ? .hidden : .visible, for: .navigationBar)
        .toolbar { if !hosted { ToolbarItemGroup(placement: .topBarTrailing) { actions } } }
        .sheet(isPresented: $showSettings) { NavigationStack { KyroPodcastSettings() } }
        .sheet(isPresented: $showQueue) { NavigationStack { KyroPodcastQueueView() } }
        .sheet(isPresented: $showFeedEntry) { NavigationStack { KyroPodcastFeedEntrySheet(discovery: discovery) } }
        .navigationDestination(item: $discovery.preview) { show in
            KyroPodcastShowView(initialShow: show, needsPageShelf: isSecondaryDestination)
        }
        .task(id: discovery.submitted) {
            if section == .discover { await discovery.search() }
        }
        .task(id: discovery.lookup) { await discovery.openLookup() }
        .onChange(of: section) { _, section in if section != .discover { discovery.cancel() } }
        .onAppear { isDisplayed = true }
        .onDisappear { isDisplayed = false }
        .task(id: isDisplayed && scenePhase == .active) {
            // Bounded, interval-gated batches (Build 133), never every feed at once.
            guard isDisplayed, scenePhase == .active else { return }
            await library.restoreAll()
            _ = await library.refreshAll(automatic: true)
        }
    }

    private var actions: some View {
        Group {
            Button { showQueue = true } label: { Label("Episode Queue", systemImage: "list.number") }
            Button { showSettings = true } label: { Label("Podcast Settings", systemImage: "slider.horizontal.3") }
        }
        .labelStyle(.iconOnly)
    }
}

struct KyroPodcastArtwork: View {
    let url: URL?
    let size: CGFloat
    var decodeSize: CGFloat? = nil
    @Environment(\.displayScale) private var scale
    var body: some View {
        LazyImage(request: url.flatMap {
            PosterImageCache.displayRequest(url: $0, pointSize: CGSize(width: decodeSize ?? size, height: decodeSize ?? size), scale: scale)
        }) { state in
            if let image = state.image {
                image.resizable().scaledToFill()
            } else {
                ZStack {
                    Color.siloSurfaceElevated
                    Image(systemName: "waveform").font(.system(size: size * 0.30, weight: .medium))
                        .foregroundStyle(KyroTheme.accentInk)
                }
            }
        }
        .onDisappear(.cancel)
        .frame(width: size, height: size)
        .clipShape(.rect(cornerRadius: size * 0.11))
        .accessibilityHidden(true)
    }
}

@MainActor @Observable
final class KyroPodcastDiscoveryState {
    struct Search: Equatable {
        let term: String
        let id = UUID()
    }
    struct Lookup: Equatable {
        let address: URL
        let fromDirectory: Bool
        let id = UUID()
    }
    var query = ""
    var address = ""
    var submitted: Search?
    var lookup: Lookup?
    var results: [PodcastDiscovery.Result] = []
    var preview: PodcastShow?
    var problem: String?
    var searching = false
    var opening = false

    func cancel() {
        submitted = nil; lookup = nil; searching = false; opening = false
    }

    /// Search results replace Discover's shelves while a search is active.
    var isShowingResults: Bool { submitted != nil || searching }

    func clearSearch() {
        query = ""; submitted = nil; results = []; searching = false; problem = nil
    }

    /// Opens a directory or chart show through the existing preview flow.
    func open(_ feed: URL) {
        problem = nil
        lookup = .init(address: feed, fromDirectory: true)
    }

    func submit() {
        let term = String(query.trimmingCharacters(in: .whitespacesAndNewlines).prefix(160))
        if term.count >= 2 { submitted = Search(term: term) }
    }

    func openFeed() {
        guard let url = PodcastAddress.url(address) else { problem = PodcastError.invalidURL.localizedDescription; return }
        problem = nil
        lookup = Lookup(address: url, fromDirectory: false)
    }

    func search() async {
        guard let submitted else { return }
        searching = true; problem = nil; results = []
        defer { if self.submitted == submitted { searching = false } }
        do {
            let matches = try await PodcastDirectory.shared.search(submitted.term, country: Locale.current.region?.identifier ?? "US")
            if !Task.isCancelled { results = matches }
        } catch {
            if !Task.isCancelled { problem = "Couldn’t search Apple Podcasts. You can still open a public RSS feed directly." }
        }
    }

    func openLookup() async {
        guard let lookup else { return }
        opening = true
        defer { if self.lookup == lookup { opening = false } }
        do {
            let item = try await KyroPodcastLibrary.shared.preview(lookup.address, fromDirectory: lookup.fromDirectory)
            if !Task.isCancelled { preview = item }
        } catch { if !Task.isCancelled { problem = error.localizedDescription } }
    }
}

private struct KyroPodcastShowLabel: View {
    let title: String
    let publisher: String
    let artwork: URL?
    var body: some View {
        HStack(spacing: 12) {
            KyroPodcastArtwork(url: artwork, size: 52)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline).lineLimit(2)
                if !publisher.isEmpty { Text(publisher).font(.subheadline).foregroundStyle(.secondary).lineLimit(1) }
            }
        }
    }
}

/// Build 135: a show page with prominent cover art, show information,
/// subscription controls and a clean episode list.
struct KyroPodcastShowView: View {
    let initialShow: PodcastShow
    var needsPageShelf = false
    @Environment(\.nowPlayingShelfCoversPushedPages) private var shelfCoversPushedPages
    @State private var error: String?
    @State private var refreshing = false
    @State private var expanded = false
    private let library = KyroPodcastLibrary.shared
    private var show: PodcastShow { library.show(for: initialShow.id) ?? initialShow }

    var body: some View {
        let subscribed = library.isSubscribed(show)
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                VStack(spacing: 14) {
                    KyroModernArtwork(url: show.artwork)
                        .frame(width: 220)
                    Text(show.title.isEmpty ? "Podcast" : show.title)
                        .font(.title2.weight(.heavy)).multilineTextAlignment(.center)
                        .accessibilityAddTraits(.isHeader)
                    if !show.publisher.isEmpty {
                        Text(show.publisher).font(.subheadline).foregroundStyle(KyroModernStyle.secondary)
                    }
                    HStack(spacing: 12) {
                        Button(action: toggleSubscription) {
                            Label(subscribed ? "Subscribed" : "Subscribe", systemImage: subscribed ? "checkmark" : "plus")
                                .font(.headline)
                                .foregroundStyle(subscribed ? .white : KyroModernStyle.night)
                                .padding(.horizontal, 22).frame(height: 46)
                                .background(Capsule().fill(subscribed ? AnyShapeStyle(KyroModernStyle.crimson) : AnyShapeStyle(Color.white)))
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint(subscribed ? "Unsubscribes" : "Adds this show to your library")
                        if subscribed {
                            Button { library.toggleFavorite(show) } label: {
                                Image(systemName: library.favoriteShows.contains(show.id) ? "heart.fill" : "heart")
                                    .frame(width: 46, height: 46)
                                    .background(Circle().fill(KyroPodcastPalette.chip))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(library.favoriteShows.contains(show.id) ? "Unfavorite Show" : "Favorite Show")
                            Button { Task { await refresh() } } label: {
                                Image(systemName: "arrow.clockwise").frame(width: 46, height: 46)
                                    .background(Circle().fill(KyroPodcastPalette.chip))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Refresh Feed")
                        }
                    }
                }
                .frame(maxWidth: .infinity)
                if !show.summary.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(show.summary).font(.subheadline).foregroundStyle(KyroModernStyle.secondary)
                            .lineLimit(expanded ? nil : 4)
                        if show.summary.count > 220 {
                            Button(expanded ? "Show Less" : "Show More") { expanded.toggle() }
                                .font(.subheadline.weight(.semibold)).foregroundStyle(KyroModernStyle.crimson)
                        }
                    }
                }
                if refreshing { ProgressView("Refreshing feed…").tint(.white) }
                if let error { Text(error).font(.footnote).foregroundStyle(KyroModernStyle.secondary) }
                let entries = library.entries(for: show)
                Text("Episodes").font(.title3.weight(.bold)).accessibilityAddTraits(.isHeader)
                if entries.isEmpty {
                    Text("No playable episodes are cached.").foregroundStyle(KyroModernStyle.secondary)
                }
                ForEach(entries) { KyroPodcastEpisodeCard(entry: $0) }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 24)
        }
        .foregroundStyle(.white)
        .tint(KyroModernStyle.crimson)
        .siloPageBackground()
        .environment(\.colorScheme, .dark)
        .navigationTitle(show.title).navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if needsPageShelf && !shelfCoversPushedPages { KyroRadioPageNowPlayingBar() }
        }
        .task { await library.restore(show) }
        .refreshable { await refresh() }
    }

    private func toggleSubscription() {
        if library.isSubscribed(show) { library.unsubscribe(show) }
        else { do { try library.subscribe(show) } catch { self.error = error.localizedDescription } }
    }

    private func refresh() async {
        guard !refreshing, library.isSubscribed(show) else { return }
        refreshing = true
        defer { refreshing = false }
        do { try await library.refresh(show); error = nil }
        catch { self.error = error.localizedDescription }
    }
}

struct KyroPodcastDownloadRows: View {
    private let library = KyroPodcastLibrary.shared
    private let downloads = KyroPodcastDownloads.shared
    var body: some View {
        Section("Podcast Storage") {
            LabeledContent("On this device", value: ByteCountFormatter.string(fromByteCount: downloads.storage, countStyle: .file))
            let entries = library.retainedEntries.filter { downloads.hasDownload($0) || downloads.status[$0.id] != nil }
            if entries.isEmpty { Text("Download an episode from its menu to listen offline.").foregroundStyle(.secondary) }
            ForEach(entries.sorted { $0.episode.title.localizedStandardCompare($1.episode.title) == .orderedAscending }) {
                KyroPodcastEpisodeRow(entry: $0)
            }
        }
    }
}

struct KyroPodcastEpisodeRow: View {
    let entry: PodcastEntry
    @State private var details = false
    private let player = KyroPodcastPlayer.shared
    private let library = KyroPodcastLibrary.shared
    private let downloads = KyroPodcastDownloads.shared

    var body: some View {
        HStack(spacing: 12) {
            Button { player.play(entry) } label: {
                HStack(spacing: 12) {
                    KyroPodcastArtwork(url: entry.artwork, size: 46)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(entry.episode.title).font(.subheadline.weight(.semibold)).lineLimit(2)
                        HStack(spacing: 4) {
                            if entry.episode.explicit { Image(systemName: "e.square.fill").accessibilityLabel("Explicit") }
                            if library.progress[entry.id]?.played == true { Image(systemName: "checkmark.circle").accessibilityLabel("Played") }
                            Text(entry.showTitle).lineLimit(1)
                            if let date = entry.episode.published { Text(date, format: .dateTime.month(.abbreviated).day()) }
                        }.font(.caption).foregroundStyle(.secondary)
                        if let p = library.progress[entry.id], p.resumable > 0 {
                            ProgressView(value: p.fraction).accessibilityLabel("Listening progress")
                        }
                        if let status = downloads.status[entry.id] {
                            switch status {
                            case .downloading(let fraction):
                                if let fraction { ProgressView(value: fraction).accessibilityLabel("Download progress") }
                                else { ProgressView().controlSize(.small).accessibilityLabel("Downloading") }
                            case .failed(let error):
                                Text(error).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                            }
                        }
                    }
                    Spacer(minLength: 0)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain)
            Menu {
                Button("Episode Details", systemImage: "info.circle") { details = true }
                Button("Add to Queue", systemImage: "text.badge.plus") { library.enqueue(entry, currentID: player.current?.id) }
                Button(library.saved.contains(entry.id) ? "Unsave Episode" : "Save Episode", systemImage: "bookmark") {
                    library.toggleSaved(entry)
                }
                Button(library.progress[entry.id]?.played == true ? "Mark Unplayed" : "Mark Played", systemImage: "checkmark.circle") {
                    library.mark(entry, played: library.progress[entry.id]?.played != true)
                }
                if case .downloading = downloads.status[entry.id] {
                    Button("Cancel Download", systemImage: "xmark.circle") { downloads.cancel(entry) }
                } else if downloads.hasDownload(entry) {
                    Button("Remove Download", systemImage: "trash", role: .destructive) { downloads.remove(entry) }
                } else {
                    Button(downloads.status[entry.id] == nil ? "Download Episode" : "Retry Download", systemImage: "arrow.down.circle") {
                        downloads.start(entry, wifiOnly: library.preferences.wifiOnly)
                    }
                }
            } label: {
                Image(systemName: "ellipsis.circle").frame(width: 44, height: 44)
                    .accessibilityLabel("Episode Actions")
            }
        }
        .sheet(isPresented: $details) {
            NavigationStack {
                List {
                    KyroPodcastShowLabel(title: entry.episode.title, publisher: entry.showTitle, artwork: entry.artwork)
                    if let season = entry.episode.season { LabeledContent("Season", value: String(season)) }
                    if let number = entry.episode.number { LabeledContent("Episode", value: String(number)) }
                    if !entry.episode.summary.isEmpty { Text(entry.episode.summary) }
                }.navigationTitle("Episode Details").navigationBarTitleDisplayMode(.inline)
            }
        }
    }
}

struct KyroPodcastQueueView: View {
    private let library = KyroPodcastLibrary.shared
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        List {
            if library.queue.entries.isEmpty { Text("Add episodes to the queue from their menus.").foregroundStyle(.secondary) }
            ForEach(library.queue.entries) { entry in
                KyroPodcastShowLabel(title: entry.episode.title, publisher: entry.showTitle, artwork: entry.artwork)
            }
            .onDelete { offsets in
                let ids = offsets.compactMap { library.queue.entries.indices.contains($0) ? library.queue.entries[$0].id : nil }
                for id in ids { library.removeFromQueue(id) }
            }
            .onMove { offsets, destination in
                if let first = offsets.first { library.moveQueue(from: first, to: destination) }
            }
        }
        .navigationTitle("Episode Queue").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
            ToolbarItem(placement: .primaryAction) { EditButton() }
        }
    }
}

struct KyroPodcastSettings: View {
    private let library = KyroPodcastLibrary.shared
    var body: some View {
        Form {
            KyroAudioThemeSection(selection: library.preferences.theme, kind: .cassette,
                                  identifierPrefix: "kyroPodcastTheme", select: library.selectTheme)
            Section("Playback") {
                Picker("Playback Speed", selection: preference(\.speed)) {
                    ForEach(PodcastPreferences.speeds, id: \.self) { Text($0.formatted() + "×").tag($0) }
                }
                Picker("Skip Back", selection: preference(\.back)) {
                    ForEach(PodcastPreferences.skips, id: \.self) { Text("\($0) seconds").tag($0) }
                }
                Picker("Skip Forward", selection: preference(\.forward)) {
                    ForEach(PodcastPreferences.skips, id: \.self) { Text("\($0) seconds").tag($0) }
                }
                Picker("Default Sleep Timer", selection: preference(\.sleepMinutes)) {
                    ForEach(PodcastPreferences.sleepOptions, id: \.self) { Text(Self.sleepLabel($0)).tag($0) }
                }
            }
            Section {
                Picker("Refresh Feeds", selection: preference(\.refreshHours)) {
                    ForEach(PodcastPreferences.refreshIntervals, id: \.self) {
                        Text($0 == 0 ? "Manually" : "Every \($0) hours").tag($0)
                    }
                }
            } footer: { Text("Automatic refresh runs in the foreground when you open Podcasts, in small batches.") }
            Section("Downloads") {
                Toggle("Wi-Fi Only", isOn: preference(\.wifiOnly))
                Toggle("Remove Downloads After Playing", isOn: preference(\.removeCompleted))
                NavigationLink("Manage Podcast Storage") {
                    List { KyroPodcastDownloadRows() }.navigationTitle("Podcast Storage")
                }
            }
        }
        .navigationTitle("Podcast Settings").navigationBarTitleDisplayMode(.inline)
    }

    static func sleepLabel(_ minutes: Int) -> String {
        switch minutes {
        case -1: "End of Episode"
        case 0: "Off"
        default: "\(minutes) minutes"
        }
    }

    private func preference<T>(_ key: WritableKeyPath<PodcastPreferences, T>) -> Binding<T> {
        Binding(get: { library.preferences[keyPath: key] }, set: {
            var preferences = library.preferences
            preferences[keyPath: key] = $0
            KyroPodcastPlayer.shared.updatePreferences(preferences)
        })
    }
}
#endif
