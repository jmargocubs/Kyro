import SwiftUI

/// Live TV's names for Kyro's C3 roles. The values live in `KyroTheme`, which
/// the app shell and Kyro's navigation share.
enum LiveTVAccent {
    /// Electric blue: filled controls with white content.
    static let primary = KyroTheme.accent
    /// Electric-blue ink for text, icons and thin indicators on black.
    static let primaryText = KyroTheme.accentInk
    /// Deep blue for glass depth and glows.
    static let depth = KyroTheme.depth
    /// Pink-red, reserved for LIVE.
    static let live = KyroTheme.live
    /// Orange, a restrained accent (favorites).
    static let ember = KyroTheme.highlight
}

/// Live TV's page and row surfaces. On iPhone they are the Media Server's own
/// (Silo's charcoal page canvas and grouped-list rows), read rather than
/// copied, so Live TV follows any change to them. Apple TV and the Mac keep
/// Live TV's black.
enum LiveTVSurface {
    #if os(iOS)
    /// Flat page colour for opaque strips over scrolling content (pinned
    /// search, Guide headers), so they meet the page without a seam.
    static let canvas = Color.siloPageCanvas
    /// A list row, or a Guide channel cell, on the page.
    static let row = Color.siloGroupedCell
    /// A resting Home category tile.
    static let tile = Color.siloGroupedCell
    /// An ended Guide programme: a step below `row`, a step above the page.
    static let pastProgram = Color.siloSurfaceElevated
    /// An upcoming Guide programme.
    static let upcomingProgram = Color.siloGroupedCell
    #else
    static let canvas = Color.siloBackground
    static let row = Color.siloSurface
    static let tile = Color.siloSurfaceElevated
    static let pastProgram = Color.siloSurface.opacity(0.55)
    static let upcomingProgram = Color.siloSurfaceElevated
    #endif
}

extension View {
    /// The page behind a Live TV screen: the Media Server's page backdrop on
    /// iPhone, black elsewhere.
    @ViewBuilder
    func liveTVPageBackground() -> some View {
        #if os(iOS)
        siloPageBackground()
        #else
        background(Color.siloBackground)
        #endif
    }
}

#if os(iOS)
/// The channel browser's search field, pinned to the top of the list.
///
/// The browser used `.searchable`. It appears when the browser replaces Home
/// on the same page, and iOS 26 then puts the field in a bottom toolbar
/// whatever placement is asked for: a glass bar along the bottom under the
/// floating navigation, holding the bottom safe area and its touches, and
/// hidden by the Classic tab bar. The Guide, pushed with its search, keeps
/// the system drawer. Same text and the same presented state as before, so
/// the Search destination and the header's search button work unchanged.
struct LiveTVChannelSearchField: View {
    private static let edgeFade: CGFloat = 16

    @Binding var text: String
    @Binding var isActive: Bool
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(Color.siloSecondaryText)
                    .accessibilityHidden(true)
                TextField("Search channels", text: $text)
                    .focused($isFocused)
                    .submitLabel(.search)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .foregroundStyle(Color.siloOnSurface)
                    .accessibilityIdentifier("liveTVChannelSearch")
                if !text.isEmpty {
                    Button { text = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(Color.siloSecondaryText)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear search")
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 40)
            .background(Color.white.opacity(0.09), in: Capsule())
            if isActive {
                Button("Cancel") {
                    text = ""
                    isActive = false
                }
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        // Flat canvas over the scrolling rows, fading out below the strip so it meets
        // the page's soft wash without an edge.
        .background {
            LiveTVSurface.canvas
                .mask {
                    VStack(spacing: 0) {
                        Color.black
                        LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                            .frame(height: Self.edgeFade)
                    }
                }
                .padding(.bottom, -Self.edgeFade)
                .allowsHitTesting(false)
        }
        .animation(.easeOut(duration: 0.2), value: isActive)
        .onChange(of: isActive, initial: true) { _, active in
            if isFocused != active { isFocused = active }
        }
        .onChange(of: isFocused) { _, focused in
            if focused != isActive { isActive = focused }
        }
    }
}
#endif

enum LiveTVNavigationBackDestination: Equatable {
    case home
    case exitLiveTV
}

enum LiveTVNavigationPolicy {
    static func backDestination(showingBrowser: Bool) -> LiveTVNavigationBackDestination {
        showingBrowser ? .home : .exitLiveTV
    }

