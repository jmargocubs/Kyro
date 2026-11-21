#if os(tvOS)
import SwiftUI
import UIKit
import UIKit.UIGestureRecognizerSubclass
import CryptoKit

/// Calls compile to no-ops in ordinary Release builds. No focus setters live here.
/// Entry points are nonisolated so any call site compiles; events raised off the
/// main thread are dropped rather than reordered (all focus work is main-thread).
enum TVFocusDiagnostics {
    nonisolated static func record(_ kind: StaticString, _ component: StaticString, _ site: StaticString) {
        #if DEBUG || KYRO_FOCUS_DIAGNOSTICS
        guard Thread.isMainThread else { return }
        MainActor.assumeIsolated {
            TVRemoteFocusInspector.shared.record(String(describing: kind), String(describing: component), String(describing: site))
        }
        #endif
    }

    nonisolated static func value<T>(_ kind: StaticString, _ component: StaticString, _ site: StaticString, _ value: T) {
        #if DEBUG || KYRO_FOCUS_DIAGNOSTICS
        guard Thread.isMainThread else { return }
        MainActor.assumeIsolated {
            let inspector = TVRemoteFocusInspector.shared
            guard inspector.enabled else { return }
            inspector.record(String(describing: kind), String(describing: component),
                             "\(site):\(inspector.identifier(value))")
        }
        #endif
    }
}

extension TVFocusDiagnostics {
    /// Installs the focus-independent export gesture (hold Play/Pause) in
    /// diagnostic builds. Compiles to nothing in ordinary Release builds.
    @MainActor static func installExportGesture(router: AppRouter) {
        #if DEBUG || KYRO_FOCUS_DIAGNOSTICS
        TVDiagnosticExportGesture.shared.install(router: router)
        #endif
    }
}

extension View {
    @ViewBuilder func tvObserveFocus<T: Hashable>(_ component: StaticString, value: T) -> some View {
        #if DEBUG || KYRO_FOCUS_DIAGNOSTICS
        self.onAppear { TVFocusDiagnostics.record("lifecycle", component, "appear") }
            .onDisappear { TVFocusDiagnostics.record("lifecycle", component, "disappear") }
            .onChange(of: value, initial: true) { _, next in
                TVFocusDiagnostics.value("binding", component, "observed", next)
            }
        #else
        self
        #endif
    }
}

#if DEBUG || KYRO_FOCUS_DIAGNOSTICS
@MainActor
final class TVRemoteFocusInspector: ObservableObject {
    static let shared = TVRemoteFocusInspector()
    @Published private(set) var enabled = false
    @Published private(set) var overlayVisible = true
    /// Events held in memory for the current or most recently stopped capture.
    @Published private(set) var capturedEventCount = 0
    /// Event counts of the saved captures, read at launch and after each save.
    @Published private(set) var savedLatestEventCount = 0
    @Published private(set) var savedPreviousEventCount = 0
    private(set) var buffer = TVFocusDiagnosticBuffer()
    /// True once this process has recorded a capture. Until then, `latest`
    /// exports the copy saved by an earlier launch.
    private var hasSessionCapture = false
    private let store: TVFocusCaptureStore?
    private let persistQueue = DispatchQueue(label: "kyro.focus-diagnostics.persist", qos: .utility)
    private var lifecycleObservers: [NSObjectProtocol] = []
    private var salt = SymmetricKey(size: .bits256)
    private var observers: [NSObjectProtocol] = []
    private var inputs: [TVPassiveRemoteObserver] = []
    private var itemIDs = NSMapTable<AnyObject, NSString>.weakToStrongObjects()
    private var nextID = 0
    private var overlay: UIWindow?
    private var label: UILabel?
    private var timer: Timer?
    private var screen = "unknown"
    private var lastInput = "none observed"
    private var previous = "unknown"
    private var current = "unknown"
    private var binding = "unknown"
    private var request = "none observed"
    private var transition = "none"
    private var cause = "unknown"

