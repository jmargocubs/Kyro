#if os(iOS) || KYRO_STANDALONE_TESTS
import Foundation

// Reused from independent Kyro X at bb2d21b, App/TabDockScrollRange.swift.
enum TabDockScrollRange: Equatable {
    case short, settling, scrollable

    init(content: CGFloat, viewport: CGFloat, insets: CGFloat) {
        let travel = content + insets - viewport
        // Wider than the accessory's height change, preventing a resize loop.
        if viewport <= 0 || travel < 48 { self = .short }
        else if travel >= 128 { self = .scrollable }
        else { self = .settling }
    }

    func permitsMinimizing(previous: Bool) -> Bool {
        switch self {
        case .short: false
        case .settling: previous
        case .scrollable: true
        }
    }
}
#endif
