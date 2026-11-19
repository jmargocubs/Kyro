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

    func visibleChannels(_ source: [LiveTVChannel]) -> [LiveTVChannel] {
        if channels.isEmpty { return source }
        return source.filter { channels[$0.id] == nil }
    }

    func visibleCategories(_ source: [String]) -> [String] {
        source.filter { !categories.contains($0) }
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
