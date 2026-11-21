#if os(tvOS)
import SwiftUI
import UIKit
import os

enum TVTopMenuLayout {
    /// Vertical clearance needed when a root tvOS page does not render a
    /// full-bleed hero behind the custom top menu. Build 99: 148 pt, 28 pt
    /// under the bar (was 188 pt, 68 pt under it). See `TVScreenLayout`.
    static let contentTopInset: CGFloat = TVScreenLayout.contentTopInset
}

/// Publishes the on-screen bounds of each panel-bearing bar element so the
/// shell can anchor the cascade / profile panel under it (§5.3 "centered
/// under the tab", §5.8 "under the avatar"). One `Anchor` per element; the
/// shell resolves the open panel's anchor in its own coordinate space.
struct TVTopMenuAnchorKey: PreferenceKey {
    static let defaultValue: [TVTopMenuPanel: Anchor<CGRect>] = [:]

    static func reduce(
        value: inout [TVTopMenuPanel: Anchor<CGRect>],
        nextValue: () -> [TVTopMenuPanel: Anchor<CGRect>]
    ) {
        value.merge(nextValue()) { _, new in new }
    }
}

/// A library content type that can surface as a root tab (Skyline §3.1).
/// Tabs represent types, not server libraries — a type's tab appears only
/// if the profile can see at least one library of that type.
enum TVLibraryTabType: String, CaseIterable, Hashable {
    case movies
    case series
    case music
    case audiobooks

    var title: String {
        switch self {
        case .movies: return "Movies"
        case .series: return "Series"
        case .music: return "Music"
        case .audiobooks: return "Audiobooks"
        }
    }

    /// SF Symbol for a library row of this type in the cascade level-1
    /// panel (§5.3). Per-library art isn't fetched there — the icon is a
    /// quiet type cue, mirroring the empty-state glyphs elsewhere.
    var systemImage: String {
        switch self {
        case .movies: return "film.stack"
        case .series: return "tv"
        case .music: return "music.note"
        case .audiobooks: return "book.closed"
        }
    }

    /// Mono section header for the cascade level-1 panel (§5.3), e.g.
    /// `MOVIE LIBRARIES`.
    var librariesHeader: String {
        switch self {
        case .movies: return "MOVIE LIBRARIES"
        case .series: return "SERIES LIBRARIES"
        case .music: return "MUSIC LIBRARIES"
        case .audiobooks: return "AUDIOBOOK LIBRARIES"
        }
    }

    /// Whether a server library belongs under this tab. A mixed library
    /// (movies + series in one folder) belongs to both video tabs — it stays
    /// one browsable library, reachable from either dropdown.
    func matches(_ library: Library) -> Bool {
        switch self {
        case .movies: return library.isMovieLibrary || library.isMixedLibrary
        case .series: return library.isSeriesLibrary || library.isMixedLibrary
        case .music: return library.type == "music"
        case .audiobooks: return library.isAudiobookLibrary
        }
    }
}

enum TVRootDestination: Hashable {
    case home
    case liveTV
    /// Phase 3: Kyro's native Sports Hub.
    case sports
    case recommendations
    case libraryType(TVLibraryTabType)
    case libraryShortcut(libraryId: Int, label: String)
    case calendar
    /// Media requests; present only while the server has requests enabled.
    case requests

    static func == (lhs: TVRootDestination, rhs: TVRootDestination) -> Bool {
        switch (lhs, rhs) {
        case (.home, .home), (.liveTV, .liveTV), (.sports, .sports), (.recommendations, .recommendations), (.calendar, .calendar),
             (.requests, .requests):
            return true
        case (.libraryType(let lhsType), .libraryType(let rhsType)):
            return lhsType == rhsType
        case (.libraryShortcut(let lhsId, _), .libraryShortcut(let rhsId, _)):
            return lhsId == rhsId
        default:
            return false
        }
    }

    func hash(into hasher: inout Hasher) {
        switch self {
        case .home:
            hasher.combine(0)
        case .liveTV:
            hasher.combine(1)
        case .recommendations:
            hasher.combine(2)
        case .libraryType(let type):
            hasher.combine(3)
            hasher.combine(type)
        case .libraryShortcut(let libraryId, _):
            hasher.combine(4)
            hasher.combine(libraryId)
        case .calendar:
            hasher.combine(5)
        case .requests:
            hasher.combine(6)
        case .sports:
            hasher.combine(7)
        }
    }

    var title: String {
        switch self {
        case .home: return "Home"
        case .liveTV: return "Live TV"
        case .sports: return "Sports"
        case .recommendations: return "For You"
        case .libraryType(let type): return type.title
        case .libraryShortcut(_, let label): return label
        case .calendar: return "Calendar"
        case .requests: return "Requests"
        }
    }
}

