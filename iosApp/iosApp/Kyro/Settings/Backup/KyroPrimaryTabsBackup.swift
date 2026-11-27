#if os(iOS) || KYRO_STANDALONE_TESTS
enum KyroPrimaryTabsBackup {
    private struct InvalidArrangement: Error {}

    /// Keep the setting identity so legacy backups normalize into a complete
    /// arrangement before preview, apply, verification and rollback.
    @MainActor
    static func setting(store: KyroGlobalNavigationStore) -> BackupSetting {
        BackupSetting(id: "navigation.fourthTab", group: .navigation, title: "Primary destinations",
            validate: { decode($0) != nil },
            read: { encode(store.preferences.primaryTabs) },
            write: { value in
                guard let tabs = decode(value) else { throw InvalidArrangement() }
                store.preferences.primaryTabs = tabs
            },
            normalize: { value in decode(value).map(encode) ?? value },
            label: { value in
                decode(value)?.all.map { $0.presentation.title }.joined(separator: ", ") ?? value.plainText
            })
    }

    static func encode(_ tabs: KyroPrimaryTabs) -> BackupValue {
        .array(tabs.destinations.map { .string($0.rawValue) })
    }

    static func decode(_ value: BackupValue) -> KyroPrimaryTabs? {
        switch value {
        case .string(let legacy):
            return KyroFourthTab(rawValue: legacy).map(KyroPrimaryTabs.init(legacy:))
        case .array(let values):
            var destinations: [KyroGlobalDestination] = []
            for value in values {
                guard case .string(let raw) = value, let destination = KyroGlobalDestination(rawValue: raw) else { return nil }
                destinations.append(destination)
            }
            return KyroPrimaryTabs(destinations)
        default:
            return nil
        }
    }
}
#endif
