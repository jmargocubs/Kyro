#if os(tvOS)
import Foundation

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
/// - Down from any header control enters the live column: the current program on the remembered
///   channel, or on the first channel. A channel without a current listing lands on its name tile,
///   which is always at the same place.
/// - Up from the first row is owned by the native focus engine; the guide
///   must not force a sideways correction after it chooses a toolbar control.
/// - Changing a filter never moves focus, unless focus was on a row the filter removed.
enum TVLiveTVGuideFocusPlanner {
    static func entryChannel(rowIDs: [String], remembered: String?) -> String? {
        if let remembered, rowIDs.contains(remembered) { return remembered }
        return rowIDs.first
    }

    static func entryTarget(rowIDs: [String], remembered: String?,
                            currentProgramID: (String) -> String?) -> TVLiveTVGuideFocus? {
        guard let channel = entryChannel(rowIDs: rowIDs, remembered: remembered) else { return nil }
        if let program = currentProgramID(channel) { return .program(channelID: channel, programID: program) }
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
}

/// The last channel the guide focused, kept for the process so reopening the guide returns to it.
@MainActor
enum TVLiveTVGuideMemory {
    static var lastChannelID: String?
}
#endif