/// Skyline top bar: wordmark left, search + the synced root tabs centered
/// (search sits left of the first root; the tabs stay screen-centered), profile
/// avatar right (§5.1). The bar is custom on purpose — the system
/// `TabView` sidebar steals leftward focus — and draws no background band;
/// it floats over each page's own scrim and dims to 70% while focus is
/// down in the content zone.
struct TVTopMenuBar: View {
    let roots: [TVRootDestination]
    let selectedRoot: TVRootDestination
    let currentProfile: UserProfile?
    /// Mirrors whether a bar element really holds focus. The bar sets it from
    /// its own `@FocusState`; the shell clears it early only for an explicit
    /// hand-off to content (selection, panel exit) so the page may claim.
    @Binding var isMenuFocused: Bool
    let focusRequest: Int
    /// Bumped when the shell has determined the bar's `@FocusState` is stale —
    /// the engine dropped focus without the bar observing it, so no suppression
    /// transition will clear it. Drops the bar's focus state without asking for
    /// focus back.
    var focusResetRequest: Int = 0
    /// Bar element to focus on the next `focusRequest` bump, overriding the
    /// default of the selected tab. The shell sets this so Menu-ing out of a
    /// panel returns focus to the *panel's* tab/avatar (§7), not whatever
    /// root happens to be selected.
    var focusRequestTarget: TVTopMenuPanel? = nil
    /// Which bar element currently has an anchored panel open (the host
    /// owns the panel; the bar only drives the dwell + hand-off). When set
    /// to the focused element, its capsule drops from inverted to
    /// `chrome.selected` once focus descends into the panel.
    let openPanel: TVTopMenuPanel?
    /// True once focus has descended from the bar into the open panel —
    /// the tab/avatar then reads as selected, not focused (§5.1).
    let panelHasFocus: Bool
    /// True while the panel is in focus-owning (entered) mode, as opposed to a
    /// passive dwell preview. Unlike `panelHasFocus` — which flips false for a
    /// frame whenever the panel's row focus is momentarily perturbed and lags
    /// behind the engine by a render pass — this is set once when the host
    /// hands focus in and stays true until the panel closes. The bar uses it
    /// to stay passive: in entered mode a `focusedItem` drop to nil means the
    /// panel claimed focus, so the bar must NOT re-pin to the tab. Re-pinning
    /// there starts a tug-of-war with the panel's own `@FocusState` (the entry
    /// oscillation that made d-pad navigation into the flyout flaky).
    let panelEntersFocus: Bool
    let onSelectRoot: (TVRootDestination) -> Void
    let onSearch: () -> Void
    let onSettings: () -> Void
    /// A bar element rested under focus for the dwell interval, or focus
    /// left every dwellable element (`nil` → close any open panel). §5.3.
    let onDwell: (TVTopMenuPanel?) -> Void
    /// The dropdown offered by the element that actually holds bar focus, or
    /// nil. Reported on every bar focus change, whatever the menu ownership
    /// flag says: that dropdown is the one Down enters natively
    /// (`TVTopMenuPanelFocusPolicy`).
    var onFocusedPanelChanged: (TVTopMenuPanel?) -> Void = { _ in }
    /// Press on the profile avatar opens the profile panel and enters it
    /// immediately; dwell only previews it.
    let onProfilePressed: () -> Void
    /// Focus left the bar through normal focus movement into page content.
    /// The bar stays enabled: Up from a page's top row reaches it natively.
    let onContentFocusHandoff: () -> Void
    var onExit: (() -> Void)? = nil

