#if os(tvOS)
import SwiftUI

enum TVLiveTVSection: String, CaseIterable, Hashable, Identifiable {
    case channels
    case categories
    case favorites

    var id: Self { self }

    var title: String {
        switch self {
        case .channels: "All Channels"
        case .categories: "Categories"
        case .favorites: "Favorites"
        }
    }

    var symbol: String {
        switch self {
        case .channels: "rectangle.stack"
        case .categories: "square.grid.2x2"
        case .favorites: "star.fill"
        }
    }
}

enum TVLiveTVChannelMenuAction: CaseIterable, Equatable {
    case watch, favorite, hide, information

    func title(isFavorite: Bool) -> String {
        switch self {
        case .watch: "Watch Channel"
        case .favorite: isFavorite ? "Remove from Favorites" : "Add to Favorites"
        case .hide: "Hide Channel"
        case .information: "Channel Information"
        }
    }
}

enum TVLiveTVCategoryMenuAction: CaseIterable, Equatable {
    case browse, guide, hide

    var title: String {
        switch self {
        case .browse: "Browse Channels"
        case .guide: "Open TV Guide"
        case .hide: "Hide Category"
        }
    }
}

/// A selected category is a child of Categories, not a disguised All Channels tab.
struct TVLiveTVBrowseNavigation: Equatable {
    var section: TVLiveTVSection = .channels
    var selectedCategory: String?
    var focusedCategory: String?
    var scrollAnchor: String?

    mutating func select(_ next: TVLiveTVSection) {
        section = next
        selectedCategory = nil
    }

    mutating func openCategory(_ category: String?) {
        if let category {
            section = .categories
            selectedCategory = category
            focusedCategory = category
        } else {
            section = .channels
            selectedCategory = nil
        }
    }

    mutating func back() -> Bool {
        guard section == .categories, selectedCategory != nil else { return false }
        selectedCategory = nil
        return true
    }

    mutating func hideCategory(_ category: String, visibleCategories: [String]) -> String? {
        let next = visibleCategories.firstIndex(of: category).flatMap { index in
            visibleCategories.indices.contains(index + 1) ? visibleCategories[index + 1]
                : (index > 0 ? visibleCategories[index - 1] : nil)
        }
        if selectedCategory == category { _ = back() }
        if scrollAnchor == category { scrollAnchor = next }
        focusedCategory = next
        return next
    }
}

@MainActor enum TVLiveTVBrowseMemory {
    private static var states: [String: TVLiveTVBrowseNavigation] = [:]

    static func save(_ navigation: TVLiveTVBrowseNavigation, for scope: TVLiveTVVisibilityScope?) {
        guard let scope else { return }
        states[scope.storageKey] = navigation
    }

    static func restore(for scope: TVLiveTVVisibilityScope?) -> TVLiveTVBrowseNavigation? {
        guard let scope else { return nil }
        return states[scope.storageKey]
    }
}

/// Pure focus-restoration state used by the TV guide and its focused tests.
struct TVLiveTVGuideNavigationState: Equatable {
    private(set) var focusedChannelID: String?

    mutating func focus(channelID: String) { focusedChannelID = channelID }

    mutating func reconcile(visibleChannelIDs: [String]) {
        guard let focusedChannelID else { return }
        if !visibleChannelIDs.contains(focusedChannelID) {
            self.focusedChannelID = visibleChannelIDs.first
        }
    }
}

/// Kyro's native Apple TV Live TV root. Networking, secure provider storage,
/// catalogs, EPG matching, favorites, and the single playback session all
/// remain owned by `LiveTVService`; this view only supplies a TV focus graph.
struct TVLiveTVRootView: View {
    @Bindable var service: LiveTVService
    let profileID: String?
    let focusRequest: Int
    let isTopMenuFocused: Bool
    let onTopMenuFocusRequest: () -> Void

    @State private var navigation = TVLiveTVBrowseNavigation()
    @State private var visibility = TVLiveTVVisibilityStore.shared
    @State private var query = ""
    @State private var search = LiveTVChannelSearchModel()
    @State private var showsGuide = false
    @State private var guideCategory: String?
    @State private var showsProviders = false
    @State private var infoChannel: LiveTVChannel?
    @State private var focusBeforeCover: FocusTarget?
    @FocusState private var focusedControl: FocusTarget?

    enum FocusTarget: Hashable {
        case section(TVLiveTVSection)
        case guide
        case providers
        case search
        case category(String)
        case channel(String)
        case retry
    }

    private let columns = Array(
        repeating: GridItem(.flexible(minimum: 250, maximum: 340), spacing: 34),
        count: 5
    )
    @State private var categoryCounts: [String: Int] = [:]

    private var scope: TVLiveTVVisibilityScope? {
        guard let providerID = service.selectedProviderID else { return nil }
        return TVLiveTVVisibilityScope(profileID: profileID ?? "local", providerID: providerID)
    }

    private var hidden: TVLiveTVVisibilitySnapshot { visibility.snapshot(for: scope) }
    private var visibleCategories: [String] { hidden.visibleCategories(service.categories) }
    private var visibleMatches: [LiveTVChannel] { hidden.visibleChannels(search.matches) }

