#if os(tvOS)
import Foundation

/// The single Kyro Apple TV rule for which primary-menu items are renderable
/// roots. Phase 2 exposes the working media foundations plus native Live TV.
/// Search and Settings are fixed shell actions; Sports remains absent until
/// its TV-native page is ready.
enum TVPrimaryMenuProjection {
    /// Supported media roots in the user's stored order. Unsupported stored
    /// destinations remain untouched for other clients and later phases.
    /// `vodTypes` are the Movies/Series tabs an IPTV provider supplies; they stay visible without
    /// a Silo library of that type.
    static func visibleItems(
        in items: [PrimaryMenuItem],
        libraries: [Library],
        vodTypes: Set<TVLibraryTabType> = []
    ) -> [PrimaryMenuItem] {
        func hasLibrary(_ type: TVLibraryTabType) -> Bool {
            vodTypes.contains(type) || libraries.contains(where: { type.matches($0) })
        }
        return items.filter { item in
            switch item {
            case .builtin(.movies): return hasLibrary(.movies)
            case .builtin(.series): return hasLibrary(.series)
            case .builtin(.home): return true
            case .builtin(.music), .builtin(.audiobooks), .builtin(.forYou),
                 .builtin(.calendar), .library, .section, .collection:
                return false
            }
        }
    }

    /// Bar roots in menu order, deduplicated, with Home forced first when absent
    /// and Live TV appended after the media roots.
    static func roots(
        for items: [PrimaryMenuItem],
        libraries: [Library],
        vodTypes: Set<TVLibraryTabType> = []
    ) -> [TVRootDestination] {
        var roots: [TVRootDestination] = []
        for item in visibleItems(in: items, libraries: libraries, vodTypes: vodTypes) {
            let root: TVRootDestination?
            switch item {
            case .builtin(.home): root = .home
            case .builtin(.movies): root = .libraryType(.movies)
            case .builtin(.series): root = .libraryType(.series)
            case .builtin(.music), .builtin(.audiobooks), .builtin(.forYou),
                 .builtin(.calendar), .library, .section, .collection:
                root = nil
            }
            if let root, !roots.contains(root) { roots.append(root) }
        }
        if !roots.contains(.home) { roots.insert(.home, at: 0) }
        // An IPTV catalog whose tab is missing from the stored menu still gets one, beside the
        // other media tabs rather than after Live TV and Sports.
        for type in [TVLibraryTabType.movies, .series] where vodTypes.contains(type) {
            let root = TVRootDestination.libraryType(type)
            if !roots.contains(root) { roots.append(root) }
        }
        if !roots.contains(.liveTV) { roots.append(.liveTV) }
        if !roots.contains(.sports) { roots.append(.sports) }
        return roots
    }
}
#endif
