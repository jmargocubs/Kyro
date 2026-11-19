// Compile with the production LiveTVChannelCatalogStore and KYRO_CHANNEL_HOST_TESTS.
// This host-only declaration mirrors the channel value type in LiveTVModels.swift; the SQL actor
// and all measured queries are production code, not a benchmark-specific reimplementation.
import Foundation
import Darwin

struct LiveTVChannel: Hashable, Identifiable, Sendable {
    let id: String
    let guideID: String?
    let name: String
    let streamURL: URL
    let logoURL: URL?
    let category: String
    var streamID: Int? = nil
}

@main
enum LiveTVChannelStoreBenchmark {
    static let first = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    static let second = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!

    static func channel(_ ordinal: Int, provider: UUID = first, category: String? = nil) -> LiveTVChannel {
        LiveTVChannel(id: provider.uuidString + ":" + String(format: "%064x", ordinal + 1),
                      guideID: "epg-\(ordinal + 1)", name: String(format: "Channel %07d", ordinal),
                      streamURL: URL(string: "https://streams.example.test/live/\(ordinal + 1).m3u8")!,
                      logoURL: nil, category: category ?? "Category \(ordinal % 40)", streamID: ordinal + 1)
    }

    static func milliseconds(_ start: ContinuousClock.Instant) -> Int {
        let duration = start.duration(to: .now).components
        return Int(duration.seconds * 1_000 + duration.attoseconds / 1_000_000_000_000_000)
    }

    static func peakRSSMB() -> Int {
        var info = rusage()
        return getrusage(RUSAGE_SELF, &info) == 0 ? Int(info.ru_maxrss) / 1_048_576 : -1
    }

    static func correctness(root: URL) async throws {
        let store = try LiveTVChannelCatalogStore(directory: root.appendingPathComponent("correctness"))
        let original = [channel(0), channel(1)]
        let originalCount = try await store.stage(original, providerID: first, generation: "old", startingOrdinal: 0)
        precondition(originalCount == 2)
        try await store.promote(providerID: first, generation: "old", expectedCount: 2)
        try await store.setFavorite(true, channelID: original[1].id, providerID: first)
        let other = channel(0, provider: second)
        let otherCount = try await store.stage([other], providerID: second, generation: "old", startingOrdinal: 0)
        precondition(otherCount == 1)
        try await store.promote(providerID: second, generation: "old", expectedCount: 1)
        let replacement = [channel(0, category: "New Category"), channel(1, category: "New Category")]
        let interruptedCount = try await store.stage([replacement[0]], providerID: first,
                                                     generation: "interrupted", startingOrdinal: 0)
        precondition(interruptedCount == 1)
        do {
            try await store.promote(providerID: first, generation: "interrupted", expectedCount: 2)
            preconditionFailure("incomplete generation promoted")
        } catch LiveTVChannelCatalogStore.StoreError.invalidGeneration { }
        let stillOld = await store.page(providerID: first)
        precondition(stillOld.map(\.category) == original.map(\.category))
        let replacementCount = try await store.stage(replacement, providerID: first,
                                                     generation: "new", startingOrdinal: 0)
        precondition(replacementCount == 2)
        try await store.promote(providerID: first, generation: "new", expectedCount: 2)
        let current = await store.page(providerID: first)
        let favorites = await store.page(providerID: first, favoritesOnly: true)
        let oldProvider = await store.page(providerID: second)
        precondition(current.map(\.category) == ["New Category", "New Category"])
        precondition(favorites.map(\.id) == [original[1].id])
        precondition(oldProvider.map(\.id) == [other.id])
        let collision = await store.channel(providerID: first, id: other.id)
        let guideMatched = await store.channel(providerID: first, id: original[0].id)
        precondition(collision == nil)
        precondition(guideMatched?.guideID == "epg-1")
        let cancelledImport = Task { () -> Bool in
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                _ = try await store.stage([channel(2)], providerID: first,
                                          generation: "cancelled", startingOrdinal: 0)
                return false
            } catch is CancellationError { return true }
            catch { return false }
        }
        let cancellationWorked = await cancelledImport.value
        precondition(cancellationWorked)
        await store.close()
        let recovered = try LiveTVChannelCatalogStore(directory: root.appendingPathComponent("correctness"))
        try await recovered.pruneOrphans()
        let restoredCount = await recovered.count(providerID: first)
        let restoredFavorites = await recovered.page(providerID: first, favoritesOnly: true)
        precondition(restoredCount == 2)
        precondition(restoredFavorites.count == 1)
        await recovered.close()
        print("host_snapshot_provider_favorites_epg,pass")
    }

    static func run(count: Int, root: URL) async throws {
        let directory = root.appendingPathComponent("channels-\(count)")
        let store = try LiveTVChannelCatalogStore(directory: directory)
        let start = ContinuousClock.now
        var ordinal = 0
        while ordinal < count {
            let batch = (ordinal..<min(ordinal + 1024, count)).map { channel($0) }
            let accepted = try await store.stage(batch, providerID: first,
                                                 generation: "benchmark", startingOrdinal: ordinal)
            precondition(accepted == batch.count)
            ordinal += batch.count
        }
        try await store.promote(providerID: first, generation: "benchmark", expectedCount: count)
        let importMS = milliseconds(start)
        let searchStart = ContinuousClock.now
        let search = await store.page(providerID: first, query: "Channel 0001234")
        let searchMS = milliseconds(searchStart)
        let categoryStart = ContinuousClock.now
        let category = await store.page(providerID: first, category: "Category 17", offset: 100)
        let categoryMS = milliseconds(categoryStart)
        let guideStart = ContinuousClock.now
        let guide = await store.page(providerID: first, offset: count - 100)
        let guideMS = milliseconds(guideStart)
        let keysetStart = ContinuousClock.now
        let keyset = await store.page(providerID: first, afterOrdinal: count - 101)
        let keysetMS = milliseconds(keysetStart)
        let categories = await store.categories(providerID: first)
        let stored = await store.count(providerID: first)
        let isolated = await store.count(providerID: second)
        precondition(stored == count && isolated == 0 && search.count == 1 && search[0].streamID == 1_235)
        precondition(category.count == 100 && guide.count == 100 && keyset.count == 100)
        precondition(guide.first?.streamID == count - 99 && guide.last?.streamID == count)
        precondition(categories.count == 40 && categories.reduce(0) { $0 + $1.count } == count)
        let last = channel(count - 1)
        let resolved = await store.channel(providerID: first, id: last.id)
        precondition(resolved?.guideID == last.guideID && resolved?.streamURL == last.streamURL)
        try await store.setFavorite(true, channelID: last.id, providerID: first)
        let favorites = await store.page(providerID: first, favoritesOnly: true)
        precondition(favorites.map(\.id) == [last.id])
        await store.close()
        let attributes = try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent("channels.sqlite").path)
        let bytes = (attributes[.size] as? NSNumber)?.intValue ?? -1
        print("\(count),\(importMS),\(searchMS),\(categoryMS),\(guideMS),\(keysetMS),\(bytes),\(peakRSSMB())")
    }

    static func main() async throws {
        guard CommandLine.arguments.count == 2 else {
            fputs("usage: live-tv-channel-benchmark TEMP_DIRECTORY\n", stderr)
            exit(2)
        }
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try await correctness(root: root)
        print("count,import_ms,search_ms,category_ms,guide_page_ms,keyset_page_ms,sqlite_bytes,process_peak_rss_mb")
        for count in [40_000, 60_000, 80_000, 100_000] { try await run(count: count, root: root) }
    }
}