    var body: some View {
        ZStack {
            TVKyroAmbientBackdrop()

            VStack(alignment: .leading, spacing: 22) {
                header
                if let progress = service.importProgress, !progress.isOnboarding, !progress.isTerminal {
                    TVCompactLiveRefreshLine(progress: progress)
                }
                controls
                content
            }
            .padding(.horizontal, 72)
            .padding(.top, TVTopMenuLayout.contentTopInset)
            .padding(.bottom, 38)
            .disabled(service.importProgress.map { $0.isOnboarding && !$0.isTerminal } ?? false)
            // Manual and automatic refreshes stay in place; only first-time setup is full screen.
            if let progress = service.importProgress, progress.isOnboarding,
               progress.providerID == service.selectedProviderID {
                TVLiveTVImportView(progress: progress, service: service,
                    onClose: { service.clearFinishedImport() },
                    onManage: { service.clearFinishedImport(); showsProviders = true })
            }
        }
        .modifier(LiveTVChannelCover(
            service: service,
            presenter: .list,
            isEnabled: !showsGuide && !showsProviders
        ))
        .fullScreenCover(isPresented: $showsGuide) {
            TVLiveTVGuideView(service: service, profileID: profileID,
                              initialCategory: guideCategory)
        }
        .fullScreenCover(isPresented: $showsProviders) {
            TVLiveTVProviderManagementView(service: service, profileID: profileID)
        }
        .sheet(item: $infoChannel, onDismiss: restoreAfterCover) { channel in
            TVLiveTVChannelInformationView(channel: channel, providerName: service.selectedProvider?.name)
        }
        .onExitCommand {
            if navigation.back() {
                // The grid's onAppear restores its stable category ID and scroll position.
            } else {
                onTopMenuFocusRequest()
            }
        }
        .task(id: service.selectedProviderID) {
            updateSearch()
            await service.prepareSelectedProvider()
            updateSearch()
        }
        .task(id: focusRequest) { claimEntryFocus() }
        .onAppear {
            service.presentation.surfaceAppeared(.list)
            if let saved = TVLiveTVBrowseMemory.restore(for: scope) { navigation = saved }
            if let category = navigation.selectedCategory, hidden.categories.contains(category) {
                _ = navigation.back()
            }
            updateSearch()
            updateCategoryCounts()
        }
        .onDisappear {
            TVLiveTVBrowseMemory.save(navigation, for: scope)
            search.cancel()
            if !showsGuide && !showsProviders { service.presentation.surfaceDisappeared(.list) }
        }
        .onChange(of: query) { updateSearch() }
        .onChange(of: navigation) { old, value in
            TVLiveTVBrowseMemory.save(value, for: scope)
            if old.section != value.section || old.selectedCategory != value.selectedCategory {
                updateSearch()
            }
        }
        .onChange(of: service.favoriteChannelIDs) { updateSearch() }
        .onChange(of: service.channelCatalogRevision) {
            updateSearch()
            updateCategoryCounts()
        }
        .onChange(of: visibility.revision) {
            if let category = navigation.selectedCategory, hidden.categories.contains(category) {
                _ = navigation.back()
            }
            updateSearch()
            updateCategoryCounts()
        }
        .onChange(of: service.selectedProviderID) {
            query = ""
            navigation = TVLiveTVBrowseMemory.restore(for: scope) ?? TVLiveTVBrowseNavigation()
            updateSearch()
            updateCategoryCounts()
        }
        .onChange(of: profileID) {
            navigation = TVLiveTVBrowseMemory.restore(for: scope) ?? TVLiveTVBrowseNavigation()
            updateSearch()
            updateCategoryCounts()
        }
        .onChange(of: focusedControl) { _, target in
            if !showsGuide && !showsProviders, let target { focusBeforeCover = target }
        }
        .onChange(of: showsGuide) { _, presented in
            if !presented { guideCategory = nil; restoreAfterCover() }
        }
        .onChange(of: showsProviders) { _, presented in
            if !presented { restoreAfterCover() }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Live TV")
                    .font(.system(size: 52, weight: .bold))
                Text(providerSummary)
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(Color.siloSecondaryText)
            }
            Spacer()
            if service.isLoading || service.isGuideLoading {
                ProgressView(service.isLoading ? "Loading channels…" : "Updating guide…")
                    .font(.system(size: 22, weight: .medium))
            }
        }
    }

    private var controls: some View {
        HStack(spacing: 14) {
            ForEach(TVLiveTVSection.allCases) { item in
                Button {
                    navigation.select(item)
                } label: {
                    Label(item.title, systemImage: item.symbol)
                }
                .buttonStyle(TVKyroChipStyle(isSelected: navigation.section == item))
                .focused($focusedControl, equals: .section(item))
                .onMoveCommand { if $0 == .up { onTopMenuFocusRequest() } }
            }

            Button { guideCategory = navigation.selectedCategory; showsGuide = true } label: {
                Label("TV Guide", systemImage: "calendar.day.timeline.left")
            }
            .buttonStyle(TVKyroChipStyle())
            .focused($focusedControl, equals: .guide)
            .onMoveCommand { if $0 == .up { onTopMenuFocusRequest() } }

            Button { showsProviders = true } label: {
                Label("Providers", systemImage: "antenna.radiowaves.left.and.right")
            }
            .buttonStyle(TVKyroChipStyle(isSelected: service.providers.isEmpty))
            .focused($focusedControl, equals: .providers)
            .onMoveCommand { if $0 == .up { onTopMenuFocusRequest() } }

            Spacer(minLength: 20)

            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                TextField("Search channels", text: $query)
                    .textFieldStyle(.plain)
            }
            .font(.system(size: 24))
            .padding(.horizontal, 20)
            .frame(width: 330, height: 54)
            .background(.ultraThinMaterial, in: Capsule())
            .focused($focusedControl, equals: .search)
            .onMoveCommand { if $0 == .up { onTopMenuFocusRequest() } }
        }
        .focusSection()
        .onMoveCommand { direction in
            // When there is no provider, the setup button is the only page
            // action. Every chip in this row must reach it with one Down.
            if direction == .down, service.providers.isEmpty {
                focusedControl = .retry
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if service.providers.isEmpty {
            statusPage(
                symbol: "antenna.radiowaves.left.and.right.slash",
                title: "Connect a Live TV provider",
                message: "Add an M3U playlist or Xtream Codes account to browse and watch channels.",
                buttonTitle: "Set Up Provider",
                action: { showsProviders = true }
            )
        } else if service.channels.isEmpty, service.isLoading {
            statusPage(symbol: "arrow.trianglehead.2.clockwise.rotate.90", title: "Loading channels",
                       message: "Kyro is securely connecting to \(service.selectedProvider?.name ?? "your provider").")
        } else if service.channels.isEmpty, let error = service.errorMessage {
            statusPage(symbol: "exclamationmark.triangle.fill", title: "Couldn’t load channels", message: error,
                       buttonTitle: "Retry", action: { Task { await service.refreshSelectedProvider() } })
        } else if service.channels.isEmpty {
            statusPage(symbol: "tv.slash", title: "No channels found",
                       message: "Refresh this provider or review its connection settings.",
                       buttonTitle: "Manage Providers", action: { showsProviders = true })
        } else if navigation.section == .categories && navigation.selectedCategory == nil {
            categoryGrid
        } else {
            channelGrid
        }
    }

    private var categoryGrid: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 28) {
                    categoryButton("All Channels", count: hidden.visibleChannels(service.channels).count, category: nil)
                    ForEach(visibleCategories, id: \.self) { category in
                        categoryButton(category, count: categoryCounts[category, default: 0], category: category)
                    }
                }
                .padding(.vertical, 18)
                .scrollTargetLayout()
            }
            .scrollPosition(id: Binding(
                get: { navigation.scrollAnchor },
                set: { navigation.scrollAnchor = $0 }
            ))
            .onAppear {
                if let category = navigation.focusedCategory, visibleCategories.contains(category) {
                    let anchor = navigation.scrollAnchor.flatMap {
                        $0 == "__all__" || visibleCategories.contains($0) ? $0 : nil
                    } ?? category
                    proxy.scrollTo(anchor, anchor: .top)
                    focusedControl = .category(category)
                }
            }
        }
        .focusSection()
    }

    private func categoryButton(_ title: String, count: Int, category: String?) -> some View {
        Button {
            openCategory(category)
        } label: {
            VStack(alignment: .leading, spacing: 12) {
                Image(systemName: category == nil ? "rectangle.stack" : "square.grid.2x2")
                    .font(.system(size: 38, weight: .semibold))
                    .foregroundStyle(KyroTheme.accentInk)
                Text(title).font(.system(size: 27, weight: .semibold)).lineLimit(2)
                Text("\(count) channels")
                    .font(.system(size: 20))
                    .foregroundStyle(Color.siloSecondaryText)
            }
            .frame(maxWidth: .infinity, minHeight: 140, alignment: .leading)
            .padding(24)
            .background(Color.siloSurface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
        .buttonStyle(TVKyroCardFocusStyle(cornerRadius: 20))
        .focused($focusedControl, equals: .category(category ?? "__all__"))
        .id(category ?? "__all__")
        .contextMenu {
            Button(TVLiveTVCategoryMenuAction.browse.title, systemImage: "rectangle.stack") { openCategory(category) }
            Button(TVLiveTVCategoryMenuAction.guide.title, systemImage: "calendar.day.timeline.left") {
                guideCategory = category
                showsGuide = true
            }
            if let category {
                Button(TVLiveTVCategoryMenuAction.hide.title, systemImage: "eye.slash") {
                    hideCategory(category)
                }
            }
        }
    }

    private func openCategory(_ category: String?) {
        navigation.openCategory(category)
    }

    private var channelGrid: some View {
        let matches = visibleMatches
        return VStack(alignment: .leading, spacing: 10) {
            if let notice = service.errorMessage ?? service.catalogNotice ?? service.guideMessage {
                Label(notice, systemImage: "info.circle")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(Color.siloSecondaryText)
                    .lineLimit(2)
            }

            if search.isSearching && matches.isEmpty {
                ProgressView("Filtering channels…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if matches.isEmpty {
                statusPage(symbol: navigation.section == .favorites ? "star.slash" : "magnifyingglass",
                           title: navigation.section == .favorites ? "No favorite channels" : "No matching channels",
                           message: navigation.section == .favorites
                               ? "Manage favorites from channel playback."
                               : "Try a different search or category.")
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 34) {
                        ForEach(matches) { channel in
                            TVLiveTVChannelCard(
                                channel: channel,
                                program: service.programPair(for: channel),
                                isFavorite: service.isFavorite(channel),
                                isPlaying: service.playerSession.activeChannelID == channel.id,
                                focus: $focusedControl,
                                play: { service.choose(channel, from: .list) },
                                toggleFavorite: { service.toggleFavorite(channel) },
                                hide: { hideChannel(channel) },
                                showInformation: { infoChannel = channel }
                            )
                        }
                    }
                    .padding(.vertical, 18)
                }
                .focusSection()
            }
        }
    }

    private func statusPage(
        symbol: String,
        title: String,
        message: String,
        buttonTitle: String? = nil,
        action: (() -> Void)? = nil
    ) -> some View {
        VStack(spacing: 20) {
            Image(systemName: symbol)
                .font(.system(size: 64, weight: .semibold))
                .foregroundStyle(KyroTheme.accentInk)
            Text(title).font(.system(size: 34, weight: .bold))
            Text(message)
                .font(.system(size: 23))
                .foregroundStyle(Color.siloSecondaryText)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 760)
            if let buttonTitle, let action {
                Button(buttonTitle, action: action)
                    .buttonStyle(TVKyroChipStyle(isSelected: true))
                    .focused($focusedControl, equals: .retry)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func updateCategoryCounts() {
        var counts: [String: Int] = [:]
        for channel in service.channels where hidden.channels[channel.id] == nil {
            counts[channel.category, default: 0] += 1
        }
        categoryCounts = counts
    }

    private func hideChannel(_ channel: LiveTVChannel) {
        let matches = visibleMatches
        let next = matches.firstIndex(where: { $0.id == channel.id }).flatMap { index in
            matches.indices.contains(index + 1) ? matches[index + 1].id
                : (index > 0 ? matches[index - 1].id : nil)
        }
        visibility.hide(channel, in: scope)
        focusedControl = next.map(FocusTarget.channel) ?? .section(navigation.section)
    }

    private func hideCategory(_ category: String) {
        let next = navigation.hideCategory(category, visibleCategories: visibleCategories)
        visibility.hideCategory(category, in: scope)
        focusedControl = next.map(FocusTarget.category) ?? .section(.categories)
    }

    private var providerSummary: String {
        guard let provider = service.selectedProvider else { return "No provider connected" }
        let suffix = provider.channelCount == 1 ? "channel" : "channels"
        return "\(provider.name) · \(provider.channelCount) \(suffix)"
    }

    private func updateSearch() {
        search.update(
            channels: hidden.visibleChannels(service.channels),
            query: query,
            category: navigation.selectedCategory,
            favoritesOnly: navigation.section == .favorites,
            favoriteIDs: service.favoriteChannelIDs,
            includeGroups: false
        )
    }

    private func claimEntryFocus() {
        guard !isTopMenuFocused else { return }
        Task { @MainActor in
            await Task.yield()
            guard !isTopMenuFocused else { return }
            focusedControl = .section(navigation.section)
        }
    }

    private func restoreAfterCover() {
        guard !isTopMenuFocused, let target = focusBeforeCover else { return }
        focusedControl = Self.restorationTarget(target,
                                                channelIDs: Set(visibleMatches.map(\.id)),
                                                categories: Set(visibleCategories),
                                                section: navigation.section)
    }

    static func restorationTarget(_ target: FocusTarget, channelIDs: Set<String>,
                                  categories: Set<String>, section: TVLiveTVSection) -> FocusTarget {
        switch target {
        case .channel(let id):
            return channelIDs.contains(id) ? target : .section(section)
        case .category(let id):
            return id == "__all__" || categories.contains(id) ? target : .section(section)
        default:
            return target
        }
    }
}

private struct TVLiveTVChannelCard: View {
    let channel: LiveTVChannel
    let program: LiveTVProgramPair
    let isFavorite: Bool
    let isPlaying: Bool
    let focus: FocusState<TVLiveTVRootView.FocusTarget?>.Binding
    let play: () -> Void
    let toggleFavorite: () -> Void
    let hide: () -> Void
    let showInformation: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button(action: play) {
                ZStack(alignment: .bottomLeading) {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(Color.siloSurface)
                        .aspectRatio(16 / 9, contentMode: .fit)
                    LiveTVChannelLogo(channel: channel, size: CGSize(width: 150, height: 78), placeholderStyle: .clear)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    LinearGradient(colors: [.clear, .black.opacity(0.78)], startPoint: .center, endPoint: .bottom)
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    HStack(spacing: 8) {
                        if program.current != nil {
                            Text("LIVE")
                                .font(.system(size: 16, weight: .black))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(KyroTheme.live, in: Capsule())
                        }
                        if isPlaying { TVKyroPlayingBadge() }
                    }
                    .padding(14)
                }
            }
            .buttonStyle(TVKyroCardFocusStyle(cornerRadius: 18))
            .focused(focus, equals: .channel(channel.id))
            .accessibilityLabel("Watch \(channel.name)")
            // A native tvOS context menu owns the long Select press. It does not
            // also dispatch the Button's short-press action, and dismissing it
            // returns to this stable channel ID in the existing lazy grid.
            .contextMenu {
                Button(TVLiveTVChannelMenuAction.watch.title(isFavorite: isFavorite),
                       systemImage: "play.fill", action: play)
                Button(TVLiveTVChannelMenuAction.favorite.title(isFavorite: isFavorite),
                       systemImage: isFavorite ? "star.slash" : "star", action: toggleFavorite)
                Button(TVLiveTVChannelMenuAction.hide.title(isFavorite: isFavorite),
                       systemImage: "eye.slash", action: hide)
                Button(TVLiveTVChannelMenuAction.information.title(isFavorite: isFavorite),
                       systemImage: "info.circle", action: showInformation)
            }

            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(channel.name)
                        .font(.system(size: 23, weight: .semibold))
                        .lineLimit(1)
                    Text(program.current?.title ?? channel.category)
                        .font(.system(size: 18))
                        .foregroundStyle(Color.siloSecondaryText)
                        .lineLimit(1)
                    if let next = program.next {
                        Text("Next: \(next.title)")
                            .font(.system(size: 16))
                            .foregroundStyle(Color.siloSecondaryText.opacity(0.8))
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 4)
                if isFavorite {
                    Image(systemName: "star.fill")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(KyroTheme.highlight)
                        .accessibilityLabel("Favorite")
                }
            }
        }
    }
}

