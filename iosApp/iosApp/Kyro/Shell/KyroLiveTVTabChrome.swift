import SwiftUI

// Live TV's chrome when it is a tab of the app's own bar (Kyro's unified
// navigation). A toolbar declared inside a tab never reaches the app's
// navigation bar, so Live TV draws its header and its own destinations as
// bars on the page instead, backed so the page scrolls cleanly under them.

extension View {
    /// `bar` pinned to the top, with the page scrolling under it. iOS 26 gives
    /// it the navigation bar's soft scroll edge; every version backs it with
    /// the page's charcoal so cards and artwork never show through the controls.
    @ViewBuilder
    func kyroTopBar<Bar: View>(@ViewBuilder _ bar: () -> Bar) -> some View {
        if #available(iOS 26.0, *) {
            safeAreaBar(edge: .top, spacing: 0) {
                bar().background(KyroTopBarBacking())
            }
        } else {
            safeAreaInset(edge: .top, spacing: 0) {
                bar().background(KyroTopBarBacking())
            }
        }
    }

    /// Live TV's header as a top bar where Live TV is a tab root; nothing at all elsewhere.
    @ViewBuilder
    func liveTVTabHeader<Header: View>(isEnabled: Bool, @ViewBuilder _ header: () -> Header) -> some View {
        if isEnabled {
            kyroTopBar(header)
        } else {
            self
        }
    }

    /// The channel browser's search field: a bar of its own where Live TV is a
    /// tab, so the list never shows through it; Build 17's inset everywhere else.
    @ViewBuilder
    func liveTVBrowserSearchField<Field: View>(asTopBar: Bool, @ViewBuilder _ field: () -> Field) -> some View {
        if asTopBar {
            kyroTopBar(field)
        } else {
            safeAreaInset(edge: .top, spacing: 0, content: field)
        }
    }
}

/// The page's own charcoal, reaching up under the status bar, so a bar reads
/// as part of the page at rest and hides what scrolls beneath it.
private struct KyroTopBarBacking: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        Color.siloPageCanvas
            .opacity(reduceTransparency ? 1 : 0.94)
            .ignoresSafeArea(edges: .top)
    }
}

/// Live TV's header as a tab root: the KYRO LIVE wordmark and, in one glass
/// group as in Build 17's toolbar, Search and the Guide when nothing else on
/// screen offers them, then Live TV settings. There is nothing behind a tab
/// root to go back to; `back` exists only for a browser no navigation can leave.
struct LiveTVTabHeader: View {
    var back: (() -> Void)?
    var search: (() -> Void)?
    var guide: (() -> Void)?
    let settings: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            if let back {
                Button(action: back) {
                    Image(systemName: "chevron.left")
                        .font(.body.weight(.semibold))
                        .frame(width: 44, height: 44)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(LiveTVAccent.primaryText)
                .siloGlass(in: Circle())
                .accessibilityLabel("Back to Live TV Home")
            }
            LiveTVBrandWordmark()
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 8)
            HStack(spacing: 0) {
                KyroMoreMenuButton()
                if let search { control("magnifyingglass", label: "Search channels", action: search) }
                if let guide { control("calendar.day.timeline.left", label: "TV Guide", action: guide) }
                control("gearshape", label: "Live TV settings", action: settings)
            }
            .padding(.horizontal, 2)
            .siloGlass(in: Capsule())
        }
        .padding(.horizontal, SiloTheme.padding)
        .padding(.top, 2)
        .padding(.bottom, 6)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("liveTVTabHeader")
    }

    private func control(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.body.weight(.semibold))
                .foregroundStyle(LiveTVAccent.primaryText)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityShowsLargeContentViewer { Label(label, systemImage: symbol) }
    }
}

/// Classic under Kyro's unified navigation: Live TV's visible destinations,
/// in the user's order, as one glass segmented control under the header. The
/// segments share the width, so all of them fit a 402pt screen with no
/// scrolling; accessibility text sizes show the symbols alone, with the large
/// content viewer and VoiceOver labels naming them. It routes through the same
/// `navigate` as every other style.
struct KyroLiveTVDestinationRow: View {
    let destinations: [KyroLiveTVDestination]
    let active: KyroLiveTVDestination
    let navigate: (KyroLiveTVDestination) -> Void

    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        HStack(spacing: 2) {
            ForEach(destinations) { destination in
                segment(destination, isActive: destination == active)
            }
        }
        .padding(3)
        .siloGlass(in: Capsule())
        .padding(.horizontal, SiloTheme.padding)
        .padding(.bottom, 8)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("kyroLiveTVRow")
    }

    private var showsTitles: Bool { !typeSize.isAccessibilitySize }

    private func segment(_ destination: KyroLiveTVDestination, isActive: Bool) -> some View {
        Button {
            if !isActive || destination == .search { navigate(destination) }
        } label: {
            VStack(spacing: 2) {
                Image(systemName: isActive ? destination.activeSystemImage : destination.systemImage)
                    .font(.body.weight(.semibold))
                    .imageScale(.medium)
                if showsTitles {
                    Text(destination.title)
                        .font(.caption2.weight(.semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }
            }
            .foregroundStyle(isActive ? Color.siloOnSurface : Color.siloSecondaryText)
            .frame(maxWidth: .infinity, minHeight: 44)
            .padding(.vertical, showsTitles ? 4 : 2)
            .background {
                if isActive {
                    Capsule()
                        .fill(Color.siloChromeSelectedFill)
                        .overlay(Capsule().stroke(Color.siloChromeSelectedBorder, lineWidth: 1))
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(destination.title)
        .accessibilityAddTraits(isActive ? .isSelected : [])
        .accessibilityShowsLargeContentViewer {
            Label(destination.title, systemImage: destination.systemImage)
        }
        .accessibilityIdentifier("kyroLiveTVRow.\(destination.rawValue)")
    }
}
