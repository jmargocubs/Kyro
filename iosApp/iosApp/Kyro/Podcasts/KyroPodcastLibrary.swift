#if os(iOS) || KYRO_PODCAST_HOST_TESTS
import Foundation
import Observation

struct PodcastPreferences: Codable, Equatable, Sendable {
    var theme: KyroRadioPlayerTheme = .crimsonNoir
    var speed: Double = 1
    var back: Int = 15
    var forward: Int = 30
    var refreshHours: Int = 12 // zero disables automatic refresh
    var wifiOnly = true
    var removeCompleted = false
    var sleepMinutes = 0 // zero off, -1 at episode end

    static let speeds = [0.5, 0.75, 1, 1.25, 1.5, 1.75, 2, 2.5, 3]
    static let skips = [10, 15, 30, 45, 60]
    static let refreshIntervals = [0, 6, 12, 24, 48]
    static let sleepOptions = [0, 15, 30, 45, 60, 90, -1]

    var isValid: Bool {
        Self.speeds.contains(speed) && Self.skips.contains(back) && Self.skips.contains(forward)
        && Self.refreshIntervals.contains(refreshHours) && Self.sleepOptions.contains(sleepMinutes)
    }
}

struct PodcastProgress: Codable, Equatable, Sendable {
    var position: Double
    var duration: Double
    var played: Bool

    static func clamped(_ seconds: Double, duration: Double) -> Double {
        let valid = seconds.isFinite ? max(0, seconds) : 0
        return duration.isFinite && duration > 0 ? min(valid, duration) : valid
    }

    var fraction: Double {
        duration.isFinite && duration > 0 ? Self.clamped(position, duration: duration) / duration : 0
    }
    var resumable: Double { played || (duration > 0 && duration - position < 2) ? 0 : position }
}

struct PodcastEntry: Codable, Hashable, Identifiable, Sendable {
    let episode: PodcastEpisode
    let showTitle: String
    let showArtwork: URL?
    var id: String { episode.id }
    var artwork: URL? { episode.artwork ?? showArtwork }

    init(_ episode: PodcastEpisode, show: PodcastShow) {
        self.episode = episode
        showTitle = show.title
        showArtwork = show.artwork
    }
}

struct PodcastQueue: Codable, Equatable {
    private(set) var entries: [PodcastEntry] = []
    mutating func add(_ entry: PodcastEntry, currentID: String?) {
        guard entries.count < 100, currentID != entry.id, !entries.contains(where: { $0.id == entry.id }) else { return }
        entries.append(entry)
    }
    mutating func remove(_ id: String) { entries.removeAll { $0.id == id } }
    mutating func move(from source: Int, to destination: Int) {
        guard entries.indices.contains(source), (0...entries.count).contains(destination) else { return }
        let entry = entries.remove(at: source)
        entries.insert(entry, at: destination > source ? destination - 1 : destination)
    }
    mutating func next() -> PodcastEntry? { entries.isEmpty ? nil : entries.removeFirst() }
}

enum PodcastSleep: Equatable {
    case off, end, deadline(Date)
    static func make(_ minutes: Int, now: Date = Date()) -> Self {
        if minutes == -1 { return .end }
        return minutes > 0 ? .deadline(now.addingTimeInterval(Double(minutes) * 60)) : .off
    }
    func shouldPause(at date: Date, ended: Bool = false) -> Bool {
        switch self {
        case .off: false
        case .end: ended
        case .deadline(let deadline): date >= deadline
        }
    }
}

enum PodcastCassetteMotion {
    static func spins(playing: Bool, seeking: Bool, visible: Bool, active: Bool, reduceMotion: Bool) -> Bool {
        (playing || seeking) && visible && active && !reduceMotion
    }
    static func tapeSizes(fraction: Double) -> (Double, Double) {
        let progress = PodcastProgress.clamped(fraction, duration: 1)
        // The cross-sectional area, not radius, tracks the amount wound.
        func diameter(_ share: Double) -> Double { sqrt(0.33 * 0.33 + share * 0.70) }
        return (diameter(1 - progress), diameter(progress))
    }
}

struct PodcastDownloadLocation: Sendable {
    let root: URL
    private static let extensions = ["mp3", "m4a", "m4b", "mp4", "aac", "wav", "aiff", "ogg", "opus", "flac", "audio"]