struct TVLiveTVProviderManagementView: View {
    @Bindable var service: LiveTVService
    let profileID: String?
    @Environment(\.dismiss) private var dismiss
    @State private var localError: String?
    @State private var providerToRemove: LiveTVProvider?
    @State private var showsPhoneSetup = false
    @State private var showsAddProvider = false
    @State private var showsHiddenManagement = false
    @State private var phoneSetupAfterAddSheet = false
    @State private var savedProviderID: UUID?
    @State private var startWatchingAfterPairing = false
    @State private var refresher = TVProviderRefreshCoordinator.shared
    @State private var vod = XtreamVODService.shared
    @FocusState private var focus: TVLiveTVProviderFocus?

    /// Only a first-time setup started from this page takes over the screen.
    private var onboardingProgress: LiveTVImportProgress? {
        guard let progress = service.importProgress, progress.isOnboarding,
              progress.providerID == service.selectedProviderID else { return nil }
        return progress
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 34) {
                header
                providerList
                // Progress is below the focusable provider rows. Its changing
                // height/content must not move their frames during a refresh.
                TVProviderRefreshPanel(coordinator: refresher, service: service, vod: vod)
            }
            .padding(.horizontal, 120)
            .padding(.vertical, 68)
        }
        .disabled(onboardingProgress != nil)
        .background(TVKyroAmbientBackdrop())
        .overlay {
            if let progress = onboardingProgress {
                TVLiveTVImportView(progress: progress, service: service,
                    onClose: { service.clearFinishedImport(); dismiss() },
                    onManage: { service.clearFinishedImport() })
            }
        }
        // Back/Menu always leaves the screen. While a text field is editing, the system keyboard
        // takes Menu first, so typing (and the nearby-iPhone keyboard) is unaffected.
        .onExitCommand { if onboardingProgress == nil { dismiss() } }
        .onAppear {
            if focus == nil { focus = TVLiveTVProviderFocusPlanner.initialFocus(providerIDs: service.providers.map(\.id)) }
        }
        .onChange(of: service.providers.map(\.id)) { _, ids in
            if let target = TVLiveTVProviderFocusPlanner.relocationIfRemoved(focus, providerIDs: ids) {
                focus = target
            }
        }
        .sheet(isPresented: $showsAddProvider, onDismiss: {
            if phoneSetupAfterAddSheet {
                phoneSetupAfterAddSheet = false
                showsPhoneSetup = true
                return
            }
            let saved = savedProviderID
            savedProviderID = nil
            restoreFocus(TVLiveTVProviderFocusPlanner.afterAddProvider(savedProviderID: saved))
            if let saved { Task { await service.startSetup(providerID: saved) } }
        }) {
            TVAddProviderSheet(service: service,
                onSaved: { id in savedProviderID = id; showsAddProvider = false },
                onCancel: { showsAddProvider = false },
                onPhoneSetup: {
                    phoneSetupAfterAddSheet = true
                    showsAddProvider = false
                })
        }
        .fullScreenCover(isPresented: $showsPhoneSetup, onDismiss: {
            if startWatchingAfterPairing {
                startWatchingAfterPairing = false
                dismiss()
            } else { restoreFocus(.phoneSetup) }
        }) {
            TVLiveTVPairingView(service: service,
                onStartWatching: { startWatchingAfterPairing = true })
        }
        .fullScreenCover(isPresented: $showsHiddenManagement, onDismiss: {
            restoreFocus(.hiddenManagement)
        }) {
            TVLiveTVHiddenManagementView(service: service, profileID: profileID)
        }
        .confirmationDialog(
            "Remove \(providerToRemove?.name ?? "provider")?",
            isPresented: Binding(get: { providerToRemove != nil }, set: { if !$0 { providerToRemove = nil } })
        ) {
            Button("Remove Provider", role: .destructive) {
                guard let provider = providerToRemove else { return }
                providerToRemove = nil
                let remaining = service.providers.map(\.id).filter { $0 != provider.id }
                Task {
                    await service.removeProvider(provider.id)
                    await XtreamVODService.shared.remove(providerID: provider.id)
                }
                restoreFocus(TVLiveTVProviderFocusPlanner.afterRemoval(remainingProviderIDs: remaining))
            }
            Button("Cancel", role: .cancel) {
                if let provider = providerToRemove { restoreFocus(.remove(provider.id)) }
                providerToRemove = nil
            }
        }
    }

    /// The screen's own Back control, directly above the list. A toolbar button in the top-right
    /// corner was the only thing above the content, so Up from the left-aligned controls found
    /// nothing until focus was moved sideways under it.
    private var header: some View {
        HStack(spacing: 24) {
            Button { dismiss() } label: { Label("Live TV", systemImage: "chevron.left") }
                .buttonStyle(TVKyroChipStyle())
                .focused($focus, equals: .back)
            VStack(alignment: .leading, spacing: 4) {
                Text("Live TV Providers").font(.system(size: 46, weight: .bold))
                Text(refreshStatus)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(Color.siloSecondaryText)
                    .lineLimit(1)
                    .frame(height: 24, alignment: .leading)
                    .accessibilityIdentifier("providers.refreshStatus")
            }
            .frame(width: 510, alignment: .leading)
            Spacer()
            Button { showsPhoneSetup = true } label: {
                Label("Set up with iPhone", systemImage: "iphone.and.arrow.forward")
            }
            .buttonStyle(TVKyroChipStyle())
            .focused($focus, equals: .phoneSetup)
            Button { showsAddProvider = true } label: { Label("Add Provider", systemImage: "plus") }
                .buttonStyle(TVKyroChipStyle(isSelected: true, fontSize: 28, minHeight: 70))
                .focused($focus, equals: .addProvider)
                .accessibilityIdentifier("providers.add")
        }
        .focusSection()
    }

    private var refreshStatus: String {
        switch refresher.phase {
        case .idle: " "
        case .running: "Refreshing provider catalogs…"
        case .finished(_, _, let message): message
        }
    }

    private func restoreFocus(_ target: TVLiveTVProviderFocus) {
        // Called only after a modal dismisses or the user explicitly removes
        // a provider. Do not queue a write that can outlive the user's next move.
        focus = target
    }

    private var providerList: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Text("Connected Providers").font(.system(size: 34, weight: .bold))
                Spacer()
                Button("Manage Hidden Channels and Categories", systemImage: "eye.slash") {
                    showsHiddenManagement = true
                }
                .buttonStyle(TVKyroChipStyle())
                .focused($focus, equals: .hiddenManagement)
            }
            if service.providers.isEmpty {
                Text("No providers yet. Choose Add Provider, or Set up with iPhone to send one without typing. Credentials are stored in the Apple TV keychain.")
                    .font(.system(size: 28))
                    .foregroundStyle(Color.siloSecondaryText)
            } else {
                ForEach(service.providers) { provider in
                    HStack(spacing: 18) {
                        Button {
                            service.selectProvider(provider.id)
                            if provider.liveEnabled { Task { await service.prepareSelectedProvider() } }
                        } label: {
                            HStack(spacing: 18) {
                                Image(systemName: service.selectedProviderID == provider.id
                                      ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(KyroTheme.accentInk)
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(provider.name).font(.system(size: 26, weight: .semibold))
                                    Text(TVProviderSummary.line(for: provider))
                                        .font(.system(size: 19))
                                        .foregroundStyle(Color.siloSecondaryText)
                                }
                                Spacer()
                            }
                            .padding(20)
                            .background(Color.siloSurface, in: RoundedRectangle(cornerRadius: 16))
                        }
                        .buttonStyle(TVKyroCardFocusStyle(cornerRadius: 16))
                        .focused($focus, equals: .provider(provider.id))

                        Button {
                            service.selectProvider(provider.id)
                            startRefresh(provider.id, scope: .all)
                        } label: {
                            Label(refresher.isRunning(providerID: provider.id) ? "Refreshing…" : "Refresh",
                                  systemImage: "arrow.clockwise")
                        }
                        .buttonStyle(TVKyroChipStyle())
                        .frame(width: 230)
                        .focused($focus, equals: .refresh(provider.id))
                        .accessibilityIdentifier("providers.refresh")

                        Button(role: .destructive) { providerToRemove = provider } label: {
                            Label("Remove", systemImage: "trash")
                        }
                        .buttonStyle(TVKyroChipStyle(isDestructive: true))
                        .focused($focus, equals: .remove(provider.id))
                    }
                    if provider.kind == .xtream {
                        TVProviderVODManagementView(provider: provider, service: service,
                            refresher: refresher, onRefresh: { startRefresh(provider.id, scope: $0) })
                    }
                }
            }

            if let message = localError ?? (refresher.isRunning ? nil : service.errorMessage) {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(KyroTheme.live)
                    .font(.system(size: 20, weight: .medium))
            }
        }
        .focusSection()
    }

    /// Every manual refresh entry point on this page goes through one coordinator, so a press
    /// always produces visible feedback and never starts a second concurrent refresh.
    private func startRefresh(_ providerID: UUID, scope: TVProviderRefreshScope) {
        localError = nil
        switch refresher.refresh(providerID: providerID, scope: scope, liveTV: service, vod: vod) {
        case .started, .nothingToRefresh: break
        case .alreadyRunning: localError = "A refresh is already in progress. It will finish before another can start."
        }
    }
}

