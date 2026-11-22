import SwiftUI

/// Kyro's Home while no Silo session is signed in: zero providers, IPTV only, or a saved Silo
/// server that is signed out. Silo's Home rows belong to a signed-in Silo profile, so none are
/// requested here. The page offers the providers Kyro can use and, with IPTV, Live TV.
struct KyroHomeView: View {
    @Environment(AppRouter.self) private var router
    #if os(iOS)
    @Environment(\.kyroShellHeader) private var shellHeader
    #endif
    private let liveTV = LiveTVService.shared
    private let profileStore = CurrentProfileStore.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                #if os(iOS)
                if shellHeader == nil {
                    AppWordmarkView(placement: .compactHeader)
                        .frame(height: SiloTheme.topBarIconHitSize)
                }
                #endif
                VStack(alignment: .leading, spacing: 6) {
                    Text(greeting)
                        .font(.system(size: 30, weight: .heavy))
                        .foregroundStyle(Color.siloOnSurface)
                        .accessibilityAddTraits(.isHeader)
                    Text(KyroHomeCopy.lead(KyroProviderState(
                        isSiloConnected: false, iptvProviderCount: liveTV.providers.count)))
                        .font(.subheadline)
                        .foregroundStyle(Color.siloOnSurface.opacity(0.62))
                        .fixedSize(horizontal: false, vertical: true)
                }
                KyroAddSourcesPanel()
            }
            .frame(maxWidth: 640, alignment: .leading)
            .padding(.horizontal, SiloTheme.padding)
            .padding(.vertical, SiloTheme.padding)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        #if os(iOS)
        .safeAreaPadding(.top, shellHeader?.runway ?? 0)
        .reportsPageChromeScroll()
        .toolbar(.hidden, for: .navigationBar)
        #endif
        .siloPageBackground()
        .task { await profileStore.refresh() }
    }

    private var greeting: String {
        profileStore.profile.map { "Hi, \($0.name)" } ?? "Welcome to Kyro"
    }
}

enum KyroHomeCopy {
    static func lead(_ state: KyroProviderState) -> String {
        state.hasIPTV
            ? "Watch Live TV now, or connect a media server for your movies and shows."
            : "Connect a media server or an IPTV provider to start watching."
    }

    /// The media-server row: a saved Silo server that is signed out is offered for sign-in by
    /// name, so reconnecting never looks like starting over.
    static func mediaServerTitle(savedServerName: String?) -> String {
        savedServerName.map { "Sign in to \($0)" } ?? "Add Media Server"
    }

    static func mediaServerSubtitle(savedServerName: String?) -> String {
        savedServerName == nil ? "Connect your Silo server" : "Your Silo server is signed out"
    }
}

/// The providers Kyro can use, as actions: watch Live TV (with IPTV), connect a media server, and
/// add IPTV. Used by Kyro's Home and by Movies and Series when they have nothing to show.
struct KyroAddSourcesPanel: View {
    @Environment(AppRouter.self) private var router
    private let liveTV = LiveTVService.shared
    #if os(iOS)
    @State private var showIPTVSetup = false
    #endif

    var body: some View {
        VStack(spacing: 12) {
            #if os(iOS)
            if !liveTV.providers.isEmpty {
                row(title: "Watch Live TV",
                    subtitle: KyroLiveTVSettingsEntry.summary(providers: liveTV.providers,
                                                              selectedProviderID: liveTV.selectedProviderID),
                    symbol: "play.tv", id: "kyroHomeWatchLiveTV") {
                    KyroUnifiedNavigation.bringLiveTVForward(router: router)
                }
            }
            #endif
            let savedServer = AuthService.shared.isLoggedIn ? nil : ServerRegistry.shared.activeServer?.displayName
            row(title: KyroHomeCopy.mediaServerTitle(savedServerName: savedServer),
                subtitle: KyroHomeCopy.mediaServerSubtitle(savedServerName: savedServer),
                symbol: "server.rack", id: "kyroHomeAddMediaServer") {
                router.navigate(to: .serverList)
            }
            #if os(iOS)
            row(title: liveTV.providers.isEmpty ? "Add IPTV" : "Manage IPTV",
                subtitle: "Xtream Codes or an M3U playlist",
                symbol: "dot.radiowaves.left.and.right", id: "kyroHomeAddIPTV") {
                showIPTVSetup = true
            }
            #endif
        }
        #if os(iOS)
        .sheet(isPresented: $showIPTVSetup) {
            NavigationStack {
                LiveTVSettingsView(service: liveTV, presentation: .sheet)
            }
        }
        #endif
    }

    private func row(title: String, subtitle: String, symbol: String, id: String,
                     action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: symbol)
                    .font(.title3)
                    .frame(width: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).fontWeight(.semibold)
                    Text(subtitle)
                        .font(.footnote)
                        .foregroundStyle(Color.siloOnSurface.opacity(0.62))
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Color.siloOnSurface.opacity(0.5))
            }
            .multilineTextAlignment(.leading)
            .accessibilityElement(children: .combine)
        }
        .buttonStyle(.marquee(.glass))
        .accessibilityIdentifier(id)
    }
}
