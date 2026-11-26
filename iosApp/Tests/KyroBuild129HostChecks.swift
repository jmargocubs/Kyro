#if KYRO_STANDALONE_TESTS
import AppKit
import Foundation
import SwiftUI

struct EPGProgram {
    let id = ""
    let channelID = ""
    let title = ""
    let start = Date()
    let end = Date()
    let summary: String? = nil
}

enum KyroPerformanceDiagnostics {
    static func playbackBuffering(_ isBuffering: Bool) {}
}

final class LiveTVStartupTrace {
    enum Outcome { case incomplete }
    let id = UUID()
    func record(_ event: String, detail: String? = nil) {}
    func finish(_ outcome: Outcome) {}
}

final class AetherLiveTVEngine {
    func prepareRuntimeDiagnostics(sessionID: UUID, generation: Int, route: LiveTVStreamRoute) {}
}

private final class DummyRadioOwner {}

@MainActor
private final class IdleLiveTVScheduler: LiveTVScheduling {
    var now: Double { 0 }
    func schedule(after seconds: Double, _ action: @escaping @MainActor @Sendable () -> Void) -> LiveTVTimerHandle {
        LiveTVTimerHandle {}
    }
}

@MainActor
private final class RecordingLiveTVOutput: LiveTVPlaybackOutput {
    var pauses = 0
    func load(_ url: URL, generation: Int) {}
    func pause() { pauses += 1 }
    func resume() {}
    func clear(final: Bool) {}
    func recoverLiveSource(_ url: URL, generation: Int) -> Bool { true }
}

private struct MoreMenuEnvKey: EnvironmentKey {
    static let defaultValue: [String]? = nil
}

private extension EnvironmentValues {
    var testMoreMenu: [String]? {
        get { self[MoreMenuEnvKey.self] }
        set { self[MoreMenuEnvKey.self] = newValue }
    }
}

private struct MoreMenuProbe: View {
    @Environment(\.testMoreMenu) private var items
    let onRead: ([String]?) -> Void

    var body: some View {
        let _ = onRead(items)
        Color.clear
    }
}

@main @MainActor
enum KyroBuild129HostChecks {
    static var count = 0
    static func check(_ condition: Bool, _ title: String) {
        precondition(condition, title)
        count += 1
    }

    static func main() throws {
        moreMenuOverlayPropagation()
        fourthTabRadioAndPersistence()
        radioRouteAndHomeNavigationPolicies()
        liveTVPiPResumeYieldsRadio()
        try sourceContracts()
        print("Build 129: \(count) navigation, reachability and PiP checks passed.")
    }

    /// Confirms the SwiftUI rule that caused Build 128's regression: `.environment`
    /// applied before `.overlay` does NOT reach the overlay, whereas `.environment`
    /// applied outside `.overlay` reaches both the wrapped content and the overlay.
    static func moreMenuOverlayPropagation() {
        var beforeOverlayValue: [String]? = ["sentinel"]
        var afterOverlayValue: [String]?
        var innerValue: [String]?

        let view = MoreMenuProbe(onRead: { innerValue = $0 })
            .overlay(alignment: .top) {
                MoreMenuProbe(onRead: { afterOverlayValue = $0 })
            }
            .environment(\.testMoreMenu, ["Calendar", "Radio"])
            .overlay(alignment: .bottom) {
                MoreMenuProbe(onRead: { beforeOverlayValue = $0 })
            }

        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: 320, height: 200)
        host.layoutSubtreeIfNeeded()