    static func backLabel(showingBrowser: Bool) -> String {
        showingBrowser ? "Back to Live TV Home" : "Back"
    }

    static func showsGuideBack(isUnifiedShell: Bool) -> Bool { isUnifiedShell }
}

struct LiveTVView: View {
    @Bindable var service: LiveTVService
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var searchText = ""
    @State private var searchModel = LiveTVChannelSearchModel()
    @State private var selectedCategory: String?
    @State private var favoritesOnly = false
    @State private var showChannelBrowser = false
    @State private var isShowingCategories = false
    @State private var isShowingSettings = false
    @State private var isShowingGuide = false
    @State private var listPosition = ScrollPosition(idType: String.self)
    @State private var browsingContextToRestore: LiveTVBrowsingContext?
    @State private var restoredContextProviderID: UUID?
    @State private var isSearchPresented = false
    @SceneStorage("liveTV.listBrowsingContext.v1") private var savedBrowsingContext = ""

    private var contentState: LiveTVChannelListContentState {
        LiveTVChannelListContentState.resolve(hasProviders: !service.providers.isEmpty,
                                              isLoading: service.isLoading,
                                              errorMessage: service.errorMessage,
                                              channelCount: service.channels.count)
    }

    /// Kyro's unified navigation hosts Live TV as a tab, with nothing behind it to go back to.
    private var isTabRoot: Bool {
        #if os(iOS)
        KyroUnifiedNavigation.isActive
        #else
        false
        #endif
    }

    private var browserTitle: String {
        if !searchText.isEmpty { return "Search Results" }
        if favoritesOnly { return "My Favorites" }
        return selectedCategory ?? "Browse Channels"
    }

