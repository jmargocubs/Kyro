#if os(iOS)
import AVKit
import Nuke
import NukeUI
import Observation
import SwiftUI

// Build 128/129: Radio, opened from More, the fourth tab, Home Radio shelves,
// Settings, or iPad/legacy navigation. Discover, Library and History share one
// page; the mini player and Now Playing follow the listener everywhere.

@MainActor
extension KyroAudioDestination {
    var secondaryRoute: SecondaryDestinationID { self == .radio ? .radio : .podcasts }

    func open(router: AppRouter) {
        let navigation = KyroGlobalNavigationStore.shared
        if openTarget(unifiedShell: KyroUnifiedNavigation.isActive, tabDestinations: navigation.tabDestinations) == .tab {
            router.popToRoot()
            navigation.selectIfTab(choice.destination)
            return
        }
        let route = Route.secondaryDestination(secondaryRoute)
        if router.visiblePushedRoutes.last != route { router.navigate(to: route) }
    }
}

@MainActor @Observable
final class KyroRadioBrowsing {
    var section: KyroRadioView.Section = .discover
    let discover = KyroRadioDiscoverModel()
    var discoverText = ""
    var libraryText = ""
    var searchField: KyroRadioQuery.Field = .name
    /// Build 139: which sources Discover's search covers.
    var sourceScope: KyroRadioSearchScope = .all
}

/// The Radio page.
struct KyroRadioView: View {
    enum Section: String, CaseIterable, Identifiable {
        case discover, library, history
        var id: String { rawValue }
        var title: String { rawValue.capitalized }
    }

    var isSecondaryDestination = false
    @Bindable var browsing: KyroRadioBrowsing
    @Environment(\.kyroShellHeader) private var shellHeader
    @Environment(\.nowPlayingShelfCoversPushedPages) private var shelfCoversPushedPages
    @State private var fallbackScrollState = PageChromeScrollState()
    @State private var isShowingSettings = false
    @State private var directoryLink: KyroRadioShelfLink?
    @FocusState private var searchFocused: Bool
    private let library = KyroRadioLibrary.shared
    private let appearance = KyroAppAppearanceStore.shared
    private var section: Section { browsing.section }
    private var discover: KyroRadioDiscoverModel { browsing.discover }
    private var searchField: KyroRadioQuery.Field { browsing.searchField }

    private var hostedRunway: CGFloat? {
        isSecondaryDestination ? nil : shellHeader?.runway
    }

    private var isHostedTab: Bool { hostedRunway != nil }

    private var scrollState: PageChromeScrollState {
        isHostedTab ? shellHeader?.scrollState(for: .radio) ?? fallbackScrollState : fallbackScrollState
    }

    private var activeSearchText: Binding<String> {
        section == .discover ? $browsing.discoverText : $browsing.libraryText
    }

    private var activeSearchPrompt: String {
        switch section {
        case .discover: searchField.prompt
        case .library: "Search saved stations"
        case .history: "Search listening history"
        }
    }

    var body: some View {
        List {
            if isHostedTab {
                KyroAudioHeader(title: "Radio") { settingsButton.font(.title3) }
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)

            }

            KyroAudioSectionPicker(title: "Radio section", selection: $browsing.section, options: Section.allCases, name: \.title)
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .accessibilityIdentifier("kyroRadioSection")
            inlineSearchRow
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)

