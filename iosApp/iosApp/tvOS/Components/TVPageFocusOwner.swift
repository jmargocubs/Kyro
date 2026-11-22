#if os(tvOS)
import SwiftUI

/// Makes an inert placeholder — an empty state, or a loading state with
/// nothing to focus yet — the focus owner for its page.
///
/// tvOS has no pointer and no Tab key, so a page that renders no focusable
/// view leaves the focus engine with nothing focused. The remote stops
/// responding, and Menu/Back never reaches the shell's `onExitCommand`
/// either, because exit commands travel up the *focused* responder chain.
/// The app then reads as hard-frozen with force quit as the only way out.
/// Any placeholder that can be a whole page's content therefore has to hold
/// focus itself.
///
/// This is the native focus graph model from `docs/tvos-focus.md`: one real,
/// visible focus target, seeded by the shell's content hand-down token. Up
/// reaches the top menu natively; there is no directional handler.
struct TVPageFocusOwner: ViewModifier {
    /// The shell's content focus hand-down token (`contentFocusRequest`).
    let focusRequest: Int
    /// True while the top menu owns focus. The placeholder must never pull
    /// focus out of the bar — a load finishing empty while the user is up in
    /// the menu is the common case.
    let isTopMenuFocused: Bool
    let accessibilityLabel: String

    @FocusState private var isFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .focusable(true)
            .focused($isFocused)
            .tvObserveFocus("Placeholder", value: isFocused)
            // The system halo would wrap the whole page. Draw the Kyro ring
            // instead so the user can always see where focus is: an invisible
            // focus target reads as a remote that stopped responding.
            .focusEffectDisabled()
            .overlay {
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .strokeBorder(TVKyroFocus.ring, lineWidth: TVKyroFocus.ringWidth)
                    .padding(8)
                    .opacity(isFocused ? 1 : 0)
                    .animation(reduceMotion ? nil : .easeOut(duration: TVKyroFocus.duration), value: isFocused)
                    .allowsHitTesting(false)
            }
            .accessibilityLabel(accessibilityLabel)
            // Runs on appear as well as on each new request, which is the
            // path that matters most: the usual way into this state is a load
            // finishing empty, which swaps the placeholder in without the
            // shell issuing a new hand-down.
            .task(id: focusRequest) {
                guard !isTopMenuFocused else { return }
                // Let the outgoing content's focus teardown commit first. A
                // claim made in the same transaction loses to the engine's own
                // repair from the resigning view.
                await Task.yield()
                // The menu can take focus during the yield.
                guard !Task.isCancelled, !isTopMenuFocused else { return }
                TVFocusDiagnostics.record("request", "Placeholder", "claimAfterYield")
                isFocused = true
            }
    }
}

/// Seeds an error page's existing primary button after the outgoing loading view unmounts.
/// The button remains the only focus owner; this modifier creates no extra focusable container.
struct TVErrorActionFocus: ViewModifier {
    let request: Int?
    let isTopMenuFocused: Bool
    @FocusState private var isFocused: Bool

    func body(content: Content) -> some View {
        content
            .focused($isFocused)
            .task(id: request) {
                guard request != nil, !isTopMenuFocused else { return }
                await Task.yield()
                guard !Task.isCancelled, !isTopMenuFocused else { return }
                isFocused = true
            }
    }
}

extension View {
    /// Make this placeholder its page's focus owner. See `TVPageFocusOwner`.
    func tvPageFocusOwner(
        focusRequest: Int,
        isTopMenuFocused: Bool,
        accessibilityLabel: String
    ) -> some View {
        modifier(
            TVPageFocusOwner(
                focusRequest: focusRequest,
                isTopMenuFocused: isTopMenuFocused,
                accessibilityLabel: accessibilityLabel
            )
        )
    }
}
#endif