    func url(for episode: PodcastEpisode, mime: String? = nil) -> URL {
        let ext = episode.media.pathExtension.lowercased()
        let inferred = switch mime?.lowercased() {
        case "audio/mpeg", "audio/mp3": "mp3"
        case "audio/mp4", "audio/m4a", "audio/x-m4a": "m4a"
        case "audio/aac", "audio/aacp": "aac"
        case "audio/wav", "audio/x-wav": "wav"
        case "audio/aiff", "audio/x-aiff": "aiff"
        case "audio/ogg", "application/ogg": "ogg"
        case "audio/opus": "opus"
        case "audio/flac", "audio/x-flac": "flac"
        case "video/mp4": "mp4"
        default: "audio"
        }
        return file(episode, suffix: Self.extensions.contains(ext) ? ext : inferred)
    }

    func existing(for episode: PodcastEpisode) -> URL? {
        let preferred = url(for: episode)
        if FileManager.default.fileExists(atPath: preferred.path) { return preferred }
        return Self.extensions.lazy.map { file(episode, suffix: $0) }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    private func file(_ episode: PodcastEpisode, suffix: String) -> URL {
        root.appendingPathComponent(PodcastAddress.fingerprint(episode.id)).appendingPathExtension(suffix)
    }
}

actor PodcastCacheDisk {
    private let directory: URL
    init(directory: URL) { self.directory = directory }

    func read(_ id: String) -> PodcastFeedCache? {
        let url = file(id)
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size <= 8 * 1024 * 1024, let data = try? Data(contentsOf: url),
              let cache = try? JSONDecoder().decode(PodcastFeedCache.self, from: data),
              cache.show.id == id else { return nil }
        return cache
    }

    func write(_ cache: PodcastFeedCache) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var folder = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try folder.setResourceValues(values)
        try JSONEncoder().encode(cache).write(to: file(cache.show.id), options: .atomic)
    }

    func remove(_ id: String) { try? FileManager.default.removeItem(at: file(id)) }
    private func file(_ id: String) -> URL {
        directory.appendingPathComponent(PodcastAddress.fingerprint(id)).appendingPathExtension("json")
    }
}

/// Serial writes preserve checkpoint order with the existing on-disk key.
/// Only the writer's queue uses its captured persistence dependencies.
private final class PodcastProgressWriter: @unchecked Sendable {
    private let defaults: UserDefaults
    private let key: String
    private let queue = DispatchQueue(label: "kyro.podcast.checkpoints", qos: .utility)

    init(defaults: UserDefaults, key: String) {
        self.defaults = defaults
        self.key = key
    }

    func submit(_ snapshot: [String: PodcastProgress]) {
        queue.async { [self] in
            #if os(iOS)
            let start = KyroPerformanceDiagnostics.isEnabled ? KyroPerformanceClock.now() : nil
            #endif
            if let data = try? JSONEncoder().encode(snapshot) { defaults.set(data, forKey: key) }
            #if os(iOS)
            if let start {
                let duration = (KyroPerformanceClock.now() - start) * 1000
                Task { @MainActor in KyroPerformanceDiagnostics.record(.podcastCheckpointWrite, milliseconds: duration) }
            }
            #endif
        }
    }

    #if KYRO_PODCAST_HOST_TESTS
    func flush() async {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume() }
        }
    }
    #endif
}

@MainActor @Observable
final class KyroPodcastLibrary {
    static let shared = KyroPodcastLibrary()
    static let maxShows = 150
    private static let preferencesKey = "kyrox.podcasts.preferences.v1"
    private static let stateKey = "kyrox.podcasts.library.v1"

    struct State: Codable {
        var shows: [PodcastShow] = []
        var progress: [String: PodcastProgress] = [:]
        var saved: Set<String> = []
        var favoriteShows: Set<String> = []
        var history: [PodcastEntry] = []
        var retained: [String: PodcastEntry] = [:]
        var queue = PodcastQueue()

        // Progress is written separately on playback checkpoints. Never
        // encode feeds, listening history and the complete queue on a tick.
        private enum CodingKeys: String, CodingKey {
            case shows, saved, favoriteShows, history, retained, queue
        }
    }
    private static let progressKey = "kyrox.podcasts.progress.v1"

    private(set) var preferences: PodcastPreferences
    private(set) var shows: [PodcastShow]
    private(set) var episodes: [String: [PodcastEpisode]] = [:]
    private(set) var progress: [String: PodcastProgress]
    private(set) var saved: Set<String>
    private(set) var favoriteShows: Set<String>
    private(set) var history: [PodcastEntry]
    private(set) var queue: PodcastQueue
    private(set) var previewCache: PodcastFeedCache?
    private(set) var isRefreshing = false
    @ObservationIgnored private var state: State
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let progressWriter: PodcastProgressWriter
    @ObservationIgnored private let disk: PodcastCacheDisk
    @ObservationIgnored private var cache: [String: PodcastFeedCache] = [:]
    @ObservationIgnored private var automaticCursor = ""
    @ObservationIgnored private var automaticChecked: [String: Date] = [:]
    @ObservationIgnored private var lastAutomaticPass: Date?

