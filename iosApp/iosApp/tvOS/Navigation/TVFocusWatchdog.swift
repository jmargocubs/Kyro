/// What a focus-outage repair should try next.
enum TVFocusRepairAction: Equatable {
    /// Re-arm the page's own entry focus — the gentle nudge, and the right one
    /// while the page still has a focus target to hand focus back to.
    case contentHandoff
    /// Un-suppress the top menu and pin its selected element.
    case topMenu
    /// Ask the engine to re-resolve from the window. Used on pushed routes,
    /// where the shell owns no focus target it could legitimately pin.
    case engineReresolve
}

/// Escalate a repeated outage at the root from the page to the top menu.
///
/// A content hand-down only repairs focus if the page has something focusable.
/// A page rendering nothing but an inert placeholder has no focus target at
/// all, so the hand-down changes nothing and the remote stays dead through
/// every retry — the shape of the "Favorites with no favorites" soft-lock. The
/// top menu always has focusable elements while it is on screen, so handing
/// focus there guarantees the user a way out even from a page that cannot take
/// focus itself.
///
/// - Parameter attempt: 1 for the first repair of an outage.
func tvFocusRepairAction(attempt: Int, isShowingRoot: Bool) -> TVFocusRepairAction {
    guard isShowingRoot else { return .engineReresolve }
    return attempt <= 1 ? .contentHandoff : .topMenu
}

/// How the top bar treats the moment its focus binding drops to nil.
enum TVTopMenuFocusLoss: Equatable {
    /// Focus really left the bar: let it go and tell the shell content owns it.
    case handOffToContent
    /// The user moved Down from a panel-bearing element: open and enter its panel.
    case enterPanel
    /// Opening or closing a preview overlay perturbed focus with no user move:
    /// put focus back on the element the user is on.
    case repin
}

/// A user's Down is never mistaken for a spurious loss: before Build 103 a
/// native Down from a tab with an open preview was re-pinned to the tab, so
/// swipes (and clicks the handler missed) could not leave it. Down from a
/// panel-bearing tab enters its panel for clicks and swipes alike; Down from
/// any other element goes to the page.
func tvTopMenuFocusLoss(
    movedDown: Bool,
    lastElementHasPanel: Bool,
    explicitHandOff: Bool,
    previewOpen: Bool,
    refocusAfterSidewaysClose: Bool
) -> TVTopMenuFocusLoss {
    if movedDown { return lastElementHasPanel ? .enterPanel : .handOffToContent }
    if explicitHandOff { return .handOffToContent }
    if previewOpen || refocusAfterSidewaysClose { return .repin }
    return .handOffToContent
}

/// Focus arriving on a bar element makes the menu the owner only when the user
/// moved it there or the bar itself asked for it. System-initiated arrivals —
/// launch, pop to root, panel teardown, cover dismissal — leave ownership with
/// the page, so the page's pending entry or return claim still lands instead
/// of being refused because the always-enabled bar happened to win a repair.
func tvTopMenuArrivalTakesOwnership(userMoved: Bool, matchesBarRequest: Bool) -> Bool {
    userMoved || matchesBarRequest
}

/// What `requestMenuFocus` does for a target.
enum TVTopMenuFocusClaim: Equatable {
    case claim
    /// The element already holds focus and the bar owns it: nothing to do.
    case alreadyFocused
    /// The binding still holds the target although the bar no longer owns
    /// focus: the binding is stale, and writing the same value is a no-op.
    case reclaimStale
}

func tvTopMenuFocusClaim(bindingMatchesTarget: Bool, barOwnsFocus: Bool) -> TVTopMenuFocusClaim {
    guard bindingMatchesTarget else { return .claim }
    return barOwnsFocus ? .alreadyFocused : .reclaimStale
}

#if os(tvOS)
import SwiftUI
import UIKit

/// Reads and nudges the live focus engine for the app's key window.
///
/// SwiftUI exposes no way to ask "does anything on screen currently hold
/// focus?", and `@FocusState` is not an answer: the engine can drop focus
/// without writing `nil` back into a binding, which is exactly the wedge this
/// watchdog exists to catch. `UIFocusSystem` is the only source of truth.
enum TVFocusSystemProbe {
    @MainActor
    private static var keyWindow: UIWindow? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .filter { $0.activationState == .foregroundActive }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)
    }

    /// The focused item's *type* name, or `nil` when nothing is focused. Only
    /// the type is returned: a focused item's description can carry item
    /// titles, and breadcrumbs must stay free of library content.
    @MainActor
    static func focusedItemTypeName() -> String? {
        focusedItem().map { String(describing: type(of: $0)) }
    }

    @MainActor
    static func focusedItem() -> UIFocusItem? {
        guard let window = keyWindow else { return nil }
        return UIFocusSystem.focusSystem(for: window)?.focusedItem
    }

    @MainActor
    static var keyWindowScreen: UIScreen? { keyWindow?.windowScene?.screen }

    /// Ask the engine to re-resolve focus from the window root. Used only on
    /// pushed routes, where the tvOS shell owns no focus target it could
    /// legitimately pin.
    @MainActor
    static func requestFocusUpdate() {
        guard let window = keyWindow else { return }
        TVFocusDiagnostics.record("request", "Watchdog", "windowSetNeedsFocusUpdate")
        window.setNeedsFocusUpdate()
        window.updateFocusIfNeeded()
    }
}

