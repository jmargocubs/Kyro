import Foundation

/// Normalized keys used to match playlist channels to guide channels.
enum EPGChannelKey {
    /// Guide IDs compare after trimming and case folding; providers mix `BBCOne.uk` and `bbcone.uk`.
    static func guideID(_ raw: String?) -> String? {
        guard let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value.lowercased()
    }

    /// Display names fold case, diacritics and width, drop punctuation and spacing, and ignore
    /// quality tags, so "BBC One HD" and "bbc one" share a key.
    static func name(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let folded = raw.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                                 locale: Locale(identifier: "en_US_POSIX")).lowercased()
        let tokens = folded.split { !$0.isLetter && !$0.isNumber }.map(String.init)
        let kept = tokens.filter { !qualityTags.contains($0) }
        let result = (kept.isEmpty ? tokens : kept).joined()
        return result.isEmpty ? nil : result
    }

    private static let qualityTags: Set<String> = ["hd", "fhd", "uhd", "sd", "4k", "hevc", "h265"]
}

/// The guide channels a playlist can show. Generic XMLTV feeds often list far more channels than a
/// playlist carries, so filtering while parsing keeps memory proportional to the playlist.
struct EPGChannelFilter: Sendable, Equatable {
    private let guideIDs: Set<String>
    private let names: Set<String>

    init(guideIDs: [String?], names: [String]) {
        self.guideIDs = Set(guideIDs.compactMap(EPGChannelKey.guideID))
        self.names = Set(names.compactMap(EPGChannelKey.name))
    }

    func accepts(channelID: String, displayNames: [String]) -> Bool {
        if let key = EPGChannelKey.guideID(channelID), guideIDs.contains(key) { return true }
        return displayNames.contains { EPGChannelKey.name($0).map(names.contains) == true }
    }
}

/// Read API shared by the in-memory guide index and a future on-disk store (Stage B SQLite).
/// Call sites that only need lookups should depend on this protocol, not on storage details.
protocol EPGQuerying: Sendable {
    var fetchedAt: Date { get }
    var programCount: Int { get }
    var isShortGuideOnly: Bool { get }
    func channelKey(guideID: String?, name: String?) -> String?
    func nowNext(guideID: String?, name: String?, at date: Date) -> EPGNowNext
    func nowNext(channelKey: String, at date: Date) -> EPGNowNext
    func programs(channelKey: String, overlapping interval: DateInterval) -> [EPGProgram]
}

/// An immutable, query-ready guide for one provider.
///
/// Each channel's programmes are sorted, deduplicated and non-overlapping, so programme end times
/// strictly increase and every lookup is a binary search.
struct EPGIndex: Sendable, EPGQuerying {
    struct Statistics: Equatable, Sendable {
        var malformed = 0
        var duplicates = 0
        var overlapsTrimmed = 0
        var outsideWindow = 0
        var overLimit = 0
        var truncated = false
        var incomplete = false
    }

    /// Canonical (`EPGTimestamp`), so it compares exactly with the same guide read from cache.
    let fetchedAt: Date
    /// Built only from Xtream short-guide listings, with no full guide underneath. It can be shown,
    /// but it never stands in for the full guide: it doesn't hide a cached one or make a refresh due.
    let isShortGuideOnly: Bool
    private(set) var programsByChannel: [String: [EPGProgram]]
    /// Normalized display name to normalized guide ID. Names shared by different guide channels are
    /// left out, so a name match never shows another channel's guide.
    let channelIDsByName: [String: String]
    private(set) var programCount: Int
    private(set) var coverageEnd: Date?
    private(set) var statistics: Statistics

    static func empty(fetchedAt: Date) -> EPGIndex {
        EPGIndex(fetchedAt: fetchedAt, programsByChannel: [:], channelIDsByName: [:], statistics: Statistics())
    }

    /// A base for short-guide listings when no full guide is loaded.
    static func shortGuideBase(fetchedAt: Date) -> EPGIndex {
        EPGIndex(fetchedAt: fetchedAt, programsByChannel: [:], channelIDsByName: [:], statistics: Statistics(),
                 isShortGuideOnly: true)
    }

