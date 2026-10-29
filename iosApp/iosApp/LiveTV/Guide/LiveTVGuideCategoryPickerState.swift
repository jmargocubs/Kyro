import Foundation

/// Stable scroll targets for the guide's category picker. The all-categories row is distinct from
/// any provider category with the same display text.
enum LiveTVGuideCategoryPickerID: Hashable, Sendable {
    case allCategories
    case category(String)
}

/// Keeps the last visible picker row independently for each provider. This is view state only; it
/// never participates in channel filtering or guide row construction.
struct LiveTVGuideCategoryPickerState {
    private var lastVisibleByProvider: [UUID: LiveTVGuideCategoryPickerID] = [:]

    func target(providerID: UUID, selectedCategory: String?, categories: [String]) -> LiveTVGuideCategoryPickerID {
        let valid = Set(categories.map(LiveTVGuideCategoryPickerID.category))
        if let lastVisible = lastVisibleByProvider[providerID],
           lastVisible == .allCategories || valid.contains(lastVisible) {
            return lastVisible
        }
        if let selectedCategory {
            let selected = LiveTVGuideCategoryPickerID.category(selectedCategory)
            if valid.contains(selected) { return selected }
        }
        return .allCategories
    }

    mutating func remember(_ id: LiveTVGuideCategoryPickerID?, providerID: UUID, categories: [String]) {
        guard let id else { return }
        let valid = Set(categories.map(LiveTVGuideCategoryPickerID.category))
        guard id == .allCategories || valid.contains(id) else { return }
        lastVisibleByProvider[providerID] = id
    }

    mutating func reconcile(providerID: UUID, categories: [String]) {
        guard let lastVisible = lastVisibleByProvider[providerID], lastVisible != .allCategories else { return }
        let valid = Set(categories.map(LiveTVGuideCategoryPickerID.category))
        if !valid.contains(lastVisible) { lastVisibleByProvider[providerID] = nil }
    }
}
