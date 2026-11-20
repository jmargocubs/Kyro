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
