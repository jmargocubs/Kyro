import Foundation

/// Disk cache of indexed guides: one compressed file per provider under Caches.
///
/// Files are named by provider ID and hold only listings, never feed URLs or credentials. Writes
/// are atomic. A corrupt, foreign-version or oversized file is deleted and reads as missing. Total
/// size and entry count are bounded, evicting the least recently written guides first.
///
/// Synchronous file I/O: call it from a nonisolated async context, never the main actor.
struct EPGCacheStore: Sendable {
    let directory: URL
    var maximumEntryBytes = 48 * 1024 * 1024
    var maximumTotalBytes = 128 * 1024 * 1024
    var maximumEntries = 8

    private static let magic = Data("KEPG".utf8)
    private static let version: UInt8 = 1
    private static let fileExtension = "epgcache"

    init(directory: URL) {
        self.directory = directory
    }

    static func makeDefault() -> EPGCacheStore? {
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        return EPGCacheStore(directory: caches.appendingPathComponent("LiveTVGuide", isDirectory: true))
    }

    func load(providerID: UUID) -> EPGIndex? {
        let url = fileURL(providerID)
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
        guard let size = attributes[.size] as? Int, size <= maximumEntryBytes,
              let file = try? Data(contentsOf: url, options: .mappedIfSafe),
              file.count > Self.magic.count + 1,
              file.prefix(Self.magic.count) == Self.magic,
              file[file.startIndex + Self.magic.count] == Self.version,
              let payload = try? (file.dropFirst(Self.magic.count + 1) as NSData).decompressed(using: .lzfse) as Data,
              let record = try? JSONDecoder().decode(Record.self, from: payload),
              let index = record.index() else {
            remove(providerID: providerID)
            return nil
        }
        return index
    }

    func save(_ index: EPGIndex, providerID: UUID) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let payload = try JSONEncoder().encode(Record(index))
        let compressed = try (payload as NSData).compressed(using: .lzfse) as Data
        var file = Self.magic
        file.append(Self.version)
        file.append(compressed)
        guard file.count <= maximumEntryBytes else {
            remove(providerID: providerID)
            throw EPGError.responseTooLarge
        }
        try file.write(to: fileURL(providerID), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        evict(keeping: providerID)
    }

    func remove(providerID: UUID) {
        try? FileManager.default.removeItem(at: fileURL(providerID))
    }

    private func fileURL(_ providerID: UUID) -> URL {
        directory.appendingPathComponent(providerID.uuidString).appendingPathExtension(Self.fileExtension)
    }

    /// Drops the oldest guides until the cache fits its size and count limits.
    private func evict(keeping providerID: UUID) {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys) else {
            return
        }
        let kept = fileURL(providerID).lastPathComponent
        let entries = urls.filter { $0.pathExtension == Self.fileExtension }.map { url in
            let values = try? url.resourceValues(forKeys: Set(keys))
            return (url: url, size: values?.fileSize ?? 0, date: values?.contentModificationDate ?? .distantPast)
        }.sorted { lhs, rhs in
            if lhs.url.lastPathComponent == kept { return true }
            if rhs.url.lastPathComponent == kept { return false }
            return lhs.date > rhs.date
        }
        var total = 0
        for (position, entry) in entries.enumerated() {
            total += entry.size
            if position > 0, position >= maximumEntries || total > maximumTotalBytes {
                try? FileManager.default.removeItem(at: entry.url)
            }
        }
    }
}

/// Compact on-disk form: channel IDs are stored once, times as whole seconds.
private struct Record: Codable {
    struct Row: Codable {
        let c: Int
        let s: Int64
        let d: Int32
        let t: String
        let st: String?
        let ds: String?
        let g: String?
        let e: String?
    }

    let fetchedAt: Double
    let channelIDs: [String]
    let names: [String: String]
    let rows: [Row]

    init(_ index: EPGIndex) {
        var channelIDs: [String] = []
        var positions: [String: Int] = [:]
        var rows: [Row] = []
        rows.reserveCapacity(index.programCount)
        for key in index.programsByChannel.keys.sorted() {
            for program in index.programsByChannel[key] ?? [] {
                let position: Int
                if let existing = positions[program.channelID] { position = existing } else {
                    position = channelIDs.count
                    positions[program.channelID] = position
                    channelIDs.append(program.channelID)
                }
                let start = Int64(program.start.timeIntervalSince1970.rounded())
                let duration = Int32(clamping: Int64(program.end.timeIntervalSince1970.rounded()) - start)
                rows.append(Row(c: position, s: start, d: duration, t: program.title, st: program.subtitle,
                                ds: program.summary, g: program.category, e: program.episode))
            }
        }
        fetchedAt = index.fetchedAt.timeIntervalSince1970
        self.channelIDs = channelIDs
        names = index.channelIDsByName
        self.rows = rows
    }

    func index() -> EPGIndex? {
        var grouped: [String: [EPGProgram]] = [:]
        for row in rows {
            guard channelIDs.indices.contains(row.c), row.d > 0,
                  let key = EPGChannelKey.guideID(channelIDs[row.c]) else { return nil }
            let start = Date(timeIntervalSince1970: TimeInterval(row.s))
            grouped[key, default: []].append(EPGProgram(
                channelID: channelIDs[row.c], start: start, end: start.addingTimeInterval(TimeInterval(row.d)),
                title: row.t, subtitle: row.st, summary: row.ds, category: row.g, episode: row.e))
        }
        // Rows were written in airing order per channel; reject a file that is not.
        for list in grouped.values where zip(list, list.dropFirst()).contains(where: { $0.end > $1.start }) {
            return nil
        }
        return EPGIndex(fetchedAt: Date(timeIntervalSince1970: fetchedAt), programsByChannel: grouped,
                        channelIDsByName: names, statistics: EPGIndex.Statistics())
    }
}
