import Foundation

@main
enum FocusDiagnosticBufferTests {
    static func main() throws {
        var buffer = TVFocusDiagnosticBuffer(capacity: 3)
        precondition(buffer.association(at: 1) == "unknown")
        buffer.append(kind: "remote", component: "window", detail: "down", uptime: 1)
        precondition(buffer.association(at: 1.2) == "inferred: input")
        precondition(buffer.association(at: 0.9) == "unknown", "future events cannot be causes")
        buffer.append(kind: "request", component: "LiveTV", detail: "entry", uptime: 1.1)
        precondition(buffer.association(at: 1.2) == "inferred: input + programmatic")
        buffer.append(kind: "lifecycle", component: "LiveTV", detail: "appear", uptime: 1.15)
        precondition(buffer.association(at: 1.2) == "inferred: input + programmatic + lifecycle/state")
        precondition(buffer.association(at: 2) == "unknown")
        buffer.append(kind: "movementFailed", component: "UIKit", detail: "not proof of fallback", uptime: 2)
        precondition(buffer.events.count == 3 && buffer.dropped == 1)
        precondition(buffer.events.first?.sequence == 2 && buffer.events.last?.sequence == 4)
        precondition(buffer.association(at: 2) == "unknown", "failed movement must not become confirmed fallback")
        for index in 0..<10_000 { buffer.append(kind: "state", component: "test", detail: "bounded", uptime: Double(index)) }
        precondition(buffer.events.count == 3 && buffer.dropped == 10_001)
        buffer.append(kind: String(repeating: "k", count: 100), component: String(repeating: "c", count: 200),
                      detail: String(repeating: "d", count: 1_000))
        precondition(buffer.events.last?.kind.count == 40 && buffer.events.last?.component.count == 80 && buffer.events.last?.detail.count == 240)
        let data = try JSONEncoder().encode(buffer.events)
        let decoded = try JSONDecoder().decode([TVFocusDiagnosticBuffer.Event].self, from: data)
        precondition(decoded == buffer.events)
        var minimum = TVFocusDiagnosticBuffer(capacity: 0)
        minimum.append(kind: "test", component: "test", detail: "one")
        minimum.append(kind: "test", component: "test", detail: "two")
        precondition(minimum.events.count == 1 && minimum.dropped == 1)
        var entry = TVMenuEntryFocusState()
        precondition(entry.receive(1, menuOwnsFocus: false))
        entry.cancel()
        precondition(!entry.consume(1), "cancelled delayed callback must stay cancelled")
        precondition(!entry.receive(1, menuOwnsFocus: false), "same token cannot replay")
        precondition(!entry.receive(2, menuOwnsFocus: true))
        precondition(entry.receive(3, menuOwnsFocus: false) && entry.consume(3))
        precondition(!entry.consume(3))
        precondition(tvFocusRepairAction(attempt: 1, isShowingRoot: true) == .contentHandoff)
        precondition(tvFocusRepairAction(attempt: 2, isShowingRoot: true) == .topMenu)
        precondition(tvFocusRepairAction(attempt: 3, isShowingRoot: false) == .engineReresolve)
        print("PASS: bounded storage, drop count, ordering, temporal ambiguity, unknown/fallback, size caps, JSON round trip")
        print("PASS: existing entry-token cancellation/consumption and watchdog escalation rules")
    }
}
