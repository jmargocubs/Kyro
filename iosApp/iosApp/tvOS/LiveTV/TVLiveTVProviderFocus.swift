#if os(tvOS)
import Foundation

/// Focus identities on the Live TV Providers screen.
enum TVLiveTVProviderFocus: Hashable {
    case back
    case provider(UUID)
    case refresh(UUID)
    case remove(UUID)
    case phoneSetup
    case addProvider
    case save
}

/// Where focus goes on the Providers screen, free of SwiftUI so it is unit-tested.
enum TVLiveTVProviderFocusPlanner {
    /// Opening the screen lands on the first provider, or on Set up with phone when there is none,
    /// so the recommended path is one press away.
    static func initialFocus(providerIDs: [UUID]) -> TVLiveTVProviderFocus {
        providerIDs.first.map(TVLiveTVProviderFocus.provider) ?? .phoneSetup
    }

    /// After a provider is removed: the next remaining provider, else Set up with phone.
    static func afterRemoval(remainingProviderIDs: [UUID]) -> TVLiveTVProviderFocus {
        initialFocus(providerIDs: remainingProviderIDs)
    }

    /// Up from these controls must reach Back, whatever column they sit in.
    static func escapesToBack(_ focus: TVLiveTVProviderFocus, providerIDs: [UUID]) -> Bool {
        switch focus {
        case .provider(let id), .refresh(let id), .remove(let id): id == providerIDs.first
        case .phoneSetup: providerIDs.isEmpty
        case .back, .save, .addProvider: false
        }
    }

    /// Closing the Add Provider sheet lands on the saved provider, or back on Add Provider after Cancel.
    static func afterAddProvider(savedProviderID: UUID?) -> TVLiveTVProviderFocus {
        savedProviderID.map(TVLiveTVProviderFocus.provider) ?? .addProvider
    }
}
#endif