    @FocusState private var focusedItem: TVTopMenuFocus?
    /// Dwell timer keyed on the focused element; cancelled on every focus
    /// move so bar sweeps never open a panel (§5.3, Open-Q5/Q7).
    @State private var dwellTask: Task<Void, Never>?
    /// The last bar element focus actually settled on. Used to restore focus
    /// when opening/closing the dropdown overlay transiently drops it.
    @State private var lastBarFocus: TVTopMenuFocus?
    /// Set when a sideways move closes the open panel: the overlay removal
    /// perturbs focus, so the next nil-drop is spurious and must be re-pinned.
    @State private var refocusAfterClose = false
    /// The element the bar itself last asked to focus. An arrival on it takes
    /// menu ownership even though it has no user heading.
    @State private var requestedFocus: TVTopMenuFocus?
    /// Set when the bar deliberately clears its own binding (watchdog reset,
    /// stale-binding reclaim), so that nil is never read as a user's Down.
    @State private var ignoreNextFocusLoss = false
    /// True only until UIKit reports the bar departure. The report can arrive
    /// before or after SwiftUI clears the binding; neither order is assumed.
    @State private var pendingBarFocusLoss = false
    @State private var movementObserverID = UUID()
    /// The element whose panel the user just explicitly closed (Menu/Back).
    /// Focus returns to it, but the dwell timer must NOT auto-reopen the panel
    /// they just dismissed — that's the "closes then immediately reopens"
    /// awkwardness. Cleared the instant focus moves to a *different* element,
    /// so resting here again later still opens it normally.
    @State private var dwellSuppressedElement: TVTopMenuFocus?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.cubbiestream.kyro",
        category: "TVFocus"
    )

    var body: some View {
        ZStack(alignment: .top) {
            tabCluster

            HStack(spacing: 0) {
                wordmark

                Spacer(minLength: SiloTheme.Skyline.tabSpacing)

                settingsButton
                    .padding(.trailing, 18)
                profileButton
            }
        }
        .frame(height: SiloTheme.Skyline.barHeight)
        .padding(.horizontal, SiloTheme.Skyline.safeAreaX)
        .padding(.top, SiloTheme.Skyline.barTopInset)
        .frame(maxWidth: .infinity, alignment: .top)
        .ignoresSafeArea(edges: [.top, .horizontal])
        // The bar dims only while focus is down in the content zone (§5.1).
        // An open panel keeps it fully lit — focus has merely descended into
        // the dropdown, and dimming the bar there greys out the panel's own
        // anchor tab and reads as a heavy "everything went dark" state.
        .opacity(isMenuFocused || openPanel != nil ? 1.0 : SiloTheme.Skyline.barDimmedOpacity)
        // Reduce Motion snaps the bar dim/restore as focus enters/leaves
        // the content zone (§5.1; §4.2 acceptance: no drift animations).
        .animation(reduceMotion ? nil : .easeInOut(duration: SiloTheme.normalDuration), value: isMenuFocused)
        // Native focus contract (docs/tvos-focus.md, "Top Menu Ownership"):
        // the bar is one focus section that stays enabled while content has
        // focus, so Up from any page's top row — click or swipe — reaches it
        // without a page handler. Entering the section from below always
        // lands on the selected tab, not the tab under the focused card.
        // Only an entered panel makes the bar inert.
        .defaultFocus($focusedItem, .root(selectedRoot), priority: .userInitiated)
        .focusSection()
        .disabled(tvTopMenuIsInert(panelEntered: panelEntersFocus))
        .tvObserveFocus("TopMenu", value: focusedItem)
        .onChange(of: panelEntersFocus) { _, value in TVFocusDiagnostics.value("state", "TopMenu", "panelEntered", value) }
        // Menu handling must not be conditionally wrapped around the focused
        // tab buttons. Toggling an `onExitCommand` ancestor when `openPanel`
        // changes invalidates tvOS focus and produces the preview-open flash.
        .background(
            TVWindowMenuPressCatcher(
                isActive: shouldCaptureExitPress,
                onExit: handleExitPress
            )
            .frame(width: 0, height: 0)
        )
        .onChange(of: focusResetRequest) { _, _ in
            // Clear the re-pin flags first: the bar has no focus to defend
            // here, and letting the nil write below take the re-pin branch
            // would have the bar grab focus the shell is handing elsewhere.
            refocusAfterClose = false
            dwellSuppressedElement = nil
            dwellTask?.cancel()
            TVFocusDiagnostics.record("request", "TopMenu", "watchdogReset")
            ignoreNextFocusLoss = focusedItem != nil
            focusedItem = nil
        }
        .onChange(of: focusRequest) { _, _ in
            let target = focusRequestTarget.map { String(describing: $0) } ?? "nil"
            Self.logger.debug("topMenu.focusRequest request=\(focusRequest, privacy: .public) target=\(target, privacy: .public)")
            requestMenuFocus()
        }
        // No `focusedItem = nil` on content hand-off: resigning focus first
        // left a frame with nothing focused. The page's own focus claim moves
        // focus out of the bar in one step; until it lands, the tab keeps it.
        .onChange(of: isMenuFocused) { _, newValue in
            if !newValue { dwellSuppressedElement = nil }
        }
        .onChange(of: panelEntersFocus) { _, entered in
            if entered { isMenuFocused = false }
        }
        .onChange(of: focusedItem) { _, newValue in
            let item = newValue.map { String(describing: $0) } ?? "nil"
            Self.logger.debug("topMenu.focus item=\(item, privacy: .public) panelHasFocus=\(panelHasFocus, privacy: .public) panelEntersFocus=\(panelEntersFocus, privacy: .public)")
            if let newValue {
                // A delayed binding report from the native move into an
                // entered panel must not replace UIKit's actual source tab.
                guard !panelEntersFocus else { return }
                lastBarFocus = newValue
                refocusAfterClose = false
                ignoreNextFocusLoss = false
                // Dropdowns follow actual focus, never the ownership flag:
                // the focused element's dropdown becomes the eligible Down
                // target, a stale preview closes, and the dwell restarts.
                // A passive preview never blocks a page claim, and the dwell
                // fires only if focus is still here when it elapses.
                onFocusedPanelChanged(dwellTarget(for: newValue))
                scheduleDwell(for: newValue)
                // Ownership follows intent, not mere arrival: a user move or
                // the bar's own request. A system repair or initial
                // resolution that lands on the always-enabled bar leaves the
                // page free to complete its pending entry or return claim.
                let owned = requestedFocus == newValue
                requestedFocus = nil
                guard owned || isMenuFocused else {
                    TVFocusDiagnostics.value("state", "TopMenu", "systemArrivalLeftUnowned", newValue)
                    return
                }
                pendingBarFocusLoss = false
                isMenuFocused = !panelEntersFocus
                return
            }
            // Entered mode: the panel claimed focus; stay passive (see
            // `panelEntersFocus`).
            if panelEntersFocus {
                isMenuFocused = false
                dwellTask?.cancel()
                return
            }
            let ignored = ignoreNextFocusLoss
            ignoreNextFocusLoss = false
            pendingBarFocusLoss = !ignored && isMenuFocused
            isMenuFocused = false
            dwellTask?.cancel()
        }
        .onAppear { TVFocusMovementTracker.setHandler(owner: movementObserverID, handleFocusTransition) }
        .onDisappear {
            dwellTask?.cancel()
            TVFocusMovementTracker.removeHandler(owner: movementObserverID)
        }
    }

    private func handleFocusTransition(_ transition: TVBarFocusTransition, key: AnyHashable?) {
        TVFocusDiagnostics.value("state", "TopMenu", "scopedTransition", transition)
        let actualItem = key?.base as? TVTopMenuFocus
        switch transition {
        case .userArrival:
            guard !panelEntersFocus else { return }
            isMenuFocused = true
            if let actualItem { lastBarFocus = actualItem }
        case .downFromBar:
            // Down is native: from a panel-bearing element the engine lands
            // in its eligible dropdown, which reports focus and is entered by
            // the host; from any other element it lands on the page. Neither
            // case is decided here, and nothing writes focus. Only ownership
            // is released.
            pendingBarFocusLoss = false
            refocusAfterClose = false
            guard !panelEntersFocus else { return }
            isMenuFocused = false
            if let actualItem { lastBarFocus = actualItem }
            if dwellTarget(for: actualItem) == nil {
                onFocusedPanelChanged(nil)
                onContentFocusHandoff()
            }
        case .otherDeparture:
            let wasOwned = isMenuFocused || pendingBarFocusLoss
            pendingBarFocusLoss = false
            guard !panelEntersFocus else { return }
            guard wasOwned, let actualItem else {
                // A system move (a page claim) took focus off the bar. Close
                // a passive preview so it never lingers over the page.
                onFocusedPanelChanged(nil)
                if openPanel != nil { onDwell(nil) }
                return
            }
            lastBarFocus = actualItem
            if openPanel != nil || refocusAfterClose {
                refocusAfterClose = false
                claimBarFocus(actualItem)
            } else {
                isMenuFocused = false
                onFocusedPanelChanged(nil)
                scheduleDwell(for: nil)
                onContentFocusHandoff()
            }
        case .unrelated:
            break
        }
    }

    // MARK: - Clusters

    /// Brand logo (mark + wordmark asset), sized to the bar row so it sits
    /// on the same centre line as the tab capsules and trailing icons.
    private var wordmark: some View {
        TVKyroWordmarkView(width: 142)
            .frame(height: SiloTheme.Skyline.barHeight)
            .accessibilityHidden(true)
    }

    private var tabCluster: some View {
        ViewThatFits(in: .horizontal) {
            centeredTabCluster
            scrollingTabCluster
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .frame(height: SiloTheme.Skyline.barHeight)
    }

    /// Keep the ordinary menu as one native focus row. Besides preserving the
    /// Skyline screen-centered composition, this gives Search and Home direct
    /// focus adjacency instead of separating them with a scroll container.
    private var centeredTabCluster: some View {
        HStack(spacing: SiloTheme.Skyline.tabSpacing) {
            searchButton

            ForEach(Array(roots.enumerated()), id: \.element) { index, root in
                rootButton(root, index: index, count: roots.count)
            }

            // Balance Search so the roots themselves remain screen-centered.
            Color.clear
                .frame(
                    width: SiloTheme.Skyline.barIconSize,
                    height: SiloTheme.Skyline.barIconSize
                )
                .accessibilityHidden(true)
        }
        // `ViewThatFits` must measure the row's intrinsic width so it can
        // select the scrolling fallback only when customization overflows.
        .fixedSize(horizontal: true, vertical: false)
    }

    /// Long customized menus keep Search fixed and scroll only the roots.
    private var scrollingTabCluster: some View {
        HStack(spacing: SiloTheme.Skyline.tabSpacing) {
            searchButton

            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: SiloTheme.Skyline.tabSpacing) {
                        ForEach(Array(roots.enumerated()), id: \.element) { index, root in
                            rootButton(root, index: index, count: roots.count)
                                .id(TVTopMenuFocus.root(root))
                        }
                    }
                    .scrollTargetLayout()
                }
                .scrollClipDisabled()
                .onChange(of: focusedItem) { _, item in
                    guard let item, case .root = item else { return }
                    withAnimation(reduceMotion ? nil : .easeOut(duration: SiloTheme.fastDuration)) {
                        proxy.scrollTo(item, anchor: .center)
                    }
                }
                .onChange(of: selectedRoot) { _, root in
                    proxy.scrollTo(TVTopMenuFocus.root(root), anchor: .center)
                }
            }
        }
        // Search and Profile stay fixed while only the customizable roots
        // scroll through the center lane.
        .padding(.horizontal, 150)
        .frame(maxWidth: .infinity)
    }

    // MARK: - Tabs

    private func rootButton(_ root: TVRootDestination, index: Int, count: Int) -> some View {
        // While its panel owns focus the tab reads as selected, not focused
        // (§5.1) — the inverted look transfers to the panel row.
        let panelOwnsFocus = panelEntersFocus && openPanel == .root(root)
        let isFocused = focusedItem == .root(root) && !panelEntersFocus
        let isSelected = selectedRoot == root || panelOwnsFocus

        return Button {
            selectRootFromMenu(root)
        } label: {
            Text(root.title)
                .font(.system(size: SiloTheme.Skyline.tabLabelSize, weight: .semibold))
                .foregroundStyle(tabForeground(isSelected: isSelected, isFocused: isFocused))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: 260)
                .padding(.horizontal, SiloTheme.Skyline.tabPaddingHorizontal)
                .padding(.vertical, SiloTheme.Skyline.tabPaddingVertical)
                .modifier(TVTopMenuCapsuleChrome(isSelected: isSelected, isFocused: isFocused))
        }
        .buttonStyle(.siloFlat)
        .focused($focusedItem, equals: .root(root))
        .background(TVBarFocusItemRegion(key: AnyHashable(TVTopMenuFocus.root(root))))
        // A ScrollView is its own focus region on tvOS. At its leading edge,
        // explicitly hand Left back to the fixed Search anchor.
        .modifier(TVTopMenuLeadingBoundaryHandler(isLeading: index == 0) {
            TVFocusDiagnostics.record("request", "TopMenu", "leadingBoundaryToSearch")
            claimBarFocus(.search)
        })
        // No Down handler: Down is a native move. When it leaves a
        // panel-bearing tab, the focus-loss decision enters that tab's panel
        // (see `handleFocusTransition`), so clicks and swipes behave the same and
        // the panel has exactly one Down owner.
        // Panel-bearing tabs publish their bounds so the shell can center the
        // anchored dropdown under them (§5.3); other tabs have no panel.
        .modifier(TVTopMenuAnchorPublisher(panel: rootPanel(root)))
        // Debug-overlay hint: SwiftUI's content→menu section hop lands on
        // the selected tab, but that rule is invisible to the focus
        // engine — the selected tab publishes its frame so the overlay
        // can mark it as the Up destination. Renders nothing when the
        // overlay setting is off; debug builds only.
        #if DEBUG
        .background(TVFocusDebugTabFramePublisher(isSelected: selectedRoot == root))
        #endif
        .accessibilityLabel("\(root.title), tab, \(index + 1) of \(count)")
        .accessibilityHint(rootPanelHint(for: root))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func rootPanel(_ root: TVRootDestination) -> TVTopMenuPanel? {
        switch root {
        case .libraryType:
            return TVLibraryMenuRootKind.category.hasSectionCascade ? .root(root) : nil
        case .libraryShortcut:
            return TVLibraryMenuRootKind.directShortcut.hasSectionCascade ? .root(root) : nil
        case .recommendations:
            return .root(root)
        case .home, .liveTV, .sports, .calendar, .requests:
            return nil
        }
    }

    private func rootPanelHint(for root: TVRootDestination) -> String {
        switch root {
        case .libraryType:
            return "Rest to choose a library"
        case .libraryShortcut:
            return "Rest to choose a section"
        case .recommendations:
            return "Rest to choose Watchlist, Favorites, or Recommendations"
        case .home, .liveTV, .sports, .calendar, .requests:
            return ""
        }
    }

    private func tabForeground(isSelected: Bool, isFocused: Bool) -> Color {
        if isFocused { return .siloBackground }
        if isSelected { return .white }
        return .white.opacity(0.62)
    }

    /// The tab keeps focus until the new page's claim moves it. Resigning it
    /// first (the old `focusedItem = nil` one turn later) left a gap that the
    /// always-enabled bar's default focus could win.
    private func selectRootFromMenu(_ root: TVRootDestination) {
        onSelectRoot(root)
    }

    /// Every bar-initiated focus write goes through here, so its arrival is
    /// recognised as the bar's own request.
    private func claimBarFocus(_ target: TVTopMenuFocus) {
        requestedFocus = target
        focusedItem = target
    }

    /// One explicit claim per request (Back from content, panel close, pop to
    /// root). The bar is enabled, so the write lands directly; there is no
    /// timed retry. A request for the element that already has focus is a
    /// no-op instead of a nil-and-reclaim bounce.
    private func requestMenuFocus() {
        let target: TVTopMenuFocus
        switch focusRequestTarget {
        // A non-nil target means focus is returning from an explicit panel
        // close (focusTopMenuIfVisible(focusing:) is only called that way).
        // Mark it so the dwell timer doesn't immediately reopen what the
        // user just dismissed. A target-less request (Up/Menu from content)
        // leaves dwell enabled — resting on a tab there should preview it.
        case .root(let root):
            dwellSuppressedElement = .root(root)
            target = .root(root)
        case .profile:
            dwellSuppressedElement = .profile
            target = .profile
        case .none:
            target = .root(selectedRoot)
        }
        switch tvTopMenuFocusClaim(bindingMatchesTarget: focusedItem == target, barOwnsFocus: isMenuFocused) {
        case .alreadyFocused:
            // Never claims ownership here: only a real arrival does.
            TVFocusDiagnostics.value("state", "TopMenu", "requestAlreadyFocused", target)
            return
        case .reclaimStale:
            // Writing the same value is a no-op, so clear the stale binding
            // and claim on the next turn. One explicit re-claim, no retry.
            TVFocusDiagnostics.value("request", "TopMenu", "reclaimStale", target)
            ignoreNextFocusLoss = true
            requestedFocus = target
            focusedItem = nil
            DispatchQueue.main.async { claimBarFocus(target) }
            return
        case .claim:
            TVFocusDiagnostics.value("request", "TopMenu", "explicit", target)
            claimBarFocus(target)
        }
        Self.logger.debug("topMenu.requestMenuFocus target=\(String(describing: target), privacy: .public)")
    }

    // MARK: - Search

    private var searchButton: some View {
        let isFocused = focusedItem == .search && !panelEntersFocus

        return Button(action: onSearch) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 27, weight: .semibold))
                .foregroundStyle(isFocused ? Color.siloBackground : .white.opacity(0.62))
                .frame(
                    width: SiloTheme.Skyline.barIconSize,
                    height: SiloTheme.Skyline.barIconSize
                )
                .modifier(TVTopMenuCapsuleChrome(isSelected: false, isFocused: isFocused))
        }
        .buttonStyle(.siloFlat)
        .focused($focusedItem, equals: .search)
        .background(TVBarFocusItemRegion(key: AnyHashable(TVTopMenuFocus.search)))
        // The inverse boundary keeps Search usable in the scrolling fallback,
        // where the roots sit in a separate scroll region. Down is native: the
        // page's entry section declares where it lands.
        .onMoveCommand { direction in
            guard direction == .right else { return }
            TVFocusDiagnostics.value("handler", "TopMenu", "searchMove", direction)
            guard let firstRoot = roots.first else { return }
            TVFocusDiagnostics.value("request", "TopMenu", "searchRightToRoot", TVTopMenuFocus.root(firstRoot))
            claimBarFocus(.root(firstRoot))
        }
        .accessibilityLabel("Search")
    }

    private var settingsButton: some View {
        let isFocused = focusedItem == .settings && !panelEntersFocus

        return Button(action: onSettings) {
            Image(systemName: "gearshape.fill")
                .font(.system(size: 25, weight: .semibold))
                .foregroundStyle(isFocused ? Color.siloBackground : KyroTheme.silver.opacity(0.76))
                .frame(
                    width: SiloTheme.Skyline.barIconSize,
                    height: SiloTheme.Skyline.barIconSize
                )
                .modifier(TVTopMenuCapsuleChrome(isSelected: false, isFocused: isFocused))
        }
        .buttonStyle(.siloFlat)
        .focused($focusedItem, equals: .settings)
        .background(TVBarFocusItemRegion(key: AnyHashable(TVTopMenuFocus.settings)))
        .accessibilityLabel("Settings")
    }

    // MARK: - Profile

    private var profileButton: some View {
        // The avatar keeps its focus ring while the profile panel is open
        // and focus is still on the avatar; once focus descends into the
        // panel the ring drops (the panel rows carry focus then, §5.8).
        let isFocused = focusedItem == .profile && !panelEntersFocus

        return Button {
            // Press opens and enters immediately (§5.8); dwell only previews.
            onProfilePressed()
        } label: {
            ProfileAvatarView(
                avatar: currentProfile?.avatarEmoji,
                imageUrl: currentProfile?.avatarImageUrl,
                name: currentProfile?.name ?? "",
                size: SiloTheme.Skyline.barIconSize,
                backgroundColor: Color.white.opacity(0.18),
                textColor: .white
            )
            .overlay {
                Circle()
                    .strokeBorder(Color.white, lineWidth: isFocused ? 3 : 0)
            }
            // Reduce Motion drops the focus scale so the avatar snaps (§4.2).
            .scaleEffect(isFocused && !reduceMotion ? 1.05 : 1.0)
            .focusEffectDisabled()
            .animation(reduceMotion ? nil : SiloTheme.springAnimation, value: isFocused)
        }
        .buttonStyle(.siloFlat)
        .focused($focusedItem, equals: .profile)
        .background(TVBarFocusItemRegion(key: AnyHashable(TVTopMenuFocus.profile)))
        .modifier(TVTopMenuAnchorPublisher(panel: .profile))
        .accessibilityLabel("Profile")
        .accessibilityHint("Rest or press to open the profile menu")
    }

    private var shouldCaptureExitPress: Bool {
        focusedItem != nil
            && !panelEntersFocus
            && (openPanel != nil || isFocusedAwayFromHome || onExit != nil)
    }

    /// Menu handler for the bar: closes a dwell-open panel first (§5.3
    /// "Menu closes"), otherwise runs the page-level bar exit. This is captured
    /// by `TVWindowMenuPressCatcher` instead of `.onExitCommand` so changing
    /// `openPanel` never rewrites the focused tab's SwiftUI ancestor chain.
    private func handleExitPress() {
        TVFocusDiagnostics.record("handler", "TopMenu", "back")
        let item = focusedItem.map { String(describing: $0) } ?? "nil"
        Self.logger.debug("topMenu.exitPress focusedItem=\(item, privacy: .public) openPanel=\(openPanel != nil, privacy: .public) selectedRoot=\(String(describing: selectedRoot), privacy: .public)")
        if openPanel != nil {
            onDwell(nil)
            return
        }
        if isFocusedAwayFromHome, selectedRoot == .home {
            claimBarFocus(.root(.home))
            isMenuFocused = true
            return
        }
        onExit?()
    }

    private var isFocusedAwayFromHome: Bool {
        focusedItem != nil && focusedItem != .root(.home)
    }

    // MARK: - Dwell (§5.3, §5.8)

    /// Restart the dwell timer whenever focus settles on a new bar
    /// element. A library tab or the profile avatar opens its panel after
    /// the dwell interval; any other element (or losing focus) closes any
    /// open panel immediately. Cancelled on every focus move so a sweep
    /// across the bar never opens a panel (Open-Q5/Q7).
    private func scheduleDwell(for item: TVTopMenuFocus?) {
        dwellTask?.cancel()

        // Moving focus to a *different bar element* — another tab, or the
        // search button — closes the open panel right away (§5.3: "moving
        // sideways to another tab closes it"), so it doesn't linger during
        // the new element's dwell. Once the panel is expected to own focus,
        // ignore top-bar repairs: tvOS may briefly re-home to Home while
        // the panel row focus claim is being applied.
        if let item, TVTopMenuPanelFocusPolicy.closesStalePreview(
            openPanel: openPanel, panelEntered: panelEntersFocus,
            focusedElementPanel: dwellTarget(for: item)) {
            onDwell(nil)
            // Closing the panel removes its overlay, which perturbs focus and
            // drops the tab we just moved to; flag it so the nil-drop re-pins.
            refocusAfterClose = true
        }

        // Don't auto-reopen a panel the user just explicitly closed: Menu/Back
        // returns focus to its tab, and resting there would otherwise re-trip
        // the dwell. Once focus has moved on to a *different* element, drop the
        // suppression so normal dwell resumes.
        if let suppressed = dwellSuppressedElement {
            if suppressed == item { return }
            dwellSuppressedElement = nil
        }

        guard let target = dwellTarget(for: item) else { return }

        dwellTask = Task { @MainActor in
            try? await Task.sleep(
                nanoseconds: SiloTheme.Skyline.cascadeDwellMilliseconds * 1_000_000
            )
            guard !Task.isCancelled else { return }
            // Confirm focus is still on the same element before opening —
            // a late move that didn't cancel in time must not fire.
            guard focusedItem == item else { return }
            onDwell(target)
        }
    }

    /// Maps a focused bar element to the panel it should dwell-open, or
    /// `nil` for elements with no panel (wordmark/search/non-library tabs).
    private func dwellTarget(for item: TVTopMenuFocus?) -> TVTopMenuPanel? {
        switch item {
        case .root(let root):
            return rootPanel(root)
        case .profile:
            return .profile
        case .search, .settings, .none:
            return nil
        }
    }
}