    /// Saves every this-many events while recording, so a crash or a forced
    /// quit loses at most this many.
    static let persistInterval = 50

    init(store: TVFocusCaptureStore? = .standard()) {
        self.store = store
        savedLatestEventCount = store?.load(.latest)?.events.count ?? 0
        savedPreviousEventCount = store?.load(.previous)?.events.count ?? 0
        // Saving on resign-active covers the TV button, the app switcher and
        // sleep before the process can be suspended or killed.
        for name in [UIApplication.willResignActiveNotification, UIApplication.didEnterBackgroundNotification] {
            lifecycleObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if note.name == UIApplication.didEnterBackgroundNotification {
                        // Backgrounding stops recording (privacy) but keeps the
                        // capture in memory and on disk, still shareable.
                        self.setEnabled(false)
                    } else if self.enabled {
                        self.persist(synchronously: true)
                    }
                }
            })
        }
    }

    var hasExportableCapture: Bool { exportableEventCount(.latest) > 0 || savedPreviousEventCount > 0 }

    func exportableEventCount(_ slot: TVFocusCaptureSlot) -> Int {
        switch slot {
        case .latest: return hasSessionCapture ? capturedEventCount : savedLatestEventCount
        case .previous: return savedPreviousEventCount
        }
    }

    func setEnabled(_ active: Bool) {
        guard active != enabled else { return }
        if active {
            // Keep the capture this fresh start replaces. Without this, "Start
            // fresh capture" erased the only copy of an earlier failure.
            if hasSessionCapture, !buffer.events.isEmpty {
                writeArchive(state: .stopped, to: .previous, synchronously: true)
            } else {
                try? store?.rotateLatestToPrevious()
            }
            savedPreviousEventCount = store?.load(.previous)?.events.count ?? savedPreviousEventCount
            enabled = true
            hasSessionCapture = true
            buffer = TVFocusDiagnosticBuffer()
            capturedEventCount = 0
            salt = SymmetricKey(size: .bits256)
            itemIDs.removeAllObjects()
            nextID = 0
            screen = "unknown"; lastInput = "none observed"
            previous = "unknown"; current = "unknown"; binding = "unknown"
            request = "none observed"; transition = "none"; cause = "unknown"
            observe(UIFocusSystem.didUpdateNotification) { [weak self] in self?.focusChanged($0, failed: false) }
            observe(UIFocusSystem.movementDidFailNotification) { [weak self] in self?.focusChanged($0, failed: true) }
            observe(UIWindow.didBecomeKeyNotification) { [weak self] _ in self?.attachInput() }
            attachInput()
            showOverlay()
            timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.render() }
            }
            record("state", "inspector", "capture-start; identifiers stable only within this capture")
            persist(synchronously: true)
        } else {
            record("state", "inspector", "capture-stop")
            enabled = false
            observers.forEach(NotificationCenter.default.removeObserver)
            observers.removeAll()
            inputs.forEach { $0.view?.removeGestureRecognizer($0) }
            inputs.removeAll()
            timer?.invalidate(); timer = nil
            overlay?.isHidden = true; overlay = nil; label = nil
            // The buffer is kept: a stopped capture stays shareable, and is
            // saved so it also survives backgrounding and relaunch.
            persist(synchronously: true)
        }
    }

    func toggleOverlay() {
        guard enabled else { return }
        overlayVisible.toggle()
        overlay?.isHidden = !overlayVisible
    }

    func record(_ kind: String, _ component: String, _ detail: String) {
        guard enabled else { return }
        if kind == "binding" {
            binding = "\(component).\(detail)"
            if !detail.hasSuffix(":nil") && !detail.hasSuffix(":false") { screen = component }
        }
        if kind == "request" { request = "\(component).\(detail)" }
        if kind == "remote" { lastInput = detail }
        buffer.append(kind: kind, component: component, detail: detail)
        capturedEventCount = buffer.events.count
        if enabled, buffer.appendedCount % Self.persistInterval == 0 { persist(synchronously: false) }
    }

    /// Hash associated values with an unexported per-capture key. No titles, identifiers,
    /// descriptions or accessibility labels leave this method in plaintext.
    func identifier<T>(_ value: T) -> String {
        if let boolean = value as? Bool { return boolean ? "true" : "false" }
        let mirror = Mirror(reflecting: value)
        if mirror.displayStyle == .optional {
            guard let child = mirror.children.first else { return "nil" }
            return identifier(child.value)
        }
        let digest = HMAC<SHA256>.authenticationCode(for: Data(String(reflecting: value).utf8), using: salt)
        let token = digest.prefix(6).map { String(format: "%02x", $0) }.joined()
        var role = "item"
        if mirror.displayStyle == .enum {
            let candidate = mirror.children.first?.label ?? String(describing: value)
            if candidate.count <= 40 && candidate.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }) {
                role = candidate
            }
        }
        return "\(role)#\(token)"
    }

    /// The frozen report for one slot, or nil when that slot holds nothing.
    func report(_ slot: TVFocusCaptureSlot = .latest) throws -> Data? {
        switch slot {
        case .latest where hasSessionCapture:
            return try archive(state: enabled ? .recording : .stopped).encoded()
        case .latest, .previous:
            guard let saved = store?.load(slot), !saved.events.isEmpty else { return nil }
            return try saved.encoded()
        }
    }

    private func archive(state: TVFocusCaptureArchive.State) -> TVFocusCaptureArchive {
        TVFocusCaptureArchive(build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
                              state: state, savedAt: Date(), buffer: buffer)
    }

    private func persist(synchronously: Bool) {
        guard hasSessionCapture else { return }
        writeArchive(state: enabled ? .recording : .stopped, to: .latest, synchronously: synchronously)
        savedLatestEventCount = buffer.events.count
    }

    private func writeArchive(state: TVFocusCaptureArchive.State, to slot: TVFocusCaptureSlot, synchronously: Bool) {
        guard let store else { return }
        let snapshot = archive(state: state)
        let write: @Sendable () -> Void = { _ = try? store.save(snapshot.encoded(), to: slot) }
        if synchronously { persistQueue.sync(execute: write) } else { persistQueue.async(execute: write) }
    }

    private func observe(_ name: Notification.Name, action: @escaping @MainActor (Notification) -> Void) {
        observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { note in
            MainActor.assumeIsolated { action(note) }
        })
    }

    private func focusChanged(_ notification: Notification, failed: Bool) {
        guard let context = notification.userInfo?[UIFocusSystem.focusUpdateContextUserInfoKey] as? UIFocusUpdateContext else {
            record("engine", "UIKit", "notification without context")
            return
        }
        let from = itemID(context.previouslyFocusedItem)
        let to = itemID(context.nextFocusedItem)
        let heading = context.focusHeading.rawValue
        if failed {
            record("movementFailed", "UIKit", "from=\(from); heading=\(heading); fallback not established")
        } else {
            previous = from; current = to
            cause = buffer.association(at: ProcessInfo.processInfo.systemUptime)
            transition = ISO8601DateFormatter().string(from: Date())
            let frame = context.nextFocusedItem?.frame ?? .zero
            let geometry = [frame.minX, frame.minY, frame.width, frame.height]
                .map { String(format: "%.0f", Double($0)) }.joined(separator: ",")
            record("transition", "UIKit", "\(from) -> \(to); heading=\(heading); frameInContainer=\(geometry); \(cause)")
        }
    }

    private func itemID(_ item: UIFocusItem?) -> String {
        guard let item else { return "nil" }
        if let known = itemIDs.object(forKey: item) { return known as String }
        nextID += 1
        // Weak keys release departed views; also impose a hard bound.
        if itemIDs.count >= 2048 { itemIDs.removeAllObjects(); record("state", "inspector", "engine identity map reset") }
        let id = "engine#\(nextID)"
        itemIDs.setObject(id as NSString, forKey: item)
        return id
    }

    private func attachInput() {
        guard enabled else { return }
        let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
        for window in windows where window.isKeyWindow && !inputs.contains(where: { $0.view === window }) {
            let observer = TVPassiveRemoteObserver(target: nil, action: nil)
            observer.cancelsTouchesInView = false
            // UIKit documents these touch-named flags as covering presses too.
            // UIGestureRecognizer has no separate delaysPressesBegan property.
            observer.delaysTouchesBegan = false
            observer.delaysTouchesEnded = false
            window.addGestureRecognizer(observer)
            inputs.append(observer)
        }
    }

    private func showOverlay() {
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }) else { return }
        let window = TVInspectorWindow(windowScene: scene)
        window.windowLevel = .alert + 99
        window.isUserInteractionEnabled = false
        window.backgroundColor = .clear
        let controller = UIViewController()
        controller.view.backgroundColor = .clear
        let text = UILabel(frame: CGRect(x: 60, y: 620, width: 1080, height: 350))
        text.font = .monospacedSystemFont(ofSize: 20, weight: .medium)
        text.textColor = .white
        text.backgroundColor = UIColor.black.withAlphaComponent(0.8)
        text.numberOfLines = 0
        text.isAccessibilityElement = false
        controller.view.addSubview(text)
        window.rootViewController = controller
        window.isHidden = !overlayVisible // Never makeKeyAndVisible.
        overlay = window; label = text
        render()
    }

    private func render() {
        label?.text = " KYRO FOCUS DIAGNOSTICS — observation only\n Screen/component: \(screen)\n Remote observed: \(lastInput)\n Engine: \(previous) → \(current)\n Binding (separate observation): \(binding)\n Last request: \(request)\n Transition: \(transition)\n Association: \(cause)\n Events: \(buffer.events.count)/512; dropped: \(buffer.dropped)\n Share without navigating: hold Play/Pause 3 s (outside playback)"
    }
}

