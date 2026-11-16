import Foundation
import SwiftUI

/// Per-category facts for the Categories page, built in one pass over the catalog already in
/// memory. Rows look values up here; nothing counts, sorts or scans inside a row body.
struct LiveTVCategoryDirectory: Equatable, Sendable {
    struct Entry: Equatable, Sendable {
        let channelCount: Int
        /// The first channel in provider order with a logo, used as the category's artwork.
        let artworkChannel: LiveTVChannel?
    }

    /// Provider order, unchanged.
    let categories: [String]
    let frequent: [String]
    let favoriteChannelCount: Int
    let totalChannelCount: Int
    private let entries: [String: Entry]

    static let empty = LiveTVCategoryDirectory(categories: [], frequent: [], favoriteChannelCount: 0,
                                               totalChannelCount: 0, entries: [:])

    func entry(for category: String) -> Entry {
        entries[category] ?? Entry(channelCount: 0, artworkChannel: nil)
    }

    static func build(categories: [String], channels: [LiveTVChannel], favoriteIDs: Set<String>,
                      ranksFrequent: Bool = true) -> LiveTVCategoryDirectory {
        var counts: [String: Int] = [:]
        var artwork: [String: LiveTVChannel] = [:]
        var favorites = 0
        counts.reserveCapacity(categories.count)
        for channel in channels {
            counts[channel.category, default: 0] += 1
            if channel.logoURL != nil, artwork[channel.category] == nil { artwork[channel.category] = channel }
            if favoriteIDs.contains(channel.id) { favorites += 1 }
        }
        var entries: [String: Entry] = [:]
        entries.reserveCapacity(categories.count)
        for category in categories where entries[category] == nil {
            entries[category] = Entry(channelCount: counts[category, default: 0], artworkChannel: artwork[category])
        }
        let frequent = ranksFrequent
            ? LiveTVGuideCategoryPickerModel.frequentCategories(categories: categories, channels: channels,
                                                                favoriteIDs: favoriteIDs)
            : []
        return LiveTVCategoryDirectory(categories: categories, frequent: frequent, favoriteChannelCount: favorites,
                                       totalChannelCount: channels.count, entries: entries)
    }
}

/// What the user picked on the Categories page.
enum LiveTVCategoryChoice: Equatable, Sendable {
    case all
    case favorites
    case category(String)

    /// The category filter this choice applies; favorites is not a category.
    var category: String? {
        if case .category(let name) = self { return name }
        return nil
    }
}

/// Navigation decisions for the Categories page, kept pure so they can be tested without a host.
enum LiveTVCategoryNavigation {
    /// How a caller shows the page. The watch screen's Guide is a tab under the player inside
    /// Watch's own cover; a push there would squeeze the page into that tab, so it gets a fixed
    /// full-height sheet with its own stack. Every other caller pushes.
    enum Presentation: Equatable { case push, fullHeightSheet }

    static func guidePresentation(isWatchGuide: Bool) -> Presentation {
        isWatchGuide ? .fullHeightSheet : .push
    }

    /// Home's choice becomes the browser's starting filters.
    static func homeFilters(for choice: LiveTVCategoryChoice) -> LiveTVBrowserFilters {
        switch choice {
        case .all: .channels
        case .favorites: .favorites
        case .category(let name): .category(name)
        }
    }

    /// The parent is selected at entry, not inferred from transient stack visibility.
    static func ownsPushedBrowser(fromCategories: Bool, isBrowserPushed: Bool,
                                  openedFromCategories: Bool) -> Bool {
        isBrowserPushed && openedFromCategories == fromCategories
    }

    static func shouldHandleBrowserPop(fromCategories: Bool, openedFromCategories: Bool,
                                       showingBrowser: Bool, stackShowsBrowser: Bool) -> Bool {
        openedFromCategories == fromCategories && showingBrowser && !stackShowsBrowser
    }

    static func shouldDismissCategories(showingCategories: Bool, browserPushedFromCategories: Bool) -> Bool {
        showingCategories && !browserPushedFromCategories
    }

    /// Where the browser replaces Home in place (Live TV itself pushed), Categories pops first.
    static func popsCategoriesOnChoice(isTabRoot: Bool) -> Bool {
        !LiveTVNavigationPolicy.pushesBrowser(isTabRoot: isTabRoot)
    }

    /// A filter page's choice is the new selection. Leaving with Back, a swipe or Cancel never
    /// calls this, so the selection stays as it was.
    static func filterSelection(for choice: LiveTVCategoryChoice) -> String? { choice.category }
}

/// How the page behaves for its caller. Home browses (rows push channels, so they show a chevron);
/// the channel browser and Guide filter (rows apply a selection, so the current one is checked).
enum LiveTVCategoryPageMode: Equatable {
    case browse
    case filter(selected: String?)

    var selected: String? {
        if case .filter(let selected) = self { return selected }
        return nil
    }
}