/// Which bar element an anchored panel is attached to (§5.3/§5.8).
enum TVTopMenuPanel: Hashable {
    case root(TVRootDestination)
    case profile
}

private enum TVTopMenuFocus: Hashable {
    case root(TVRootDestination)
    case search
    case settings
    case profile
}

/// Capsule chrome for top-bar tabs and the search button (§5.1):
/// resting = bare label, selected = `chrome.selected` capsule, focused =
/// inverted white capsule. Focus inversion is the platform grammar — no
/// outline ring, no system halo.
private struct TVTopMenuCapsuleChrome: ViewModifier {
    let isSelected: Bool
    let isFocused: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .background(Capsule().fill(fillColor))
            .overlay {
                Capsule().strokeBorder(borderColor, lineWidth: 1)
            }
            .focusEffectDisabled()
            // Reduce Motion snaps the tab/search capsule inversion (§4.2).
            .animation(reduceMotion ? nil : SiloTheme.springAnimation, value: isFocused)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: isSelected)
    }

    private var fillColor: Color {
        if isFocused { return .white }
        if isSelected { return .siloChromeSelectedFill }
        return .clear
    }

    private var borderColor: Color {
        if isFocused { return .clear }
        if isSelected { return .siloChromeSelectedBorder }
        return .clear
    }
}