/// Focus-independent export. Holding Play/Pause for `holdDuration` outside
/// playback freezes the latest capture and starts the same authenticated,
/// two-minute, LAN-only share the inspector page uses. The QR code and code
/// appear in a window that can never take focus, so nothing has to be
/// navigated. It is an explicit gesture: nothing is shared automatically.
///
/// Conflict rules (Build 103 review):
/// - Outside playback, the recognizer *delays* Play/Pause delivery
///   (`delaysTouchesBegan/Ended`, which UIKit applies to presses too) until it
///   fails. A short press fails it on release and is then delivered, so a
///   card's `onPlayPauseCommand` still runs. A 3-second hold is recognized
///   instead, and `cancelsTouchesInView` cancels the press, so the views
///   never see it and the focused card does not activate.
/// - During playback it never receives the press at all
///   (`shouldReceive press:` returns false), so players, inline Live TV and
///   Picture in Picture get Play/Pause immediately with no added latency.
///   The same applies while any view controller is presented (covers,
///   sheets, the Guide).
/// Play/Pause is not a system-reserved press. Delivery order is a device
/// check: see the Build 103 acceptance list.
@MainActor
final class TVDiagnosticExportGesture: NSObject, UIGestureRecognizerDelegate {
    static let shared = TVDiagnosticExportGesture()
    static let holdDuration: TimeInterval = 3
    private var recognizers: [UILongPressGestureRecognizer] = []
    private var observer: NSObjectProtocol?
    private weak var router: AppRouter?

