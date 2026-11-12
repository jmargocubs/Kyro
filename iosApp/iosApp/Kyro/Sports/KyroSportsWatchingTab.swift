import Foundation

/// Feed stays mounted behind the other tabs so its scroll position and filters never reset.
enum KyroSportsWatchingTab: String, CaseIterable, Identifiable {
    case feed, game, stats, news

    var id: Self { self }
    var title: String { rawValue.capitalized }
}

/// Layout rules for the pinned event's tabs that do not need a view to test.
enum KyroSportsWatchingLayout {
    /// Game, Stats and News draw under the hub's top inset (status bar, shell header, player and
    /// tab bar). Only the Feed reports its scroll to the shell header, so the other tabs need an
    /// opaque backing there or their rows show through the header.
    static func needsOpaqueInset(tab: KyroSportsWatchingTab, hasPinnedEvent: Bool) -> Bool {
        hasPinnedEvent && tab != .feed
    }
}