/// Shared surface for every Skyline anchored menu (§5.3 cascade + flyout,
/// §5.8 profile) so they read as one family. A frosted material base under
/// a near-opaque vertical tint — lighter at the top, as if lit from above —
/// finished with a gradient hairline that brightens along the top lip and a
/// two-layer shadow (a tight contact shadow under a broad ambient one) so
/// the panel floats over the page on its own depth rather than needing a
/// page scrim to darken everything behind it.
struct TVSkylinePanelChrome: ViewModifier {
    var cornerRadius: CGFloat = SiloTheme.Skyline.dropdownCornerRadius

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return content
            .background(shape.fill(.regularMaterial))
            .background(
                shape.fill(
                    LinearGradient(
                        colors: [
                            Color(hex: "#23252C").opacity(0.92),
                            Color(hex: "#141519").opacity(0.95),
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
            )
            .overlay {
                shape.strokeBorder(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.22),
                            Color.white.opacity(0.05),
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 1
                )
            }
            .shadow(color: .black.opacity(0.35), radius: 8, y: 4)
            .shadow(color: .black.opacity(0.55), radius: 40, y: 24)
    }
}

/// Mono section header shared by the Skyline panels and the action popover.
struct TVSkylinePanelHeader: View {
    let text: String
    var size: CGFloat = SiloTheme.Skyline.dropdownHeaderSize
    var horizontalPadding: CGFloat = 16
    var topPadding: CGFloat = 8
    var bottomPadding: CGFloat = 10

