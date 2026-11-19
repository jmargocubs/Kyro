#if os(tvOS)
import Foundation
import CoreGraphics

/// TV Guide geometry follows the safe viewport; focus never changes these metrics.
enum TVLiveTVGuideLayout {
    static func horizontalInset(viewportWidth: CGFloat) -> CGFloat {
        min(28, max(16, viewportWidth * 0.012))
    }

    static func verticalInset(viewportHeight: CGFloat) -> CGFloat {
        min(20, max(10, viewportHeight * 0.012))
    }

    static func channelWidth(viewportWidth: CGFloat) -> CGFloat {
        min(430, max(330, viewportWidth * 0.205))
    }

    static func rowHeight(viewportHeight: CGFloat) -> CGFloat {
        min(138, max(116, viewportHeight * 0.116))
    }
    static let cellGap: CGFloat = 6

    static func programCellWidth(_ timelineWidth: CGFloat) -> CGFloat {
        max(timelineWidth - cellGap, min(timelineWidth, 1))
    }

    static func visibleProgramWidth(viewportWidth: CGFloat) -> CGFloat {
        max(0, viewportWidth - 2 * horizontalInset(viewportWidth: viewportWidth)
            - channelWidth(viewportWidth: viewportWidth))
    }
}

/// Every focusable place in the TV Guide, with stable identities so focus can be set explicitly
/// instead of left to the focus engine's geometric guess.
enum TVLiveTVGuideFocus: Hashable {
    case back
    case category
    case favorites
    case refresh
    /// The channel's name tile at the left of its row.
    case channel(String)
    case program(channelID: String, programID: String)
    /// The "No guide information" cell of a channel without listings.
    case noGuide(String)

    var channelID: String? {
        switch self {
        case .channel(let id), .noGuide(let id): id
        case .program(let id, _): id
        case .back, .category, .favorites, .refresh: nil
        }
    }

    var isHeader: Bool { channelID == nil }
}

/// The guide's focus rules, free of SwiftUI so they are unit-tested.
///
/// - Down from any header control enters the name tile of the remembered channel, or the first
///   channel. Native focus then moves Right through the live and upcoming listings.
/// - Up into the toolbar uses its remembered native region default, not a
///   correction after the engine has already highlighted another control.
/// - Changing a filter never moves focus, unless focus was on a row the filter removed.
enum TVLiveTVGuideFocusPlanner {
    static func entryChannel(rowIDs: [String], remembered: String?) -> String? {
        if let remembered, rowIDs.contains(remembered) { return remembered }
        return rowIDs.first
    }

    static func entryTarget(rowIDs: [String], remembered: String?) -> TVLiveTVGuideFocus? {
        guard let channel = entryChannel(rowIDs: rowIDs, remembered: remembered) else { return nil }
        return .channel(channel)
    }

    /// True only when focus sits on a row that is no longer listed.
    static func mustRelocate(_ focus: TVLiveTVGuideFocus?, rowIDs: [String]) -> Bool {
        guard let channel = focus?.channelID else { return false }
        return !rowIDs.contains(channel)
    }

    /// The program airing at `now`, if the listings cover it.
    static func currentProgram(in programs: [EPGProgram], at now: Date) -> EPGProgram? {
        programs.first { $0.start <= now && now < $0.end }
    }

    /// Past cells stay visible but cannot intercept Left/Right from the channel or live cell.
    /// Do not revoke focus from a cell that becomes past while the user is on it.
    static func canFocusProgram(_ program: EPGProgram, at now: Date, isFocused: Bool) -> Bool {
        isFocused || LiveTVGuideProgramState(program, at: now) != .past
    }

    static func nextListingBoundary(in programs: [EPGProgram], after now: Date) -> Date? {
        programs.flatMap { [$0.start, $0.end] }.filter { $0 > now }.min()
    }
}

/// Native region preferences, not a directional-command dispatcher. Nil focus
/// during a sheet or playback leaves the last owner and restoration target intact.
struct TVLiveTVGuideFocusHistory: Equatable {
    private(set) var header: TVLiveTVGuideFocus = .category
    private(set) var grid: TVLiveTVGuideFocus?
    private(set) var isInGrid = false

    mutating func observe(_ target: TVLiveTVGuideFocus?) {
        guard let target else { return }
        if target.isHeader {
            header = target
            isInGrid = false
        } else {
            grid = target
            isInGrid = true
        }
    }

    func gridDefault(entry: TVLiveTVGuideFocus?) -> TVLiveTVGuideFocus? {
        if isInGrid { return grid }
        // Back keeps the row and scroll position, but Down starts at its channel tile.
        if let channelID = grid?.channelID { return .channel(channelID) }
        return entry
    }

    /// Back is a boundary handoff, not a dismissal, while the grid owns focus.
    /// Commit the ownership change before writing focus so rapid repeated presses cannot loop.
    mutating func returnToHeader() -> Bool {
        guard isInGrid else { return false }
        isInGrid = false
        return true
    }

    func allowsGridEntry(_ entry: TVLiveTVGuideFocus?, laidOutRows: Set<String>) -> Bool {
        if isInGrid { return true }
        guard let channelID = gridDefault(entry: entry)?.channelID else { return false }
        return laidOutRows.contains(channelID)
    }

    mutating func reconcile(rowIDs: [String]) {
        guard TVLiveTVGuideFocusPlanner.mustRelocate(grid, rowIDs: rowIDs) else { return }
        grid = nil
        isInGrid = false
    }
}

/// Freeze only the active row, not the catalog. Keeping the whole row avoids
/// moving a focused cell's geometry when a refreshed listing changes boundaries.
struct TVLiveTVGuideListingSnapshot {
    let channelID: String
    let programs: [EPGProgram]

    func programs(for channelID: String, latest: () -> [EPGProgram]) -> [EPGProgram] {
        self.channelID == channelID ? programs : latest()
    }
}

/// The last channel the guide focused, kept for the process so reopening the guide returns to it.
@MainActor
enum TVLiveTVGuideMemory {
    static var lastChannelID: String?
}
#endif