    init(defaults: UserDefaults = .standard, base: URL? = nil) {
        self.defaults = defaults
        progressWriter = PodcastProgressWriter(defaults: defaults, key: Self.progressKey)
        let base = base ?? URL.applicationSupportDirectory.appendingPathComponent("KyroPodcasts", isDirectory: true)
        disk = PodcastCacheDisk(directory: base.appendingPathComponent("Feeds", isDirectory: true))
        let decoder = JSONDecoder()
        var stored = defaults.data(forKey: Self.stateKey).flatMap { try? decoder.decode(State.self, from: $0) } ?? State()
        stored.progress = defaults.data(forKey: Self.progressKey).flatMap {
            try? decoder.decode([String: PodcastProgress].self, from: $0)
        } ?? [:]
        let prefs = defaults.data(forKey: Self.preferencesKey).flatMap { try? decoder.decode(PodcastPreferences.self, from: $0) }
        state = stored
        shows = stored.shows
        progress = stored.progress
        saved = stored.saved
        favoriteShows = stored.favoriteShows
        history = stored.history
        queue = stored.queue
        preferences = prefs.flatMap { $0.isValid ? $0 : nil } ?? PodcastPreferences()
    }

    func selectTheme(_ theme: KyroRadioPlayerTheme) {
        var updated = preferences
        updated.theme = theme
        updatePreferences(updated)
    }

    func updatePreferences(_ preferences: PodcastPreferences) {
        guard preferences.isValid, preferences != self.preferences else { return }
        self.preferences = preferences
        defaults.set(try? JSONEncoder().encode(preferences), forKey: Self.preferencesKey)
    }

    func show(for id: String) -> PodcastShow? {
        shows.first { $0.id == id } ?? (previewCache?.show.id == id ? previewCache?.show : nil)
    }

    func isSubscribed(_ show: PodcastShow) -> Bool { shows.contains { $0.id == show.id } }

    func preview(_ address: URL, fromDirectory: Bool) async throws -> PodcastShow {
        if let existing = shows.first(where: { $0.feed == address || $0.portableFeed == address }) {
            await restore(existing)
            return show(for: existing.id) ?? existing
        }
        let starter = PodcastShow(id: PodcastAddress.fingerprint(address.absoluteString), feed: address, title: "",
            portableFeed: fromDirectory && PodcastAddress.portable(address) ? address : nil)
        let result = try await PodcastFeedService.shared.load(starter, cached: nil, maxAge: 0)
        try Task.checkCancellation()
        if let existing = shows.first(where: {
            $0.feed == result.address || $0.feed == result.documentAddress ||
                result.documentAddress != nil && cache[$0.id]?.documentAddress == result.documentAddress
        }) {
            await restore(existing)
            return show(for: existing.id) ?? existing
        }
        previewCache = result
        return result.show
    }

    func subscribe(_ show: PodcastShow) throws {
        guard !isSubscribed(show), !shows.contains(where: { $0.feed == show.feed }) else { return }
        guard shows.count < Self.maxShows else { throw PodcastError.capacity }
        shows.append(show)
        if let previewCache, previewCache.show.id == show.id { accept(previewCache) }
        persist()
    }

    func unsubscribe(_ show: PodcastShow) {
        shows.removeAll { $0.id == show.id }
        favoriteShows.remove(show.id)
        episodes[show.id] = nil
        cache[show.id] = nil
        Task { await disk.remove(show.id) }
        persist()
    }

    /// Import without fanning out to publishers or requiring the network.
    func importFeeds(_ urls: [URL]) {
        var known = Set(shows.flatMap { [$0.feed, $0.portableFeed].compactMap { $0 } })
        for url in urls where shows.count < Self.maxShows && known.insert(url).inserted {
            shows.append(.init(id: PodcastAddress.fingerprint(url.absoluteString), feed: url,
                               title: url.host() ?? "Podcast"))
        }
        persist()
    }

    func restore(_ show: PodcastShow) async {
        guard cache[show.id] == nil, let result = await disk.read(show.id),
              isSubscribed(show), cache[show.id] == nil else { return }
        cache[show.id] = result
        setEpisodes(result)
    }

    func restoreAll() async {
        for show in shows {
            guard !Task.isCancelled else { return }
            await restore(show)
        }
    }