    var body: some View {
        Text(text)
            .font(.system(size: size, design: .monospaced))
            .tracking(size * 0.26)
            .foregroundStyle(Color.white.opacity(0.38))
            .lineLimit(1)
            .padding(.horizontal, horizontalPadding)
            .padding(.top, topPadding)
            .padding(.bottom, bottomPadding)
    }
}

/// The bar is inert only while an entered panel owns focus. Content focus
/// never disables it; that made Up depend on a per-page `onMoveCommand`,
/// which touch-surface swipes do not reliably deliver.
func tvTopMenuIsInert(panelEntered: Bool) -> Bool { panelEntered }

/// The scrolling overflow layout puts its roots in a separate focus region
/// from the fixed Search button. This boundary reconnects the two regions
/// without taking ownership of ordinary movement inside either one.
private struct TVTopMenuLeadingBoundaryHandler: ViewModifier {
    let isLeading: Bool
    let onMoveLeft: () -> Void

    @ViewBuilder
    func body(content: Content) -> some View {
        if isLeading {
            content.onMoveCommand { direction in
                TVFocusDiagnostics.value("handler", "TopMenuLeadingBoundary", "move", direction)
                if direction == .left { onMoveLeft() }
            }
        } else {
            content
        }
    }
}

/// Publishes a bar element's bounds into `TVTopMenuAnchorKey` so the shell
/// can anchor its panel. A `nil` panel publishes nothing (elements with no
/// panel).
private struct TVTopMenuAnchorPublisher: ViewModifier {
    let panel: TVTopMenuPanel?

    @ViewBuilder
    func body(content: Content) -> some View {
        if let panel {
            content.anchorPreference(key: TVTopMenuAnchorKey.self, value: .bounds) {
                [panel: $0]
            }
        } else {
            content
        }
    }
}

/// Window-level Menu press capture. A SwiftUI `.onExitCommand` fires only
/// while its view holds focus, and adding or removing one around a focused
/// view rebuilds that view's ancestor chain. This recognizer stays mounted
/// and declines the press while inactive, so the system Menu behavior still
/// passes through (on Home, for the top bar).
struct TVWindowMenuPressCatcher: UIViewRepresentable {
    var isActive = true
    var onExit: () -> Void

