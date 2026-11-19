#if os(tvOS)
import Foundation
import Observation

/// Local visibility is a presentation preference, never a mutation of an IPTV catalog.
struct TVLiveTVVisibilityScope: Hashable {
    let profileID: String
    let providerID: UUID

    var storageKey: String { "\(profileID)|\(providerID.uuidString)" }
}

struct TVLiveTVHiddenChannel: Codable, Equatable, Identifiable {
    let id: String
    let name: String
    let category: String
}

struct TVLiveTVVisibilitySnapshot: Codable, Equatable {
    var channels: [String: TVLiveTVHiddenChannel] = [:]
    var categories: Set<String> = []

    var hiddenChannelIDs: Set<String> { Set(channels.keys) }
    var isEmpty: Bool { channels.isEmpty && categories.isEmpty }

    /// Channel and category rules for `source` alone. Prefer `TVLiveTVVisibilityPolicy`, which also
    /// hides a stream listed again under a visible category.
    func visibleChannels(_ source: [LiveTVChannel]) -> [LiveTVChannel] {
        TVLiveTVVisibilityPolicy(snapshot: self, catalog: source).visibleChannels(source)
    }

    func visibleCategories(_ source: [String]) -> [String] {
        source.filter { !categories.contains($0) }
    }
}

/// The one rule every normal Live TV surface uses: All Channels, Categories and their counts,
/// Favorites, channel search and the TV Guide. A channel is hidden when it was hidden itself, when
/// its category is hidden, or when the same stream is also listed under a hidden category.
/// Individual channel rules and category rules stay independent: restoring a category never
/// restores a channel hidden on its own. The catalog, provider data, guide data and Favorites are
/// never changed. Category rules match by name, so newly imported channels in a hidden category
/// stay hidden.
struct TVLiveTVVisibilityPolicy {
    let snapshot: TVLiveTVVisibilitySnapshot
    private let hiddenStreamKeys: Set<String>

    init(snapshot: TVLiveTVVisibilitySnapshot, catalog: [LiveTVChannel]) {
        self.snapshot = snapshot
        guard !snapshot.categories.isEmpty else {
            hiddenStreamKeys = []
            return
        }
        var keys = Set<String>()
        for channel in catalog where snapshot.categories.contains(channel.category) {
            keys.insert(Self.streamKey(channel))
        }
        hiddenStreamKeys = keys
    }

    /// Xtream lists one stream under several categories with the same stream ID; an M3U repeats
    /// its URL. Either identifies the same channel across categories.
    static func streamKey(_ channel: LiveTVChannel) -> String {
        if let streamID = channel.streamID { return "id:\(streamID)" }
        return "url:\(channel.streamURL.absoluteString)"
    }

    func isVisible(_ channel: LiveTVChannel) -> Bool {
        if snapshot.channels[channel.id] != nil { return false }
        if snapshot.categories.isEmpty { return true }
        if snapshot.categories.contains(channel.category) { return false }
        return !hiddenStreamKeys.contains(Self.streamKey(channel))
    }

    func visibleChannels(_ source: [LiveTVChannel]) -> [LiveTVChannel] {
        if snapshot.isEmpty { return source }
        return source.filter(isVisible)
    }

    func visibleCategories(_ source: [String]) -> [String] {
        snapshot.visibleCategories(source)
    }

    /// Visible channels per visible category, for the category grid.
    func categoryCounts(_ catalog: [LiveTVChannel]) -> [String: Int] {
        var counts: [String: Int] = [:]
        for channel in catalog where isVisible(channel) {
            counts[channel.category, default: 0] += 1
        }
        return counts
    }
}

@MainActor @Observable
final class TVLiveTVVisibilityStore {
    static let shared = TVLiveTVVisibilityStore()
    private static let key = "kyro.tv.liveTV.visibility.v1"
    private let defaults: UserDefaults
    private var records: [String: TVLiveTVVisibilitySnapshot]
    private(set) var revision = 0

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.key),
           let decoded = try? JSONDecoder().decode([String: TVLiveTVVisibilitySnapshot].self, from: data) {
            records = decoded
        } else {
            records = [:]
        }
    }

    func snapshot(for scope: TVLiveTVVisibilityScope?) -> TVLiveTVVisibilitySnapshot {
        guard let scope else { return TVLiveTVVisibilitySnapshot() }
        return records[scope.storageKey] ?? TVLiveTVVisibilitySnapshot()
    }

    func hide(_ channel: LiveTVChannel, in scope: TVLiveTVVisibilityScope?) {
        guard let scope else { return }
        var snapshot = snapshot(for: scope)
        snapshot.channels[channel.id] = TVLiveTVHiddenChannel(id: channel.id, name: channel.name, category: channel.category)
        save(snapshot, for: scope)
    }

    func hideCategory(_ category: String, in scope: TVLiveTVVisibilityScope?) {
        guard let scope else { return }
        var snapshot = snapshot(for: scope)
        snapshot.categories.insert(category)
        save(snapshot, for: scope)
    }

    func restoreChannel(_ id: String, in scope: TVLiveTVVisibilityScope?) {
        guard let scope else { return }
        var snapshot = snapshot(for: scope)
        snapshot.channels.removeValue(forKey: id)
        save(snapshot, for: scope)
    }

    func restoreCategory(_ category: String, in scope: TVLiveTVVisibilityScope?) {
        guard let scope else { return }
        var snapshot = snapshot(for: scope)
        snapshot.categories.remove(category)
        save(snapshot, for: scope)
    }

    func restoreAll(in scope: TVLiveTVVisibilityScope?) {
        guard let scope else { return }
        save(TVLiveTVVisibilitySnapshot(), for: scope)
    }

    private func save(_ snapshot: TVLiveTVVisibilitySnapshot, for scope: TVLiveTVVisibilityScope) {
        guard records[scope.storageKey] != snapshot else { return }
        records[scope.storageKey] = snapshot
        if let data = try? JSONEncoder().encode(records) { defaults.set(data, forKey: Self.key) }
        revision &+= 1
    }
}
#endif