    func install(router: AppRouter) {
        self.router = router
        attach()
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(forName: UIWindow.didBecomeKeyNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.attach() }
        }
    }

    private func attach() {
        recognizers.removeAll { $0.view == nil }
        let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
        for window in windows where window.isKeyWindow && !recognizers.contains(where: { $0.view === window }) {
            let recognizer = UILongPressGestureRecognizer(target: self, action: #selector(handle(_:)))
            recognizer.allowedPressTypes = [NSNumber(value: UIPress.PressType.playPause.rawValue)]
            recognizer.allowedTouchTypes = []
            recognizer.minimumPressDuration = Self.holdDuration
            recognizer.cancelsTouchesInView = true
            recognizer.delaysTouchesBegan = true
            recognizer.delaysTouchesEnded = true
            recognizer.delegate = self
            window.addGestureRecognizer(recognizer)
            recognizers.append(recognizer)
        }
    }

    @objc private func handle(_ recognizer: UILongPressGestureRecognizer) {
        guard recognizer.state == .began else { return }
        TVFocusReportServer.shared.start(.latest, presentsOverlay: true)
    }

    nonisolated func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                                       shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }

    /// Not receiving the press is what keeps playback free of delay: a
    /// recognizer that declines here never delays or cancels it.
    nonisolated func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive press: UIPress) -> Bool {
        MainActor.assumeIsolated { isEligible(gestureRecognizer.view as? UIWindow) }
    }

    nonisolated func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        MainActor.assumeIsolated { isEligible(gestureRecognizer.view as? UIWindow) }
    }

    private func isEligible(_ window: UIWindow?) -> Bool {
        guard let window else { return false }
        let routeHasPlayer = router?.visiblePushedRoutes.last.map { route in
            switch route {
            case .player, .playerWithFile: return true
            default: return false
            }
        } ?? false
        return tvDiagnosticExportHoldIsEligible(
            presentsController: Self.presentsController(window.rootViewController),
            liveTVPlaybackActive: LiveTVService.shared.presentation.phase != .idle,
            videoPlayerMounted: routeHasPlayer || router?.presentedPlayer != nil
                || TVPlayerPresence.isActive || Self.videoPlayerIsMounted(in: window)
        )
    }

    /// Secondary check only. The player's controls attach this recognizer,
    /// but they are not mounted while the player loads or hold-seeks, so the
    /// primary signal is `TVPlayerPresence`, which spans the whole lifecycle.
    private static func videoPlayerIsMounted(in window: UIWindow) -> Bool {
        window.gestureRecognizers?.contains { $0 is TouchSurfaceContactGestureRecognizer } ?? false
    }

    /// Any presented controller anywhere under the root, not only the root's:
    /// SwiftUI can present a cover from a nested hosting controller.
    private static func presentsController(_ controller: UIViewController?, depth: Int = 0) -> Bool {
        guard let controller, depth < 12 else { return false }
        if controller.presentedViewController != nil { return true }
        return controller.children.contains { presentsController($0, depth: depth + 1) }
    }
}