    func makeUIView(context: Context) -> TVWindowMenuPressUIView {
        let view = TVWindowMenuPressUIView()
        apply(to: view)
        return view
    }

    func updateUIView(_ uiView: TVWindowMenuPressUIView, context: Context) {
        apply(to: uiView)
    }

    private func apply(to view: TVWindowMenuPressUIView) {
        view.isActive = isActive
        view.onExit = onExit
    }
}

final class TVWindowMenuPressUIView: UIView, UIGestureRecognizerDelegate {
    var isActive = false
    var onExit: () -> Void = {}

    private weak var attachedWindow: UIWindow?
    private var recognizer: UITapGestureRecognizer?

    override func didMoveToWindow() {
        super.didMoveToWindow()
        attachRecognizerIfNeeded()
    }

    deinit {
        detachRecognizer()
    }

    private func attachRecognizerIfNeeded() {
        guard attachedWindow !== window else { return }
        detachRecognizer()

        guard let window else { return }
        let recognizer = UITapGestureRecognizer(target: self, action: #selector(handleMenuPress(_:)))
        recognizer.allowedPressTypes = [NSNumber(value: UIPress.PressType.menu.rawValue)]
        recognizer.cancelsTouchesInView = true
        recognizer.delegate = self

        window.addGestureRecognizer(recognizer)
        attachedWindow = window
        self.recognizer = recognizer
    }

    private func detachRecognizer() {
        if let recognizer, let attachedWindow {
            attachedWindow.removeGestureRecognizer(recognizer)
        }
        recognizer = nil
        attachedWindow = nil
    }

    @objc private func handleMenuPress(_ recognizer: UITapGestureRecognizer) {
        guard isActive, recognizer.state == .ended else { return }
        TVFocusDiagnostics.record("handler", "WindowMenuCatcher", "back-ended")
        onExit()
    }

    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        isActive && window != nil
    }
}

// MARK: - For You dropdown

private enum TVForYouAction: Hashable {
    case watchlist
    case favorites
    case recommendations
}

/// Anchored For You dropdown: a single-level menu under the For You root
/// tab, matching the top-bar dwell/down focus contract used by library
/// cascades.
struct TVForYouDropdown: View {
    /// Rows are real focus targets: the For You tab holds bar focus (Down
    /// lands on a row natively) or the panel is entered. Otherwise they are
    /// passive labels.
    let acceptsFocus: Bool
    let focusEntryGeneration: Int
    let onPanelFocusChanged: (Bool) -> Void
    let onClose: () -> Void
    let onExitToContent: () -> Void
    let onWatchlist: () -> Void
    let onFavorites: () -> Void
    let onRecommendations: () -> Void

    @FocusState private var focusedAction: TVForYouAction?
    @State private var lastAppliedEntryGeneration = 0

    var body: some View {
        panel
            .tvObserveFocus("ForYouDropdown", value: focusedAction)
            .onChange(of: focusEntryGeneration) { _, generation in
                applyEntryGeneration(generation)
            }
            .onChange(of: focusedAction) { _, newValue in
                onPanelFocusChanged(newValue != nil)
            }
            .onChange(of: acceptsFocus) { _, entered in
                if !entered { focusedAction = nil }
            }
            .onAppear {
                if acceptsFocus { applyEntryGeneration(focusEntryGeneration) }
            }
    }

    private func applyEntryGeneration(_ generation: Int) {
        guard acceptsFocus,
              generation > 0,
              generation != lastAppliedEntryGeneration else { return }
        lastAppliedEntryGeneration = generation
        TVFocusDiagnostics.record("request", "ForYouDropdown", "entryWatchlist")
        focusedAction = .watchlist
    }

    private var panel: some View {
        VStack(alignment: .leading, spacing: 10) {
            panelHeader

            actionButton("Watchlist", systemImage: "bookmark.fill", id: .watchlist, action: onWatchlist)
                .modifier(TVDropdownBoundaryMoveHandler(onMoveUp: onClose, onMoveDown: nil))
            actionButton("Favorites", systemImage: "heart.fill", id: .favorites, action: onFavorites)
            actionButton("Recommendations", systemImage: "sparkles", id: .recommendations, action: onRecommendations)
                .modifier(TVDropdownBoundaryMoveHandler(onMoveUp: nil, onMoveDown: onExitToContent))
        }
        .padding(SiloTheme.Skyline.dropdownPadding)
        .frame(width: SiloTheme.Skyline.dropdownWidth, alignment: .leading)
        .modifier(TVSkylinePanelChrome())
        .focusSection()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("For You menu")
    }

    private var panelHeader: some View {
        TVSkylinePanelHeader(text: "FOR YOU", bottomPadding: 2)
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private func actionButton(
        _ title: String,
        systemImage: String,
        id: TVForYouAction,
        action: @escaping () -> Void
    ) -> some View {
        let label = HStack(spacing: 14) {
            Image(systemName: systemImage)
                .font(.system(size: 20, weight: .semibold))
                .frame(width: 30)

            Text(title)
                .font(.system(size: SiloTheme.Skyline.dropdownRowTextSize, weight: .semibold))
                .lineLimit(1)

            Spacer(minLength: 0)
        }

        if acceptsFocus {
            Button(action: action) {
                label
            }
            .buttonStyle(TVProfileMenuButtonStyle(isDestructive: false))
            .focused($focusedAction, equals: id)
        } else {
            label
                .foregroundStyle(.white.opacity(0.86))
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
        }
    }
}

private struct TVDropdownBoundaryMoveHandler: ViewModifier {
    let onMoveUp: (() -> Void)?
    let onMoveDown: (() -> Void)?

