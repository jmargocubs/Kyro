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

/// A focus update is useful to the top bar only when UIKit identifies the
/// actual source or destination as part of that bar. No heading is cached for
/// a later SwiftUI callback: notification and FocusState ordering is not a
/// platform contract.
enum TVBarFocusTransition: Equatable {
    case downFromBar
    case userArrival
    case otherDeparture
    case unrelated
}

struct TVBarFocusTransitionGate {
    private var lastConsumedSequence = 0

    mutating func consume(sequence: Int, sourceInBar: Bool, destinationInBar: Bool,
                          isDown: Bool, isDirectional: Bool) -> TVBarFocusTransition {
        guard sequence > lastConsumedSequence else { return .unrelated }
        lastConsumedSequence = sequence
        if sourceInBar && !destinationInBar {
            return isDown ? .downFromBar : .otherDeparture
        }
        if !sourceInBar && destinationInBar && isDirectional { return .userArrival }
        return .unrelated
    }
}

#if os(tvOS)
import SwiftUI
import UIKit

/// Reads and nudges the live focus engine for the app's key window.
/// SwiftUI's FocusState can stay non-nil after the engine drops focus.
enum TVFocusSystemProbe {
    @MainActor
    private static var keyWindow: UIWindow? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .filter { $0.activationState == .foregroundActive }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)
    }

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

    @MainActor
    static func requestFocusUpdate() {
        guard let window = keyWindow else { return }
        TVFocusDiagnostics.record("request", "Watchdog", "windowSetNeedsFocusUpdate")
        window.setNeedsFocusUpdate()
        window.updateFocusIfNeeded()
    }
}

@MainActor
enum TVFocusMovementTracker {
    private static var observer: NSObjectProtocol?
    private static weak var barRegion: UIView?
    private static var sequence = 0
    private static var gate = TVBarFocusTransitionGate()
    private static var onBarTransition: ((TVBarFocusTransition) -> Void)?
    private static var handlerOwner: UUID?

    static func setHandler(owner: UUID, _ handler: @escaping (TVBarFocusTransition) -> Void) {
        handlerOwner = owner
        onBarTransition = handler
    }

    static func removeHandler(owner: UUID) {
        guard handlerOwner == owner else { return }
        handlerOwner = nil
        onBarTransition = nil
    }

    static func setBarRegion(_ view: UIView?) { barRegion = view }
    static func removeBarRegion(_ view: UIView) {
        if barRegion === view { barRegion = nil }
    }

    private static func isInsideBar(_ view: UIView?) -> Bool {
        guard let view, let barRegion, let window = barRegion.window,
              view.window === window else { return false }
        let frame = view.convert(view.bounds, to: barRegion)
        return barRegion.bounds.contains(CGPoint(x: frame.midX, y: frame.midY))
    }

    static func install() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(
            forName: UIFocusSystem.didUpdateNotification, object: nil, queue: nil
        ) { note in
            guard Thread.isMainThread else { return }
            MainActor.assumeIsolated {
                guard let context = note.userInfo?[UIFocusSystem.focusUpdateContextUserInfoKey] as? UIFocusUpdateContext else { return }
                sequence += 1
                let heading = context.focusHeading
                let transition = gate.consume(
                    sequence: sequence,
                    sourceInBar: isInsideBar(context.previouslyFocusedView),
                    destinationInBar: isInsideBar(context.nextFocusedView),
                    isDown: heading.contains(.down),
                    isDirectional: !heading.intersection([.up, .down, .left, .right]).isEmpty
                )
                if transition != .unrelated { onBarTransition?(transition) }
            }
        }
    }
}

/// The marker measures the bar in its window without becoming a focus item or
/// intercepting a press. A focus item not represented by a UIView is unmatched.
private final class TVBarFocusRegionView: UIView {
    override var canBecomeFocused: Bool { false }
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil {
            TVFocusMovementTracker.removeBarRegion(self)
        } else {
            TVFocusMovementTracker.setBarRegion(self)
        }
    }
}

struct TVBarFocusRegion: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
        let view = TVBarFocusRegionView()
        view.isUserInteractionEnabled = false
        return view
    }
    func updateUIView(_ uiView: UIView, context: Context) {
        TVFocusMovementTracker.setBarRegion(uiView)
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
