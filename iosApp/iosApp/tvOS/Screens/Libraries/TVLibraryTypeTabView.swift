#if os(tvOS)
import SwiftUI

/// Body of a Skyline library-type tab (Movies / Series / Music /
/// Audiobooks): the selected sub-destination's content, with the
/// Recommended landing as the default.
///
/// Collections and Browse are reached from the top-bar cascade (§5.3), which
/// commits `selectedPill`. Up from content goes straight to the bar.
struct TVLibraryTypeTabView: View {
    let type: TVLibraryTabType
    /// The library this tab is currently scoped to (§3.1). Resolved by the
    /// shell from the persisted per-profile scope, or the first library on
    /// cold start. The cascade selector (§5.3) switches it.
    let activeLibrary: Library?
    /// Selected sub-destination, owned by the shell so it survives tab
    /// switches within a session (§8); cold start always lands on
    /// Recommended. Written by the cascade dropdown.
    @Binding var selectedPill: TVLibraryPill
    /// Whether this body is a Movies/Series category tab, which narrows a
    /// mixed library to that tab's media type. A pinned library shortcut
    /// (Kyro keeps them) passes false: the user picked the whole library, so
    /// a mixed library keeps both movies and series.
    var scopesMixedLibraries: Bool = true
    var focusRequest: Int = 0
    var isTopMenuFocused: Bool = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.locale) private var locale

    var body: some View {
        siloBody
    }

    private var siloBody: some View {
        Group {
            if let activeLibrary {
                ZStack(alignment: .top) {
                    pillContent(for: activeLibrary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        // §4.2 sub-destination content switch: the cascade
                        // dropdown commits a new `selectedPill`, and selecting
                        // the tab crossfades the swap. Keyed on the pill so a
                        // switch inserts the new content and removes the old;
                        // Reduce Motion drops the drift to opacity only.
                        .id(selectedPill)
                        .transition(pillContentTransition)
                }
                // Re-create the tab body when the scoped library changes so
                // section fetches and grid state reset cleanly.
                .id("\(activeLibrary.id)-\(mediaScope?.rawValue ?? "all")")
            } else {
                EmptyStateView(
                    icon: "square.stack.3d.up",
                    title: AppLanguage.string(noLibrariesTitle, locale: locale),
                    subtitle: AppLanguage.string(.libraryNoLibrariesVisibleBody, locale: locale)
                )
                .padding(.top, TVTopMenuLayout.contentTopInset)
                .tvPageFocusOwner(
                    focusRequest: focusRequest,
                    isTopMenuFocused: isTopMenuFocused,
                    accessibilityLabel: AppLanguage.string(noLibrariesTitle, locale: locale)
                )
            }
        }
        .siloBackground()
    }

    private var mediaScope: LibraryVideoScope? {
        Self.mediaScope(for: type, library: activeLibrary, scopesMixedLibraries: scopesMixedLibraries)
    }

    private var noLibrariesTitle: LocalizedStringResource {
        switch type {
        case .movies: return .libraryNoLibrariesOfTypeMovies
        case .series: return .libraryNoLibrariesOfTypeSeries
        case .music: return .libraryNoLibrariesOfTypeMusic
        case .audiobooks: return .libraryNoLibrariesOfTypeAudiobooks
        }
    }

    /// The media type a mixed library is narrowed to: the Movies or Series
    /// tab it was opened from. Single-type libraries are never narrowed.
    static func mediaScope(
        for type: TVLibraryTabType,
        library: Library?,
        scopesMixedLibraries: Bool = true
    ) -> LibraryVideoScope? {
        guard scopesMixedLibraries, library?.isMixedLibrary == true else { return nil }
        switch type {
        case .movies: return .movie
        case .series: return .series
        case .music, .audiobooks: return nil
        }
    }

    @ViewBuilder
    private func pillContent(for library: Library) -> some View {
        switch selectedPill {
        case .recommended:
            TVLibraryBrowseView(
                library: library,
                mediaScope: mediaScope,
                focusRequest: focusRequest,
                isTopMenuFocused: isTopMenuFocused
            )
        case .collections:
            TVLibraryCollectionsView(
                library: library,
                mediaScope: mediaScope,
                focusRequest: focusRequest,
                isTopMenuFocused: isTopMenuFocused
            )
        case .browse:
            TVLibraryGridView(
                libraryId: library.id,
                libraryName: library.name,
                libraryType: library.type,
                mediaScope: mediaScope,
                initialFilter: .none,
                showsHeader: false,
                showsAlphabetRail: true,
                topContentInset: SiloTheme.Skyline.libraryContentTopInset,
                focusRequest: focusRequest,
                isTopMenuFocused: isTopMenuFocused
            )
        }
    }

    // MARK: - Selection & focus routing

    /// Asymmetric transition for the sub-destination content swap (§4.2).
    /// Incoming content fades in while drifting 12 px upward into place;
    /// outgoing content fades out without sliding. Reduce Motion → opacity
    /// only, no drift (the §4.2 acceptance "no drift animations").
    private var pillContentTransition: AnyTransition {
        guard !reduceMotion else { return .opacity }
        return .asymmetric(
            insertion: .opacity.combined(with: .offset(y: SiloTheme.Skyline.pillDriftY)),
            removal: .opacity
        )
    }
}
#endif