    func body(content: Content) -> some View {
        content.onMoveCommand { direction in
            TVFocusDiagnostics.value("handler", "DropdownBoundary", "move", direction)
            switch direction {
            case .up:
                onMoveUp?()
            case .down:
                onMoveDown?()
            default:
                break
            }
        }
    }
}

// MARK: - Profile dropdown

private enum TVProfileAction: Hashable {
    case switchProfile
    case watchlist
    case favorites
    case history
    case watchParty
    case settings
    case switchServer
    case signOut
}

/// Anchored profile dropdown panel (§5.8): the same `glass.strong` level-1
/// panel as the cascade, hosted by the shell under the avatar. The shell
/// owns positioning and Menu-to-close; this view owns only its rows and the
/// focus hand-off when the host bumps `focusEntryGeneration`.
struct TVProfileDropdown: View {
    let profileName: String
    let avatar: String?
    /// Server-resolved avatar image URL (`avatar_url`), preferred over the
    /// raw `avatar` ref when present.
    var avatarImageUrl: String? = nil
    /// Display name of the active server, shown under the profile name in
    /// the §5.8 mono header style.
    let serverHost: String?
    /// Rows are real focus targets: the avatar holds bar focus (Down lands on
    /// a row natively) or the panel is entered. Otherwise passive labels.
    let acceptsFocus: Bool
    /// Bumped by the host when focus should enter — lands on the first row.
    let focusEntryGeneration: Int
    /// Reports whether any row currently holds focus, so the host can drop
    /// the avatar's focus ring once focus descends (§5.8).
    let onPanelFocusChanged: (Bool) -> Void
    let onSwitchProfile: () -> Void
    let onWatchlist: () -> Void
    let onFavorites: () -> Void
    let onHistory: () -> Void
    let onWatchParty: () -> Void
    let onSettings: () -> Void
    let onSwitchServer: () -> Void
    let onSignOut: () -> Void

    @FocusState private var focusedAction: TVProfileAction?
    @State private var lastAppliedEntryGeneration = 0

    var body: some View {
        panel
            // Rows are passive labels until the panel can take focus: its
            // avatar is focused or the panel is entered.
            .onChange(of: focusEntryGeneration) { _, generation in
                applyEntryGeneration(generation)
            }
            .onChange(of: focusedAction) { _, newValue in
                onPanelFocusChanged(newValue != nil)
            }
            .onChange(of: acceptsFocus) { _, entered in
                if !entered { focusedAction = nil }
            }
            .onAppear {
                if acceptsFocus { applyEntryGeneration(focusEntryGeneration) }
            }
    }

    private func applyEntryGeneration(_ generation: Int) {
        guard acceptsFocus,
              generation > 0,
              generation != lastAppliedEntryGeneration else { return }
        lastAppliedEntryGeneration = generation
        TVFocusDiagnostics.record("request", "ProfileDropdown", "entrySwitchProfile")
        focusedAction = .switchProfile
    }

    private var panel: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            actionButton("Switch Profile", systemImage: "person.2.fill", id: .switchProfile, action: onSwitchProfile)
            actionButton("Watchlist", systemImage: "bookmark.fill", id: .watchlist, action: onWatchlist)
            actionButton("Favorites", systemImage: "heart.fill", id: .favorites, action: onFavorites)
            actionButton("History", systemImage: "clock.fill", id: .history, action: onHistory)
            if WatchPartyEntry.isAvailable {
                actionButton(WatchPartySession.shared.isEngaged ? "Return to Watch Party" : "Watch Party", systemImage: "person.3", id: .watchParty, action: onWatchParty)
            }

            divider

            actionButton("Settings", systemImage: "gearshape.fill", id: .settings, action: onSettings)
            // The guide marks Switch Server as Android-only (§5.8), but tvOS
            // already ships multi-server switching — dropping it here would
            // regress existing users.
            actionButton("Switch Server", systemImage: "server.rack", id: .switchServer, action: onSwitchServer)
            actionButton("Sign Out", systemImage: "rectangle.portrait.and.arrow.right", id: .signOut, isDestructive: true, action: onSignOut)
        }
        .padding(SiloTheme.Skyline.dropdownPadding)
        .frame(width: SiloTheme.Skyline.dropdownWidth, alignment: .leading)
        .modifier(TVSkylinePanelChrome())
        .focusSection()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Profile menu")
    }

    private var header: some View {
        HStack(spacing: 14) {
            ProfileAvatarView(
                avatar: avatar,
                imageUrl: avatarImageUrl,
                name: profileName,
                size: 44,
                backgroundColor: Color.white.opacity(0.16),
                textColor: .white
            )

            VStack(alignment: .leading, spacing: 2) {
                Text(profileName)
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)

                if let serverHost, !serverHost.isEmpty {
                    Text(serverHost.uppercased())
                        .font(.system(size: SiloTheme.Skyline.dropdownHeaderSize, design: .monospaced))
                        .tracking(1.4)
                        .foregroundStyle(Color.white.opacity(0.38))
                        .lineLimit(1)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private var divider: some View {
        Rectangle()
            .fill(Color.siloDivider)
            .frame(height: 1)
            .padding(.horizontal, 12)
    }

    @ViewBuilder
    private func actionButton(
        _ title: String,
        systemImage: String,
        id: TVProfileAction,
        isDestructive: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        let label = HStack(spacing: 14) {
            Image(systemName: systemImage)
                .font(.system(size: 20, weight: .semibold))
                .frame(width: 30)

            Text(title)
                .font(.system(size: SiloTheme.Skyline.dropdownRowTextSize, weight: .semibold))
                .lineLimit(1)

            Spacer(minLength: 0)
        }

        if acceptsFocus {
            Button(action: action) {
                label
            }
            .buttonStyle(TVProfileMenuButtonStyle(isDestructive: isDestructive))
            .focused($focusedAction, equals: id)
        } else {
            label
                .foregroundStyle(isDestructive ? .red.opacity(0.9) : .white.opacity(0.86))
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
        }
    }
}

private struct TVProfileMenuButtonStyle: ButtonStyle {
    let isDestructive: Bool

    func makeBody(configuration: Configuration) -> some View {
        TVProfileMenuButtonBody(
            configuration: configuration,
            isDestructive: isDestructive
        )
    }
}

private struct TVProfileMenuButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let isDestructive: Bool

    @Environment(\.isFocused) private var isFocused
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        configuration.label
            .foregroundStyle(foregroundColor)
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(isFocused ? Color.white : Color.clear)
            )
            .opacity(configuration.isPressed ? 0.75 : 1.0)
            .focusEffectDisabled()
            // Match the cascade: focus feedback follows each press immediately.
            .animation(nil, value: isFocused)
            .animation(reduceMotion ? nil : .easeOut(duration: SiloTheme.fastDuration), value: configuration.isPressed)
    }

    private var foregroundColor: Color {
        if isFocused { return .siloBackground }
        if isDestructive { return .red.opacity(0.9) }
        return .white.opacity(0.86)
    }
}
#endif
