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
    enum Section: String, CaseIterable {
        case discover = "Discover", library = "Library", latest = "Latest Episodes",
             downloads = "Downloads", history = "Listening History"
        var icon: String {
            switch self {
            case .discover: "magnifyingglass"
            case .library: "books.vertical"
            case .latest: "clock.badge"
            case .downloads: "arrow.down.circle"
            case .history: "clock.arrow.circlepath"
            }
        }
    }
    let isSecondaryDestination: Bool
    @Binding var selection: KyroAudioDestination
    @Environment(\.kyroShellHeader) private var shellHeader
    @Environment(\.nowPlayingShelfCoversPushedPages) private var shelfCoversPushedPages
    @Environment(\.scenePhase) private var scenePhase
    @State private var section: Section = .discover
    @State private var fallbackScroll = PageChromeScrollState()
    @State private var showSettings = false
    @State private var showQueue = false
    @State private var isDisplayed = false
    @State private var discovery = KyroPodcastDiscoveryState()
    private var runway: CGFloat? { isSecondaryDestination ? nil : shellHeader?.runway }
    private var hosted: Bool { runway != nil }
    private let library = KyroPodcastLibrary.shared

    var body: some View {
        List {
            if hosted {
                HStack {
                    Text(KyroAudioDestination.title).font(.largeTitle.bold()).accessibilityAddTraits(.isHeader)
                    Spacer()
                    actions
                }
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }
            KyroAudioSelector(selection: $selection)
            Picker("Podcast section", selection: $section) {
                ForEach(Section.allCases, id: \.self) { Label($0.rawValue, systemImage: $0.icon).tag($0) }
            }
            .pickerStyle(.menu)
            .listRowSeparator(.hidden)
            .accessibilityIdentifier("kyroPodcastSection")
            switch section {
            case .discover: KyroPodcastDiscover(model: discovery)
            case .library: KyroPodcastSubscriptionRows(needsPageShelf: isSecondaryDestination)
            case .latest: KyroPodcastLatestRows()
            case .downloads: KyroPodcastDownloadRows()
            case .history: KyroPodcastHistoryRows()
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Color.siloPageCanvas.ignoresSafeArea())
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
        .navigationDestination(item: $discovery.preview) { show in
            KyroPodcastShowView(initialShow: show, needsPageShelf: isSecondaryDestination)
        }
        .task(id: discovery.submitted) {
            if section == .discover { await discovery.search() }
        }
        .task(id: discovery.lookup) {
            if section == .discover { await discovery.openLookup() }
        }
        .onChange(of: section) { _, section in if section != .discover { discovery.cancel() } }
        .onAppear { isDisplayed = true }
        .onDisappear { isDisplayed = false }
        .task(id: isDisplayed && scenePhase == .active) {
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
private final class KyroPodcastDiscoveryState {
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

private struct KyroPodcastDiscover: View {
    @Bindable var model: KyroPodcastDiscoveryState
    @FocusState private var focused: Field?
    private enum Field { case search, rss }

    var body: some View {
        Section("Find a podcast") {
            HStack {
                TextField("Podcast title or creator", text: $model.query)
                    .submitLabel(.search).onSubmit(submit).focused($focused, equals: .search)
                Button("Search", action: submit).buttonStyle(.borderless)
                    .disabled(model.query.trimmingCharacters(in: .whitespacesAndNewlines).count < 2)
            }
            HStack {
                TextField("Public RSS feed address", text: $model.address)
                    .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled().focused($focused, equals: .rss)
                    .submitLabel(.go).onSubmit(openFeed)
                Button("Open", action: openFeed).buttonStyle(.borderless).disabled(model.address.isEmpty)
            }
            Link("Search results from Apple Podcasts", destination: URL(string: "https://podcasts.apple.com/")!)
                .font(.caption)
            if let problem = model.problem { Text(problem).font(.footnote).foregroundStyle(.secondary) }
        }
        if model.searching || model.opening { ProgressView(model.searching ? "Searching Apple Podcasts…" : "Opening feed…") }
        if model.submitted != nil, !model.searching, model.results.isEmpty, model.problem == nil {
            Text("No public feeds found. Try another title or creator, or enter a feed address.")
                .foregroundStyle(.secondary)
        }
        ForEach(model.results) { result in
            HStack {
                Button {
                    focused = nil
                    model.problem = nil
                    model.lookup = .init(address: result.feed, fromDirectory: true)
                } label: {
                    KyroPodcastShowLabel(title: result.title, publisher: result.publisher, artwork: result.artwork)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if let link = result.appleLink {
                    Link(destination: link) {
                        Image(systemName: "arrow.up.right.square").frame(width: 44, height: 44)
                    }.accessibilityLabel("View \(result.title) in Apple Podcasts")
                }
            }
        }
    }

    private func submit() {
        focused = nil
        model.submit()
    }

    private func openFeed() {
        focused = nil
        model.openFeed()
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

private struct KyroPodcastSubscriptionRows: View {
    let needsPageShelf: Bool
    enum Sort: String, CaseIterable { case recent = "Recently Added", title = "Title", creator = "Creator" }
    @State private var query = ""
    @State private var sort = Sort.recent
    @State private var importing = false
    @State private var exporting = false
    @State private var exportDocument: PodcastOPMLDocument?
    @State private var message: String?
    private let library = KyroPodcastLibrary.shared

    private var shows: [PodcastShow] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let matches = library.shows.filter { term.isEmpty || $0.title.localizedCaseInsensitiveContains(term)
            || $0.publisher.localizedCaseInsensitiveContains(term) }
        switch sort {
        case .recent: return Array(matches.reversed())
        case .title: return matches.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        case .creator: return matches.sorted { $0.publisher.localizedStandardCompare($1.publisher) == .orderedAscending }
        }
    }

    var body: some View {
        Section("Subscriptions") {
            TextField("Search subscriptions", text: $query)
            HStack {
                Picker("Sort", selection: $sort) {
                    ForEach(Sort.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.menu)
                Spacer()
                Menu("Manage Library") {
                    Button("Refresh All Feeds", systemImage: "arrow.clockwise") { Task { await refresh() } }
                    Button("Import OPML", systemImage: "square.and.arrow.down") { importing = true }
                    Button("Export OPML", systemImage: "square.and.arrow.up") {
                        exportDocument = PodcastOPMLDocument(data: PodcastOPML.write(library.shows))
                        exporting = true
                    }
                }
            }
            if library.isRefreshing { ProgressView("Refreshing feeds…") }
            if let message { Text(message).font(.footnote).foregroundStyle(.secondary) }
            if shows.isEmpty { Text("No matching subscriptions. Find a show in Discover or import OPML.").foregroundStyle(.secondary) }
            ForEach(shows) { show in
                NavigationLink { KyroPodcastShowView(initialShow: show, needsPageShelf: needsPageShelf) } label: {
                    KyroPodcastShowLabel(title: show.title, publisher: show.publisher, artwork: show.artwork)
                }
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.xml, .kyroOPML, .data], onCompletion: importFile)
        .fileExporter(isPresented: $exporting, document: exportDocument,
                      contentType: .kyroOPML, defaultFilename: "Kyro Podcasts") { result in
            if case .failure(let error) = result { message = error.localizedDescription }
        }
    }

    private func refresh() async {
        let failures = await library.refreshAll(automatic: false)
        message = failures > 0 ? "Couldn’t refresh \(failures) feeds. Cached episodes are still available." : nil
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

private extension UTType {
    static var kyroOPML: UTType { UTType(filenameExtension: "opml", conformingTo: .xml) ?? .xml }
}

private struct PodcastOPMLDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.kyroOPML]
    let data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { .init(regularFileWithContents: data) }
}

struct KyroPodcastShowView: View {
    let initialShow: PodcastShow
    var needsPageShelf = false
    @Environment(\.nowPlayingShelfCoversPushedPages) private var shelfCoversPushedPages
    @State private var error: String?
    @State private var refreshing = false
    private let library = KyroPodcastLibrary.shared
    private var show: PodcastShow { library.show(for: initialShow.id) ?? initialShow }

    var body: some View {
        List {
            KyroPodcastShowLabel(title: show.title, publisher: show.publisher, artwork: show.artwork)
            if !show.summary.isEmpty { Text(show.summary).font(.subheadline) }
            HStack {
                Button(library.isSubscribed(show) ? "Unsubscribe" : "Subscribe", action: toggleSubscription)
                    .buttonStyle(.borderedProminent)
                if library.isSubscribed(show) {
                    Button {
                        library.toggleFavorite(show)
                    } label: {
                        Label(library.favoriteShows.contains(show.id) ? "Unfavorite Show" : "Favorite Show",
                              systemImage: library.favoriteShows.contains(show.id) ? "heart.fill" : "heart")
                    }.buttonStyle(.borderless).labelStyle(.iconOnly)
                    Spacer()
                    Button("Refresh Feed", systemImage: "arrow.clockwise") { Task { await refresh() } }
                        .buttonStyle(.borderless).labelStyle(.iconOnly)
                }
            }
            if refreshing { ProgressView("Refreshing feed…") }
            if let error { Text(error).font(.footnote).foregroundStyle(.secondary) }
            Section("Episodes") {
                let entries = library.entries(for: show)
                if entries.isEmpty { Text("No playable episodes are cached.").foregroundStyle(.secondary) }
                ForEach(entries) { KyroPodcastEpisodeRow(entry: $0) }
            }
        }
        .navigationTitle("Podcast").navigationBarTitleDisplayMode(.inline)
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

private struct KyroPodcastLatestRows: View {
    private let library = KyroPodcastLibrary.shared
    var body: some View {
        let entries = library.latest()
        let saved = (entries + library.retainedEntries + library.shows.flatMap { library.entries(for: $0) })
            .filter { library.saved.contains($0.id) }
        if !saved.isEmpty {
            Section("Saved Episodes") {
                ForEach(saved.reduce(into: [PodcastEntry]()) { items, entry in
                    if !items.contains(where: { $0.id == entry.id }) { items.append(entry) }
                }) { KyroPodcastEpisodeRow(entry: $0) }
            }
        }
        Section("Latest Episodes") {
            if entries.isEmpty { Text("Subscribe to a podcast to see its latest episodes.").foregroundStyle(.secondary) }
            ForEach(entries) { KyroPodcastEpisodeRow(entry: $0) }
        }
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

private struct KyroPodcastHistoryRows: View {
    private let library = KyroPodcastLibrary.shared
    @State private var confirm = false
    var body: some View {
        Section("Listening History") {
            if library.history.isEmpty { Text("No episodes played yet.").foregroundStyle(.secondary) }
            else {
                Button("Clear Listening History", role: .destructive) { confirm = true }
                    .confirmationDialog("Clear podcast listening history?", isPresented: $confirm) {
                        Button("Clear History", role: .destructive) { library.clearHistory() }
                    }
                ForEach(library.history) { KyroPodcastEpisodeRow(entry: $0) }
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
            Section("Cassette Player") {
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