    func refresh(_ show: PodcastShow, maxAge: TimeInterval = 0) async throws {
        guard isSubscribed(show) else { return }
        await restore(show)
        guard let current = shows.first(where: { $0.id == show.id }) else { return }
        let existing = cache[show.id]
        if existing?.isFresh(for: current.feed, maxAge: maxAge) == true { return }
        let result = try await PodcastFeedService.shared.load(current, cached: existing, maxAge: maxAge)
        try Task.checkCancellation()
        guard isSubscribed(current) else { return }
        if let duplicate = shows.first(where: {
            $0.id != show.id && ($0.feed == result.address || $0.feed == result.documentAddress ||
                result.documentAddress != nil && cache[$0.id]?.documentAddress == result.documentAddress)
        }) {
            // Keep the older identity so progress, downloads and queue entries
            // are not orphaned. A pending, unpopulated import is safe to fold in.
            if cache[duplicate.id] == nil, state.progress.keys.allSatisfy({ !$0.hasPrefix(duplicate.id + ":") }),
               !state.retained.values.contains(where: { $0.episode.showID == duplicate.id }), duplicate.portableFeed == nil {
                unsubscribe(duplicate)
            } else { return }
        }
        accept(result)
        if let index = shows.firstIndex(where: { $0.id == show.id }), shows[index] != result.show {
            shows[index] = result.show
            persist()
        }
    }

    func refreshAll(automatic: Bool) async -> Int {
        guard !isRefreshing, !automatic || preferences.refreshHours > 0 else { return 0 }
        if automatic {
            let now = Date()
            guard now.timeIntervalSince(lastAutomaticPass ?? .distantPast) >= 120 else { return 0 }
            lastAutomaticPass = now
        }
        isRefreshing = true
        defer { isRefreshing = false }
        let interval = automatic ? Double(preferences.refreshHours) * 3600 : 0
        let sorted = shows.sorted { $0.id < $1.id }
        let rotated = sorted.filter { $0.id > automaticCursor } + sorted.filter { $0.id <= automaticCursor }
        let candidates = automatic ? Array(rotated.filter {
            Date().timeIntervalSince(automaticChecked[$0.id] ?? .distantPast) >= interval
        }.prefix(8)) : sorted
        var failures = 0
        // Small parallel batches, with a hard per-operation bound.
        for index in stride(from: 0, to: candidates.count, by: 3) {
            if Task.isCancelled { break }
            let batch = candidates[index..<min(index + 3, candidates.count)]
            await withTaskGroup(of: Bool.self) { group in
                for show in batch {
                    group.addTask { @MainActor in
                        do { try await self.refresh(show, maxAge: interval); return true }
                        catch { return false }
                    }
                }
                for await success in group where !success { failures += 1 }
            }
            if automatic {
                automaticCursor = batch.last?.id ?? automaticCursor
                for show in batch { automaticChecked[show.id] = Date() }
            }
        }
        return failures
    }

    func entries(for show: PodcastShow, limit: Int = PodcastFeed.episodeLimit) -> [PodcastEntry] {
        let items = episodes[show.id] ?? (previewCache?.show.id == show.id ? previewCache?.episodes ?? [] : [])
        return items.prefix(limit).map { PodcastEntry($0, show: show) }
    }

    func latest(limit: Int = 100) -> [PodcastEntry] {
        shows.flatMap { entries(for: $0, limit: limit) }
            .sorted { ($0.episode.published ?? .distantPast) > ($1.episode.published ?? .distantPast) }
            .prefix(limit).map { $0 }
    }

    /// Shelf diagnostics need a count, not a rebuilt and sorted card list.
    func cachedLatestCount(upTo limit: Int) -> Int {
        guard limit > 0 else { return 0 }
        var count = 0
        for show in shows {
            count += episodes[show.id]?.count ?? (previewCache?.show.id == show.id ? previewCache?.episodes.count ?? 0 : 0)
            if count >= limit { return limit }
        }
        return count
    }

    func continuing() -> [PodcastEntry] {
        var seen = Set<String>()
        let positions = progress
        var recent = (history + retainedEntries).filter { seen.insert($0.id).inserted && (positions[$0.id]?.resumable ?? 0) > 0 }
        // Progress restored on a new device has no listening-history row.
        let missing = Set(positions.filter { $0.value.resumable > 0 }.keys).subtracting(seen)
        if !missing.isEmpty {
            for show in shows {
                for episode in episodes[show.id] ?? [] where missing.contains(episode.id) {
                    recent.append(PodcastEntry(episode, show: show))
                }
            }
        }
        return recent
    }

