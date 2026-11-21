import Foundation

/// The top menu's dropdown focus contract (docs/tvos-focus.md, "Top Menu Dropdowns").
///
/// Every dropdown (Movies and Series cascades, library shortcuts, For You, Profile) follows the
/// same rules, and each rule has one owner:
///
/// - **Actual bar focus** decides which dropdown is *eligible*. While a panel-bearing tab holds
///   focus, its dropdown is a real focus destination directly below it, visible or not.
/// - **The native focus engine** moves focus into an eligible dropdown on Down, for clicks and
///   touch-surface swipes alike. No handler, focus watcher or geometry match is involved.
/// - **The dropdown** reports that it received focus; the host then marks it entered, shows it,
///   makes the page ineligible and the bar inert.
/// - **Explicit exits** (Back, Up past the first row, Down past the last row, a selection) close it.
///
/// Before this contract, Down from a tab landed on the page first, and a UIKit notification had to
/// be matched to the tab by geometry, while the bar's ownership flag was still set, before the host
/// pulled focus back into the dropdown. Previews were also shown and closed only while that flag
/// was set. A transient focus drop cleared the flag, so dropdowns stopped opening, stale ones stayed
/// open over another tab, and Down went to the page.
enum TVTopMenuPanelFocusPolicy {
    /// Whether `panel` accepts focus. Only one dropdown can be eligible: the one under the focused
    /// bar element, or the one the user has entered.
    static func isEligible<Panel: Equatable>(_ panel: Panel, focusedBarPanel: Panel?,
                                             openPanel: Panel?, panelEntered: Bool) -> Bool {
        if panelEntered { return openPanel == panel }
        return focusedBarPanel == panel
    }

    /// Whether a mounted dropdown takes part in the focus graph at all. Dropdowns stay mounted
    /// (inserting one used to drop bar focus), so a closed, ineligible one is disabled: an invisible
    /// focus section or container must never sit over the page and absorb its directional moves.
    static func participatesInFocus<Panel: Equatable>(_ panel: Panel, focusedBarPanel: Panel?,
                                                      openPanel: Panel?, panelEntered: Bool) -> Bool {
        openPanel == panel || isEligible(panel, focusedBarPanel: focusedBarPanel,
                                         openPanel: openPanel, panelEntered: panelEntered)
    }

    /// What the host does when a dropdown reports focus.
    enum PanelFocusEvent: Equatable {
        /// Focus arrived natively (Down from its tab): open it if needed and enter it.
        case enter
        /// Already entered; only telemetry changed.
        case none
    }

    static func panelReportedFocus(hasFocus: Bool, panelEntered: Bool) -> PanelFocusEvent {
        hasFocus && !panelEntered ? .enter : .none
    }

    /// A dwell preview shown for another element closes when bar focus moves on. Evaluated on every
    /// actual bar focus change, never gated by menu ownership. `focusedElementPanel` is the
    /// dropdown the newly focused element offers, or nil (Home, Live TV, Search, Settings...).
    static func closesStalePreview<Panel: Equatable>(openPanel: Panel?, panelEntered: Bool,
                                                     focusedElementPanel: Panel?) -> Bool {
        guard let openPanel, !panelEntered else { return false }
        return focusedElementPanel != openPanel
    }
}