            switch section {
            case .discover:
                KyroRadioDiscoverContent(model: discover, searchText: browsing.discoverText, scope: browsing.sourceScope, open: openShelf)
            case .library:
                KyroRadioLibraryContent(searchText: browsing.libraryText)
            case .history:
                KyroRadioHistoryContent(searchText: browsing.libraryText)
            }
        }
        .listStyle(.plain)
        .scrollDismissesKeyboard(.interactively)
        .scrollContentBackground(.hidden)
        .background {
            if appearance.selection == .signature {
                KyroSignatureBackdrop(finish: section == .discover ? .discovery : .dense)
            } else {
                Color.siloPageCanvas.ignoresSafeArea()
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if let hostedRunway {
                Color.clear.frame(height: hostedRunway)
            }
        }
        .reportsPageChromeScroll(to: scrollState)
        // Build 130: pushed, this page covers the tab bar and its Now Playing
        // accessory, so it carries the one bar itself. The List reserves
        // scroll space; the bar steps aside while the inline field is editing.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if KyroAudioDestination.pageHostsNowPlayingBar(isSecondaryDestination: isSecondaryDestination,
                                                                shelfCoversPushedPages: shelfCoversPushedPages) {
                KyroRadioPageNowPlayingBar()
            }
        }
        .navigationTitle(isHostedTab ? "" : "Radio")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(isHostedTab ? .hidden : .visible, for: .navigationBar)
        .toolbar {
            if !isHostedTab {
                ToolbarItem(placement: .topBarTrailing) {
                    settingsButton
                }
            }
        }
        .sheet(isPresented: $isShowingSettings) { KyroRadioSettingsView() }
        .navigationDestination(item: $directoryLink) { link in
            switch link {
            case let .directory(title, query): KyroRadioDirectoryPage(title: title, query: query)
            case let .collection(collection): KyroIPTVMusicCollectionPage(collection: collection)
            case .favorites, .history: EmptyView()
            }
        }
        .tint(KyroTheme.accentInk)
        .onAppear { discover.loadIfNeeded(library.preferences.discoveryQuery) }
        .onChange(of: section) { _, _ in searchFocused = false }
        .onChange(of: library.preferences.discoveryQuery) { old, new in
            if discover.query == old { discover.update(new) }
        }
        .onChange(of: browsing.discoverText) { _, text in
            var query = discover.query
            query.text = text
            query.field = searchField
            discover.update(query, debounce: true)
        }
        .onChange(of: searchField) { _, field in
            var query = discover.query
            query.field = field
            guard !query.trimmedText.isEmpty else { return }
            discover.update(query)
        }
        .task { await refreshSavedDetails() }
        // Build 139: IPTV music collections follow the Live TV catalog. Bounded indexed queries,
        // and only when the catalog, providers, hidden categories or a correction changed.
        .task(id: "\(LiveTVService.shared.channelCatalogRevision)|\(KyroIPTVMusicLibrary.shared.revision)") {
            await KyroIPTVMusicLibrary.shared.refresh()
        }
    }

    private func openShelf(_ link: KyroRadioShelfLink) {
        switch link {
        case .directory, .collection: directoryLink = link
        case .favorites: browsing.libraryText = ""; browsing.section = .library
        case .history: browsing.libraryText = ""; browsing.section = .history
        }
    }

    private var settingsButton: some View {
        Button { isShowingSettings = true } label: {
            Image(systemName: "slider.horizontal.3")
                .foregroundStyle(KyroTheme.accentInk)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Radio Settings")
        .accessibilityIdentifier("kyroRadioSettings")
    }

    private var inlineSearchRow: some View {
        HStack(spacing: 10) {
            KyroAudioSearchField(hasText: !activeSearchText.wrappedValue.isEmpty, clear: { activeSearchText.wrappedValue = "" }) {
                TextField(activeSearchPrompt, text: activeSearchText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($searchFocused)
                    .submitLabel(.search)
                    .onSubmit {
                        searchFocused = false
                    }
            }
            if section == .discover {
                Menu {
                    Picker("Search by", selection: $browsing.searchField) {
                        ForEach(KyroRadioQuery.Field.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    let collections = KyroIPTVMusicLibrary.shared.availableCollections
                    if !collections.isEmpty {
                        Picker("Sources", selection: $browsing.sourceScope) {
                            Text(KyroRadioSearchScope.all.title).tag(KyroRadioSearchScope.all)
                            Text(KyroRadioSearchScope.internetRadio.title).tag(KyroRadioSearchScope.internetRadio)
                            ForEach(collections) { Text($0.title).tag(KyroRadioSearchScope.collection($0)) }
                        }
                    }
                } label: {
                    Image(systemName: "line.3.horizontal.decrease")
                        .frame(width: 48, height: 48)
                        .background { KyroControlSurface() }
                }
                .accessibilityLabel("Search by")
                .accessibilityValue(searchField.title)
            }
        }
    }

    /// Favorites restored from a backup have only an ID and a name. One
    /// bounded request per 100 stations fills in their streams and logos.
    private func refreshSavedDetails() async {
        let missing = library.stationsNeedingDetails
        guard !missing.isEmpty else { return }
        for start in stride(from: 0, to: min(missing.count, 300), by: 100) {
            let batch = Array(missing[start..<min(start + 100, missing.count)])
            guard let fresh = try? await KyroRadioBrowserClient.shared.stations(uuids: batch) else { return }
            library.refreshDetails(fresh)
        }
    }
}

/// The Now Playing bar a pushed Radio page shows above its bottom search
/// bar. It is the app's `NowPlayingShelf`, so the same single bar shows (a TV
/// remote session, then an audiobook, then radio) and taps open the same
/// Now Playing screen; it is empty, and takes no space, with nothing playing.
/// It steps aside while the keyboard is up so it never crowds the search field.
struct KyroRadioPageNowPlayingBar: View {
    @State private var isKeyboardVisible = false

    var body: some View {
        // A VStack stays in the hierarchy when empty, so the keyboard
        // observers below keep running while the bar is hidden.
        VStack(spacing: 0) {
            if !isKeyboardVisible {
                NowPlayingShelf(style: .card)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
            isKeyboardVisible = true
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            isKeyboardVisible = false
        }
    }
}

private extension KyroRadioQuery.Field {
    var prompt: String {
        switch self {
        case .name: "Station name or call sign"
        case .genre: "Genre, like jazz or news"
        case .location: "City or state"
        }
    }
}

// MARK: - Discover

private struct KyroRadioDiscoverContent: View {
    let model: KyroRadioDiscoverModel
    let searchText: String
    var scope: KyroRadioSearchScope = .all
    let open: (KyroRadioShelfLink) -> Void
    @State private var isShowingFilters = false
    private let library = KyroRadioLibrary.shared

    private var isSearching: Bool { !searchText.trimmingCharacters(in: .whitespaces).isEmpty }
    private var showsShelves: Bool {
        let preferred = library.preferences.discoveryQuery
        let query = model.query
        return !isSearching && query.tag == nil && query.countryCode == preferred.countryCode &&
            query.state == preferred.state && query.language == preferred.language
    }

    var body: some View {
        Group {
            regionChips
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets())
            if !isSearching {
                genreChips
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets())
            }
            if showsShelves {
                KyroRadioSourcesShelf(openInternetRadio: { open(.directory(title: "Internet Radio", query: .worldwide())) },
                                      openCollection: { open(.collection($0)) })
                KyroRadioDiscoverShelves(local: model, preferences: library.preferences, open: open)
            } else {
                if isSearching { KyroIPTVSearchResults(text: searchText, scope: scope) }
                if !isSearching || scope.includesInternetRadio { results }
            }
        }
        .sheet(isPresented: $isShowingFilters) {
            KyroRadioFiltersView(query: model.query) { model.update($0) }
        }
        .onAppear { model.loadGenresIfNeeded() }
    }

    private var regionChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip("United States", isOn: model.query.countryCode == "US" && model.query.state == nil) {
                    set { $0.countryCode = "US"; $0.state = nil }
                }
                chip("Illinois", isOn: model.query.countryCode == "US" && model.query.state == "Illinois") {
                    set { $0.countryCode = "US"; $0.state = "Illinois" }
                }
                chip("Worldwide", isOn: model.query.countryCode == nil && model.query.state == nil) {
                    set { $0.countryCode = nil; $0.state = nil }
                }
                let preferred = library.preferences
                if preferred.countryCode != nil, preferred.countryCode != "US" || (preferred.state != nil && preferred.state != "Illinois") {
                    chip(preferred.regionTitle, isOn: model.query.countryCode == preferred.countryCode && model.query.state == preferred.state) {
                        set { $0.countryCode = preferred.countryCode; $0.state = preferred.state }
                    }
                }
                chip(model.query.language.map { "Language: \($0.capitalized)" } ?? "Filters", systemImage: "line.3.horizontal.decrease",
                     isOn: model.query.language != nil) {
                    isShowingFilters = true
                }
            }
            .padding(.horizontal, SiloTheme.padding)
            .padding(.vertical, 4)
        }
    }

    @ViewBuilder
    private var genreChips: some View {
        if !model.genres.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Browse by Genre").font(.headline).padding(.horizontal, SiloTheme.padding)
                    .accessibilityAddTraits(.isHeader)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        if model.query.tag != nil {
                            chip("All Genres", isOn: false) { set { $0.tag = nil } }
                        }
                        ForEach(model.genres.prefix(30)) { genre in
                            chip(genre.title, isOn: model.query.tag == genre.value) {
                                set { $0.tag = $0.tag == genre.value ? nil : genre.value }
                            }
                        }
                    }
                    .padding(.horizontal, SiloTheme.padding)
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var results: some View {
        Group {
            Text(resultsTitle)
                .font(.title3.bold())
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .accessibilityAddTraits(.isHeader)
            KyroRadioDirectoryRows(model: model)
        }
    }

    private var resultsTitle: String {
        let place: String
        switch (model.query.countryCode, model.query.state) {
        case (nil, _): place = "Worldwide"
        case ("US", "Illinois"): place = "Illinois"
        case ("US", nil): place = "United States"
        case (let code?, let state): place = [state, code].compactMap { $0 }.joined(separator: ", ")
        }
        if isSearching { return "Results · \(place)" }
        if let tag = model.query.tag { return "\(tag.capitalized) · \(place)" }
        return "Popular · \(place)"
    }

    private func set(_ change: (inout KyroRadioQuery) -> Void) {
        var query = model.query
        change(&query)
        model.update(query)
    }

    private func chip(_ title: String, systemImage: String? = nil, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let systemImage { Image(systemName: systemImage) }
                Text(title).lineLimit(1)
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(isOn ? KyroTheme.textPrimary : KyroTheme.textSecondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background { KyroControlSurface(selected: isOn, cornerRadius: 20) }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

/// Country, state and language for Discover.
private struct KyroRadioFiltersView: View {
    let query: KyroRadioQuery
    let apply: (KyroRadioQuery) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var draft: KyroRadioQuery

    init(query: KyroRadioQuery, apply: @escaping (KyroRadioQuery) -> Void) {
        self.query = query
        self.apply = apply
        _draft = State(initialValue: query)
    }

    var body: some View {
        NavigationStack {
            Form {
                KyroRadioRegionPickers(countryCode: $draft.countryCode, countryName: .constant(nil),
                                       state: $draft.state, language: $draft.language)
                Section {
                    Button("Clear Filters", role: .destructive) {
                        draft.countryCode = nil; draft.state = nil; draft.language = nil; draft.tag = nil
                    }
                }
            }
            .navigationTitle("Filters")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") { apply(draft); dismiss() }
                }
            }
        }
        .tint(KyroTheme.accentInk)
    }
}

