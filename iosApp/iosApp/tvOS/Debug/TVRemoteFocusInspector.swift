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
    private(set) var buffer = TVFocusDiagnosticBuffer()
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

    func setEnabled(_ active: Bool) {
        guard active != enabled else { return }
        enabled = active
        if active {
            buffer = TVFocusDiagnosticBuffer()
            salt = SymmetricKey(size: .bits256)
            itemIDs.removeAllObjects()
            nextID = 0
            screen = "unknown"; lastInput = "none observed"
            previous = "unknown"; current = "unknown"; binding = "unknown"
            request = "none observed"; transition = "none"; cause = "unknown"
            observe(UIFocusSystem.didUpdateNotification) { [weak self] in self?.focusChanged($0, failed: false) }
            observe(UIFocusSystem.movementDidFailNotification) { [weak self] in self?.focusChanged($0, failed: true) }
            observe(UIWindow.didBecomeKeyNotification) { [weak self] _ in self?.attachInput() }
            observe(UIApplication.didEnterBackgroundNotification) { [weak self] _ in self?.setEnabled(false) }
            attachInput()
            showOverlay()
            timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.render() }
            }
            record("state", "inspector", "capture-start; identifiers stable only within this capture")
        } else {
            observers.forEach(NotificationCenter.default.removeObserver)
            observers.removeAll()
            inputs.forEach { $0.view?.removeGestureRecognizer($0) }
            inputs.removeAll()
            timer?.invalidate(); timer = nil
            overlay?.isHidden = true; overlay = nil; label = nil
            TVFocusReportServer.shared.stop()
        }
    }

    func toggleOverlay() {
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

    func report() throws -> Data {
        struct Report: Encodable {
            let schema = 1
            let build: String
            let limitations = "Temporal associations are inferred, not causation. Focus heading is not raw remote input. Binding observations are not engine confirmation. Failed movement is not proof of fallback. Capture excludes events while disabled/backgrounded. No media text or network credentials collected."
            let dropped: Int
            let events: [TVFocusDiagnosticBuffer.Event]
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(Report(build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
                                         dropped: buffer.dropped, events: buffer.events))
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
        label?.text = " KYRO FOCUS DIAGNOSTICS — observation only\n Screen/component: \(screen)\n Remote observed: \(lastInput)\n Engine: \(previous) → \(current)\n Binding (separate observation): \(binding)\n Last request: \(request)\n Transition: \(transition)\n Association: \(cause)\n Events: \(buffer.events.count)/512; dropped: \(buffer.dropped)"
    }
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
