import Foundation

/// Which content providers this device has connected. Kyro profiles are separate: a profile
/// exists with zero providers, and adding, switching or removing a provider never touches it.
///
/// - Silo is connected only with a signed-in session. A saved but signed-out server is a
///   provider to reconnect, not a connection: nothing may send Silo requests for it.
/// - IPTV providers (M3U and Xtream Codes) are stored on the device by `LiveTVService`,
///   with their credentials in the Keychain, independent of Silo.
struct KyroProviderState: Equatable {
    var isSiloConnected: Bool
    var iptvProviderCount: Int

    var hasIPTV: Bool { iptvProviderCount > 0 }
    var hasAnyProvider: Bool { isSiloConnected || hasIPTV }

    /// What the Home tab shows. Silo's Home rows are fetched from the Silo server for the
    /// signed-in Silo profile, so they need a Silo session; everything else is Kyro's own Home.
    enum HomeContent: Equatable { case silo, kyro }
    var homeContent: HomeContent { isSiloConnected ? .silo : .kyro }

    /// Whether a page may load Silo libraries. Without a session the request has no owner and
    /// the owner fence rejects it ("The active server or profile changed"), so it is not sent.
    var loadsSiloLibraries: Bool { isSiloConnected }

    @MainActor
    static var current: KyroProviderState {
        KyroProviderState(
            isSiloConnected: AuthService.shared.isLoggedIn,
            iptvProviderCount: LiveTVService.shared.providers.count
        )
    }
}

/// Kyro's first-run setup: create a Kyro profile, then optionally connect a provider.
enum KyroFirstRunSetup {
    enum Step: Equatable { case createProfile, chooseSource }

    enum Source: String, Equatable, CaseIterable, Identifiable {
        case mediaServer
        case iptv
        var id: String { rawValue }
    }

    static let maximumNameLength = 30

    /// Setup runs when Kyro owns the profile list (no Silo session) and it is empty. Anyone with a
    /// saved Kyro profile goes straight to Who's Watching; a signed-in Silo account keeps Silo's.
    static func needsSetup(isSiloSignedIn: Bool, localProfileCount: Int) -> Bool {
        !isSiloSignedIn && localProfileCount == 0
    }

    /// IPTV is set up and watched in Live TV, which exists on iPhone. Apple TV in this build has
    /// no Live TV, so it offers only a media server rather than a button that leads nowhere.
    static func sources(supportsLiveTV: Bool) -> [Source] {
        supportsLiveTV ? [.mediaServer, .iptv] : [.mediaServer]
    }

    static var platformSources: [Source] {
        #if os(iOS)
        sources(supportsLiveTV: true)
        #else
        sources(supportsLiveTV: false)
        #endif
    }

    /// A trimmed name of 1…30 characters, or nil.
    static func validatedName(_ raw: String) -> String? {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= maximumNameLength else { return nil }
        return name
    }

    /// After saving an IPTV provider, enter Kyro on Live TV. Closing the form without saving
    /// stays on the source choice.
    static func entersLiveTV(providerCountBefore: Int, providerCountAfter: Int) -> Bool {
        providerCountAfter > providerCountBefore
    }
}