    var retainedEntries: [PodcastEntry] {
        // Observe checkpoint state, not the active player's timestamp.
        _ = progress
        _ = saved
        return Array(state.retained.values)
    }

    func toggleFavorite(_ show: PodcastShow) {
        guard isSubscribed(show) else { return }
        if !favoriteShows.insert(show.id).inserted { favoriteShows.remove(show.id) }
        persist()
    }

    func toggleSaved(_ entry: PodcastEntry) {
        if !saved.insert(entry.id).inserted { saved.remove(entry.id) }
        retain(entry)
    }

    func retain(_ entry: PodcastEntry) {
        state.retained[entry.id] = entry
        persist()
    }

    func recordStart(_ entry: PodcastEntry) {
        history.removeAll { $0.id == entry.id }
        history.insert(entry, at: 0)
        if history.count > 150 { history.removeLast() }
        retain(entry)
    }

    func clearHistory() { history = []; persist() }

    func checkpoint(_ entry: PodcastEntry, position: Double, duration: Double, played: Bool, publish: Bool) {
        let safeDuration = duration.isFinite && duration > 0 ? min(604_800, duration) : 0
        let safePosition = min(604_800, PodcastProgress.clamped(position, duration: safeDuration))
        let value = PodcastProgress(position: safePosition, duration: safeDuration, played: played)
        if state.progress[entry.id] == value, !publish { return }
        if state.progress[entry.id] != value {
            state.progress[entry.id] = value
            persistProgress()
        }
        if publish, progress != state.progress { progress = state.progress }
        if state.retained[entry.id] == nil { retain(entry) }
    }

    func resumePosition(for id: String) -> Double { state.progress[id]?.resumable ?? 0 }

    func mark(_ entry: PodcastEntry, played: Bool) {
        let prior = state.progress[entry.id]
        checkpoint(entry, position: played ? prior?.position ?? 0 : 0,
                   duration: prior?.duration ?? entry.episode.duration ?? 0, played: played, publish: true)
    }

    func enqueue(_ entry: PodcastEntry, currentID: String?) {
        let count = queue.entries.count
        queue.add(entry, currentID: currentID)
        if count != queue.entries.count { persist() }
    }
    func removeFromQueue(_ id: String) {
        guard queue.entries.contains(where: { $0.id == id }) else { return }
        queue.remove(id)
        persist()
    }
    func moveQueue(from: Int, to: Int) { queue.move(from: from, to: to); persist() }
    func nextInQueue() -> PodcastEntry? {
        let entry = queue.next()
        if entry != nil { persist() }
        return entry
    }

    func snapshot() -> State { state }

    func mergePortable(shows incoming: [PodcastShow], progress incomingProgress: [String: PodcastProgress],
                       saved incomingSaved: Set<String>, favorites incomingFavorites: Set<String>) {
        var mapping: [String: String] = [:]
        for show in incoming {
            if let current = shows.first(where: { $0.id == show.id || $0.feed == show.feed || $0.portableFeed == show.feed }) {
                mapping[show.id] = current.id
            } else if shows.count < Self.maxShows {
                shows.append(show)
                mapping[show.id] = show.id
            }
        }
        func localID(_ value: String) -> String? {
            let parts = value.split(separator: ":", maxSplits: 1)
            guard parts.count == 2, let show = mapping[String(parts[0])] else { return nil }
            return show + ":" + parts[1]
        }
        for (id, value) in incomingProgress {
            if let key = localID(id) { state.progress[key] = value }
        }
        saved.formUnion(incomingSaved.compactMap(localID))
        favoriteShows.formUnion(incomingFavorites.compactMap { mapping[$0] })
        progress = state.progress
        persistProgress()
        persist()
    }

    private func setEpisodes(_ result: PodcastFeedCache) {
        let list = result.episodes.sorted { ($0.published ?? .distantPast) > ($1.published ?? .distantPast) }
        if episodes[result.show.id] != list { episodes[result.show.id] = list }
    }

    private func accept(_ result: PodcastFeedCache) {
        cache[result.show.id] = result
        setEpisodes(result)
        Task { try? await disk.write(result) }
    }

    private func persist() {
        state.shows = shows
        state.saved = saved
        state.favoriteShows = favoriteShows
        state.history = history
        state.queue = queue
        if let data = try? JSONEncoder().encode(state) { defaults.set(data, forKey: Self.stateKey) }
    }

    private func persistProgress() {
        progressWriter.submit(state.progress)
    }

    #if KYRO_PODCAST_HOST_TESTS
    func flushProgressWrites() async { await progressWriter.flush() }
    #endif
}
#endif