/// Country, state/region and language pickers, from Radio Browser's own lists.
struct KyroRadioRegionPickers: View {
    @Binding var countryCode: String?
    @Binding var countryName: String?
    @Binding var state: String?
    @Binding var language: String?
    @State private var countries: [KyroRadioFacet] = []
    @State private var states: [KyroRadioFacet] = []
    @State private var languages: [KyroRadioFacet] = []
    @State private var failed = false

    var body: some View {
        Section {
            Picker("Country", selection: Binding(get: { countryCode }, set: { code in
                countryCode = code
                countryName = countries.first { $0.value == code }?.title
                state = nil
            })) {
                Text("Worldwide").tag(nil as String?)
                if let countryCode, !countries.contains(where: { $0.value == countryCode }) {
                    Text(countryName ?? countryCode).tag(Optional(countryCode))
                }
                ForEach(countries) { Text($0.title).tag(Optional($0.value)) }
            }
            if countryCode != nil {
                Picker("State or Region", selection: $state) {
                    Text("Any").tag(nil as String?)
                    if let state, !states.contains(where: { $0.value == state }) { Text(state).tag(Optional(state)) }
                    ForEach(states) { Text($0.title).tag(Optional($0.value)) }
                }
            }
            Picker("Language", selection: $language) {
                Text("Any Language").tag(nil as String?)
                if let language, !languages.contains(where: { $0.value == language }) {
                    Text(language.capitalized).tag(Optional(language))
                }
                ForEach(languages) { Text($0.title).tag(Optional($0.value)) }
            }
        } footer: {
            if failed {
                Text("Couldn’t load every list from Radio Browser. Saved choices still work.")
            } else {
                Text("No location access is used. Lists come from Radio Browser.")
            }
        }
        .task { await loadLists() }
        .task(id: countryCode) { await loadStates() }
    }

