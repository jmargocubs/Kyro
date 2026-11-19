#if os(tvOS)
import Foundation

/// Every focusable place on the Live TV page. The control row and the content region are two
/// native focus sections; these identities let each region name where focus enters it.
enum TVLiveTVBrowseFocus: Hashable {
    case section(TVLiveTVSection)
    case guide
    case providers
    case search
    case category(String)
    case channel(String)
    /// The action on a status page: Set Up Provider, Retry, or Manage Providers.
    case retry
    /// A status or loading page with no action. It is still a real focus target, so Down from
    /// every control lands somewhere and Back/Up keep working.
    case placeholder

    /// The Live TV control row: All Channels, Categories, Favorites, TV Guide, Providers, Search.
    var isControlRow: Bool {
        switch self {
        case .section, .guide, .providers, .search: true
        case .category, .channel, .retry, .placeholder: false
        }
    }
}

/// What the content region shows, reduced to what focus needs.
enum TVLiveTVBrowseContent: Equatable {
    /// A status page with a button (setup, retry, manage providers).
    case action
    /// A status or loading page without a button.
    case placeholder
    case categories(visible: [String])
    case channels(firstID: String?)
}

/// One Back press moves up exactly one level of the Live TV hierarchy:
/// selected category's channels → category grid → Live TV control row → main navigation.
enum TVLiveTVBackAction: Equatable {
    case closeCategory(String)
    case focusControls(TVLiveTVSection)
    case topMenu
}

/// The Live TV page's focus rules, free of SwiftUI so they are unit-tested. The view applies them
/// as native region defaults (`defaultFocus` with `.userInitiated` priority on each focus section),
/// never as directional-command interception.
enum TVLiveTVBrowseFocusPlanner {
    static let allChannelsCardID = "__all__"

    /// Down from any control in the row enters the content region here. Every chip gets the same
    /// destination, so no chip depends on what happens to sit directly beneath it.
    static func contentEntry(_ content: TVLiveTVBrowseContent,
                             navigation: TVLiveTVBrowseNavigation,
                             rememberedChannelID: String?,
                             rememberedChannelIsListed: Bool) -> TVLiveTVBrowseFocus {
        switch content {
        case .action:
            return .retry
        case .placeholder:
            return .placeholder
        case .categories(let visible):
            if let category = navigation.focusedCategory, visible.contains(category) {
                return .category(category)
            }
            return .category(allChannelsCardID)
        case .channels(let firstID):
            if let rememberedChannelID, rememberedChannelIsListed { return .channel(rememberedChannelID) }
            return firstID.map(TVLiveTVBrowseFocus.channel) ?? .placeholder
        }
    }

    /// Up from the content region returns to the selected section's chip, so the row the user
    /// came from is where they land, whichever card they were on.
    static func controlEntry(_ navigation: TVLiveTVBrowseNavigation) -> TVLiveTVBrowseFocus {
        .section(navigation.section)
    }

    static func back(from focus: TVLiveTVBrowseFocus?,
                     navigation: TVLiveTVBrowseNavigation) -> TVLiveTVBackAction {
        guard let focus, !focus.isControlRow else { return .topMenu }
        if navigation.section == .categories, let category = navigation.selectedCategory {
            return .closeCategory(category)
        }
        return .focusControls(navigation.section)
    }

    /// After a category opens, its loading placeholder holds focus until its own results land.
    /// Then focus moves into the channels, but only if the user has not moved elsewhere.
    static func afterChannelResults(currentFocus: TVLiveTVBrowseFocus?,
                                    firstChannelID: String?) -> TVLiveTVBrowseFocus? {
        guard currentFocus == .placeholder else { return nil }
        return firstChannelID.map(TVLiveTVBrowseFocus.channel)
    }

    /// The category grid regains focus only when Back closed a category. Selecting the
    /// Categories chip shows the grid without pulling focus out of the control row.
    static func categoryGridRestoration(pending: String?, visible: [String]) -> TVLiveTVBrowseFocus? {
        guard let pending else { return nil }
        return .category(visible.contains(pending) ? pending : allChannelsCardID)
    }
}
#endif
