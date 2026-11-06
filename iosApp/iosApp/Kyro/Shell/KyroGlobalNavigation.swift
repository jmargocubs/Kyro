import Foundation
import Observation

/// The five destinations shared by every Kyro global navigation presentation.
/// Live TV's Guide, Search, Favorites, and Channels remain contextual screens,
/// not global destinations.
enum KyroGlobalDestination: String, Codable, CaseIterable, Identifiable, Sendable {
    case home
    case movies
    case series
    case forYou
    case liveTV

    var id: String { rawValue }

    static let requiredDestinations: [Self] = [.home, .movies, .series, .forYou, .liveTV]
}

/// Global navigation presentation. This choice applies to the whole app.
enum KyroNavigationPresentationStyle: String, Codable, CaseIterable, Identifiable, Sendable {
    case classic
    case glassDock
    case thumbFan

    var id: String { rawValue }

    var isFloating: Bool { self != .classic }
}

/// Device-local global navigation preferences. Version 1 deliberately has no
/// per-destination visibility or ordering: all five product destinations are
/// required. The schema version is also stored in the preference key.
struct KyroGlobalNavigationPreferences: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    private(set) var schemaVersion = currentSchemaVersion
    var style: KyroNavigationPresentationStyle = .classic
    var autoCollapse = true
    var idleBehavior: KyroLiveTVNavigationIdleBehavior = .collapse
    var hapticsEnabled = true
    var thumbScrubbing = true
    var allowsDragging = true
    var startingEdge: KyroNavigationEdge = .right
    private var dockAnchor: KyroNavigationAnchor?
    private var fanAnchor: KyroNavigationAnchor?

    init() {}

    /// The existing gesture presentation consumes an anchor for either
    /// floating style; Classic has no saved position.
    func anchor(for style: KyroNavigationPresentationStyle) -> KyroNavigationAnchor {
        let saved: KyroNavigationAnchor? = switch style {
        case .glassDock: dockAnchor
        case .thumbFan: fanAnchor
        case .classic: nil
        }
        return saved ?? .default(for: startingEdge)
    }

    mutating func setAnchor(_ anchor: KyroNavigationAnchor, for style: KyroNavigationPresentationStyle) {
        switch style {
        case .glassDock: dockAnchor = anchor
        case .thumbFan: fanAnchor = anchor
        case .classic: break
        }
    }

    mutating func resetPositions() {
        dockAnchor = nil
        fanAnchor = nil
    }

    /// Copies only preferences compatible with global navigation. The old
    /// Live TV destination order and hidden set are intentionally ignored.
    init(migrating legacy: KyroLiveTVNavigationPreferences) {
        self.init()
        style = KyroNavigationPresentationStyle(rawValue: legacy.style.rawValue) ?? .classic
        autoCollapse = legacy.autoCollapse
        idleBehavior = legacy.idleBehavior
        hapticsEnabled = legacy.hapticsEnabled
        thumbScrubbing = legacy.thumbScrubbing
        allowsDragging = legacy.allowsDragging
        startingEdge = legacy.startingEdge

        // Keep both positions even when Classic is currently selected: a
        // user may switch back to either floating presentation later.
        setAnchor(legacy.anchor(for: .glassDock), for: .glassDock)
        setAnchor(legacy.anchor(for: .thumbFan), for: .thumbFan)
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, style, autoCollapse, idleBehavior, hapticsEnabled,
             thumbScrubbing, allowsDragging, startingEdge, dockAnchor, fanAnchor
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        func value<T: Decodable>(_ key: CodingKeys) -> T? {
            try? values.decodeIfPresent(T.self, forKey: key)
        }
        let defaults = Self()
        let decodedVersion: Int = value(.schemaVersion) ?? Self.currentSchemaVersion
        schemaVersion = decodedVersion == Self.currentSchemaVersion
            ? decodedVersion
            : Self.currentSchemaVersion
        style = value(.style) ?? defaults.style
        autoCollapse = value(.autoCollapse) ?? defaults.autoCollapse
        idleBehavior = value(.idleBehavior) ?? defaults.idleBehavior
        hapticsEnabled = value(.hapticsEnabled) ?? defaults.hapticsEnabled
        thumbScrubbing = value(.thumbScrubbing) ?? defaults.thumbScrubbing
        allowsDragging = value(.allowsDragging) ?? defaults.allowsDragging
        startingEdge = value(.startingEdge) ?? defaults.startingEdge
        dockAnchor = value(.dockAnchor)
        fanAnchor = value(.fanAnchor)
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(Self.currentSchemaVersion, forKey: .schemaVersion)
        try values.encode(style, forKey: .style)
        try values.encode(autoCollapse, forKey: .autoCollapse)
        try values.encode(idleBehavior, forKey: .idleBehavior)
        try values.encode(hapticsEnabled, forKey: .hapticsEnabled)
        try values.encode(thumbScrubbing, forKey: .thumbScrubbing)
        try values.encode(allowsDragging, forKey: .allowsDragging)
        try values.encode(startingEdge, forKey: .startingEdge)
        try values.encodeIfPresent(dockAnchor, forKey: .dockAnchor)
        try values.encodeIfPresent(fanAnchor, forKey: .fanAnchor)
    }
}

/// Sole owner of the selected global destination and global preferences.
/// Selection is session state; preferences persist locally between launches.
@MainActor
@Observable
final class KyroGlobalNavigationStore {
    static let shared = KyroGlobalNavigationStore()
    static let defaultsKey = "kyro.navigation.global.v1"
    static let legacyLiveTVDefaultsKey = KyroLiveTVNavigationStore.defaultsKey

    var selectedDestination: KyroGlobalDestination = .home

    var preferences: KyroGlobalNavigationPreferences {
        didSet {
            if preferences != oldValue { savePreferences() }
        }
    }

    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        if let data = defaults.data(forKey: Self.defaultsKey),
           let saved = try? JSONDecoder().decode(KyroGlobalNavigationPreferences.self, from: data) {
            preferences = saved
        } else if let data = defaults.data(forKey: Self.legacyLiveTVDefaultsKey),
                  let legacy = try? JSONDecoder().decode(KyroLiveTVNavigationPreferences.self, from: data) {
            preferences = KyroGlobalNavigationPreferences(migrating: legacy)
            savePreferences()
        } else {
            preferences = KyroGlobalNavigationPreferences()
        }
    }

    private func savePreferences() {
        guard let data = try? JSONEncoder().encode(preferences) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }
}