    private func loadLists() async {
        let client = KyroRadioBrowserClient.shared
        async let countryList = try? client.facets(.country, limit: 250)
        async let languageList = try? client.facets(.language, limit: 120)
        let (c, l) = await (countryList, languageList)
        countries = (c ?? []).sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        languages = l ?? []
        failed = c == nil || l == nil
    }

    private func loadStates() async {
        states = []
        guard let countryCode else { return }
        // The states list filters by country name, which the countries list provides.
        let name = countries.first { $0.value == countryCode }?.title ?? countryName
        guard let name else { return }
        let list = (try? await KyroRadioBrowserClient.shared.facets(.state, country: name, limit: 120)) ?? []
        states = list.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }
}

// MARK: - Library and History

private struct KyroRadioLibraryContent: View {
    let searchText: String
    @State private var sort: KyroRadioLibrary.Sort = .recentlyAdded
    @AppStorage("kyrox.radio.libraryGrid.v1") private var grid = true
    private let library = KyroRadioLibrary.shared

    var body: some View {
        let saved = library.favorites(matching: searchText, sort: sort)
        // Build 139: favorite IPTV music channels (Live TV's favorites) share this page.
        KyroIPTVFavoriteRows(searchText: searchText)
        if library.favorites.isEmpty {
            ContentUnavailableView("No Favorite Stations", systemImage: "heart",
                description: Text("Tap the heart on a station in Discover to save it here."))
                .listRowBackground(Color.clear)
        } else {
            HStack(spacing: 12) {
                Text("Favorite Stations").font(.title3.bold()).accessibilityAddTraits(.isHeader)
                Spacer()
                Menu {
                    Picker("Sort", selection: $sort) {
                        ForEach(KyroRadioLibrary.Sort.allCases) { Text($0.title).tag($0) }
                    }
                } label: {
                    Image(systemName: "arrow.up.arrow.down").frame(width: 44, height: 44)
                        .background { KyroControlSurface() }
                }
                .accessibilityLabel("Sort")
                .accessibilityValue(sort.title)
                Button { grid.toggle() } label: {
                    Image(systemName: grid ? "list.bullet" : "square.grid.2x2").frame(width: 44, height: 44)
                        .background { KyroControlSurface() }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(grid ? "Show as List" : "Show as Grid")
            }
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            if saved.isEmpty {
                ContentUnavailableView.search(text: searchText).listRowBackground(Color.clear)
            } else if grid {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), alignment: .top)], spacing: 16) {
                    ForEach(saved) { entry in
                        KyroRadioStationTile(station: entry.station, size: 96)
                    }
                }
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            } else {
                ForEach(saved) { entry in
                    KyroRadioStationRow(station: entry.station)
                        .swipeActions {
                            Button("Remove", role: .destructive) { library.setFavorite(entry.station, false) }
                        }
                }
            }
        }
    }
}

