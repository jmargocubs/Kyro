#if os(iOS) || KYRO_STANDALONE_TESTS
import Foundation
import Observation

enum KyroAppAppearance: String, CaseIterable, Identifiable, Sendable {
    case signature
    case classicDark

    var id: String { rawValue }
    var title: String {
        switch self {
        case .signature: "Kyro Signature"
        case .classicDark: "Classic Dark"
        }
    }
}

/// Device-local app chrome. Independent of both player themes and navigation.
@MainActor @Observable
final class KyroAppAppearanceStore {
    static let shared = KyroAppAppearanceStore()
    static let key = "kyrox.appAppearance.v1"
    @ObservationIgnored private let defaults: UserDefaults
    private(set) var selection: KyroAppAppearance

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        selection = defaults.string(forKey: Self.key).flatMap(KyroAppAppearance.init(rawValue:)) ?? .signature
    }

    func select(_ appearance: KyroAppAppearance) {
        guard selection != appearance else { return }
        defaults.set(appearance.rawValue, forKey: Self.key)
        selection = appearance
    }

    func backupSetting() -> BackupSetting {
        BackupSetting(id: "general.appAppearance", group: .general, title: "App Appearance",
                      validate: { Self.decode($0) != nil },
                      read: { .string(self.selection.rawValue) },
                      write: { value in
                          guard let appearance = Self.decode(value) else { throw InvalidAppearance() }
                          self.select(appearance)
                      },
                      label: { Self.decode($0)?.title ?? "Unsupported appearance" })
    }

    private struct InvalidAppearance: Error {}

    private static func decode(_ value: BackupValue) -> KyroAppAppearance? {
        guard case .string(let raw) = value else { return nil }
        return KyroAppAppearance(rawValue: raw)
    }
}
#endif