    init(fetchedAt: Date, programsByChannel: [String: [EPGProgram]], channelIDsByName: [String: String],
         statistics: Statistics, isShortGuideOnly: Bool = false) {
        self.fetchedAt = EPGTimestamp.canonical(fetchedAt)
        self.isShortGuideOnly = isShortGuideOnly
        self.programsByChannel = programsByChannel
        self.channelIDsByName = channelIDsByName
        self.statistics = statistics
        programCount = programsByChannel.values.reduce(0) { $0 + $1.count }
        coverageEnd = programsByChannel.values.compactMap(\.last?.end).max()
    }

    /// Builds an index from a parsed feed. Synchronous and CPU-bound; call it off the main actor.
    init(document: EPGDocument, fetchedAt: Date, now: Date, limits: EPGLimits) throws {
        var statistics = Statistics(malformed: document.malformedCount, truncated: document.isTruncated,
                                    incomplete: document.isIncomplete)
        let window = Self.window(now: now, limits: limits)
        var grouped: [String: [EPGProgram]] = [:]
        for program in document.programs {
            guard let key = EPGChannelKey.guideID(program.channelID) else { continue }
            grouped[key, default: []].append(program)
        }
        try Task.checkCancellation()

        var normalized: [String: [EPGProgram]] = [:]
        normalized.reserveCapacity(grouped.count)
        var total = 0
        for (key, programs) in grouped {
            let list = Self.normalize(programs, window: window, now: now,
                                      limit: limits.maximumProgramsPerChannel, statistics: &statistics)
            guard !list.isEmpty else { continue }
            normalized[key] = list
            total += list.count
        }
        try Task.checkCancellation()

        if total > limits.maximumIndexedPrograms, !normalized.isEmpty {
            let perChannel = max(1, limits.maximumIndexedPrograms / normalized.count)
            for (key, list) in normalized where list.count > perChannel {
                normalized[key] = Self.nearest(list, to: now, limit: perChannel, statistics: &statistics)
            }
        }

        self.init(fetchedAt: fetchedAt, programsByChannel: normalized,
                  channelIDsByName: Self.nameMap(document.channels), statistics: statistics)
    }

    var channelCount: Int { programsByChannel.count }

    /// The guide channel for a playlist channel: its guide ID first, then an unambiguous display name.
    func channelKey(guideID: String?, name: String?) -> String? {
        if let key = EPGChannelKey.guideID(guideID), programsByChannel[key] != nil { return key }
        if let nameKey = EPGChannelKey.name(name), let key = channelIDsByName[nameKey],
           programsByChannel[key] != nil { return key }
        return nil
    }

    func nowNext(guideID: String?, name: String?, at date: Date) -> EPGNowNext {
        guard let key = channelKey(guideID: guideID, name: name) else { return .empty }
        return nowNext(channelKey: key, at: date)
    }

    func nowNext(channelKey: String, at date: Date) -> EPGNowNext {
        guard let list = programsByChannel[channelKey] else { return .empty }
        let index = Self.firstIndex(endingAfter: date, in: list)
        guard index < list.count else { return .empty }
        let candidate = list[index]
        guard candidate.start <= date else { return EPGNowNext(current: nil, next: candidate) }
        return EPGNowNext(current: candidate, next: index + 1 < list.count ? list[index + 1] : nil)
    }

    /// Programmes on one channel that overlap `interval`, in airing order.
    func programs(channelKey: String, overlapping interval: DateInterval) -> [EPGProgram] {
        guard let list = programsByChannel[channelKey] else { return [] }
        var result: [EPGProgram] = []
        var index = Self.firstIndex(endingAfter: interval.start, in: list)
        while index < list.count, list[index].start < interval.end {
            result.append(list[index])
            index += 1
        }
        return result
    }

    /// Replaces one channel's listings within the span the new programmes cover, keeping the rest.
    /// Used for Xtream short EPG, which is newer than the bulk feed for the hours it covers.
    func replacingPrograms(_ programs: [EPGProgram], guideID: String, now: Date, limits: EPGLimits) -> EPGIndex {
        guard let key = EPGChannelKey.guideID(guideID) else { return self }
        var statistics = self.statistics
        let incoming = Self.normalize(programs, window: Self.window(now: now, limits: limits), now: now,
                                      limit: limits.maximumProgramsPerChannel, statistics: &statistics)
        guard let first = incoming.first, let last = incoming.last else { return self }
        let kept = (programsByChannel[key] ?? []).filter { $0.end <= first.start || $0.start >= last.end }
        var merged = programsByChannel
        merged[key] = Self.normalize(incoming + kept, window: Self.window(now: now, limits: limits), now: now,
                                     limit: limits.maximumProgramsPerChannel, statistics: &statistics)
        return EPGIndex(fetchedAt: fetchedAt, programsByChannel: merged, channelIDsByName: channelIDsByName,
                        statistics: statistics, isShortGuideOnly: isShortGuideOnly)
    }

