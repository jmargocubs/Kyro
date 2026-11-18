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
    let focusRequest: Int
    let isTopMenuFocused: Bool
    let onTopMenuFocusRequest: () -> Void

    @State private var section: TVLiveTVSection = .channels
    @State private var selectedCategory: String?
    @State private var query = ""
    @State private var search = LiveTVChannelSearchModel()
    @State private var showsGuide = false
    @State private var showsProviders = false
    @FocusState private var focusedControl: FocusTarget?

    fileprivate enum FocusTarget: Hashable {
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

    var body: some View {
        ZStack {
            TVKyroAmbientBackdrop()

            VStack(alignment: .leading, spacing: 22) {
                header
                controls
                content
            }
            .padding(.horizontal, 72)
            .padding(.top, TVTopMenuLayout.contentTopInset)
            .padding(.bottom, 38)
        }
        .modifier(LiveTVChannelCover(
            service: service,
            presenter: .list,
            isEnabled: !showsGuide && !showsProviders
        ))
        .fullScreenCover(isPresented: $showsGuide) {
            TVLiveTVGuideView(service: service)
        }
        .fullScreenCover(isPresented: $showsProviders) {
            TVLiveTVProviderManagementView(service: service)
        }
        .task(id: service.selectedProviderID) {
            updateSearch()
            await service.prepareSelectedProvider()
            updateSearch()
        }
        .task(id: focusRequest) { claimEntryFocus() }
        .onAppear {
            service.presentation.surfaceAppeared(.list)
            updateSearch()
            updateCategoryCounts()
        }
        .onDisappear {
            search.cancel()
            if !showsGuide && !showsProviders { service.presentation.surfaceDisappeared(.list) }
        }
        .onChange(of: query) { updateSearch() }
        .onChange(of: section) {
            updateSearch()
        }
        .onChange(of: selectedCategory) { updateSearch() }
        .onChange(of: service.favoriteChannelIDs) { updateSearch() }
        .onChange(of: service.channelCatalogRevision) {
            updateSearch()
            updateCategoryCounts()
        }
        .onChange(of: service.selectedProviderID) {
            query = ""
            selectedCategory = nil
            updateSearch()
            updateCategoryCounts()
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
                    section = item
                    if item != .categories { selectedCategory = nil }
                } label: {
                    Label(item.title, systemImage: item.symbol)
                }
                .buttonStyle(TVKyroChipStyle(isSelected: section == item))
                .focused($focusedControl, equals: .section(item))
                .onMoveCommand { if $0 == .up { onTopMenuFocusRequest() } }
            }

            Button { showsGuide = true } label: {
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
        } else if section == .categories && selectedCategory == nil {
            categoryGrid
        } else {
            channelGrid
        }
    }

    private var categoryGrid: some View {
        ScrollView {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 28) {
                categoryButton("All Channels", count: service.channels.count, category: nil)
                ForEach(service.categories, id: \.self) { category in
                    categoryButton(category, count: categoryCounts[category, default: 0], category: category)
                }
            }
            .padding(.vertical, 18)
        }
        .focusSection()
    }

    private func categoryButton(_ title: String, count: Int, category: String?) -> some View {
        Button {
            selectedCategory = category
            section = .channels
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
    }

    private var channelGrid: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let notice = service.errorMessage ?? service.catalogNotice ?? service.guideMessage {
                Label(notice, systemImage: "info.circle")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(Color.siloSecondaryText)
                    .lineLimit(2)
            }

            if search.isSearching && search.matches.isEmpty {
                ProgressView("Filtering channels…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if search.matches.isEmpty {
                statusPage(symbol: section == .favorites ? "star.slash" : "magnifyingglass",
                           title: section == .favorites ? "No favorite channels" : "No matching channels",
                           message: section == .favorites
                               ? "Manage favorites from channel playback."
                               : "Try a different search or category.")
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 34) {
                        ForEach(search.matches) { channel in
                            TVLiveTVChannelCard(
                                channel: channel,
                                program: service.programPair(for: channel),
                                isFavorite: service.isFavorite(channel),
                                isPlaying: service.playerSession.activeChannelID == channel.id,
                                focus: $focusedControl,
                                play: { service.choose(channel, from: .list) }
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
        for channel in service.channels { counts[channel.category, default: 0] += 1 }
        categoryCounts = counts
    }

    private var providerSummary: String {
        guard let provider = service.selectedProvider else { return "No provider connected" }
        let suffix = provider.channelCount == 1 ? "channel" : "channels"
        return "\(provider.name) · \(provider.channelCount) \(suffix)"
    }

    private func updateSearch() {
        search.update(
            channels: service.channels,
            query: query,
            category: selectedCategory,
            favoritesOnly: section == .favorites,
            favoriteIDs: service.favoriteChannelIDs,
            includeGroups: false
        )
    }

    private func claimEntryFocus() {
        guard !isTopMenuFocused else { return }
        Task { @MainActor in
            await Task.yield()
            guard !isTopMenuFocused else { return }
            focusedControl = .section(section)
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
    @Environment(\.dismiss) private var dismiss
    @State private var kind: LiveTVProviderKind = .m3u
    @State private var name = "My Provider"
    @State private var playlistURL = ""
    @State private var xmltvURL = ""
    @State private var serverURL = ""
    @State private var username = ""
    @State private var password = ""
    @State private var localError: String?
    @State private var providerToRemove: LiveTVProvider?
    @State private var showsPhoneSetup = false
    @FocusState private var focus: TVLiveTVProviderFocus?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 34) {
                header
                providerList
                phoneSetupEntry
                Divider().overlay(Color.white.opacity(0.18))
                addProviderForm
            }
            .padding(.horizontal, 120)
            .padding(.vertical, 60)
        }
        .background(TVKyroAmbientBackdrop())
        // Back/Menu always leaves the screen. While a text field is editing, the system keyboard
        // takes Menu first, so typing (and the nearby-iPhone keyboard) is unaffected.
        .onExitCommand { dismiss() }
        .onAppear {
            if focus == nil { focus = TVLiveTVProviderFocusPlanner.initialFocus(providerIDs: service.providers.map(\.id)) }
        }
        .fullScreenCover(isPresented: $showsPhoneSetup, onDismiss: { restoreFocus(.phoneSetup) }) {
            TVLiveTVPairingView(service: service)
        }
        .confirmationDialog(
            "Remove \(providerToRemove?.name ?? "provider")?",
            isPresented: Binding(get: { providerToRemove != nil }, set: { if !$0 { providerToRemove = nil } })
        ) {
            Button("Remove Provider", role: .destructive) {
                guard let provider = providerToRemove else { return }
                providerToRemove = nil
                let remaining = service.providers.map(\.id).filter { $0 != provider.id }
                Task { await service.removeProvider(provider.id) }
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
            Text("Live TV Providers").font(.system(size: 46, weight: .bold))
            Spacer()
        }
        .focusSection()
    }

    /// Up from the topmost row goes to Back explicitly, whichever column it starts in.
    private func upToBack(_ direction: MoveCommandDirection, from origin: TVLiveTVProviderFocus) {
        guard direction == .up,
              TVLiveTVProviderFocusPlanner.escapesToBack(origin, providerIDs: service.providers.map(\.id)) else { return }
        focus = .back
    }

    private func restoreFocus(_ target: TVLiveTVProviderFocus) {
        Task { @MainActor in
            await Task.yield()
            focus = target
        }
    }

    private var providerList: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Connected Providers")
                .font(.system(size: 34, weight: .bold))
            if service.providers.isEmpty {
                Text("No providers configured. Credentials are stored in the Apple TV keychain.")
                    .font(.system(size: 22))
                    .foregroundStyle(Color.siloSecondaryText)
            } else {
                ForEach(service.providers) { provider in
                    HStack(spacing: 18) {
                        Button {
                            service.selectProvider(provider.id)
                            Task { await service.prepareSelectedProvider() }
                        } label: {
                            HStack(spacing: 18) {
                                Image(systemName: service.selectedProviderID == provider.id
                                      ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(KyroTheme.accentInk)
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(provider.name).font(.system(size: 26, weight: .semibold))
                                    Text("\(provider.kind == .xtream ? "Xtream Codes" : "M3U") · \(provider.channelCount) channels")
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
                        .onMoveCommand { upToBack($0, from: .provider(provider.id)) }

                        Button {
                            service.selectProvider(provider.id)
                            Task { await service.refresh(providerID: provider.id) }
                        } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                        .buttonStyle(TVKyroChipStyle())
                        .disabled(service.isLoading)
                        .focused($focus, equals: .refresh(provider.id))
                        .onMoveCommand { upToBack($0, from: .refresh(provider.id)) }

                        Button(role: .destructive) { providerToRemove = provider } label: {
                            Label("Remove", systemImage: "trash")
                        }
                        .buttonStyle(TVKyroChipStyle(isDestructive: true))
                        .focused($focus, equals: .remove(provider.id))
                        .onMoveCommand { upToBack($0, from: .remove(provider.id)) }
                    }
                }
            }

            if service.isLoading { ProgressView("Connecting…") }
            if let message = localError ?? service.errorMessage {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(KyroTheme.live)
                    .font(.system(size: 20, weight: .medium))
            }
        }
        .focusSection()
    }

    /// The recommended way to add a provider: send it from the Kyro iPhone app instead of typing
    /// long URLs and passwords with the Siri Remote.
    private var phoneSetupEntry: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                showsPhoneSetup = true
            } label: {
                Label("Set up with phone", systemImage: "iphone.and.arrow.forward")
            }
            .buttonStyle(TVKyroChipStyle(isSelected: true))
            .focused($focus, equals: .phoneSetup)
            .onMoveCommand { upToBack($0, from: .phoneSetup) }
            Text("Send a provider from the Kyro iPhone app. Nothing to type here.")
                .font(.system(size: 20)).foregroundStyle(Color.siloSecondaryText)
        }
        .focusSection()
    }

    private var addProviderForm: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Add Provider").font(.system(size: 34, weight: .bold))
            Picker("Provider Type", selection: $kind) {
                Text("M3U Playlist").tag(LiveTVProviderKind.m3u)
                Text("Xtream Codes").tag(LiveTVProviderKind.xtream)
            }
            .pickerStyle(.segmented)

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
                .font(.system(size: 19))
                .foregroundStyle(Color.siloSecondaryText)

            Button {
                saveProvider()
            } label: {
                Label("Save and Connect", systemImage: "plus.circle.fill")
            }
            .buttonStyle(TVKyroChipStyle(isSelected: true))
            .disabled(!canSave)
            .focused($focus, equals: .save)
        }
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
        do {
            let id: UUID
            switch kind {
            case .m3u:
                id = try service.saveConfiguration(name: name, playlistURL: playlistURL, xmltvURL: xmltvURL)
            case .xtream:
                id = try service.saveXtreamConfiguration(
                    name: name, serverURL: serverURL, username: username, password: password
                )
            }
            localError = nil
            password = ""
            Task { await service.refresh(providerID: id) }
            // Land on the new provider's row instead of a cleared form.
            restoreFocus(.provider(id))
        } catch {
            localError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}

private struct TVLiveTVProviderFieldStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .font(.system(size: 24))
            .padding(.horizontal, 18)
            .frame(minHeight: 58)
            .background(Color.siloSurface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

struct TVLiveTVGuideView: View {
    @Bindable var service: LiveTVService
    @Environment(\.dismiss) private var dismiss
    @Environment(\.timeZone) private var timeZone
    @State private var timeline = LiveTVGuideTimeline(now: .now, timeZone: .current, lookBack: 30 * 60,
                                                      lookAhead: 6 * 60 * 60, pointsPerMinute: 3)
    @State private var category: String?
    @State private var favoritesOnly = false
    @State private var rows: [LiveTVChannel] = []
    @State private var rowIDs: [String] = []
    @State private var rowIndices: [String: Int] = [:]
    @State private var detail: TVLiveTVGuideDetail?
    @State private var navigationState = TVLiveTVGuideNavigationState()
    @State private var focusHistory = TVLiveTVGuideFocusHistory()
    @State private var activeListing: TVLiveTVGuideListingSnapshot?
    @State private var entryTarget: TVLiveTVGuideFocus?
    @State private var entryRefreshDate: Date?
    @State private var laidOutRows: Set<String> = []
    @Namespace private var headerScope
    @Namespace private var gridScope
    @FocusState private var focus: TVLiveTVGuideFocus?

    private let channelWidth: CGFloat = 310
    private let rowHeight: CGFloat = 112

    var body: some View {
        ZStack {
            TVKyroAmbientBackdrop()
            ScrollViewReader { proxy in
                VStack(alignment: .leading, spacing: 18) {
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
            .padding(.horizontal, 58)
            .padding(.vertical, 42)
        }
        .defaultFocus($focus, focusHistory.isInGrid ? focusHistory.grid : focusHistory.header)
        .modifier(LiveTVChannelCover(service: service, presenter: .guide, isEnabled: true))
        .onAppear {
            service.presentation.surfaceAppeared(.guide)
            if let last = TVLiveTVGuideMemory.lastChannelID { navigationState.focus(channelID: last) }
            rebuildRows()
        }
        .onDisappear { service.presentation.surfaceDisappeared(.guide) }
        .onChange(of: category) { rebuildRows() }
        .onChange(of: favoritesOnly) { rebuildRows() }
        .onChange(of: service.favoriteChannelIDs) { if favoritesOnly { rebuildRows() } }
        .onChange(of: service.channelCatalogRevision) { rebuildRows() }
        .onChange(of: service.guideRevision) { prepareEntryTarget() }
        .task(id: entryRefreshDate) {
            // A listing boundary invalidates the inactive region's preference,
            // not focus. This is not a delayed directional correction. It is
            // cancelled with the view and never writes while the grid owns focus.
            guard let date = entryRefreshDate else { return }
            do { try await Task.sleep(for: .seconds(max(0, date.timeIntervalSinceNow))) }
            catch { return }
            guard !Task.isCancelled else { return }
            prepareEntryTarget()
        }
        .onChange(of: service.guideChannelRevisions[entryTarget?.channelID ?? ""] ?? 0) {
            // SQLite residency and short EPG publish per-channel revisions,
            // without changing guideRevision. Refresh the inactive region's
            // preference too, but never redirect a user already in the grid.
            prepareEntryTarget()
        }
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
        .onExitCommand { dismiss() }
        .sheet(item: $detail) { detail in
            TVLiveTVProgramDetail(detail: detail) {
                service.choose(detail.channel, from: .guide)
                self.detail = nil
            }
        }
    }

    // MARK: Header

    private var guideHeader: some View {
        HStack(spacing: 16) {
            Button { dismiss() } label: { Label("Back", systemImage: "chevron.left") }
                .buttonStyle(TVKyroChipStyle())
                .focused($focus, equals: .back)
            Text("TV Guide").font(.system(size: 46, weight: .bold))
            Spacer()
            Menu {
                Button("All Categories") { category = nil }
                ForEach(service.categories, id: \.self) { value in
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
        .frame(height: 38)
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
                    LiveTVChannelLogo(channel: channel, size: CGSize(width: 80, height: 52))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(channel.name).font(.system(size: 22, weight: .semibold)).lineLimit(1)
                        if isPlaying(channel) {
                            TVKyroPlayingBadge()
                        } else {
                            Text(channel.category).font(.system(size: 16)).foregroundStyle(Color.siloSecondaryText).lineLimit(1)
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
                    Button {
                        if LiveTVGuideAction(cell.program, at: .now) == .tune {
                            service.choose(channel, from: .guide)
                        } else {
                            detail = TVLiveTVGuideDetail(channel: channel, program: cell.program)
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(cell.program.title)
                                .font(.system(size: 21, weight: .semibold))
                                .lineLimit(1)
                            Text("\(cell.program.start.formatted(date: .omitted, time: .shortened))–\(cell.program.end.formatted(date: .omitted, time: .shortened))")
                                .font(.system(size: 16))
                                .foregroundStyle(Color.siloSecondaryText)
                        }
                        .padding(.horizontal, 15)
                        .frame(width: max(cell.width - 6, 80), height: rowHeight - 8, alignment: .leading)
                        .background(programColor(cell.program), in: RoundedRectangle(cornerRadius: 12))
                    }
                    .buttonStyle(TVKyroCardFocusStyle(cornerRadius: 12))
                    .focused($focus, equals: .program(channelID: channel.id, programID: cell.program.id))
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
        guard let channelID = TVLiveTVGuideFocusPlanner.entryChannel(
            rowIDs: rowIDs, remembered: navigationState.focusedChannelID),
              let index = rowIndices[channelID] else {
            entryTarget = nil
            entryRefreshDate = nil
            return
        }
        let programs = service.guidePrograms(for: rows[index], overlapping: timeline.interval)
        let now = Date.now
        entryTarget = TVLiveTVGuideFocusPlanner.entryTarget(
            rowIDs: rowIDs, remembered: navigationState.focusedChannelID,
            currentProgramID: { _ in TVLiveTVGuideFocusPlanner.currentProgram(in: programs, at: now)?.id })
        entryRefreshDate = TVLiveTVGuideFocusPlanner.nextListingBoundary(in: programs, after: now)
    }

    /// Filters and catalog updates rebuild the rows without moving focus. Focus moves only when it
    /// sat on a row that is gone, and then to the filter it came from, never into the grid.
    private func rebuildRows() {
        rows = LiveTVChannelFiltering.filter(
            service.channels,
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