private enum TVAddProviderFocus: Hashable { case type, name, cancel, save, phone }

/// The typed provider form, shown only on request in a sheet so the Providers page leads with
/// connected providers instead of a permanently expanded form.
struct TVAddProviderSheet: View {
    @Bindable var service: LiveTVService
    let onSaved: (UUID) -> Void
    let onCancel: () -> Void
    let onPhoneSetup: () -> Void
    @State private var kind: LiveTVProviderKind = .m3u
    @State private var name = "My Provider"
    @State private var playlistURL = ""
    @State private var xmltvURL = ""
    @State private var serverURL = ""
    @State private var username = ""
    @State private var password = ""
    @State private var formStep = 1
    @State private var contentSelection = IPTVContentSelection.newProvider(for: .m3u)
    @State private var isSubmitting = false
    @State private var localError: String?
    @FocusState private var focus: TVAddProviderFocus?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                HStack(spacing: 24) {
                    Text("Add Provider").font(.system(size: 46, weight: .bold))
                    Spacer()
                    Button { onPhoneSetup() } label: {
                        Label("Set up with iPhone", systemImage: "iphone.and.arrow.forward")
                    }
                    .buttonStyle(TVKyroChipStyle())
                    .focused($focus, equals: .phone)
                    Button("Cancel", action: onCancel)
                        .buttonStyle(TVKyroChipStyle())
                        .focused($focus, equals: .cancel)
                        .accessibilityIdentifier("providers.add.cancel")
                }
                .focusSection()
                addProviderForm
                if let localError {
                    Label(localError, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(KyroTheme.live).font(.system(size: 22, weight: .medium))
                }
            }
            .padding(.horizontal, 120)
            .padding(.vertical, 68)
        }
        .background(TVKyroAmbientBackdrop())
        .onAppear { focus = .type }
        .onExitCommand { if formStep == 2 { formStep = 1 } else { onCancel() } }
        .accessibilityIdentifier("providers.add.sheet")
    }

    private var addProviderForm: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text(formStep == 1 ? "Step 1 · Enter Provider Information" : "Step 2 · Choose Content")
                .font(.system(size: 34, weight: .bold))
            if formStep == 1 {
            Picker("Provider Type", selection: $kind) {
                Text("M3U Playlist").tag(LiveTVProviderKind.m3u)
                Text("Xtream Codes").tag(LiveTVProviderKind.xtream)
            }
            .pickerStyle(.segmented)
            .font(.system(size: 30, weight: .semibold))
            .frame(minHeight: 76)
            .focused($focus, equals: .type)
            .accessibilityIdentifier("liveTV.providerType")

            TextField("Provider name", text: $name)
                .modifier(TVLiveTVProviderFieldStyle())
            if kind == .m3u {
                TextField("M3U playlist URL", text: $playlistURL)
                    .modifier(TVLiveTVProviderFieldStyle())
                TextField("XMLTV guide URL (optional)", text: $xmltvURL)
                    .modifier(TVLiveTVProviderFieldStyle())
            } else {
                TextField("Server URL", text: $serverURL)
                    .modifier(TVLiveTVProviderFieldStyle())
                TextField("Username", text: $username)
                    .modifier(TVLiveTVProviderFieldStyle())
                SecureField("Password", text: $password)
                    .modifier(TVLiveTVProviderFieldStyle())
            }

            Text("Kyro stores provider configuration in the device keychain. URLs and credentials are never written into the app bundle.")
                .font(.system(size: 27))
                .foregroundStyle(Color.siloSecondaryText)
            Button("Next · Choose Content") { formStep = 2 }
                .buttonStyle(TVKyroChipStyle(isSelected: true, fontSize: 29, minHeight: 76))
                .disabled(!canSave)
                .focused($focus, equals: .save)
            } else {
                TVIPTVContentSelectionView(selection: $contentSelection, kind: kind)
                HStack(spacing: 24) {
                    Button("Back to Provider Details") { formStep = 1 }
                        .buttonStyle(TVKyroChipStyle())
                    Button("Add Service") { saveProvider() }
                        .buttonStyle(TVKyroChipStyle(isSelected: true, fontSize: 29, minHeight: 76))
                        .disabled(!canSave || !contentSelection.isValid(for: kind) || isSubmitting)
                        .focused($focus, equals: .save)
                }
            }
        }
        .onChange(of: kind) { contentSelection = .newProvider(for: kind) }
        .focusSection()
    }

    private var canSave: Bool {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        switch kind {
        case .m3u:
            return !playlistURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .xtream:
            return !serverURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !password.isEmpty
        }
    }

    private func saveProvider() {
        guard !isSubmitting, contentSelection.isValid(for: kind), canSave else { return }
        isSubmitting = true
        do {
            let id: UUID
            switch kind {
            case .m3u:
                id = try service.saveConfiguration(name: name, playlistURL: playlistURL, xmltvURL: xmltvURL,
                                                   selection: contentSelection)
            case .xtream:
                id = try service.saveXtreamConfiguration(
                    name: name, serverURL: serverURL, username: username, password: password,
                    selection: contentSelection
                )
            }
            localError = nil
            password = ""
            isSubmitting = false
            // The Providers page starts first-time setup once the sheet has dismissed, then
            // lands focus on the new provider's row.
            onSaved(id)
        } catch {
            isSubmitting = false
            localError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}

struct TVIPTVContentSelectionView: View {
    @Binding var selection: IPTVContentSelection
    let kind: LiveTVProviderKind

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Choose what you’d like to import from this service. You can change these options later.")
                .font(.system(size: 28)).foregroundStyle(Color.siloSecondaryText)
            HStack(spacing: 22) {
                card("Live TV", detail: "Live channels and TV Guide", symbol: "tv",
                     selected: selection.liveTV, available: true) {
                    selection.liveTV.toggle()
                }
                card("VOD Movies", detail: kind == .xtream ? "On-demand movies" : "Unavailable for M3U playlists",
                     symbol: "film", selected: selection.movies, available: kind == .xtream) {
                    selection.movies.toggle()
                }
                card("VOD TV Series", detail: kind == .xtream ? "Shows, seasons, and episodes" : "Unavailable for M3U playlists",
                     symbol: "tv.and.hifispeaker.fill", selected: selection.series, available: kind == .xtream) {
                    selection.series.toggle()
                }
            }
            if !selection.isValid(for: kind) {
                Text("Select at least one available content type to add this service.")
                    .font(.system(size: 24, weight: .semibold)).foregroundStyle(KyroTheme.live)
            }
        }
        .focusSection()
    }

    private func card(_ title: String, detail: String, symbol: String,
                      selected: Bool, available: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 17) {
                HStack {
                    Image(systemName: symbol).font(.system(size: 36))
                    Spacer()
                    Image(systemName: selected ? "checkmark.square.fill" : "square")
                        .font(.system(size: 38)).foregroundStyle(selected ? KyroTheme.accentInk : Color.siloSecondaryText)
                }
                Text(title).font(.system(size: 30, weight: .bold))
                Text(detail).font(.system(size: 23)).foregroundStyle(Color.siloSecondaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(26)
            .frame(maxWidth: .infinity, minHeight: 185, alignment: .leading)
            .background(Color.siloSurface, in: RoundedRectangle(cornerRadius: 20))
        }
        .buttonStyle(TVKyroCardFocusStyle(cornerRadius: 20))
        .disabled(!available)
        .accessibilityLabel("\(title), \(available ? (selected ? "selected" : "not selected") : "unavailable")")
    }
}

