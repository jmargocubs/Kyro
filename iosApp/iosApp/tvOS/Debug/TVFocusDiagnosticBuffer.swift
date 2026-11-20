import Foundation

/// Value-only, bounded storage. Callers supply structural identifiers, never media/user text.
struct TVFocusDiagnosticBuffer {
    struct Event: Codable, Equatable {
        let sequence: Int
        let uptime: TimeInterval
        let timestamp: Date
        let kind: String
        let component: String
        let detail: String
    }

    let capacity: Int
    private(set) var events: [Event] = []
    private(set) var dropped = 0
    private var sequence = 0

    init(capacity: Int = 512) { self.capacity = max(1, capacity) }

    /// Total events appended, including ones the ring has since dropped.
    var appendedCount: Int { sequence }

    mutating func append(kind: String, component: String, detail: String,
                         uptime: TimeInterval = ProcessInfo.processInfo.systemUptime,
                         timestamp: Date = Date()) {
        sequence += 1
        if events.count == capacity { events.removeFirst(); dropped += 1 }
        events.append(Event(sequence: sequence, uptime: uptime, timestamp: timestamp,
                            kind: String(kind.prefix(40)), component: String(component.prefix(80)),
                            detail: String(detail.prefix(240))))
    }

    /// Temporal association only. Multiple plausible sources remain ambiguous.
    func association(at uptime: TimeInterval) -> String {
        let recent = events.filter { uptime >= $0.uptime && uptime - $0.uptime <= 0.35 }
        var sources: [String] = []
        if recent.contains(where: { $0.kind == "remote" || $0.kind == "handler" }) { sources.append("input") }
        if recent.contains(where: { $0.kind == "request" }) { sources.append("programmatic") }
        if recent.contains(where: { $0.kind == "lifecycle" || $0.kind == "state" }) { sources.append("lifecycle/state") }
        return sources.isEmpty ? "unknown" : "inferred: " + sources.joined(separator: " + ")
    }
}

/// The exported report. It holds only the sanitized ring, so the same value is
/// safe to persist and to serve. Schema 2 adds `state` and `savedAt`; schema 1
/// readers that only read `events` and `dropped` keep working.
struct TVFocusCaptureArchive: Codable, Equatable {
    enum State: String, Codable { case recording, stopped }

    var schema = 2
    let build: String
    var limitations = "Temporal associations are inferred, not causation. Focus heading is not raw remote input. Binding observations are not engine confirmation. Failed movement is not proof of fallback. Capture excludes events while disabled/backgrounded. No media text or network credentials collected."
    let state: State
    let savedAt: Date
    let dropped: Int
    let events: [TVFocusDiagnosticBuffer.Event]

    init(build: String, state: State, savedAt: Date, buffer: TVFocusDiagnosticBuffer) {
        self.build = build
        self.state = state
        self.savedAt = savedAt
        self.dropped = buffer.dropped
        self.events = buffer.events
    }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }

    static func decode(_ data: Data) throws -> TVFocusCaptureArchive {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(TVFocusCaptureArchive.self, from: data)
    }
}

/// Which saved capture an export reads.
enum TVFocusCaptureSlot: String, CaseIterable {
    /// The capture that is recording now, or the most recent one that stopped.
    case latest
    /// The capture that "Start fresh capture" replaced. Kept so a fresh start
    /// never destroys the only copy of an earlier failure.
    case previous
}

/// Two files in Application Support. Only sanitized archives are written; a
/// corrupt or unreadable file reads as absent instead of throwing into the UI.
/// The capped ring keeps each file well under 200 KB.
struct TVFocusCaptureStore {
    static let maximumFileBytes = 1_000_000
    let directory: URL

    static func standard(fileManager: FileManager = .default) -> TVFocusCaptureStore? {
        guard let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        return TVFocusCaptureStore(directory: base.appendingPathComponent("KyroFocusDiagnostics", isDirectory: true))
    }

    func url(for slot: TVFocusCaptureSlot) -> URL {
        directory.appendingPathComponent("\(slot.rawValue)-capture.json")
    }

    func save(_ data: Data, to slot: TVFocusCaptureSlot) throws {
        guard data.count <= Self.maximumFileBytes else { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: url(for: slot), options: [.atomic])
    }

    func load(_ slot: TVFocusCaptureSlot) -> TVFocusCaptureArchive? {
        let file = url(for: slot)
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
              let size = attributes[.size] as? Int, size <= Self.maximumFileBytes,
              let data = try? Data(contentsOf: file) else { return nil }
        return try? TVFocusCaptureArchive.decode(data)
    }

    /// Called before a fresh capture overwrites `latest`. Keeps the old latest
    /// as `previous`; an empty latest never replaces a useful previous.
    func rotateLatestToPrevious() throws {
        guard let latest = load(.latest), !latest.events.isEmpty else { return }
        try save(latest.encoded(), to: .previous)
    }
}
