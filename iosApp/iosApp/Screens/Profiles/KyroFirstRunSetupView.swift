import SwiftUI

/// Kyro's first-run setup, shown in place of Who's Watching while Kyro owns the profile list and
/// it is empty. It creates a Kyro profile on the device with the existing profile form, then
/// offers the providers: a media server through Silo's existing setup, or IPTV through Live TV's
/// existing Xtream Codes / M3U form. Every provider is optional; "Not now" enters Kyro with none.
struct KyroFirstRunSetupView: View {
    let router: AppRouter
    /// Who's Watching reloads its list once the profile exists.
    let onProfileCreated: () async -> Void
    /// Setup is over (a provider flow took over, or Kyro was entered).
    let onFinish: () -> Void

    @State private var step: KyroFirstRunSetup.Step = .createProfile
    @State private var profile: UserProfile?
    @State private var showCreateProfile = false
    @State private var errorText: String?
    #if os(iOS)
    @State private var showIPTVSetup = false
    @State private var iptvProviderCountBefore = 0
    #endif

    var body: some View {
        stage
        #if os(tvOS)
        .fullScreenCover(isPresented: $showCreateProfile) { createProfileForm }
        #else
        .sheet(isPresented: $showCreateProfile) {
            createProfileForm.presentationDetents([.large])
        }
        .sheet(isPresented: $showIPTVSetup, onDismiss: iptvSetupClosed) {
            NavigationStack {
                LiveTVSettingsView(service: .shared, presentation: .sheet)
            }
        }
        #endif
    }

    private var steps: some View {
        VStack(spacing: 28) {
            switch step {
            case .createProfile: welcome
            case .chooseSource: chooseSource
            }
            if let errorText {
                MarqueeErrorText(errorText)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: step)
    }

    @ViewBuilder
    private var stage: some View {
        #if os(tvOS)
        // Who's Watching's own tvOS layout: a centered column over its scrim.
        VStack(spacing: 60) {
            AppWordmarkView(placement: .topBar)
            steps.frame(maxWidth: 820)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .focusSection()
        #else
        MarqueeStage(avoidsKeyboard: false) {
            AppWordmarkView(placement: .topBar)
                .frame(maxWidth: .infinity)
        } content: {
            steps
        }
        #endif
    }

    // MARK: Steps

    private var welcome: some View {
        VStack(spacing: 28) {
            MarqueeHeadline(
                title: "Welcome to Kyro",
                lead: "Create your profile to get started. It stays on this device, whatever servers or IPTV providers you connect.",
                alignment: .center
            )
            Button {
                errorText = nil
                showCreateProfile = true
            } label: {
                Label("Create Profile", systemImage: "person.crop.circle.badge.plus")
            }
            .buttonStyle(.marquee(.primary))
            .accessibilityIdentifier("kyroSetupCreateProfile")
        }
    }

    private var chooseSource: some View {
        VStack(spacing: 18) {
            MarqueeHeadline(
                title: "Add your media",
                lead: "Connect a media server or an IPTV provider. You can add more, or change them, later in Settings.",
                alignment: .center
            )
            .padding(.bottom, 10)
            ForEach(KyroFirstRunSetup.platformSources) { source in
                Button { choose(source) } label: { sourceLabel(source) }
                    .buttonStyle(.marquee(.glass))
                    .accessibilityIdentifier("kyroSetupSource-\(source.rawValue)")
            }
            Button("Not now") { enterKyro() }
                .buttonStyle(.marquee(.plain, fullWidth: false, compact: true))
                .padding(.top, 6)
                .accessibilityIdentifier("kyroSetupNotNow")
        }
    }

    private func sourceLabel(_ source: KyroFirstRunSetup.Source) -> some View {
        let (title, subtitle, symbol) = switch source {
        case .mediaServer: ("Add Media Server", "Connect your Silo server", "server.rack")
        case .iptv: ("Add IPTV", "Xtream Codes or an M3U playlist", "dot.radiowaves.left.and.right")
        }
        return HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.title3)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).fontWeight(.semibold)
                Text(subtitle)
                    .font(.footnote)
                    .foregroundStyle(Color.siloOnSurface.opacity(0.62))
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Color.siloOnSurface.opacity(0.5))
        }
        .accessibilityElement(children: .combine)
    }

    private var createProfileForm: some View {
        CreateProfileView {
            showCreateProfile = false
            Task { await profileCreated() }
        }
    }

    // MARK: Actions

    private func profileCreated() async {
        do {
            // A household in first-run setup has exactly the profile just made.
            guard let created = try await KyroLocalIdentityRuntime.shared.profiles().first else { return }
            KyroLocalIdentityRuntime.shared.activateNewProfile(created)
            profile = created
            await onProfileCreated()
            step = .chooseSource
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func choose(_ source: KyroFirstRunSetup.Source) {
        switch source {
        case .mediaServer:
            // Silo's own setup and sign-in. Its Back returns to Who's Watching, which now lists
            // this profile; signing in continues to the Silo account's profiles as before.
            onFinish()
            router.resetToServerSetup()
        case .iptv:
            #if os(iOS)
            iptvProviderCountBefore = LiveTVService.shared.providers.count
            showIPTVSetup = true
            #endif
        }
    }

    #if os(iOS)
    private func iptvSetupClosed() {
        guard KyroFirstRunSetup.entersLiveTV(
            providerCountBefore: iptvProviderCountBefore,
            providerCountAfter: LiveTVService.shared.providers.count
        ) else { return }
        enterKyro()
        KyroGlobalNavigationStore.shared.selectedDestination = .liveTV
    }
    #endif

    private func enterKyro() {
        onFinish()
        CurrentProfileStore.shared.reset()
        router.resetToHome()
    }
}