    var body: some View {
        // A ZStack rather than a Group: Group would hand these appear/disappear handlers to each
        // branch, so switching between Home and the browser would cancel search and save state.
        ZStack {
            if showChannelBrowser {
                browserList
            } else {
                LiveTVHomeContent(model: homeModel, epg: homeEPG, actions: homeActions)
            }
        }
        // Inside the navigation too, so Classic's tab shows the page rather than its own black.
        .liveTVPageBackground()
        #if os(iOS)
        .kyroLiveTVNavigation(isEnabled: !service.providers.isEmpty, active: activeNavigationDestination,
                              navigate: navigate(to:))
        .liveTVTabHeader(isEnabled: isTabRoot) {
            // Live TV's own navigation already leads Home, so the header has no Back unless
            // there is none (no provider yet), and offers Search and the Guide only when it doesn't.
            LiveTVTabHeader(back: showChannelBrowser && service.providers.isEmpty ? { returnHome() } : nil,
                            search: tabHeaderOffers(.search) ? { performHeaderAction(.search) } : nil,
                            guide: tabHeaderOffers(.guide) ? { performHeaderAction(.guide) } : nil,
                            settings: { performHeaderAction(.settings) })
        }
        #endif
        .liveTVPageBackground()
        .tint(LiveTVAccent.primaryText)
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbar {
            // The channel browser is an in-place destination on the unified
            // Live TV tab, so it still needs an explicit contextual return.
            if !isTabRoot || showChannelBrowser {
                LiveTVHomeToolbar(back: handleBack,
                                  backLabel: LiveTVNavigationPolicy.backLabel(showingBrowser: showChannelBrowser),
                                  search: { performHeaderAction(.search) },
                                  guide: { performHeaderAction(.guide) },
                                  settings: { performHeaderAction(.settings) })
            }
        }
        .refreshable { await service.refreshSelectedProvider() }
        .sheet(isPresented: $isShowingSettings) {
            NavigationStack {
                LiveTVSettingsView(service: service)
            }
            .tint(LiveTVAccent.primaryText)
        }
        .sheet(isPresented: $isShowingCategories) {
            NavigationStack {
                List {
                    Button("All Channels") { enterBrowser(using: .channels); isShowingCategories = false }
                    ForEach(service.categories, id: \.self) { category in
                        Button(category) { enterBrowser(using: .category(category)); isShowingCategories = false }
                    }
                }.navigationTitle("Categories").navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { isShowingCategories = false } } }
            }.tint(LiveTVAccent.primaryText)
        }
        .navigationDestination(isPresented: $isShowingGuide) {
            #if os(iOS)
            LiveTVGuideView(service: service, navigation: KyroLiveTVNavigationRoute(
                isEnabled: !service.providers.isEmpty, navigate: navigate(to:)))
            #else
            LiveTVGuideView(service: service)
            #endif
        }
        .fullScreenCover(item: Binding(
            get: { service.presentation.channel(for: .list) },
            set: { if $0 == nil { service.presentation.coverDismissed(from: .list) } }
        )) { channel in
            LiveTVPlayerView(channel: channel, channels: service.channels, session: service.playerSession,
                             service: service)
        }
        .task(id: service.selectedProviderID) {
            restoreBrowsingContext(for: service.selectedProviderID)
            updateSearch()
            await service.prepareSelectedProvider()
        }
        .onAppear {
            restoreBrowsingContext(for: service.selectedProviderID)
            updateSearch()
            service.presentation.surfaceAppeared(.list)
        }
        .onDisappear {
            // A tab stays alive while another tab shows. Saving or cancelling here re-renders the
            // hidden list, which then returns to the top; backgrounding still saves (`scenePhase`).
            guard !isTabRoot else {
                service.presentation.surfaceDisappeared(.list)
                return
            }
            saveBrowsingContext()
            searchModel.cancel()
            service.presentation.surfaceDisappeared(.list)
        }
        .onChange(of: searchText) { _, query in
            if !query.isEmpty, !showChannelBrowser {
                enterBrowser(using: .search(query: query), resumingSavedPosition: false)
            } else if !query.isEmpty {
                showChannelBrowser = true
            }
            updateSearch()
        }
        .onChange(of: selectedCategory) { updateSearch() }
        .onChange(of: favoritesOnly) { updateSearch() }
        .onChange(of: service.favoriteChannelIDs) { updateSearch() }
        .onChange(of: service.channelCatalogRevision) {
            reconcileBrowsingContext()
            updateSearch()
        }
        .onChange(of: service.selectedProviderID) { _, providerID in
            restoreBrowsingContext(for: providerID)
            updateSearch()
        }
        .onChange(of: scenePhase) { _, phase in if phase == .background { saveBrowsingContext() } }
    }

    // MARK: Home

    /// Built from the bounded provider-scoped preview the service already keeps; no catalog scan.
    private var homeModel: LiveTVHomeModel {
        LiveTVHomeModel(
            providers: service.providers,
            selectedProviderID: service.selectedProviderID,
            channelCount: service.channels.count,
            isLoading: service.isLoading,
            contentState: contentState,
            errorMessage: service.channels.isEmpty ? nil : LiveTVHomeErrorPresentation.message(service.errorMessage),
            sections: LiveTVHomeSections(recents: service.homeRecentChannels,
                                         favorites: service.homeFavoriteChannels,
                                         isPlayable: { service.canPlay($0) }),
            upNext: service.homeUpNext,
            categories: service.categories,
            carouselEnabled: !showChannelBrowser && !isShowingCategories && !isShowingSettings && !isShowingGuide &&
                scenePhase == .active && service.presentation.phase == .idle)
    }

    private var homeEPG: LiveTVHomeEPG {
        LiveTVHomeEPG { [service] channel, date in
            service.isGuideStale ? nil : service.programPair(for: channel, at: date).current
        }
    }

    private var homeActions: LiveTVHomeActions {
        LiveTVHomeActions(
            play: { service.choose($0, from: .list) },
            toggleFavorite: { service.toggleFavorite($0) },
            browse: { enterBrowser(using: $0) },
            showAllCategories: { isShowingCategories = true },
            showGuide: { performHeaderAction(.guide) },
            showSettings: { performHeaderAction(.settings) },
            selectProvider: { selectProvider($0) },
            retry: { Task { await service.refreshSelectedProvider() } },
            isFavorite: { service.isFavorite($0) },
            loadPrograms: { channel in
                guard !service.isGuideStale else { return LiveTVProgramPair(current: nil, next: nil) }
                return service.programPair(for: channel)
            })
    }

    private func selectProvider(_ providerID: UUID) {
        saveBrowsingContext(for: service.selectedProviderID)
        restoredContextProviderID = nil
        service.selectProvider(providerID)
    }

    private func handleBack() {
        switch LiveTVNavigationPolicy.backDestination(showingBrowser: showChannelBrowser) {
        case .home:
            returnHome()
        case .exitLiveTV:
            dismiss()
        }
    }

    // MARK: Channel browser

    private var browserList: some View {
        List {
            Section {
                HStack {
                    Spacer()
                    Text(browserTitle).font(.headline).foregroundStyle(Color.siloOnSurface)
                }
                if service.providers.count > 1, let provider = service.selectedProvider {
                    Menu {
                        ForEach(service.providers) { option in
                            Button { selectProvider(option.id) } label: {
                                if option.id == provider.id {
                                    Label(option.name, systemImage: "checkmark")
                                } else { Text(option.name) }
                            }
                        }
                    } label: {
                        Label("Provider: \(provider.name)", systemImage: "antenna.radiowaves.left.and.right")
                            .font(.subheadline)
                    }
                    .accessibilityLabel("Live TV provider: \(provider.name). Switch provider")
                }
            }
            // Sits on the page itself, so the page shows through.
            #if os(iOS)
            .listRowBackground(Color.clear)
            #else
            .listRowBackground(Color.siloBackground)
            #endif
            browserStatus
            if !service.providers.isEmpty {
                Section {
                    HStack(spacing: 10) {
                        Menu {
                            Button("All Categories") { selectedCategory = nil }
                            ForEach(service.categories, id: \.self) { category in
                                Button(category) { selectedCategory = category }
                            }
                        } label: {
                            Label(selectedCategory ?? "All Categories", systemImage: "line.3.horizontal.decrease")
                                .foregroundStyle(LiveTVAccent.primaryText)
                        }
                        Spacer()
                        Button { favoritesOnly.toggle() } label: {
                            Label(favoritesOnly ? "Favorites" : "All", systemImage: favoritesOnly ? "star.fill" : "star")
                                .foregroundStyle(favoritesOnly ? LiveTVAccent.ember : Color.siloSecondaryText)
                        }.buttonStyle(.plain).accessibilityLabel(favoritesOnly ? "Show all channels" : "Show favorites only")
                    }.listRowBackground(LiveTVSurface.row)
                }
                if searchModel.resultCount == 0 {
                    Section { ContentUnavailableView.search(text: searchText).listRowBackground(LiveTVSurface.row) }
                } else {
                    ForEach(searchModel.orderedCategories, id: \.self) { category in
                        Section(category) {
                            ForEach(searchModel.groups[category] ?? []) { channel in channelRow(channel) }
                        }
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .scrollPosition($listPosition)
        #if os(iOS)
        .liveTVBrowserSearchField(asTopBar: isTabRoot) {
            LiveTVChannelSearchField(text: $searchText, isActive: $isSearchPresented)
        }
        #else
        .searchable(text: $searchText, isPresented: $isSearchPresented, prompt: "Search channels")
        #endif
    }

    @ViewBuilder
    private var browserStatus: some View {
        if case .loading = contentState {
            Section {
                HStack(spacing: 12) {
                    ProgressView()
                    Text("Loading channels…").foregroundStyle(Color.siloSecondaryText)
                }
                .listRowBackground(LiveTVSurface.row)
            }
        } else if case .failed(let error) = contentState {
            Section {
                ContentUnavailableView {
                    Label("Couldn’t Load Channels", systemImage: "wifi.exclamationmark")
                } description: {
                    Text(error)
                } actions: {
                    Button("Try Again") { Task { await service.refreshSelectedProvider() } }
                        .tint(LiveTVAccent.primaryText)
                }
                .listRowBackground(LiveTVSurface.row)
            }
        } else if case .setup = contentState {
            Section {
                ContentUnavailableView {
                    Label("Set Up Live TV", systemImage: "antenna.radiowaves.left.and.right")
                } description: {
                    Text("Add an M3U playlist or Xtream Codes account to browse live channels.")
                } actions: {
                    Button("Add Playlist") { isShowingSettings = true }
                        .buttonStyle(.borderedProminent)
                        .tint(LiveTVAccent.primary)
                }
                .listRowBackground(LiveTVSurface.row)
            }
        } else if case .noChannels = contentState {
            Section {
                ContentUnavailableView(
                    "No Channels",
                    systemImage: "tv",
                    description: Text("Refresh the playlist or check its settings.")
                )
                .listRowBackground(LiveTVSurface.row)
            }
        }
        if !service.channels.isEmpty, let error = LiveTVHomeErrorPresentation.message(service.errorMessage) {
            Section {
                Label(error, systemImage: "exclamationmark.circle")
                    .font(.footnote).foregroundStyle(.red)
                    .listRowBackground(LiveTVSurface.row)
            }
        }
    }

    private func updateSearch() {
        searchModel.update(channels: service.channels, query: searchText, category: selectedCategory,
                           favoritesOnly: favoritesOnly, favoriteIDs: service.favoriteChannelIDs)
        guard let context = browsingContextToRestore,
              context.providerID == service.selectedProviderID,
              let providerID = service.selectedProviderID else { return }
        Task { @MainActor in
            await searchModel.waitForCurrentSearch()
            guard browsingContextToRestore == context, service.selectedProviderID == providerID,
                  service.hasCatalog(for: providerID),
                  showChannelBrowser,
                  searchText == context.searchQuery, selectedCategory == context.category,
                  favoritesOnly == context.favoritesOnly else { return }
            let visibleIDs = searchModel.groups.values
            if let channelID = context.channelID,
               visibleIDs.contains(where: { $0.contains(where: { $0.id == channelID }) }) {
                listPosition.scrollTo(id: channelID, anchor: .top)
            } else if let x = context.offsetX, let y = context.offsetY {
                listPosition.scrollTo(point: CGPoint(x: x, y: y))
            }
            browsingContextToRestore = nil
        }
    }

    private func restoreBrowsingContext(for providerID: UUID?) {
        guard let providerID, restoredContextProviderID != providerID else { return }
        restoredContextProviderID = providerID
        selectedCategory = nil
        favoritesOnly = false
        searchText = ""
        listPosition = ScrollPosition(idType: String.self)
        // A Home snapshot leaves Home showing with clean filters; its position waits in storage
        // until the user re-enters the same browser.
        if let context = storedBrowsingContext(for: providerID), context.shouldPresentBrowser {
            browsingContextToRestore = context
            selectedCategory = context.category
            favoritesOnly = context.favoritesOnly
            searchText = context.searchQuery
            showChannelBrowser = true
        } else {
            browsingContextToRestore = nil
            showChannelBrowser = false
        }
        reconcileBrowsingContext()
    }

    private func reconcileBrowsingContext() {
        guard let providerID = service.selectedProviderID,
              let valid = browsingContextToRestore?.validatedWhenReady(
                  selectedProviderID: providerID, catalogIsLoaded: service.hasCatalog(for: providerID),
                  categories: service.categories, channels: service.channels) else { return }
        browsingContextToRestore = valid
        if selectedCategory != valid.category { selectedCategory = valid.category }
    }

    private func storedBrowsingContext(for providerID: UUID) -> LiveTVBrowsingContext? {
        LiveTVBrowsingContextCollection.decoded(savedBrowsingContext)?.context(for: providerID)
    }

    private func saveBrowsingContext() {
        saveBrowsingContext(for: service.selectedProviderID)
    }

    private func saveBrowsingContext(for providerID: UUID?) {
        guard showChannelBrowser, let providerID else { return }
        storeBrowsingContext(currentBrowsingContext(for: providerID))
    }

    /// The browser as it stands. A restore that has not run yet (its catalog is still loading)
    /// keeps its saved position, so leaving early does not overwrite it with an empty one.
    private func currentBrowsingContext(for providerID: UUID) -> LiveTVBrowsingContext {
        if let pending = browsingContextToRestore, pending.providerID == providerID,
           pending.category == selectedCategory, pending.favoritesOnly == favoritesOnly,
           pending.searchQuery == searchText {
            var context = pending
            context.isBrowserVisible = showChannelBrowser
            return context
        }
        let point = listPosition.point
        return LiveTVBrowsingContext(providerID: providerID, category: selectedCategory,
                                     favoritesOnly: favoritesOnly, searchQuery: searchText,
                                     channelID: listPosition.viewID(type: String.self),
                                     offsetX: point.map { Double($0.x) }, offsetY: point.map { Double($0.y) },
                                     isBrowserVisible: showChannelBrowser)
    }

    private func storeBrowsingContext(_ context: LiveTVBrowsingContext) {
        let collection = LiveTVBrowsingContextCollection.decoded(savedBrowsingContext) ?? LiveTVBrowsingContextCollection()
        if let encoded = collection.replacing(context).encoded() { savedBrowsingContext = encoded }
    }

    /// An intentional return to Home is persisted, so the browser does not reopen on the next visit.
    private func returnHome() {
        if let providerID = service.selectedProviderID {
            storeBrowsingContext(currentBrowsingContext(for: providerID).returningHome())
        }
        browsingContextToRestore = nil
        showChannelBrowser = false
        isSearchPresented = false
        searchText = ""
        selectedCategory = nil
        favoritesOnly = false
    }

    /// Every entry point starts from its own filters. Re-entering the browser the user left for
    /// Home resumes its saved position; any other entry drops a pending restore.
    private func enterBrowser(using filters: LiveTVBrowserFilters, resumingSavedPosition: Bool = true) {
        searchText = filters.query
        selectedCategory = filters.category
        favoritesOnly = filters.favoritesOnly
        showChannelBrowser = true
        listPosition = ScrollPosition(idType: String.self)
        browsingContextToRestore = resumingSavedPosition
            ? service.selectedProviderID.flatMap { storedBrowsingContext(for: $0)?.resumedBrowser(for: filters) }
            : nil
        reconcileBrowsingContext()
        updateSearch()
    }

    private func performHeaderAction(_ action: LiveTVHomeHeaderAction) {
        action.activate(
            search: {
                enterBrowser(using: .search(query: searchText), resumingSavedPosition: false)
                // The field belongs to the browser List, which may only appear in this update.
                Task { @MainActor in isSearchPresented = true }
            },
            guide: { isShowingGuide = true },
            settings: { isShowingSettings = true })
    }

#if os(iOS)
    // MARK: Kyro floating navigation

    private var activeNavigationDestination: KyroLiveTVDestination {
        KyroLiveTVActiveDestination.resolve(showingGuide: isShowingGuide, showingBrowser: showChannelBrowser,
                                            searching: isSearchPresented || !searchText.isEmpty,
                                            favoritesOnly: favoritesOnly)
    }

    /// Whether the tab-root header needs Search or the Guide: only when Live TV's own navigation
    /// doesn't show it, because the user hid it from Classic's row or there is no navigation yet.
    private func tabHeaderOffers(_ destination: KyroLiveTVDestination) -> Bool {
        if KyroUnifiedNavigation.isActive { return true }
        let preferences = KyroLiveTVNavigationStore.shared.preferences
        guard !service.providers.isEmpty, !preferences.style.isFloating else { return true }
        return !preferences.isVisible(destination)
    }

    /// Reaches the screens Live TV already has, through the same paths as the header and Home.
    private func navigate(to destination: KyroLiveTVDestination) {
        let leavingGuide = isShowingGuide && destination != .guide
        switch destination {
        case .home:
            isShowingGuide = false
            if showChannelBrowser { returnHome() }
        case .guide:
            isShowingGuide = true
        case .favorites:
            isShowingGuide = false
            enterBrowser(using: .favorites)
        case .channels:
            isShowingGuide = false
            enterBrowser(using: .channels)
        case .search:
            isShowingGuide = false
            enterBrowser(using: .search(query: searchText), resumingSavedPosition: false)
            Task { @MainActor in
                // The search field belongs to the browser List; after leaving the Guide it
                // exists only once the pop has finished.
                if leavingGuide { try? await Task.sleep(for: .milliseconds(450)) }
                isSearchPresented = true
            }
        case .sportsHub:
            // Never offered until a Sports Hub exists (`KyroLiveTVDestination.isAvailable`).
            break
        }
    }
#endif

    private func channelRow(_ channel: LiveTVChannel) -> some View {
        HStack(spacing: 12) {
            Button {
                service.choose(channel, from: .list)
            } label: {
                HStack(spacing: 12) {
                    channelLogo(channel)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(channel.name)
                            .font(.body.weight(.medium))
                            .foregroundStyle(Color.siloOnSurface)
                            .lineLimit(1)
                        if !service.isGuideStale {
                            let pair = service.programPair(for: channel)
                            if let current = pair.current {
                                Text("Now · \(current.title)")
                                    .font(.caption)
                                    .foregroundStyle(Color.siloSecondaryText)
                                    .lineLimit(1)
                            }
                            if let next = pair.next {
                                Text("Next · \(next.title)")
                                    .font(.caption2)
                                    .foregroundStyle(Color.siloSecondaryText.opacity(0.8))
                                    .lineLimit(1)
                            }
                        } else if service.guideMessage != nil || service.isGuideStale {
                            Text("Program guide unavailable")
                                .font(.caption)
                                .foregroundStyle(Color.siloSecondaryText)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "play.fill")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(LiveTVAccent.primaryText)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Play \(channel.name)")

            Button {
                service.toggleFavorite(channel)
            } label: {
                Image(systemName: service.isFavorite(channel) ? "star.fill" : "star")
                    .foregroundStyle(service.isFavorite(channel) ? LiveTVAccent.ember : Color.siloSecondaryText)
                    .frame(width: 40, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(service.isFavorite(channel) ? "Remove \(channel.name) from favorites" : "Add \(channel.name) to favorites")
        }
        .listRowBackground(LiveTVSurface.row)
    }

    private func channelLogo(_ channel: LiveTVChannel) -> some View {
        LiveTVChannelLogo(channel: channel, size: CGSize(width: 50, height: 42))
    }
}

/// A channel's logo, or a TV placeholder when it has none.
struct LiveTVChannelLogo: View {
    let channel: LiveTVChannel
    let size: CGSize
    /// `.clear` draws logos straight onto a colored card, with no tile behind a missing one.
    var placeholderStyle: ImagePlaceholderStyle = .surface

    var body: some View {
        if let logoURL = channel.logoURL {
            AsyncImageView(url: logoURL.absoluteString, targetSize: size, contentMode: .fit,
                           placeholderStyle: placeholderStyle, placeholderSymbol: "tv")
                .frame(width: size.width, height: size.height)
                .accessibilityHidden(true)
        } else {
            Image(systemName: "tv")
                .font(placeholderStyle == .clear ? .largeTitle : .title3)
                .foregroundStyle(placeholderStyle == .clear ? Color.white.opacity(0.85) : LiveTVAccent.primaryText)
                .frame(width: size.width, height: size.height)
                .background(placeholderStyle == .clear ? Color.clear : Color.siloSurfaceElevated,
                            in: RoundedRectangle(cornerRadius: 8))
                .accessibilityHidden(true)
        }
    }
}

struct LiveTVSettingsView: View {
    @Bindable var service: LiveTVService
    @Environment(\.dismiss) private var dismiss
    @State private var providerName = "My Playlist"
    @State private var playlistURL = ""
    @State private var xmltvURL = ""
    @State private var serverURL = ""
    @State private var username = ""
    @State private var password = ""
    @State private var providerKind: LiveTVProviderKind = .m3u
    @State private var errorMessage: String?
    @State private var providerToRemove: LiveTVProvider?
#if KYRO_INTERNAL_EPG_STORAGE_TOGGLE
    @AppStorage(EPGStorageMode.defaultsKey) private var sqliteStorageEnabled = false
#endif

    var body: some View {
        Form {
            Section("Provider & Catalog") {
                if let provider = service.selectedProvider {
                    LabeledContent("Active provider", value: provider.name)
                    LabeledContent("Imported channels", value: provider.channelCount.formatted())
                    LabeledContent("Import limit", value: "\(LiveTVChannelSnapshotStore.maximumChannels.formatted()) channels")
                    if let notice = service.catalogNotice {
                        Label(notice, systemImage: "info.circle")
                            .font(.footnote).foregroundStyle(Color.siloSecondaryText)
                    }
                    LabeledContent("Catalog status", value: LiveTVCatalogStatus(truncated: provider.catalogWasTruncated).rawValue)
                    Button {
                        Task { await service.refreshSelectedProvider() }
                    } label: {
                        HStack {
                            Label("Refresh Playlist", systemImage: "arrow.clockwise")
                            Spacer()
                            if service.isLoading { ProgressView() }
                        }
                    }
                    .disabled(service.isLoading)
                } else {
                    Text("Add a provider to view catalog details.").foregroundStyle(Color.siloSecondaryText)
                }
            }

#if os(iOS)
            if KyroLiveTVNavigation.isSupported {
                Section("Navigation") {
                    NavigationLink {
                        KyroLiveTVNavigationSettingsView(store: .shared)
                    } label: {
                        LabeledContent {
                            Text(KyroLiveTVNavigationStore.shared.preferences.style.title)
                        } label: {
                            Label("Navigation", systemImage: "hand.point.up.left")
                        }
                    }
                    .accessibilityIdentifier("kyroLiveTVNavigationSettingsLink")
                }
            }
#endif

            Section("Providers") {
                if service.providers.isEmpty {
                    Text("No providers configured.")
                        .foregroundStyle(Color.siloSecondaryText)
                }
                ForEach(service.providers) { provider in
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(provider.name)
                            Text("\(provider.kind == .m3u ? "M3U" : "Xtream") · \(provider.channelCount.formatted()) channels")
                                .font(.caption).foregroundStyle(Color.siloSecondaryText)
                        }
                        Spacer()
                        if provider.id == service.selectedProviderID {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(LiveTVAccent.primaryText)
                        }
                        Button(role: .destructive) { providerToRemove = provider } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Remove \(provider.name)")
                    }
                }
            }

            Section("Add IPTV Provider") {
                Picker("Provider type", selection: $providerKind) {
                    Text("M3U Playlist").tag(LiveTVProviderKind.m3u)
                    Text("Xtream Codes").tag(LiveTVProviderKind.xtream)
                }
                .pickerStyle(.segmented)
                TextField("Provider name", text: $providerName)
                    .textContentType(.name)
                if providerKind == .m3u {
                    TextField("Playlist URL (HTTP or HTTPS)", text: $playlistURL)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    TextField("XMLTV guide URL (optional)", text: $xmltvURL)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    Text("Playlist and guide addresses are stored in Keychain.")
                } else {
                    TextField("Server URL (HTTP or HTTPS, optional port)", text: $serverURL)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    TextField("Username", text: $username)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField("Password", text: $password)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    Text("Credentials are stored in Keychain and sent only to this provider. HTTP connections are not encrypted.")
                }
                Text("Provider settings are fetched only when added or when you refresh Live TV.")
                    .font(.footnote)
                    .foregroundStyle(Color.siloSecondaryText)
                if let errorMessage {
                    Text(errorMessage).font(.footnote).foregroundStyle(.red)
                }
                Button("Save Provider") { saveProvider() }
                    .disabled(providerKind == .m3u
                              ? playlistURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                              : serverURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                || username.isEmpty || password.isEmpty)
            }

#if KYRO_INTERNAL_EPG_STORAGE_TOGGLE
            Section("INTERNAL TEST — EPG Storage") {
                Toggle("Use experimental SQLite guide", isOn: $sqliteStorageEnabled)
                Text("Currently active: \(service.activeEPGStorageMode == .sqlite ? "SQLite" : "Existing in-memory backend"). Changes apply after force-quitting and reopening Kyro. This control is included only in the owner’s experimental test build.")
                    .font(.footnote)
                    .foregroundStyle(Color.siloSecondaryText)
                if sqliteStorageEnabled != (service.activeEPGStorageMode == .sqlite) {
                    Text("Restart required to activate the selected backend.")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(LiveTVAccent.primaryText)
                }
            }
#endif
        }
        .scrollContentBackground(.hidden)
        .background(Color.siloBackground)
        .navigationTitle("Live TV Settings")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
            }
        }
        .confirmationDialog(
            "Remove \(providerToRemove?.name ?? "provider")?",
            isPresented: Binding(
                get: { providerToRemove != nil },
                set: { if !$0 { providerToRemove = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Remove Provider", role: .destructive) {
                if let providerToRemove { Task { await service.removeProvider(providerToRemove.id) } }
                providerToRemove = nil
            }
        }
    }

    private func saveProvider() {
        do {
            if providerKind == .m3u {
                _ = try service.saveConfiguration(name: providerName, playlistURL: playlistURL, xmltvURL: xmltvURL)
            } else {
                _ = try service.saveXtreamConfiguration(name: providerName, serverURL: serverURL,
                                                       username: username, password: password)
            }
            dismiss()
        } catch let error as LiveTVError {
            errorMessage = error.localizedDescription
        } catch {
            errorMessage = "The provider could not be saved."
        }
    }
}