/// The hold is offered only with no presented controller, no Live TV playback
/// (presented, inline, restoring or Picture in Picture) and no video player
/// mounted (including the pushed `.player` route, which is not presented).
func tvDiagnosticExportHoldIsEligible(presentsController: Bool, liveTVPlaybackActive: Bool,
                                      videoPlayerMounted: Bool) -> Bool {
    !presentsController && !liveTVPlaybackActive && !videoPlayerMounted
}

private final class TVInspectorWindow: UIWindow {
    override var canBecomeFocused: Bool { false }
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? { nil }
}

/// Never recognizes, delays, cancels, prevents, or requires another recognizer to fail.
/// Raw presses may not include touch-surface swipes or system-reserved actions.
private final class TVPassiveRemoteObserver: UIGestureRecognizer {
    override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool { false }
    override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool { false }
    override func shouldRequireFailure(of otherGestureRecognizer: UIGestureRecognizer) -> Bool { false }
    override func shouldBeRequiredToFail(by otherGestureRecognizer: UIGestureRecognizer) -> Bool { false }
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent) {
        for press in presses {
            let action: String
            switch press.type {
            case .upArrow: action = "up"
            case .downArrow: action = "down"
            case .leftArrow: action = "left"
            case .rightArrow: action = "right"
            case .select: action = "select"
            case .menu: action = "back/menu"
            case .playPause: action = "play/pause"
            default: action = "other press"
            }
            TVRemoteFocusInspector.shared.record("remote", "window", action)
        }
        state = .failed
    }
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) { state = .failed }
}
#endif
#endif