/// Records the heading of the latest focus update. The observer runs
/// synchronously when UIKit posts the update (`queue: nil`), which is before
/// SwiftUI's next graph update applies `@FocusState` changes and runs
/// `onChange`. The top bar uses it to tell a user's move (a heading) from a
/// programmatic claim or an engine repair (no heading).
@MainActor
enum TVFocusMovementTracker {
    private(set) static var lastHeading: UIFocusHeading = []
    private static var observer: NSObjectProtocol?

    static var lastMoveWasDown: Bool { lastHeading.contains(.down) }
    static var lastMoveWasDirectional: Bool {
        !lastHeading.intersection([.up, .down, .left, .right]).isEmpty
    }

    static func install() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(
            forName: UIFocusSystem.didUpdateNotification, object: nil, queue: nil
        ) { note in
            guard Thread.isMainThread else { return }
            MainActor.assumeIsolated {
                let context = note.userInfo?[UIFocusSystem.focusUpdateContextUserInfoKey] as? UIFocusUpdateContext
                lastHeading = context?.focusHeading ?? []
            }
        }
    }
}

/// Watches for the focus engine losing focus entirely — no focused item, so no
/// control reacts to the remote and the app reads as hard-frozen — and fires a
/// single repair nudge per detection.
///
/// Field reports of this wedge showed the main thread alive and the top bar's
/// `@FocusState` stale at a non-nil item, so the bar's own compensating re-pin
/// never ran. Detection therefore cannot be derived from app state; it has to
/// come from the engine (`TVFocusSystemProbe`).
///
/// Per docs/tvos-focus.md the repair must not fight the engine: one nudge per
/// detected outage, rate-limited, and never a retry loop.
struct TVFocusWatchdogModifier: ViewModifier {
    /// False whenever something other than the shell legitimately owns (or
    /// suspends) focus — a presented cover, a system dialog, the background.
    /// A "no focused item" reading is not actionable in those states.
    let isActive: Bool
    /// Passed the 1-based repair attempt for the current outage, so the shell
    /// can escalate when an earlier attempt failed to restore focus.
    let onRepair: (Int) -> Void

    private static let checkInterval = Duration.seconds(2)
    /// Two consecutive misses (~4 s) before acting. One miss is routinely seen
    /// mid-transition, while a cover dismisses or content swaps in.
    private static let missesBeforeRepair = 2
    /// Monotonic: a wall-clock step (NTP, manual date change) must not be able
    /// to read as "the last repair was in the future" and gate repair off.
    private static let minimumTimeBetweenRepairs = Duration.seconds(5)
    private static let maximumRepairsPerOutage = 3

    @State private var consecutiveMisses = 0
    @State private var repairsThisOutage = 0
    @State private var lastRepairAt: ContinuousClock.Instant?
    @State private var repairPending = false

    func body(content: Content) -> some View {
        content
            .task(id: isActive) {
                guard isActive else {
                    resetOutageState()
                    return
                }
                while !Task.isCancelled {
                    try? await Task.sleep(for: Self.checkInterval)
                    guard !Task.isCancelled else { return }
                    check()
                }
            }
    }

    @MainActor
    private func check() {
        if let focused = TVFocusSystemProbe.focusedItemTypeName() {
            recordRecoveryIfNeeded(focused: focused)
            resetOutageState()
            return
        }

        consecutiveMisses += 1
        guard consecutiveMisses >= Self.missesBeforeRepair else { return }
        guard repairsThisOutage < Self.maximumRepairsPerOutage else { return }
        let now = ContinuousClock.now
        if let lastRepairAt, now - lastRepairAt < Self.minimumTimeBetweenRepairs {
            return
        }

        repairsThisOutage += 1
        lastRepairAt = now
        repairPending = true
        DiagnosticsCoordinator.recordBreadcrumb(
            level: .warning,
            category: .focus,
            tag: "FocusRepair",
            message: "no focused item after \(consecutiveMisses) checks; repair attempt \(repairsThisOutage)",
            attrs: [
                "target": .string("focusSystem"),
                "action": .string("repair"),
            ]
        )
        TVFocusDiagnostics.value("request", "Watchdog", "repairAttempt", repairsThisOutage)
        onRepair(repairsThisOutage)
    }

    @MainActor
    private func recordRecoveryIfNeeded(focused: String) {
        guard consecutiveMisses >= Self.missesBeforeRepair else { return }
        // Distinguishing repaired from self-healing outages is the point of
        // this line: it tells a field report how often the wedge is real
        // versus a transient the engine would have resolved on its own.
        DiagnosticsCoordinator.recordBreadcrumb(
            category: .focus,
            tag: "FocusRepair",
            message: repairPending
                ? "focus restored after \(consecutiveMisses) checks"
                : "focus recovered unaided after \(consecutiveMisses) checks",
            attrs: [
                "target": .string(focused),
                "action": .string(repairPending ? "restoredAfterRepair" : "recoveredUnaided"),
            ]
        )
    }

    private func resetOutageState() {
        consecutiveMisses = 0
        repairsThisOutage = 0
        repairPending = false
    }
}

extension View {
    func tvFocusWatchdog(isActive: Bool, onRepair: @escaping (Int) -> Void) -> some View {
        modifier(TVFocusWatchdogModifier(isActive: isActive, onRepair: onRepair))
    }
}
#endif