    /// Removes a short-guide-only channel when its overlay is evicted. Full guides never call
    /// this: their base listings must remain available after an overlay expires.
    func removingPrograms(guideID: String) -> EPGIndex {
        guard isShortGuideOnly, let key = EPGChannelKey.guideID(guideID), programsByChannel[key] != nil else {
            return self
        }
        var remaining = programsByChannel
        remaining.removeValue(forKey: key)
        return EPGIndex(fetchedAt: fetchedAt, programsByChannel: remaining,
                        channelIDsByName: channelIDsByName, statistics: statistics,
                        isShortGuideOnly: true)
    }

    // MARK: - Building

    private static func window(now: Date, limits: EPGLimits) -> DateInterval {
        DateInterval(start: now.addingTimeInterval(-limits.pastRetention),
                     end: now.addingTimeInterval(limits.futureHorizon))
    }

    /// Sorts one channel, keeps the first programme at each start instant, trims a programme that
    /// runs into the next one, and bounds the list around `now`. Deterministic for a given input.
    private static func normalize(_ programs: [EPGProgram], window: DateInterval, now: Date, limit: Int,
                                  statistics: inout Statistics) -> [EPGProgram] {
        let ordered = programs.enumerated()
            .filter { item in
                let inside = item.element.end > window.start && item.element.start < window.end
                if !inside { statistics.outsideWindow += 1 }
                return inside
            }
            .sorted { $0.element.start == $1.element.start ? $0.offset < $1.offset : $0.element.start < $1.element.start }
            .map(\.element)
        var result: [EPGProgram] = []
        result.reserveCapacity(ordered.count)
        for program in ordered {
            if let previous = result.last {
                if program.start == previous.start {
                    statistics.duplicates += 1
                    continue
                }
                if program.start < previous.end {
                    statistics.overlapsTrimmed += 1
                    result[result.count - 1] = previous.ending(at: program.start)
                }
            }
            result.append(program)
        }
        return nearest(result, to: now, limit: limit, statistics: &statistics)
    }

    /// At most `limit` programmes, mostly upcoming, with a little history before `now`.
    private static func nearest(_ list: [EPGProgram], to now: Date, limit: Int,
                                statistics: inout Statistics) -> [EPGProgram] {
        guard list.count > limit else { return list }
        let current = firstIndex(endingAfter: now, in: list)
        let start = max(0, min(current - limit / 8, list.count - limit))
        statistics.overLimit += list.count - limit
        return Array(list[start ..< start + limit])
    }

    private static func firstIndex(endingAfter date: Date, in list: [EPGProgram]) -> Int {
        var low = 0
        var high = list.count
        while low < high {
            let middle = (low + high) / 2
            if list[middle].end <= date { low = middle + 1 } else { high = middle }
        }
        return low
    }

    private static func nameMap(_ channels: [EPGChannel]) -> [String: String] {
        var map: [String: String] = [:]
        var ambiguous = Set<String>()
        for channel in channels {
            guard let key = EPGChannelKey.guideID(channel.id) else { continue }
            for name in Set(channel.displayNames.compactMap(EPGChannelKey.name)) where !ambiguous.contains(name) {
                if let existing = map[name], existing != key {
                    map[name] = nil
                    ambiguous.insert(name)
                } else {
                    map[name] = key
                }
            }
        }
        return map
    }
}

enum EPGGuideStatus {
    static func message(for index: EPGIndex) -> String? {
        if index.statistics.incomplete { return "Guide feed was incomplete; some listings may be missing." }
        return index.programCount == 0 ? "No guide listings are available yet." : nil
    }
}

private extension EPGProgram {
    func ending(at date: Date) -> EPGProgram {
        EPGProgram(channelID: channelID, start: start, end: date, title: title, subtitle: subtitle,
                   summary: summary, category: category, episode: episode)
    }
}