private struct TVProviderVODManagementView: View {
    let provider: LiveTVProvider
    @Bindable var service: LiveTVService
    let refresher: TVProviderRefreshCoordinator
    let onRefresh: (TVProviderRefreshScope) -> Void
    @State private var vod = XtreamVODService.shared
    @State private var movieCount = 0
    @State private var seriesCount = 0
    @State private var draftSelection = IPTVContentSelection.legacyLiveOnly

    private var currentProgress: XtreamVODImportProgress? {
        vod.progress?.providerID == provider.id ? vod.progress : nil
    }

    private var capability: String {
        guard provider.vodEnabled else { return "Not checked — VOD is disabled" }
        guard let progress = currentProgress else {
            return vod.refreshedAt(providerID: provider.id) == nil ? "Not checked — refresh to discover" : "Previously loaded"
        }
        switch progress.stage {
        case .ready: return movieCount + seriesCount > 0 ? "Catalog available" : "Provider returned empty catalogs"
        case .failed:
            if progress.failure == .unsupported { return "Unsupported VOD endpoint" }
            if progress.failure == .authentication { return "Authentication failed" }
            return "Failed — \(progress.message ?? "check connection and retry")"
        case .cancelled: return "Cancelled"
        default: return "Checking provider capabilities and catalogs…"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 17) {
            Text("Content Libraries · \(provider.name)")
                .font(.system(size: 29, weight: .bold))
            Text("Live TV: \(draftSelection.liveTV ? "Selected" : "Not selected") · \(provider.channelCount.formatted()) last imported")
            Text("Movies: \(draftSelection.movies ? "Selected" : "Not selected") · \(movieCount.formatted()) cached")
            Text("Series: \(draftSelection.series ? "Selected" : "Not selected") · \(seriesCount.formatted()) cached")
            Text("VOD capability: \(capability)")
            Text("Last successful refresh: \(vod.refreshedAt(providerID: provider.id)?.formatted(date: .abbreviated, time: .shortened) ?? "Never")")
            HStack(spacing: 18) {
                Button(draftSelection.liveTV ? "Disable Live TV" : "Enable Live TV") {
                    draftSelection.liveTV.toggle()
                }
                .buttonStyle(TVKyroChipStyle(isSelected: draftSelection.liveTV))
                .disabled(draftSelection.liveTV && !draftSelection.movies && !draftSelection.series)
                Button(draftSelection.movies ? "Disable Movies" : "Enable Movies") {
                    draftSelection.movies.toggle()
                }.buttonStyle(TVKyroChipStyle(isSelected: draftSelection.movies))
                    .disabled(provider.kind != .xtream || (draftSelection.movies && !draftSelection.liveTV && !draftSelection.series))
                Button(draftSelection.series ? "Disable Series" : "Enable Series") {
                    draftSelection.series.toggle()
                }.buttonStyle(TVKyroChipStyle(isSelected: draftSelection.series))
                    .disabled(provider.kind != .xtream || (draftSelection.series && !draftSelection.liveTV && !draftSelection.movies))
            }
            HStack(spacing: 18) {
                Button("Apply & Refresh Selected") {
                    guard !refresher.isRunning else { onRefresh(.all); return }
                    guard service.setContentSelection(draftSelection, for: provider.id) else { return }
                    onRefresh(.all)
                }
                .buttonStyle(TVKyroChipStyle(isSelected: true))
                .disabled(!draftSelection.isValid(for: provider.kind))
                // Stays focusable when Movies and Series are off so a press explains what to enable.
                Button(refresher.isRunning(providerID: provider.id) ? "Refreshing…" : "Refresh Movies & Series") {
                    onRefresh(.vodOnly)
                }
                .buttonStyle(TVKyroChipStyle())
                .accessibilityIdentifier("providers.refreshVOD")
                Button("Clear VOD Cache") {
                    guard vod.activeProviderID != provider.id else { return }
                    Task { await vod.clearCache(providerID: provider.id); await loadCounts() }
                }
                    .buttonStyle(TVKyroChipStyle(isDestructive: true))
            }
            Text("Changing selections does not download or delete catalogs. Choose Apply & Refresh Selected to import them.")
                .foregroundStyle(Color.siloSecondaryText)
        }
        .font(.system(size: 22))
        .padding(30)
        .background(Color.siloSurface.opacity(0.75), in: RoundedRectangle(cornerRadius: 20))
        .task(id: vod.revision) { await loadCounts() }
        .onAppear { draftSelection = provider.contentSelection }
        .focusSection()
    }

    private func loadCounts() async {
        movieCount = await vod.count(providerID: provider.id, kind: .movie)
        seriesCount = await vod.count(providerID: provider.id, kind: .series)
    }
}

private struct TVLiveTVProviderFieldStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .font(.system(size: 30))
            .padding(.horizontal, 24)
            .frame(minHeight: 72)
            .background(Color.siloSurface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

/// Stable, full-screen setup surface shared by typed and phone-paired providers.
/// Only source-record stages use a determinate bar; no overall percentage is invented.
enum TVProviderSetupState {
    static func isComplete(live: LiveTVImportStage, vodEnabled: Bool,
                           vod: XtreamVODImportStage?) -> Bool {
        isComplete(live: live, liveSelected: true, vodEnabled: vodEnabled, vod: vod)
    }

    static func isComplete(live: LiveTVImportStage, liveSelected: Bool, vodEnabled: Bool,
                           vod: XtreamVODImportStage?) -> Bool {
        guard !liveSelected || live == .ready || live == .failed || live == .cancelled else { return false }
        guard vodEnabled else { return true }
        return vod == .ready || vod == .failed || vod == .cancelled
    }
}

struct TVLiveTVImportView: View {
    let progress: LiveTVImportProgress
    @Bindable var service: LiveTVService
    let onClose: () -> Void
    let onManage: () -> Void
    @State private var vod = XtreamVODService.shared
    @State private var vodAttempted = false
    @State private var vodBlocked = false
    @State private var browseKind: XtreamVODKind?
    @State private var cachedMovieCount = 0
    @State private var cachedSeriesCount = 0
    @FocusState private var actionFocus: CompletionAction?
    private enum CompletionAction: Hashable { case start, movie, series, manage }

    private var provider: LiveTVProvider? { service.providers.first { $0.id == progress.providerID } }
    private var liveSelected: Bool { provider?.liveEnabled == true }
    private var vodEnabled: Bool { provider?.kind == .xtream && provider?.vodEnabled == true }
    private var vodProgress: XtreamVODImportProgress? {
        guard vodAttempted, vod.progress?.providerID == progress.providerID else { return nil }
        return vod.progress
    }
    private var complete: Bool {
        TVProviderSetupState.isComplete(live: progress.stage, liveSelected: liveSelected,
                                        vodEnabled: vodEnabled, vod: vodProgress?.stage)
    }
    private var liveFailed: Bool { liveSelected && (progress.stage == .failed || progress.stage == .cancelled) }
    private var vodFailed: Bool { vodProgress?.stage == .failed || vodProgress?.stage == .cancelled }
    private var hasIssues: Bool { liveFailed || vodFailed }

    private var stageTitle: String {
        if progress.isTerminal, vodEnabled, let stage = vodProgress?.stage {
            switch stage {
            case .connecting: return "Discovering VOD capabilities"
            case .downloading(.movie): return "Loading Movies"
            case .importing(.movie): return "Importing Movies"
            case .downloading(.series): return "Loading Series"
            case .importing(.series): return "Importing Series"
            case .ready: return liveFailed ? "Setup finished with issues" : "Setup complete"
            case .failed: return "VOD catalog failed"
            case .cancelled: return "VOD catalog cancelled"
            }
        }
        switch progress.stage {
        case .connecting: return "Connecting to provider"
        case .downloading: return "Downloading channel catalog"
        case .importing: return "Importing Live TV"
        case .categories: return "Preparing channel categories"
        case .guide: return "Preparing TV Guide"
        case .saving: return "Saving and finalizing"
        case .ready: return vodBlocked ? "Another VOD refresh is in progress" : vodEnabled ? "Discovering VOD capabilities" : "Setup complete"
        case .failed: return vodEnabled ? "Discovering VOD capabilities" : "Setup failed"
        case .cancelled: return "Setup cancelled"
        }
    }

    var body: some View {
        ZStack {
            TVKyroAmbientBackdrop()
            LinearGradient(colors: [KyroTheme.accentInk.opacity(0.12), .clear, .black.opacity(0.24)],
                           startPoint: .topLeading, endPoint: .bottomTrailing).ignoresSafeArea()
            VStack(alignment: .leading, spacing: 34) {
                Text("KYRO  /  PROVIDER SETUP")
                    .font(.system(size: 24, weight: .bold)).tracking(5)
                    .foregroundStyle(KyroTheme.accentInk)
                Text(complete ? (preferredAction == .manage ? "Setup Needs Attention" : hasIssues ? "Your Entertainment Is Ready — With Issues" : "Your Entertainment Is Ready")
                              : "Setting Up Your Entertainment")
                    .font(.system(size: 62, weight: .heavy))
                Text(progress.providerName)
                    .font(.system(size: 32, weight: .semibold)).foregroundStyle(Color.siloSecondaryText)
                HStack(spacing: 18) {
                    Image(systemName: complete && !hasIssues ? "checkmark.circle.fill" : hasIssues ? "exclamationmark.triangle.fill" : "arrow.down.circle")
                        .foregroundStyle(KyroTheme.accentInk)
                    Text(stageTitle).font(.system(size: 36, weight: .bold))
                    if progress.stage == .importing, let fraction = progress.count.fraction {
                        Text("\(Int((fraction * 100).rounded(.down)))%")
                            .font(.system(size: 32, weight: .bold).monospacedDigit())
                    }
                }
                .frame(height: 56)
                Group {
                    if progress.stage == .importing, let fraction = progress.count.fraction {
                        ProgressView(value: fraction)
                    } else if !complete {
                        ProgressView()
                    } else {
                        ProgressView(value: hasIssues ? 0 : 1)
                    }
                }
                .tint(KyroTheme.accentInk)
                .scaleEffect(x: 1, y: 2.5, anchor: .center)
                .frame(height: 24)
                HStack(spacing: 24) {
                    catalogCard("Live TV", count: liveSelected ? progress.count.accepted : nil,
                                status: liveStatus, detail: liveSelected ? recordLine : "Not selected")
                    catalogCard("Movies", count: displayedVODCount(.movie), status: vodStatus(.movie),
                                detail: vodRecordLine(.movie))
                    catalogCard("Series", count: displayedVODCount(.series), status: vodStatus(.series),
                                detail: vodRecordLine(.series))
                }
                if let message = vodProgress?.message, vodFailed {
                    Text(message).font(.system(size: 25)).foregroundStyle(KyroTheme.live)
                } else if let message = progress.message, liveFailed || complete {
                    Text(message).font(.system(size: 25))
                        .foregroundStyle(message.contains("could not") || liveFailed ? KyroTheme.live : Color.siloSecondaryText)
                } else if progress.count.rejected > 0 {
                    Text(skippedLine).font(.system(size: 22)).foregroundStyle(Color.siloSecondaryText)
                }
                actions
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 100).padding(.top, 64)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .task(id: progress.isTerminal) {
            guard progress.isTerminal, vodEnabled, !vodAttempted else { return }
            guard vod.activeProviderID == nil else { vodBlocked = true; return }
            vodBlocked = false
            vodAttempted = true
            await vod.refresh(providerID: progress.providerID, liveTV: service)
        }
        .task(id: vod.revision) {
            cachedMovieCount = await vod.count(providerID: progress.providerID, kind: .movie)
            cachedSeriesCount = await vod.count(providerID: progress.providerID, kind: .series)
        }
        .fullScreenCover(isPresented: Binding(get: { browseKind != nil }, set: { if !$0 { browseKind = nil } })) {
            if let kind = browseKind, let provider {
                TVXtreamVODView(provider: provider, kind: kind, focusRequest: 0,
                                isTopMenuFocused: false, onMoveUp: nil, topInset: 70)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: progress.stage)
        .animation(.easeInOut(duration: 0.25), value: vodProgress?.stage)
        .onChange(of: complete) { if complete { actionFocus = preferredAction } }
        .onChange(of: cachedMovieCount) { if complete { actionFocus = preferredAction } }
        .onChange(of: cachedSeriesCount) { if complete { actionFocus = preferredAction } }
        .onChange(of: progress.stage) {
            if progress.stage == .connecting { vodAttempted = false; vodBlocked = false }
        }
        .accessibilityIdentifier("liveTV.importProgress")
    }

    private var liveStatus: String {
        guard liveSelected else { return "Not Selected" }
        if liveFailed { return "Failed" }
        return progress.stage == .ready ? "Ready" : "Loading"
    }

    private var preferredAction: CompletionAction {
        if liveStatus == "Ready" { return .start }
        if vodAvailable(.movie) { return .movie }
        if vodAvailable(.series) { return .series }
        return .manage
    }

    private func vodAvailable(_ kind: XtreamVODKind) -> Bool {
        guard (kind == .movie ? provider?.vodMoviesEnabled : provider?.vodSeriesEnabled) == true else { return false }
        return vodStatus(kind) == "Ready" || (kind == .movie ? cachedMovieCount : cachedSeriesCount) > 0
    }

    private func displayedVODCount(_ kind: XtreamVODKind) -> Int? {
        guard (kind == .movie ? provider?.vodMoviesEnabled : provider?.vodSeriesEnabled) == true else { return nil }
        if vodStatus(kind) == "Ready" || vodStatus(kind) == "Empty" {
            return kind == .movie ? vodProgress?.movies.accepted : vodProgress?.series.accepted
        }
        let count = kind == .movie ? cachedMovieCount : cachedSeriesCount
        return count > 0 ? count : nil
    }

    private func vodStatus(_ kind: XtreamVODKind) -> String {
        guard provider?.kind == .xtream else { return "Unsupported" }
        guard vodEnabled && (kind == .movie ? provider?.vodMoviesEnabled : provider?.vodSeriesEnabled) == true else { return "Not Selected" }
        guard let state = vodProgress else { return "Waiting" }
        switch kind == .movie ? state.movieResult : state.seriesResult {
        case .notSelected: return "Not Selected"
        case .waiting: return "Waiting"
        case .loading: return "Loading"
        case .ready: return "Ready"
        case .empty: return "Empty"
        case .unsupported: return "Unsupported"
        case .authentication: return "Authentication failed"
        case .failed: return "Failed"
        case .cancelled: return "Cancelled"
        }
    }

    private func vodRecordLine(_ kind: XtreamVODKind) -> String {
        guard (kind == .movie ? provider?.vodMoviesEnabled : provider?.vodSeriesEnabled) == true else { return "Not selected" }
        guard let state = vodProgress else { return vodEnabled ? "Catalog not loaded yet" : "Enable in Live TV Providers" }
        let count = kind == .movie ? state.movies : state.series
        if vodStatus(kind) == "Failed" || vodStatus(kind) == "Unsupported" || vodStatus(kind) == "Authentication failed" {
            let cached = kind == .movie ? cachedMovieCount : cachedSeriesCount
            return cached > 0 ? "Previous catalog retained · \(cached.formatted()) available" : "No catalog imported"
        }
        guard count.total > 0 else { return "\(count.accepted.formatted()) available" }
        if count.overLimit > 0, vodStatus(kind) == "Ready" {
            return "\(count.accepted.formatted()) imported · \(count.overLimit.formatted()) over the on-device limit"
        }
        let percentage = Int(((count.fraction ?? 0) * 100).rounded(.down))
        return "\(count.processed.formatted()) / \(count.total.formatted()) source records · \(percentage)%"
    }

    private func catalogCard(_ title: String, count: Int?, status: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title).font(.system(size: 27, weight: .bold))
            Text(count.map { $0.formatted() } ?? "—")
                .font(.system(size: 49, weight: .heavy).monospacedDigit())
            Text(status).font(.system(size: 25, weight: .semibold)).foregroundStyle(KyroTheme.accentInk)
            Text(detail).font(.system(size: 20)).foregroundStyle(Color.siloSecondaryText)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, minHeight: 192, alignment: .leading)
        .padding(24)
        .background(Color.siloSurface.opacity(0.9), in: RoundedRectangle(cornerRadius: 22))
    }

    @ViewBuilder private var actions: some View {
        HStack(spacing: 20) {
            if complete {
                if liveStatus == "Ready" {
                    Button("Start Watching", action: onClose)
                        .buttonStyle(TVKyroChipStyle(isSelected: true, fontSize: 28, minHeight: 70))
                        .focused($actionFocus, equals: .start)
                }
                if vodAvailable(.movie) {
                    Button("Browse Movies") { browseKind = .movie }
                        .buttonStyle(TVKyroChipStyle(isSelected: liveStatus != "Ready"))
                        .focused($actionFocus, equals: .movie)
                }
                if vodAvailable(.series) {
                    Button("Browse Series") { browseKind = .series }
                        .buttonStyle(TVKyroChipStyle(isSelected: liveStatus != "Ready" && !vodAvailable(.movie)))
                        .focused($actionFocus, equals: .series)
                }
                Button("Manage Provider", action: onManage).buttonStyle(TVKyroChipStyle())
                    .focused($actionFocus, equals: .manage)
                if liveFailed {
                    Button("Retry Live TV") { Task { await service.refresh(providerID: progress.providerID) } }
                        .buttonStyle(TVKyroChipStyle())
                }
                if vodFailed {
                    Button("Retry VOD") { Task { await vod.refresh(providerID: progress.providerID, liveTV: service) } }
                        .buttonStyle(TVKyroChipStyle())
                }
            } else if [.connecting, .downloading, .importing, .categories].contains(progress.stage) {
                Button("Cancel Import") { service.cancelImport() }.buttonStyle(TVKyroChipStyle())
            } else if vodBlocked {
                Button("Retry VOD") {
                    guard vod.activeProviderID == nil else { return }
                    vodBlocked = false
                    vodAttempted = true
                    Task { await vod.refresh(providerID: progress.providerID, liveTV: service) }
                }.buttonStyle(TVKyroChipStyle())
            } else if vodEnabled, progress.isTerminal {
                Button("Cancel VOD Import") { vod.cancel() }.buttonStyle(TVKyroChipStyle())
            }
        }
        .focusSection()
        .onAppear { if complete { actionFocus = preferredAction } }
    }

    private var recordLine: String {
        if let total = progress.count.total {
            let percent = progress.count.fraction.map { " · \(Int(($0 * 100).rounded(.down)))%" } ?? ""
            return "\(progress.count.processed.formatted()) / \(total.formatted()) source records\(percent)"
        }
        return "\(progress.count.processed.formatted()) source records processed"
    }

    private var skippedLine: String {
        var parts: [String] = []
        if progress.count.malformed > 0 { parts.append("\(progress.count.malformed.formatted()) malformed") }
        if progress.count.duplicate > 0 { parts.append("\(progress.count.duplicate.formatted()) duplicate") }
        if progress.count.unsupported > 0 { parts.append("\(progress.count.unsupported.formatted()) unsupported") }
        if progress.count.limited > 0 { parts.append("\(progress.count.limited.formatted()) over limit") }
        return parts.isEmpty ? "\(progress.count.rejected.formatted()) records not imported" : parts.joined(separator: " · ") + " records not imported"
    }
}

struct TVLiveTVGuideView: View {
    @Bindable var service: LiveTVService
    let profileID: String?
    let initialCategory: String?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.timeZone) private var timeZone
    @State private var timeline = LiveTVGuideTimeline(now: .now, timeZone: .current, lookBack: 30 * 60,
                                                      lookAhead: 6 * 60 * 60, pointsPerMinute: 4.2)
    @State private var viewportSize = CGSize(width: 1920, height: 1080)
    @State private var visibility = TVLiveTVVisibilityStore.shared
    @State private var category: String?
    @State private var didSeedCategory = false
    @State private var favoritesOnly = false
    @State private var rows: [LiveTVChannel] = []
    @State private var rowIDs: [String] = []
    @State private var rowIndices: [String: Int] = [:]
    @State private var detail: TVLiveTVGuideDetail?
    @State private var navigationState = TVLiveTVGuideNavigationState()
    @State private var focusHistory = TVLiveTVGuideFocusHistory()
    @State private var activeListing: TVLiveTVGuideListingSnapshot?
    @State private var entryTarget: TVLiveTVGuideFocus?
    @State private var laidOutRows: Set<String> = []
    @Namespace private var headerScope
    @Namespace private var gridScope
    @FocusState private var focus: TVLiveTVGuideFocus?

    private var channelWidth: CGFloat { TVLiveTVGuideLayout.channelWidth(viewportWidth: viewportSize.width) }
    private var rowHeight: CGFloat { TVLiveTVGuideLayout.rowHeight(viewportHeight: viewportSize.height) }
    private var scope: TVLiveTVVisibilityScope? {
        guard let providerID = service.selectedProviderID else { return nil }
        return TVLiveTVVisibilityScope(profileID: profileID ?? "local", providerID: providerID)
    }
    private var hidden: TVLiveTVVisibilitySnapshot { visibility.snapshot(for: scope) }

    var body: some View {
        ZStack {
            TVKyroAmbientBackdrop()
            ScrollViewReader { proxy in
                VStack(alignment: .leading, spacing: 8) {
                    guideHeader
                    timelineHeader
                    guideGrid
                }
                .onChange(of: rowIDs) { _, _ in
                    // Initial/filter layout only. Never scroll on a focus move:
                    // Up must preserve the timeline's horizontal position.
                    guard !focusHistory.isInGrid, let channelID = entryTarget?.channelID else { return }
                    var transaction = Transaction(animation: nil)
                    transaction.disablesAnimations = true
                    withTransaction(transaction) {
                        proxy.scrollTo(channelID, anchor: .topLeading)
                    }
                }
            }
            .padding(.horizontal, TVLiveTVGuideLayout.horizontalInset(viewportWidth: viewportSize.width))
            .padding(.vertical, TVLiveTVGuideLayout.verticalInset(viewportHeight: viewportSize.height))
        }
        .onGeometryChange(for: CGSize.self) { $0.size } action: { viewportSize = $0 }
        .defaultFocus($focus, focusHistory.isInGrid ? focusHistory.grid : focusHistory.header)
        .modifier(LiveTVChannelCover(service: service, presenter: .guide, isEnabled: true))
        .onAppear {
            service.presentation.surfaceAppeared(.guide)
            if let last = TVLiveTVGuideMemory.lastChannelID { navigationState.focus(channelID: last) }
            if !didSeedCategory {
                category = initialCategory
                didSeedCategory = true
            }
            rebuildRows()
        }
        .onDisappear { service.presentation.surfaceDisappeared(.guide) }
        .onChange(of: category) { rebuildRows() }
        .onChange(of: favoritesOnly) { rebuildRows() }
        .onChange(of: service.favoriteChannelIDs) { if favoritesOnly { rebuildRows() } }
        .onChange(of: service.channelCatalogRevision) { rebuildRows() }
        .onChange(of: visibility.revision) { rebuildRows() }
        .onChange(of: focus) { _, newFocus in
            focusHistory.observe(newFocus)
            if let id = newFocus?.channelID {
                if activeListing?.channelID != id,
                   let index = rowIndices[id] {
                    activeListing = TVLiveTVGuideListingSnapshot(
                        channelID: id,
                        programs: service.guidePrograms(for: rows[index], overlapping: timeline.interval))
                }
                navigationState.focus(channelID: id)
                TVLiveTVGuideMemory.lastChannelID = id
            } else if newFocus != nil {
                activeListing = nil
                prepareEntryTarget()
            }
        }
        .onExitCommand {
            if focusHistory.returnToHeader() {
                focus = focusHistory.header
            } else {
                dismiss()
            }
        }
        .sheet(item: $detail) { detail in
            TVLiveTVProgramDetail(detail: detail) {
                service.choose(detail.channel, from: .guide)
                self.detail = nil
            }
        }
    }

    // MARK: Header

    private var guideHeader: some View {
        HStack(spacing: 12) {
            Button { dismiss() } label: { Label("Back", systemImage: "chevron.left") }
                .buttonStyle(TVKyroChipStyle())
                .focused($focus, equals: .back)
            Text("TV Guide").font(.system(size: 40, weight: .bold))
            Spacer()
            Menu {
                Button("All Categories") { category = nil }
                ForEach(hidden.visibleCategories(service.categories), id: \.self) { value in
                    Button(value) { category = value }
                }
            } label: {
                Label(category ?? "All Categories", systemImage: "line.3.horizontal.decrease.circle")
            }
            .buttonStyle(TVKyroChipStyle(isSelected: category != nil))
            .focused($focus, equals: .category)
            Button {
                favoritesOnly.toggle()
            } label: {
                Label("Favorites", systemImage: favoritesOnly ? "star.fill" : "star")
            }
            .buttonStyle(TVKyroChipStyle(isSelected: favoritesOnly))
            .focused($focus, equals: .favorites)
            Button {
                guard !service.isLoading, !service.isGuideLoading else { return }
                Task { await service.refreshSelectedProvider() }
            } label: { Label("Refresh", systemImage: "arrow.clockwise") }
            .buttonStyle(TVKyroChipStyle())
            .focused($focus, equals: .refresh)
        }
        .defaultFocus($focus, focusHistory.header, priority: .userInitiated)
        .focusScope(headerScope)
        .focusSection()
    }

    private var timelineHeader: some View {
        HStack(spacing: 0) {
            Text("CHANNEL")
                .font(.system(size: 18, weight: .bold, design: .monospaced))
                .foregroundStyle(Color.siloSecondaryText)
                .frame(width: channelWidth, alignment: .leading)
            ForEach(timeline.ticks) { tick in
                Text(tick.date.formatted(date: .omitted, time: .shortened))
                    .font(.system(size: tick.isHour ? 20 : 17, weight: tick.isHour ? .bold : .medium))
                    .foregroundStyle(tick.isHour ? Color.white : Color.siloSecondaryText)
                    .frame(width: CGFloat(LiveTVGuideTimeline.slot / 60) * timeline.pointsPerMinute,
                           alignment: .leading)
            }
        }
        .frame(height: 32)
    }

    // MARK: Grid

    private var guideGrid: some View {
        ScrollView([.horizontal, .vertical]) {
            LazyVStack(alignment: .leading, spacing: 8) {
                ForEach(rows) { channel in
                    guideRow(channel)
                        .id(channel.id)
                        .onGeometryChange(for: Bool.self) { $0.size.height > 0 } action: { laidOut in
                            if laidOut { laidOutRows.insert(channel.id) }
                            else { laidOutRows.remove(channel.id) }
                        }
                        .onDisappear { laidOutRows.remove(channel.id) }
                        .task {
                            await service.refreshShortEPG(for: channel)
                            prepareEntryTarget()
                        }
                }
            }
        }
        // Never let geometry choose an arbitrary future cell while the lazy
        // entry row is still being laid out. No input or correction is queued.
        .disabled(!focusHistory.allowsGridEntry(entryTarget, laidOutRows: laidOutRows))
        .defaultFocus($focus, focusHistory.gridDefault(entry: entryTarget), priority: .userInitiated)
        .focusScope(gridScope)
        .focusSection()
        .overlay {
            if rows.isEmpty {
                ContentUnavailableView(
                    favoritesOnly ? "No Favorite Channels" : "No Guide Channels",
                    systemImage: favoritesOnly ? "star.slash" : "calendar.badge.exclamationmark",
                    description: Text("Choose another filter or refresh the provider.")
                )
            }
        }
    }

    private func guideRow(_ channel: LiveTVChannel) -> some View {
        HStack(spacing: 0) {
            Button {
                service.choose(channel, from: .guide)
            } label: {
                HStack(spacing: 16) {
                    LiveTVChannelLogo(channel: channel, size: CGSize(width: 96, height: 64))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(channel.name).font(.system(size: 26, weight: .semibold)).lineLimit(2)
                        if isPlaying(channel) {
                            TVKyroPlayingBadge()
                        } else {
                            Text(channel.category).font(.system(size: 19)).foregroundStyle(Color.siloSecondaryText).lineLimit(1)
                        }
                    }
                    Spacer()
                }
                .padding(.horizontal, 14)
                .frame(width: channelWidth, height: rowHeight)
                .background(Color.siloSurface, in: RoundedRectangle(cornerRadius: 14))
            }
            .buttonStyle(TVKyroCardFocusStyle(cornerRadius: 14))
            .focused($focus, equals: .channel(channel.id))

            programTimeline(for: channel)
        }
    }

    @ViewBuilder
    private func programTimeline(for channel: LiveTVChannel) -> some View {
        let programs = activeListing?.programs(for: channel.id) {
            service.guidePrograms(for: channel, overlapping: timeline.interval)
        } ?? service.guidePrograms(for: channel, overlapping: timeline.interval)
        let cells = LiveTVGuideCell.cells(for: programs, in: timeline)
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 14).fill(Color.black.opacity(0.22))
            if cells.isEmpty {
                Button {
                    service.choose(channel, from: .guide)
                } label: {
                    Text("No guide information · Watch channel")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(Color.siloSecondaryText)
                        .frame(width: 520, height: rowHeight - 8, alignment: .leading)
                        .padding(.horizontal, 18)
                        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(TVKyroCardFocusStyle(cornerRadius: 12))
                .focused($focus, equals: .noGuide(channel.id))
            } else {
                ForEach(cells) { cell in
                    let target = TVLiveTVGuideFocus.program(channelID: channel.id, programID: cell.program.id)
                    Button {
                        if LiveTVGuideAction(cell.program, at: .now) == .tune {
                            service.choose(channel, from: .guide)
                        } else {
                            detail = TVLiveTVGuideDetail(channel: channel, program: cell.program)
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(cell.program.title)
                                .font(.system(size: 24, weight: .semibold))
                                .lineLimit(2)
                            Text("\(cell.program.start.formatted(date: .omitted, time: .shortened))–\(cell.program.end.formatted(date: .omitted, time: .shortened))")
                                .font(.system(size: 18))
                                .foregroundStyle(Color.siloSecondaryText)
                        }
                        .padding(.horizontal, 15)
                        .frame(width: TVLiveTVGuideLayout.programCellWidth(cell.width),
                               height: rowHeight - 8, alignment: .leading)
                        .clipped()
                        .background(programColor(cell.program), in: RoundedRectangle(cornerRadius: 12))
                    }
                    .buttonStyle(TVKyroCardFocusStyle(cornerRadius: 12))
                    // The first Right from a channel must reach live (or the next upcoming
                    // listing), never an earlier program in the look-back window.
                    .disabled(!TVLiveTVGuideFocusPlanner.canFocusProgram(
                        cell.program, at: .now, isFocused: focus == target))
                    .focused($focus, equals: target)
                    // Placed by layout, not `.offset`: the focus engine then searches from where
                    // the cell is actually drawn, so Down/Right/Left pick the visible neighbour.
                    .padding(.leading, cell.x)
                }
            }

            TimelineView(.periodic(from: .now, by: 60)) { context in
                if timeline.interval.contains(context.date) {
                    Rectangle()
                        .fill(KyroTheme.live)
                        .frame(width: 3, height: rowHeight)
                        .offset(x: timeline.x(for: context.date))
                        .allowsHitTesting(false)
                }
            }
        }
        .frame(width: timeline.width, height: rowHeight, alignment: .leading)
    }

    private func programColor(_ program: EPGProgram) -> Color {
        switch LiveTVGuideProgramState(program, at: .now) {
        case .past: LiveTVSurface.pastProgram
        case .current: KyroTheme.depth.opacity(0.88)
        case .upcoming: LiveTVSurface.upcomingProgram
        }
    }

    private func isPlaying(_ channel: LiveTVChannel) -> Bool {
        service.playerSession.activeChannelID == channel.id
    }

    // MARK: Focus

    /// Prepare the native grid region's preference while the toolbar owns focus.
    /// No direction handlers or focus writes: the engine chooses it on entry.
    private func prepareEntryTarget() {
        guard !focusHistory.isInGrid else { return }
        entryTarget = TVLiveTVGuideFocusPlanner.entryTarget(
            rowIDs: rowIDs, remembered: navigationState.focusedChannelID)
    }

    /// Filters and catalog updates rebuild the rows without moving focus. Focus moves only when it
    /// sat on a row that is gone, and then to the filter it came from, never into the grid.
    private func rebuildRows() {
        if let category, hidden.categories.contains(category) { self.category = nil }
        rows = LiveTVChannelFiltering.filter(
            hidden.visibleChannels(service.channels),
            query: "",
            category: category,
            favoritesOnly: favoritesOnly,
            favoriteIDs: service.favoriteChannelIDs
        )
        rowIDs = rows.map(\.id)
        rowIndices = Dictionary(rowIDs.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: { first, _ in first })
        navigationState.reconcile(visibleChannelIDs: rowIDs)
        let removedActiveRow = TVLiveTVGuideFocusPlanner.mustRelocate(focusHistory.grid, rowIDs: rowIDs)
        focusHistory.reconcile(rowIDs: rowIDs)
        if removedActiveRow {
            activeListing = nil
            // The sole exceptional write: the focused row was removed, not
            // merely refreshed. Return to the user's originating filter.
            if focus?.channelID != nil { focus = focusHistory.header }
        }
        prepareEntryTarget()
    }
}

private struct TVLiveTVGuideDetail: Identifiable {
    let channel: LiveTVChannel
    let program: EPGProgram
    var id: String { program.id }
}

private struct TVLiveTVProgramDetail: View {
    let detail: TVLiveTVGuideDetail
    let watch: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text(detail.program.title).font(.system(size: 42, weight: .bold))
            Text(detail.channel.name).font(.system(size: 24, weight: .semibold)).foregroundStyle(KyroTheme.accentInk)
            Text("\(detail.program.start.formatted(date: .omitted, time: .shortened))–\(detail.program.end.formatted(date: .omitted, time: .shortened))")
                .font(.system(size: 22)).foregroundStyle(Color.siloSecondaryText)
            if let summary = detail.program.summary, !summary.isEmpty {
                Text(summary).font(.system(size: 22)).foregroundStyle(Color.siloSecondaryText).lineLimit(8)
            }
            HStack(spacing: 18) {
                Button("Watch Channel", action: watch).buttonStyle(.borderedProminent)
                Button("Close") { dismiss() }.buttonStyle(.bordered)
            }
        }
        .padding(70)
        .frame(minWidth: 900, minHeight: 520, alignment: .topLeading)
        .background(TVKyroAmbientBackdrop())
    }
}
#endif