        check(innerValue == ["Calendar", "Radio"], "wrapped shell content reads More menu environment")
        check(afterOverlayValue == ["Calendar", "Radio"], "overlay inside .environment reads More menu")
        check(beforeOverlayValue == nil, "overlay outside .environment reads nil (regression explanation)")
    }

    static func fourthTabRadioAndPersistence() {
        let suite = "kyro.build129.nav.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        check(KyroFourthTab.default == .sports, "Sports remains the default fourth tab")
        check(KyroFourthTab.allCases == [.sports, .forYou, .favorites, .radio],
              "fourth tab options include Sports, For You, Favorites and Radio")

        let fiveTabs = KyroGlobalDestination.tabDestinations(fourthTab: .radio)
        check(fiveTabs == [.home, .movies, .series, .radio, .liveTV] && fiveTabs.count == 5,
              "five-tab layout preserved when Radio is the fourth tab")

        let store = KyroGlobalNavigationStore(defaults: defaults)
        check(store.preferences.fourthTab == .sports, "fresh store defaults to Sports")
        check(!store.selectIfTab(.radio), "cannot select Radio tab while Sports is the fourth tab")

        store.preferences.fourthTab = .radio
        check(store.selectIfTab(.radio) && store.selectedDestination == .radio,
              "selecting Radio as fourth tab makes it selectable")

        let reloaded = KyroGlobalNavigationStore(defaults: defaults)
        check(reloaded.preferences.fourthTab == .radio, "fourthTab = .radio persists in UserDefaults")
        check(reloaded.tabDestinations == [.home, .movies, .series, .radio, .liveTV],
              "reloaded store keeps five tabs with Radio")

        // Switching away from Radio while on Radio keeps selection on the new 4th tab.
        reloaded.selectIfTab(.radio)
        reloaded.preferences.fourthTab = .sports
        check(reloaded.selectedDestination == .sports, "switching fourth tab updates hidden selection safely")

        // Existing primary destinations stay intact.
        for choice in KyroFourthTab.allCases {
            let tabs = KyroGlobalDestination.tabDestinations(fourthTab: choice)
            check(tabs.count == 5 && tabs[0] == .home && tabs[1] == .movies && tabs[2] == .series && tabs[4] == .liveTV,
                  "five-tab frame intact for \(choice.rawValue)")
        }
    }

    static func radioRouteAndHomeNavigationPolicies() {
        let defaultTabs = KyroGlobalDestination.tabDestinations(fourthTab: .sports)
        let radioTabs = KyroGlobalDestination.tabDestinations(fourthTab: .radio)

        // More menu visibility for Radio.
        check(KyroRadioNavigationPolicy.moreMenuIncludesRadio(unifiedShell: true, tabDestinations: defaultTabs),
              "More includes Radio when Sports is the fourth tab")
        check(!KyroRadioNavigationPolicy.moreMenuIncludesRadio(unifiedShell: true, tabDestinations: radioTabs),
              "More omits Radio when Radio is already the fourth tab")
        check(!KyroRadioNavigationPolicy.moreMenuIncludesRadio(unifiedShell: false, tabDestinations: defaultTabs),
              "legacy/iPad shell uses profile/sidebar entries rather than unified More menu")

        // Profile menu visibility for iPad and legacy iPhone shell.
        check(!KyroRadioNavigationPolicy.profileMenuOffersRadio(unifiedShell: true),
              "unified iPhone profile menu does not duplicate More/tab Radio")
        check(KyroRadioNavigationPolicy.profileMenuOffersRadio(unifiedShell: false),
              "iPad and legacy iPhone profile menu expose Radio")

        // Home Radio shelf header & entry-point routing.
        check(KyroRadioNavigationPolicy.openTarget(unifiedShell: true, tabDestinations: radioTabs) == .tab,
              "Home shelf header selects Radio tab when Radio is the fourth tab")
        check(KyroRadioNavigationPolicy.openTarget(unifiedShell: true, tabDestinations: defaultTabs) == .secondaryRoute,
              "Home shelf header pushes secondary Radio route when Sports is the fourth tab")
        check(KyroRadioNavigationPolicy.openTarget(unifiedShell: false, tabDestinations: radioTabs) == .secondaryRoute,
              "iPad and legacy shell push secondary Radio route")
    }

    static func liveTVPiPResumeYieldsRadio() {
        let exclusivity = KyroPlaybackExclusivity.shared
        let radioOwner = DummyRadioOwner()
        var radioYields = 0
        exclusivity.register(radioOwner, source: .radio) { radioYields += 1 }
        defer { exclusivity.unregister(radioOwner) }

        var isInPiP = true
        let output = RecordingLiveTVOutput()
        let controller = LiveTVPlaybackController(scheduler: IdleLiveTVScheduler())
        controller.output = output
        controller.isTransportInPictureInPicture = { isInPiP }
        let url = URL(string: "https://tv.example/live.m3u8")!

        controller.play(channelID: "ch1", url: url)
        check(radioYields == 1, "starting Live TV yields active radio")
        controller.phaseChanged(.playing, generation: controller.generation)
        controller.togglePlayback()
        check(controller.state == .paused, "Live TV pauses")

        // Start Radio while Live TV PiP is paused, then resume Live TV directly via AVKit PiP Play.
        exclusivity.begin(radioOwner, source: .radio)
        controller.phaseChanged(.playing, generation: controller.generation)
        check(controller.state == .playing, "PiP Play transitions paused Live TV back to playing")
        check(radioYields == 2, "resuming Live TV from PiP invokes playback exclusivity and yields radio")

        // Outside PiP without system resume permission, automatic engine `.playing` is rejected and does NOT yield radio.
        controller.togglePlayback()
        isInPiP = false
        controller.phaseChanged(.playing, generation: controller.generation)
        check(controller.state == .paused && output.pauses == 3, "viewer pause stands outside PiP")
        check(radioYields == 2, "rejected engine resume never yields radio")

        // System interruption resume also yields radio.
        controller.togglePlayback() // -> playing
        check(radioYields == 3, "manual resume yields radio")
        controller.pauseForSystemInterruption(canResumeAutomatically: true)
        controller.resumeAfterSystemInterruption()
        check(radioYields == 4, "system interruption resume yields radio")
    }

    static func sourceContracts() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        func source(_ path: String) throws -> String {
            try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
        }

        let content = try source("iosApp/iosApp/ContentView.swift")
        let headerOverlayRange = content.range(of: "KyroAppHeader(router: router, scrollStates: kyroShellScrollStates, store: kyroNavigation)")!.lowerBound
        let statusOverlayRange = content.range(of: "statusColumnBar(statusColumn)")!.lowerBound
        let moreEnvRange = content.range(of: ".environment(\\.kyroMoreMenu, moreMenuContext)")!.lowerBound
        check(moreEnvRange > headerOverlayRange && moreEnvRange > statusOverlayRange,
              "ContentView places .environment(\\.kyroMoreMenu, moreMenuContext) outside KyroAppHeader and statusColumnBar overlays")
        check(content.contains("if !kyroNavigation.tabDestinations.contains(.radio)"),
              "More menu checks whether Radio is already the fourth tab")
        check(content.contains("kyroSidebarRadio"),
              "iPad sidebar exposes Radio")
        check(content.contains("KyroRadioView(isSecondaryDestination: true)"),
              "secondary Radio route pushes KyroRadioView with isSecondaryDestination")

        let debugShell = try source("iosApp/iosApp/Kyro/KyroDebugLiveTVFixtureRoute.swift")
        let debugOverlay = debugShell.range(of: "KyroAppHeader(router: router, scrollStates: scrollStates, store: store)")!.lowerBound
        let debugMoreEnv = debugShell.range(of: ".environment(\\.kyroMoreMenu, moreMenu)")!.lowerBound
        check(debugMoreEnv > debugOverlay,
              "debug unified shell places .environment(\\.kyroMoreMenu, moreMenu) outside KyroAppHeader overlay")

        let radioViews = try source("iosApp/iosApp/Kyro/Radio/KyroRadioViews.swift")
        check(radioViews.contains("KyroRadioEntry.open(router: router)") && radioViews.contains("kyroHomeRadioHeader-"),
              "Radio Home shelf headers open Radio via KyroRadioEntry")
        check(radioViews.contains("var isHostedTab: Bool") && radioViews.contains("KyroRadioSettingsForm"),
              "KyroRadioView adapts to fourth-tab hosting and shares KyroRadioSettingsForm")

        let settings = try source("iosApp/iosApp/Screens/Settings/IOSSettingsOverview.swift")
        check(settings.contains("KyroRadioSettingsRow()"), "Settings overview includes Radio Settings row")

        let topBar = try source("iosApp/iosApp/Components/TabTopBarActions.swift")
        check(topBar.contains("KyroRadioEntry.profileMenuOffersRadio") && topBar.contains("KyroRadioEntry.open(router: router)"),
              "Profile menu offers Radio on iPad and legacy shell")

        let project = try source("iosApp/project.yml")
        check(project.components(separatedBy: "CURRENT_PROJECT_VERSION: 132").count == 4, "app and extensions target Build 132")
        check(project.components(separatedBy: "MARKETING_VERSION: \"1.0.132\"").count == 4, "version 1.0.132")
    }
}
#endif