/// A letter tile for categories without artwork. The color comes from a stable hash of the name
/// so it is the same on every launch (`hashValue` is seeded per process).
enum LiveTVCategoryFallbackIcon {
    static func letter(for category: String) -> String {
        // Provider names often read "USA | Sports"; the part after the last separator is the name.
        let tail = category.split(separator: "|").last.map(String.init) ?? category
        let source = tail.first(where: { $0.isLetter || $0.isNumber }) != nil ? tail : category
        guard let first = source.first(where: { $0.isLetter || $0.isNumber }) else { return "#" }
        return String(first).uppercased()
    }

    static func hue(for category: String) -> Double {
        var hash: UInt32 = 5381
        for scalar in category.unicodeScalars { hash = (hash &* 33) &+ scalar.value }
        return Double(hash % 360) / 360
    }
}

/// Live TV's full-page category browser. Home, the channel browser and the Guide each pass their
/// own selection and remembered position, so sharing the page never couples their filters.
/// The page owns its scroll position and search while open; callers only hear the final choice
/// and, on leaving, the last visible row. Scrolling never writes the caller's state.
struct LiveTVCategoryBrowserPage: View {
    let title: String
    let allTitle: String
    let mode: LiveTVCategoryPageMode
    let categories: [String]
    let channels: [LiveTVChannel]
    let favoriteIDs: Set<String>
    let catalogRevision: Int
    /// Home offers a Favorites row; filters keep their own favorites toggle.
    var showsFavorites = false
    let initialPosition: LiveTVGuideCategoryPickerID?
    let select: (LiveTVCategoryChoice) -> Void
    /// Reports the last visible row when the page leaves, for the caller's remembered position.
    var rememberPosition: (LiveTVGuideCategoryPickerID?) -> Void = { _ in }
    /// Shown as a Cancel button when the page has its own stack (the watch screen's Guide).
    var cancel: (() -> Void)?

    @State private var query = ""
    @State private var directory = LiveTVCategoryDirectory.empty
    @State private var projection = LiveTVGuideCategoryPickerModel.Projection(frequent: [], remaining: [])
    @State private var position: LiveTVGuideCategoryPickerID?
    @State private var hasPrepared = false
    @FocusState private var isSearchFocused: Bool

    private var isSearching: Bool { !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                searchField
                LazyVStack(alignment: .leading, spacing: 0) {
                    rows
                }
                .scrollTargetLayout()
            }
            .padding(.bottom, 24)
        }
        .scrollPosition(id: $position, anchor: .top)
        .scrollDismissesKeyboard(.immediately)
        .liveTVPageBackground()
        .tint(LiveTVAccent.primaryText)
        .navigationTitle(title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.large)
        #endif
        .toolbar {
            if let cancel {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: cancel) }
            }
        }
        .accessibilityIdentifier("liveTVCategoriesPage")
        .onAppear(perform: prepareIfNeeded)
        .onDisappear { rememberPosition(position) }
        .onChange(of: query) { refreshProjection() }
        .onChange(of: catalogRevision) { rebuildDirectory(keepingPosition: true) }
        .onChange(of: categories) { rebuildDirectory(keepingPosition: true) }
        .onChange(of: favoriteIDs) { rebuildDirectory(keepingPosition: true) }
    }

    // MARK: Data

    private func prepareIfNeeded() {
        guard !hasPrepared else { return }
        hasPrepared = true
        position = initialPosition
        rebuildDirectory(keepingPosition: false)
    }

    private func rebuildDirectory(keepingPosition: Bool) {
        let interval = KyroPerformanceDiagnostics.begin("Category data", .categoryDirectory)
        directory = LiveTVCategoryDirectory.build(categories: categories, channels: channels, favoriteIDs: favoriteIDs)
        KyroPerformanceDiagnostics.end(interval)
        refreshProjection()
        if keepingPosition, case .category(let name)? = position, !categories.contains(name) {
            position = .allCategories
        }
    }

    private func refreshProjection() {
        let next = LiveTVGuideCategoryPickerModel.projection(categories: directory.categories, query: query,
                                                             frequent: directory.frequent)
        if next != projection { projection = next }
    }

    // MARK: Content

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(Color.siloSecondaryText)
                .accessibilityHidden(true)
            TextField("Search categories", text: $query)
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
                .autocorrectionDisabled()
                .submitLabel(.search)
                .focused($isSearchFocused)
                .foregroundStyle(Color.siloOnSurface)
                .accessibilityIdentifier("liveTVCategoriesSearch")
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Color.siloSecondaryText)
                        // Build 75: a finger-sized target without growing the field.
                        .frame(width: 36, height: 36)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.trailing, -8)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 40)
        .background(Color.siloSurfaceElevated, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.horizontal, 16)
        .padding(.top, 4)
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private var rows: some View {
        if !isSearching {
            row(id: .allCategories, title: allTitle, count: directory.totalChannelCount, symbol: "square.grid.2x2",
                isSelected: mode == .filter(selected: nil)) { select(.all) }
            if showsFavorites && directory.favoriteChannelCount > 0 {
                sectionHeader("Favorites")
                favoritesRow
            }
        }
        if !projection.frequent.isEmpty {
            sectionHeader("Frequent")
            ForEach(projection.frequent, id: \.self, content: categoryRow)
        }
        if !projection.remaining.isEmpty {
            sectionHeader("Categories")
            ForEach(projection.remaining, id: \.self, content: categoryRow)
        }
        if isSearching && projection.remaining.isEmpty {
            ContentUnavailableView.search(text: query)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 28)
        }
    }

    /// Favorites is not a scroll target; it sits beside All so remembered positions stay categories.
    private var favoritesRow: some View {
        Button { select(.favorites) } label: {
            LiveTVCategoryRowLabel(title: "Favorite Channels", count: directory.favoriteChannelCount,
                                   icon: .symbol("star.fill"), accessory: accessory(isSelected: false))
                .equatable()
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("liveTVCategoriesFavorites")
    }

    private func categoryRow(_ category: String) -> some View {
        let entry = directory.entry(for: category)
        return row(id: .category(category), title: category, count: entry.channelCount,
                   artwork: entry.artworkChannel, isSelected: mode.selected == category) {
            select(.category(category))
        }
    }

    private func row(id: LiveTVGuideCategoryPickerID, title: String, count: Int, symbol: String? = nil,
                     artwork: LiveTVChannel? = nil, isSelected: Bool,
                     action: @escaping () -> Void) -> some View {
        let icon: LiveTVCategoryRowLabel.Icon = symbol.map { .symbol($0) }
            ?? artwork.map { .artwork($0) }
            ?? .letter(title)
        return Button(action: action) {
            LiveTVCategoryRowLabel(title: title, count: count, icon: icon,
                                   accessory: accessory(isSelected: isSelected))
                .equatable()
        }
        .buttonStyle(.plain)
        .id(id)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func accessory(isSelected: Bool) -> LiveTVCategoryRowLabel.Accessory {
        switch mode {
        case .browse: .chevron
        case .filter: isSelected ? .checkmark : .none
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.title3.weight(.bold))
            .foregroundStyle(Color.siloOnSurface)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.top, 18)
            .padding(.bottom, 6)
            .accessibilityAddTraits(.isHeader)
    }
}

