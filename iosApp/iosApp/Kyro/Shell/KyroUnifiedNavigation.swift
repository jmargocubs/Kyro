import SwiftUI
import UIKit

/// Kyro's unified Classic shell, currently gated for testing. The production
/// feature-flag behavior remains unchanged until rollout is approved.
///
/// Off by default. It is read once at launch from the
/// `kyro.unifiedNavigation.enabled` default (`-kyro.unifiedNavigation.enabled YES`
/// on the command line), so the Build 17 navigation stays the shipping one.
enum KyroUnifiedNavigation {
    static let defaultsKey = "kyro.unifiedNavigation.enabled"

#if KYRO_UNIFIED_NAV_FORCE_ON
    /// Dedicated iPhone validation builds force the shell on so a stale
    /// UserDefaults value cannot make the build appear to be the fallback.
    /// Production builds do not define this condition.
    @MainActor
    static let isActive: Bool = UIDevice.current.userInterfaceIdiom == .phone
#else
    @MainActor
    static let isActive: Bool = UserDefaults.standard.bool(forKey: defaultsKey)
        && UIDevice.current.userInterfaceIdiom == .phone
#endif

    /// Native iPhone tab bars display four ordinary items and place the fifth
    /// here. The four media roots remain in their original order.
    static let tabBarCapacity = 5

    static func liveTVIndex(itemCount: Int) -> Int {
        let count = max(itemCount, 0)
        return count + 1 <= tabBarCapacity ? count : tabBarCapacity - 2
    }

    /// Live TV can be shown as a tab only from the shell's root: a pushed
    /// screen or a presented one sits over every tab.
    static func canSelectLiveTVTab(pathIsEmpty: Bool, isPresentingOverShell: Bool) -> Bool {
        pathIsEmpty && !isPresentingOverShell
    }

    /// Picture in Picture asked for Live TV and none of its screens is up.
    /// From the shell root select the one global Live TV destination. Elsewhere
    /// present over the current screen and leave its stack untouched.
    @MainActor
    static func bringLiveTVForward(router: AppRouter, store: KyroGlobalNavigationStore? = nil,
                                   presentation: LiveTVPresentation? = nil) {
        let store = store ?? KyroGlobalNavigationStore.shared
        let presentation = presentation ?? LiveTVService.shared.presentation
        if canSelectLiveTVTab(pathIsEmpty: router.path.isEmpty,
                              isPresentingOverShell: router.presentedItemDetail != nil
                                  || router.presentedPlayer != nil) {
            store.selectedDestination = .liveTV
        } else {
            presentation.presentOverCurrentScreen()
        }
    }
}

#if DEBUG || KYRO_UNIFIED_NAV_TOGGLE
/// Device testing only: turns the unified navigation on or off for the next
/// launch. Compiled into Debug builds and into Release builds made with
/// `SWIFT_ACTIVE_COMPILATION_CONDITIONS='$(inherited) KYRO_UNIFIED_NAV_TOGGLE'`
/// on the command line; the project never sets it, so shipping builds have no
/// switch and keep the Build 17 navigation. Off unless the tester turns it on.
struct KyroUnifiedNavigationTestSection: View {
    @AppStorage(KyroUnifiedNavigation.defaultsKey) private var isEnabled = false

    var body: some View {
        Section {
            Toggle("Live TV as a Tab", isOn: $isEnabled)
                .accessibilityIdentifier("kyroUnifiedNavigationToggle")
            if isEnabled != KyroUnifiedNavigation.isActive && UIDevice.current.userInterfaceIdiom == .phone {
                Label("Close and reopen Kyro to apply.", systemImage: "arrow.clockwise")
                    .font(.footnote)
                    .foregroundStyle(KyroTheme.accentInk)
            }
        } header: {
            Text("Experimental")
        } footer: {
            Text("Test build only. Puts Live TV in the app's tab bar on iPhone. Takes effect the next time Kyro opens.")
        }
    }
}
#endif

/// SiloTabBar adapter for the fifth native slot. `isSelected` is derived from
/// the global enum; it does not store a competing Live TV boolean.
struct KyroShellTab {
    let title: String
    let systemImage: String
    let isSelected: Binding<Bool>
    let content: () -> AnyView

    @MainActor
    static func liveTV(store: KyroGlobalNavigationStore, service: LiveTVService) -> KyroShellTab {
        KyroShellTab(
            title: "Live TV",
            systemImage: "dot.radiowaves.left.and.right",
            isSelected: Binding(
                get: { store.selectedDestination == .liveTV },
                set: { if $0 { store.selectedDestination = .liveTV } }
            ),
            content: { AnyView(LiveTVView(service: service)) }
        )
    }
}

extension EnvironmentValues {
    @Entry var kyroShellTab: KyroShellTab? = nil
}

extension View {
    /// Around `MainTabView` on iPhone. Without the flag it changes nothing.
    @ViewBuilder
    func kyroUnifiedNavigation() -> some View {
        if KyroUnifiedNavigation.isActive {
            modifier(KyroUnifiedNavigationShell(service: .shared))
        } else {
            self
        }
    }
}

private struct KyroUnifiedNavigationShell: ViewModifier {
    @Bindable var service: LiveTVService

    func body(content: Content) -> some View {
        content
            .environment(\.kyroShellTab, .liveTV(store: .shared, service: service))
            .fullScreenCover(item: Binding(
                get: { service.presentation.channel(for: .shell) },
                set: { if $0 == nil { service.presentation.coverDismissed(from: .shell) } }
            )) { channel in
                LiveTVPlayerView(channel: channel, channels: service.channels, session: service.playerSession,
                                 service: service)
            }
    }
}
