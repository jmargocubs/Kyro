#if os(tvOS)
import Foundation

/// The single Kyro Apple TV rule for which primary-menu items are renderable
/// roots. Phase 1 intentionally exposes only the working media foundations:
/// Home, Movies, and Series. Search and Settings are fixed shell actions;
/// Live TV and Sports remain absent until their TV-native pages are ready.
enum TVPrimaryMenuProjection {
    /// Supported Phase 1 roots in the user's stored order. Unsupported stored
    /// destinations remain untouched for other clients and later phases.
    static func visibleItems(
        in items: [PrimaryMenuItem],
        libraries: [Library]
    ) -> [PrimaryMenuItem] {
        func hasLibrary(_ type: TVLibraryTabType) -> Bool {
            libraries.contains(where: { type.matches($0) })
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

    /// Bar roots in menu order, deduplicated, with Home forced first when absent.
    static func roots(
        for items: [PrimaryMenuItem],
        libraries: [Library]
    ) -> [TVRootDestination] {
        var roots: [TVRootDestination] = []
        for item in visibleItems(in: items, libraries: libraries) {
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
        return roots
    }
}
#endif