/// Build 139: Radio Browser stations and IPTV music channels together, newest first.
private struct KyroRadioHistoryContent: View {
    let searchText: String
    @State private var isConfirmingClear = false
    private let library = KyroRadioLibrary.shared
    private let music = KyroIPTVMusicLibrary.shared

    private enum Item: Identifiable {
        case radio(KyroRadioSavedStation)
        case iptv(KyroIPTVHistoryEntry)
        var id: String { switch self { case .radio(let entry): "r-\(entry.id)"; case .iptv(let entry): "i-\(entry.id)" } }
        var date: Date { switch self { case .radio(let entry): entry.date; case .iptv(let entry): entry.date } }
    }

    var body: some View {
        let radio = library.history.filter { $0.station.matches(searchText) }.map(Item.radio)
        let iptv = music.history.filter {
            searchText.isEmpty || $0.name.localizedCaseInsensitiveContains(searchText) || $0.collection.title.localizedCaseInsensitiveContains(searchText)
        }.map(Item.iptv)
        let entries = (radio + iptv).sorted { $0.date > $1.date }
        if library.history.isEmpty && music.history.isEmpty {
            ContentUnavailableView("No Listening History", systemImage: "clock",
                description: Text("Stations and music channels you play appear here. History stays on this iPhone."))
                .listRowBackground(Color.clear)
        } else {
            Button("Clear History", role: .destructive) { isConfirmingClear = true }
                .listRowBackground(Color.clear)
                .confirmationDialog("Clear radio listening history?", isPresented: $isConfirmingClear, titleVisibility: .visible) {
                    Button("Clear History", role: .destructive) { library.clearHistory(); music.clearHistory() }
                }
            if entries.isEmpty {
                ContentUnavailableView.search(text: searchText).listRowBackground(Color.clear)
            }
            ForEach(entries) { item in
                switch item {
                case .radio(let entry):
                    KyroRadioStationRow(station: entry.station, playedAt: entry.date)
                        .swipeActions {
                            Button("Remove", role: .destructive) { library.removeFromHistory(entry.id) }
                        }
                case .iptv(let entry):
                    KyroIPTVHistoryRow(entry: entry)
                        .swipeActions {
                            Button("Remove", role: .destructive) { music.removeFromHistory(entry.id) }
                        }
                }
            }
        }
    }
}

// MARK: - Station row

struct KyroRadioStationRow: View {
    let station: KyroRadioStation
    var playedAt: Date?
    private let player = KyroRadioPlayer.shared
    private let library = KyroRadioLibrary.shared

    private var isCurrent: Bool { player.station?.id == station.id }

