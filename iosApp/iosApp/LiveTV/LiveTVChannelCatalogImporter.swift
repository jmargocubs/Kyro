#if os(iOS) || KYRO_CHANNEL_HOST_TESTS
import Foundation

/// Production bridge from a parsed provider catalog into the generation-scoped channel store.
/// Parsing is still array-backed in this migration step; staging itself retains at most one
/// 1,024-channel batch and never changes the visible generation until all rows validate.
enum LiveTVChannelCatalogImporter {
    static let batchSize = 1_024

    @discardableResult
    static func replace(_ channels: [LiveTVChannel], providerID: UUID,
                        in store: LiveTVChannelCatalogStore,
                        generation: String = UUID().uuidString) async throws -> Int {
        guard !channels.isEmpty else { throw LiveTVChannelCatalogStore.StoreError.invalidGeneration }
        try Task.checkCancellation()
        var ordinal = 0
        while ordinal < channels.count {
            try Task.checkCancellation()
            let end = min(ordinal + batchSize, channels.count)
            let accepted = try await store.stage(Array(channels[ordinal..<end]), providerID: providerID,
                                                 generation: generation, startingOrdinal: ordinal)
            guard accepted == end - ordinal else { throw LiveTVChannelCatalogStore.StoreError.invalidGeneration }
            ordinal = end
        }
        try Task.checkCancellation()
        try await store.promote(providerID: providerID, generation: generation, expectedCount: channels.count)
        try? await store.pruneOrphans()
        return channels.count
    }

    /// Transitional offline bridge. A cached channel is intentionally non-playable, matching the
    /// existing JSON snapshot rule; a fresh provider refresh supplies its current stream URL.
    static func restore(providerID: UUID, from store: LiveTVChannelCatalogStore,
                        maximumChannels: Int = LiveTVCatalogLimits.maximumChannels) async -> [LiveTVChannel]? {
        guard let stored = await store.offlineCatalog(providerID: providerID, maximumChannels: maximumChannels) else {
            return nil
        }
        var result: [LiveTVChannel] = []
        result.reserveCapacity(stored.count)
        let offlineURL = URL(string: "about:blank")!
        for channel in stored {
            result.append(LiveTVChannel(id: channel.id, guideID: channel.guideID, name: channel.name,
                                        streamURL: offlineURL, logoURL: channel.logoURL,
                                        category: channel.category, streamID: channel.streamID))
        }
        return result
    }
}
#endif
