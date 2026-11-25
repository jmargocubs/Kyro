import SwiftUI

// Kyro keeps its accepted Apple TV top menu and focus architecture
// (TVMainTabView, TVTopMenuBar, TVCascadeSelector, TVPageFocusOwner). Upstream
// Silo's merged router and library pages reference two types from upstream's
// replacement shell; they are declared here so those files compile unchanged.
// See docs/kyro-upstream-integration.md (navigation batch).

/// Upstream: the shell page Switch Profile returns to on Back. Kyro's shell does
/// not record one yet, so `AppRouter.tvShellPlace` stays nil and Back from Switch
/// Profile keeps Kyro's existing behavior.
struct TVShellPlace: Equatable {
    let root: TVRootDestination
    let pillSelections: [TVLibraryTabType: TVLibraryPill]
}

/// Upstream: true while a page shows a panel that owns focus (library Sort).
/// Kyro's top bar does not read it; Kyro's own focus owner handles the panel.
struct TVPagePanelOpenKey: PreferenceKey {
    static let defaultValue = false

    static func reduce(value: inout Bool, nextValue: () -> Bool) {
        value = value || nextValue()
    }
}