    var body: some View {
        HStack(spacing: 12) {
            Button { player.play(station) } label: {
                HStack(spacing: 12) {
                    KyroRadioArtwork(station: station, size: 52)
                        .overlay(alignment: .bottomTrailing) {
                            if isCurrent && player.isPlaying {
                                Image(systemName: "waveform")
                                    .font(.caption2.bold())
                                    .padding(4)
                                    .background(KyroTheme.accent, in: Circle())
                                    .foregroundStyle(.white)
                                    .offset(x: 4, y: 4)
                            }
                        }
                    VStack(alignment: .leading, spacing: 3) {
                        Text(station.name)
                            .font(.body.weight(.semibold))
                            .foregroundStyle(isCurrent ? KyroTheme.accentInk : KyroTheme.textPrimary)
                            .lineLimit(2)
                        if !station.location.isEmpty {
                            Text(station.location).font(.subheadline).foregroundStyle(KyroTheme.textSecondary).lineLimit(1)
                        }
                        Text(detailLine).font(.caption).foregroundStyle(KyroTheme.textSecondary).lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Play \(station.name)")
            .accessibilityHint(station.location)

            Button { library.toggleFavorite(station) } label: {
                Image(systemName: library.isFavorite(station.id) ? "heart.fill" : "heart")
                    .font(.title3)
                    .foregroundStyle(KyroTheme.accentInk)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(library.isFavorite(station.id) ? "Remove \(station.name) from Library" : "Save \(station.name) to Library")
        }
        .listRowBackground(Color.clear)
        .accessibilityIdentifier("kyroRadioStation-\(station.id)")
    }

    private var detailLine: String {
        var parts: [String] = []
        if let playedAt { parts.append(playedAt.formatted(.relative(presentation: .named))) }
        if let format = station.formatLine { parts.append(format) }
        parts += station.tags.prefix(2).map(\.capitalized)
        return parts.isEmpty ? "Live radio" : parts.joined(separator: " · ")
    }
}

/// A station's logo through the shared artwork pipeline. Build 139: one
/// source-aware container for Radio Browser stations and IPTV channels alike.
struct KyroRadioArtwork: View {
    let station: KyroRadioStation?
    var size: CGFloat
    /// The size the logo is decoded at, when it differs from `size`. The
    /// radio bar resizes as the tab bar minimizes on scroll; decoding at one
    /// fixed size keeps that from starting a new image request each time.
    var decodeSize: CGFloat? = nil

    var body: some View {
        KyroRadioSourceArtwork(url: station?.favicon, collection: station?.iptv?.collection, size: size, decodeSize: decodeSize)
    }
}

// MARK: - Mini player and Now Playing

/// The radio bar above the tab bar, in the same slot as the audiobook bar.
struct KyroRadioMiniPlayerView: View {
    var style: NowPlayingBarStyle = .card
    @Environment(\.nowPlayingAccessoryIsInline) private var isInline
    private let player = KyroRadioPlayer.shared

    /// One decode for the expanded and inline bar.
    static let artworkDecodeSize: CGFloat = KyroAudioMiniLayout.artworkDecodeSize

    /// Song and artist when the stream sends them; otherwise the state, and
    /// for a playing IPTV channel its collection and provider instead of a
    /// bare "Live".
    static func subtitle(player: KyroRadioPlayer, station: KyroRadioStation) -> String {
        let line = KyroRadioStatusText.line(player: player)
        if player.state == .playing, player.track == nil, station.iptv != nil, !station.location.isEmpty {
            return "Live · " + station.location
        }
        return line
    }

    var body: some View {
        if let station = player.station {
            HStack(spacing: KyroAudioMiniLayout.spacing) {
                Button { player.isShowingNowPlaying = true } label: {
                    HStack(spacing: KyroAudioMiniLayout.spacing) {
                        KyroRadioArtwork(station: station, size: KyroAudioMiniLayout.artworkSize(inline: isInline),
                                         decodeSize: KyroRadioMiniPlayerView.artworkDecodeSize)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(station.name).font(.subheadline.weight(.semibold)).foregroundStyle(.white).lineLimit(1)
                            if !isInline {
                                Text(KyroRadioMiniPlayerView.subtitle(player: player, station: station))
                                    .font(.footnote).foregroundStyle(KyroSignature.secondary).lineLimit(1)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Now playing \(station.name)")
                .accessibilityHint("Opens Now Playing")

                KyroRadioTransportButton(player: player, size: KyroAudioMiniLayout.controlSize)
                    .frame(width: 44, height: 44)
            }
            .padding(.horizontal, KyroAudioMiniLayout.horizontalPadding)
            .padding(.vertical, KyroAudioMiniLayout.verticalPadding(inline: isInline))
            .modifier(KyroAudioMiniChrome(style: style))
            // Same card margins as the podcast bar (iPad, status column,
            // and the Radio page's own bar).
            .padding(.horizontal, style == .card ? KyroAudioMiniLayout.cardSideMargin : 0)
            .padding(.bottom, style == .card ? KyroAudioMiniLayout.cardBottomMargin : 0)
            .accessibilityIdentifier("kyroRadioMiniPlayer")
        }
    }
}

/// Play/Pause, or Retry after a failure. Never a seek control.
private struct KyroRadioTransportButton: View {
    let player: KyroRadioPlayer
    var size: CGFloat
    private let appearance = KyroRadioPlayerAppearance.shared

    var body: some View {
        Button {
            if case .failed = player.state, let station = player.station {
                player.play(station)
            } else {
                player.togglePlayPause()
            }
        } label: {
            Group {
                switch player.state {
                case .connecting, .reconnecting:
                    ProgressView()
                case .failed:
                    Image(systemName: "arrow.clockwise")
                case .playing:
                    Image(systemName: "pause.fill")
                case .idle, .paused:
                    Image(systemName: "play.fill")
                }
            }
            .font(size > 50 ? .largeTitle : .body.weight(.semibold))
            .frame(width: size, height: size)
            .modifier(KyroAudioMiniTransportFinish(theme: appearance.theme))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private var label: String {
        switch player.state {
        case .playing: "Pause"
        case .failed: "Try Again"
        case .connecting, .reconnecting: "Connecting"
        case .idle, .paused: "Play"
        }
    }
}

enum KyroRadioStatusText {
    @MainActor
    static func line(player: KyroRadioPlayer) -> String {
        switch player.state {
        case .connecting: return "Connecting…"
        case .reconnecting(let attempt): return "Reconnecting (\(attempt) of \(KyroRadioPlaybackMachine.maxReconnectAttempts))…"
        case .failed(let error): return error.message
        case .paused: return "Paused"
        case .idle: return ""
        case .playing:
            if let track = player.track { return [track.title, track.artist].compactMap { $0 }.joined(separator: " — ") }
            return "Live"
        }
    }
}

/// Presents Now Playing from the app root (attach once).
struct KyroRadioNowPlayingPresentation: ViewModifier {
    private let player = KyroRadioPlayer.shared

    func body(content: Content) -> some View {
        content.sheet(isPresented: Binding(get: { player.isShowingNowPlaying && player.hasSession },
                                           set: { player.isShowingNowPlaying = $0 })) {
            KyroRadioNowPlayingView()
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
    }
}

// Build 132: `KyroRadioNowPlayingView` (the turntable) lives in KyroRadioTurntable.swift.

// MARK: - Settings

enum KyroRadioSettingsEntry {
    static let title = "Radio Settings"
    static let subtitle = "Region, language and listening history"
    static let systemImage = "radio"
    static let searchTerms = ["radio", "radio settings", "radio browser", "internet radio", "stations", "region", "country", "state", "language", "history"]

    static func summary(preferences: KyroRadioPreferences, favoriteCount: Int) -> String {
        if let state = preferences.state, !state.isEmpty { return state }
        if let country = preferences.countryName, !country.isEmpty { return country }
        if let code = preferences.countryCode, !code.isEmpty { return code }
        return favoriteCount > 0 ? "\(favoriteCount) saved" : "Worldwide"
    }
}

struct KyroRadioSettingsRow: View {
    private let library = KyroRadioLibrary.shared

    var body: some View {
        NavigationLink {
            KyroRadioSettingsForm()
        } label: {
            SettingsOverviewRow(
                title: KyroRadioSettingsEntry.title,
                subtitle: KyroRadioSettingsEntry.subtitle,
                systemImage: KyroRadioSettingsEntry.systemImage,
                value: KyroRadioSettingsEntry.summary(preferences: library.preferences,
                                                    favoriteCount: library.favorites.count)
            )
        }
        .accessibilityIdentifier("kyroSettingsRadio")
    }
}

struct KyroRadioSettingsView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            KyroRadioSettingsForm()
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                }
        }
        .tint(KyroTheme.accentInk)
    }
}

struct KyroRadioSettingsForm: View {
    @State private var isConfirmingClear = false
    private let library = KyroRadioLibrary.shared

    var body: some View {
        Form {
            // Build 132: the expanded player's theme.
            KyroRadioPlayerAppearanceSection()
            KyroRadioRegionPickers(
                countryCode: binding(\.countryCode), countryName: binding(\.countryName),
                state: binding(\.state), language: binding(\.language))
            // Build 139: IPTV music channels in Radio.
            Section {
                NavigationLink("Manage Music Sources") { KyroIPTVMusicSourcesSettings() }
            } header: {
                Text("Music Sources")
            } footer: {
                Text("SiriusXM, Music Choice, Stingray Music and other music channels from your IPTV providers.")
            }
            .kyroSettingsRowSurface()
            Section("History") {
                LabeledContent("Saved", value: "\(library.history.count) of \(KyroRadioLibrary.maxHistory) stations")
                Button("Clear History", role: .destructive) { isConfirmingClear = true }
                    .disabled(library.history.isEmpty)
            }
            .kyroSettingsRowSurface()
            Section {
                NavigationLink("Customize Home") { KyroHomeCustomizationView(host: .shared) }
            } header: {
                Text("Home")
            } footer: {
                Text("Turn on Favorite Radio Stations and Recently Played Radio in Customize Home. They’re off until you turn them on.")
            }
            Section {
                Text("Stations come from Radio Browser, a free community directory. Kyro tells it when you start a station, as it asks apps to. Listening history stays on this iPhone and isn’t included in settings backups.")
                    .font(.footnote).foregroundStyle(.secondary)
            } header: {
                Text("About")
            }
        }
        .scrollContentBackground(.hidden)
        .background(SettingsBackdrop())
        .navigationTitle("Radio Settings")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Clear radio listening history?", isPresented: $isConfirmingClear, titleVisibility: .visible) {
            Button("Clear History", role: .destructive) { library.clearHistory() }
        }
        .tint(KyroTheme.accentInk)
    }

    private func binding(_ keyPath: WritableKeyPath<KyroRadioPreferences, String?>) -> Binding<String?> {
        Binding(get: { library.preferences[keyPath: keyPath] },
                set: { value in library.updatePreferences { $0[keyPath: keyPath] = value } })
    }
}

// MARK: - Home

/// The play or waveform badge on a Home radio card. Its own view (Build 130)
/// so a playback change redraws the badge, not the whole shelf.
private struct KyroHomeRadioPlayBadge: View {
    let stationID: String
    private let player = KyroRadioPlayer.shared

    var body: some View {
        Image(systemName: player.station?.id == stationID && player.isPlaying ? "waveform" : "play.fill")
            .font(.caption.bold())
            .foregroundStyle(.white)
            .frame(width: 30, height: 30)
            .background(KyroTheme.accent, in: Circle())
            .padding(6)
    }
}

/// Favorite Radio Stations and Recently Played Radio on Home. Draws nothing
/// when the shelf has no stations.
struct KyroHomeRadioRail: View {
    let shelf: KyroHomeShelf
    @Environment(AppRouter.self) private var router
    private let library = KyroRadioLibrary.shared
    private let player = KyroRadioPlayer.shared

    /// The largest shelf size Customize Home offers (Build 139).
    static let maximumStations = 30

    var stations: [KyroRadioStation] {
        let saved = shelf == .favoriteRadio ? library.favorites : library.history
        // Build 139: the shelf size from Customize Home (default 20, the Build 138 limit).
        let limit = KyroAudioShelfLimits.shared.value(shelf == .favoriteRadio ? .favoriteRadio : .recentRadio)
        return saved.prefix(min(limit, Self.maximumStations)).map(\.station)
    }

    var body: some View {
        let _ = KyroPerformanceDiagnostics.count(.homeRadioRailBody)
        let stations = stations
        if !stations.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Button {
                    KyroAudioDestination.radio.open(router: router)
                } label: {
                    HStack(spacing: 6) {
                        Text(shelf.title)
                            .font(.title3.bold())
                            .foregroundStyle(KyroTheme.textPrimary)
                        Image(systemName: "chevron.right")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(KyroTheme.textSecondary)
                            .accessibilityHidden(true)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(.isHeader)
                .accessibilityHint("Opens Radio")
                .accessibilityIdentifier("kyroHomeRadioHeader-\(shelf.rawValue)")
                .padding(.horizontal, SiloTheme.padding)
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 12) {
                        ForEach(stations) { station in card(station) }
                    }
                    .padding(.horizontal, SiloTheme.padding)
                }
            }
        }
    }

    private func card(_ station: KyroRadioStation) -> some View {
        Button { player.play(station) } label: {
            VStack(alignment: .leading, spacing: 8) {
                KyroRadioArtwork(station: station, size: 112)
                    .overlay(alignment: .bottomTrailing) {
                        KyroHomeRadioPlayBadge(stationID: station.id)
                    }
                Text(station.name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(KyroTheme.textPrimary)
                    .lineLimit(2, reservesSpace: true)
                    .multilineTextAlignment(.leading)
            }
            .frame(width: 112, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Play \(station.name)")
        .contextMenu {
            Button(library.isFavorite(station.id) ? "Remove from Library" : "Save to Library",
                   systemImage: library.isFavorite(station.id) ? "heart.slash" : "heart") {
                library.toggleFavorite(station)
            }
        }
    }
}
#endif
