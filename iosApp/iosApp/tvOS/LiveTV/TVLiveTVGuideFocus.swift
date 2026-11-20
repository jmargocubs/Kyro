#if os(tvOS)
import Foundation
import CoreGraphics

/// TV Guide geometry, derived only from the safe-area viewport the guide is offered. Content never
/// feeds back into these numbers, and focus never changes them.
///
/// Build 97 regression: the timeline header sat outside the grid's scroll view at a fixed
/// 4.2 pt/min, so channel column + 6.5 h of ticks (≈2,030 pt) was wider than the screen. The
/// over-wide header widened the guide's stack, the full-screen cover centered it, and the channel
/// column was pushed past the left edge while the header ran past the program blocks. The viewport
/// was also measured from that inflated stack. Now the scale is chosen so the visible window fits
/// the program viewport, the header shares the grid's horizontal scroll offset inside a clipped
/// frame, and the viewport is read from a GeometryReader that content cannot resize.
enum TVLiveTVGuideLayout {
    /// The span of the timeline that fits beside the channel column without scrolling.
    static let visibleWindowMinutes: CGFloat = 180
    static let minimumPointsPerMinute: CGFloat = 4.2
    static let maximumPointsPerMinute: CGFloat = 9
    static let cellGap: CGFloat = 6
    static let rowSpacing: CGFloat = 8
    static let timelineHeaderHeight: CGFloat = 34
    /// Room below the last row for a focused cell's lift and shadow.
    static let focusRoom: CGFloat = 16

    /// Inside the cover's 80 pt side safe area. Build 98 used 1.2 % (21 pt at 1760 pt); Build 99
    /// uses 0.8 % (14 pt), which still clears a focused channel tile's ring and lift.
    static func horizontalInset(viewportWidth: CGFloat) -> CGFloat {
        min(24, max(12, viewportWidth * 0.008))
    }

    static func verticalInset(viewportHeight: CGFloat) -> CGFloat {
        min(18, max(8, viewportHeight * 0.012))
    }

    static func channelWidth(viewportWidth: CGFloat) -> CGFloat {
        min(400, max(320, viewportWidth * 0.2))
    }

    static func rowHeight(viewportHeight: CGFloat) -> CGFloat {
        min(132, max(108, viewportHeight * 0.12))
    }

    static func programCellWidth(_ timelineWidth: CGFloat) -> CGFloat {
        max(timelineWidth - cellGap, min(timelineWidth, 1))
    }

    /// Width left for program cells beside the channel column.
    static func visibleProgramWidth(viewportWidth: CGFloat) -> CGFloat {
        max(0, viewportWidth - 2 * horizontalInset(viewportWidth: viewportWidth)
            - channelWidth(viewportWidth: viewportWidth))
    }

    /// Scale so `visibleWindowMinutes` fills the program viewport. Later listings scroll in.
    static func pointsPerMinute(viewportWidth: CGFloat) -> CGFloat {
        min(maximumPointsPerMinute,
            max(minimumPointsPerMinute, visibleProgramWidth(viewportWidth: viewportWidth) / visibleWindowMinutes))
    }

    /// All guide geometry for one viewport. Channel column, timeline header and program cells use
    /// the same `channelWidth` and `pointsPerMinute`, so they share one coordinate system.
    struct Metrics: Equatable {
        let viewport: CGSize
        let horizontalInset: CGFloat
        let verticalInset: CGFloat
        let channelWidth: CGFloat
        let rowHeight: CGFloat
        let pointsPerMinute: CGFloat
        /// The part of `viewport` that lies in the bottom safe-area band (Build 99). The grid
        /// scrolls through it; resting rows stay above it.
        let bottomOverscan: CGFloat

        init(viewport: CGSize, bottomOverscan: CGFloat = 0) {
            self.viewport = viewport
            self.bottomOverscan = max(0, bottomOverscan)
            horizontalInset = TVLiveTVGuideLayout.horizontalInset(viewportWidth: viewport.width)
            verticalInset = TVLiveTVGuideLayout.verticalInset(viewportHeight: viewport.height)
            channelWidth = TVLiveTVGuideLayout.channelWidth(viewportWidth: viewport.width)
            // Rows size from the safe height, so reaching into the overscan band adds rows on
            // screen rather than making each row taller.
            rowHeight = TVLiveTVGuideLayout.rowHeight(viewportHeight: viewport.height - self.bottomOverscan)
            pointsPerMinute = TVLiveTVGuideLayout.pointsPerMinute(viewportWidth: viewport.width)
        }

        /// Bottom content margin of the grid: the overscan band, the bottom inset, and room for a
        /// focused row's lift, so the last row is fully visible when scrolled to the end.
        var gridBottomMargin: CGFloat { bottomOverscan + verticalInset + TVLiveTVGuideLayout.focusRoom }

        /// The guide's usable width inside its insets: header, timeline and grid all clip to it.
        var contentWidth: CGFloat { max(0, viewport.width - 2 * horizontalInset) }
        var programViewportWidth: CGFloat { max(0, contentWidth - channelWidth) }
        var visibleMinutes: CGFloat { programViewportWidth / pointsPerMinute }
        var slotWidth: CGFloat { CGFloat(30) * pointsPerMinute }
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

    /// Where Down from the toolbar enters the grid. The preferred channel when
    /// its lazy row is laid out; otherwise the first laid-out row in guide
    /// order. A specific target, never geometry, and never a dropped press:
    /// the old gate disabled the whole grid until the preferred row mounted,
    /// and a remembered channel far down could leave Down dead indefinitely.
    func entry(_ entry: TVLiveTVGuideFocus?, rowIDs: [String], laidOutRows: Set<String>) -> TVLiveTVGuideFocus? {
        if isInGrid { return grid }
        let preferred = gridDefault(entry: entry)
        if let channelID = preferred?.channelID, laidOutRows.contains(channelID) { return preferred }
        if let fallback = rowIDs.first(where: laidOutRows.contains) { return .channel(fallback) }
        return preferred
    }

    /// The grid is excluded only while no entry target is laid out at all.
    func allowsGridEntry(_ entry: TVLiveTVGuideFocus?, rowIDs: [String], laidOutRows: Set<String>) -> Bool {
        if isInGrid { return true }
        guard let channelID = self.entry(entry, rowIDs: rowIDs, laidOutRows: laidOutRows)?.channelID else { return false }
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
