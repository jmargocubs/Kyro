import SwiftUI

// Sports Hub, Phase S1: the tab and its page shell only. No sports data is fetched. Each future
// module (live scores, schedules, followed teams, IPTV game matching) is one `KyroSportsHubModule`
// case; S2 replaces a module's placeholder card with its real content without changing the page.

/// The modules the Sports Hub will hold, in page order.
enum KyroSportsHubModule: String, CaseIterable, Identifiable {
    case liveNow
    case upcoming
    case followedTeams
    case watchOnLiveTV

    var id: String { rawValue }

    var title: String {
        switch self {
        case .liveNow: "Live Now"
        case .upcoming: "Upcoming"
        case .followedTeams: "Your Teams"
        case .watchOnLiveTV: "Watch on Live TV"
        }
    }

    var summary: String {
        switch self {
        case .liveNow: "Scores from games in progress, updated as they happen."
        case .upcoming: "Schedules for the leagues and competitions you care about."
        case .followedTeams: "Follow teams to see their results and next games first."
        case .watchOnLiveTV: "Jump from a game to the Live TV channel showing it."
        }
    }

    var systemImage: String {
        switch self {
        case .liveNow: "dot.radiowaves.left.and.right"
        case .upcoming: "calendar"
        case .followedTeams: "star"
        case .watchOnLiveTV: "play.tv"
        }
    }
}

/// A Kyro-only fourth-tab root, shown inside the unified shell's tab bar.
struct KyroRootPageView: View {
    let page: KyroRootPage

    var body: some View {
        switch page {
        case .sports:
            KyroSportsHubView()
        case .favorites:
            KyroTabRootContainer(title: "Favorites") {
                FavoritesView(showsNavigationTitle: false)
            }
        }
    }
}

/// Hosts a page that normally lives in a navigation stack (it titles itself with the navigation
/// bar) as a tab root: it leaves the shell header's runway, adds the page title, and hides the bar.
private struct KyroTabRootContainer<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    @Environment(\.kyroShellHeader) private var shellHeader

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.largeTitle.bold())
                .foregroundStyle(KyroTheme.textPrimary)
                .padding(.horizontal, SiloTheme.padding)
                .padding(.top, SiloTheme.smallPadding)
                .padding(.bottom, SiloTheme.smallPadding)
                .accessibilityAddTraits(.isHeader)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            Color.clear.frame(height: shellHeader?.runway ?? 0)
        }
        .siloPageBackground()
        .toolbar(.hidden, for: .navigationBar)
    }
}

/// The Sports tab. A placeholder for S1: a hero and one card per future module.
struct KyroSportsHubView: View {
    @Environment(\.kyroShellHeader) private var shellHeader
    @State private var fallbackScrollState = PageChromeScrollState()

    private var scrollState: PageChromeScrollState {
        shellHeader?.scrollState(for: .sports) ?? fallbackScrollState
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(alignment: .leading, spacing: SiloTheme.padding) {
                KyroSportsHero()
                VStack(spacing: 12) {
                    ForEach(KyroSportsHubModule.allCases) { module in
                        KyroSportsModulePlaceholder(module: module)
                    }
                }
                Text("Kyro doesn't fetch any sports data yet.")
                    .font(.footnote)
                    .foregroundStyle(KyroTheme.textSecondary)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 4)
            }
            .frame(maxWidth: 720)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, SiloTheme.padding)
            .padding(.top, SiloTheme.smallPadding)
            .padding(.bottom, SiloTheme.largePadding)
        }
        .reportsPageChromeScroll(to: scrollState)
        .siloScrollEdgeEffect()
        .safeAreaInset(edge: .top, spacing: 0) {
            Color.clear.frame(height: shellHeader?.runway ?? 0)
        }
        .siloPageBackground()
        .toolbar(.hidden, for: .navigationBar)
        .accessibilityIdentifier("kyroSportsHub")
    }
}

private struct KyroSportsHero: View {
    @State private var store = KyroGlobalNavigationStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ZStack {
                Circle()
                    .fill(KyroTheme.activeGradient)
                    .frame(width: 56, height: 56)
                    .shadow(color: KyroTheme.accent.opacity(0.55), radius: 18)
                Image(systemName: "trophy.fill")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 6) {
                Text("Sports")
                    .font(.largeTitle.bold())
                    .foregroundStyle(KyroTheme.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                Text("Scores, schedules and your teams, with the channel to watch them on. Coming soon.")
                    .font(.subheadline)
                    .foregroundStyle(KyroTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Until games are matched to channels, sports on IPTV is one tap away.
            Button {
                store.selectIfTab(.liveTV)
            } label: {
                Label("Browse Live TV", systemImage: "dot.radiowaves.left.and.right")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(KyroTheme.accent, in: Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("kyroSportsBrowseLiveTV")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(RadialGradient(colors: [KyroTheme.depth.opacity(0.85), .clear],
                                     center: .topLeading, startRadius: 0, endRadius: 320))
        }
        .kyroGlass(RoundedRectangle(cornerRadius: 24, style: .continuous), glow: true)
    }
}

private struct KyroSportsModulePlaceholder: View {
    let module: KyroSportsHubModule

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: module.systemImage)
                .font(.title3)
                .foregroundStyle(KyroTheme.accentInk)
                .frame(width: 40, height: 40)
                .background(KyroTheme.selectedFill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(module.title)
                        .font(.headline)
                        .foregroundStyle(KyroTheme.textPrimary)
                    Spacer(minLength: 4)
                    Text("Soon")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(KyroTheme.accentInk)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .overlay(Capsule().strokeBorder(KyroTheme.selectedBorder, lineWidth: 1))
                }
                Text(module.summary)
                    .font(.footnote)
                    .foregroundStyle(KyroTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .kyroGlass(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(module.title), coming soon. \(module.summary)")
        .accessibilityIdentifier("kyroSportsModule-\(module.rawValue)")
    }
}