/// One category row: icon, full name, right-aligned channel count, then a chevron or checkmark.
/// Equatable, so scrolling and searching re-render only rows whose values changed.
struct LiveTVCategoryRowLabel: View, Equatable {
    enum Icon: Equatable {
        case symbol(String)
        case artwork(LiveTVChannel)
        case letter(String)
    }

    enum Accessory: Equatable { case chevron, checkmark, none }

    let title: String
    let count: Int
    let icon: Icon
    let accessory: Accessory

    private static let iconSize = CGSize(width: 40, height: 40)

    var body: some View {
        HStack(spacing: 12) {
            iconView
            Text(verbatim: title)
                .font(.body)
                .foregroundStyle(Color.siloOnSurface)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(count, format: .number)
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(Color.siloSecondaryText)
                .layoutPriority(1)
            accessoryView
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 56)
        // Build 75: a hairline from the title's leading edge, as in the reference list, so long
        // runs of similar provider names read as separate rows. Icons stay unbroken.
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(height: 0.5)
                .padding(.leading, 16 + Self.iconSize.width + 12)
                .accessibilityHidden(true)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: title))
        .accessibilityValue(count == 1 ? "1 channel" : "\(count) channels")
    }

    @ViewBuilder
    private var iconView: some View {
        let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)
        switch icon {
        case .symbol(let name):
            Image(systemName: name)
                .font(.body.weight(.semibold))
                .foregroundStyle(LiveTVAccent.primaryText)
                .frame(width: Self.iconSize.width, height: Self.iconSize.height)
                .background(Color.siloSurfaceElevated, in: shape)
        case .artwork(let channel):
            LiveTVChannelLogo(channel: channel, size: CGSize(width: 36, height: 30))
                .frame(width: Self.iconSize.width, height: Self.iconSize.height)
                .background(Color.siloSurfaceElevated, in: shape)
                .clipShape(shape)
        case .letter(let name):
            Text(LiveTVCategoryFallbackIcon.letter(for: name))
                .font(.headline)
                .foregroundStyle(.white)
                .frame(width: Self.iconSize.width, height: Self.iconSize.height)
                .background(Color(hue: LiveTVCategoryFallbackIcon.hue(for: name), saturation: 0.45, brightness: 0.55),
                            in: shape)
        }
    }

    @ViewBuilder
    private var accessoryView: some View {
        switch accessory {
        case .chevron:
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Color.siloSecondaryText.opacity(0.7))
        case .checkmark:
            Image(systemName: "checkmark")
                .font(.body.weight(.semibold))
                .foregroundStyle(LiveTVAccent.primaryText)
                .frame(width: 18)
        case .none:
            Color.clear.frame(width: 18, height: 1)
        }
    }
}
