#if os(iOS)
import XCTest
import UniformTypeIdentifiers
@testable import Silo

// Build 88: the real stores behind the backup registry, in an isolated defaults domain. These never
// read or write the app's own settings, the Keychain or the network.

@MainActor
private final class FakeLocalPlayback: LocalPlaybackPreferences {
    var bufferAhead: BufferAheadMode = .automatic
    var losslessAudioEnabled = false
    var backgroundPlaybackEnabled = false
    var deinterlaceMode: DeinterlacePreference = .automatic
    var deinterlaceFieldRate: DeinterlaceFieldRatePreference = .fullMotion
    var trueHDAtmosEnabled = true
}

@MainActor
final class SettingsBackupLiveRegistryTests: XCTestCase {
    private var suiteName = ""
    private var defaults = UserDefaults()
    private let app = SettingsBackupAppInfo(version: "1.0.0", build: "88", platform: "iOS", idiom: "phone")

    override func setUp() {
        super.setUp()
        suiteName = "kyro.settingsBackupTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private struct Rig {
        let registry: SettingsBackupRegistry
        let navigation: KyroGlobalNavigationStore
        let downloads: DownloadSettings
        let playback: FakeLocalPlayback
    }

    private func makeRig(idiom: String = "phone", pip: Bool = true) -> Rig {
        let navigation = KyroGlobalNavigationStore(defaults: defaults)
        let downloads = DownloadSettings(defaults: defaults)
        let playback = FakeLocalPlayback()
        let registry = SettingsBackupLiveRegistry.make(.init(
            navigation: navigation, downloads: downloads, playback: playback,
            defaults: defaults, idiom: idiom, supportsPictureInPicture: pip))
        return Rig(registry: registry, navigation: navigation, downloads: downloads, playback: playback)
    }

    private func applyAll(_ data: Data, to rig: Rig, journal: RestoreJournalStoring = BackupMemoryJournal(),
                          groups: Set<SettingsBackupGroup> = Set(SettingsBackupGroup.allCases)) throws -> RestoreOutcome {
        let preview = SettingsBackupPlanner.preview(try SettingsBackupCodec.decode(data), registry: rig.registry)
        return SettingsBackupApplier(registry: rig.registry, journal: journal).apply(preview: preview, selectedGroups: groups)
    }

    func testEverySettingIsOnTheExplicitLocalAllowlist() {
        let ids = Set(makeRig().registry.settings.map(\.id))
        XCTAssertEqual(ids, [
            "navigation.fourthTab",
            "liveTV.categoryAppearance", "liveTV.categoryGrouping", "liveTV.guideStyle",
            "sports.soccerSupplement", "sports.wtaStats", "sports.tennisNews", "sports.atpStats", "sports.tennisPlayerInfo",
            "downloads.preferredFormat", "downloads.wifiOnly", "downloads.defaultDeleteWatched",
            "downloads.defaultMaxStorageGB", "downloads.sortOption", "downloads.keepWatched", "downloads.simultaneous",
            "playback.bufferAhead", "playback.losslessAudio", "pip.backgroundPlayback",
            "advancedAV.deinterlaceMode", "advancedAV.deinterlaceFieldRate", "advancedAV.trueHDAtmos",
            "nav.style", "nav.startingEdge", "nav.idleBehavior", "nav.autoCollapse", "nav.haptics",
            "nav.thumbScrubbing", "nav.allowsDragging",
        ])
        for id in ids { XCTAssertFalse(SettingsBackupSafety.isSensitiveName(id), id) }
    }

    func testRoundTripThroughRealStores() throws {
        let source = makeRig()
        source.navigation.preferences.fourthTab = .favorites
        source.downloads.wifiOnly = false
        source.downloads.simultaneousDownloads = 4
        source.downloads.defaultMaxStorageGB = 50
        source.downloads.sortOption = .alphabetical
        source.playback.bufferAhead = .extended
        source.navigation.preferences.style = .glassDock
        defaults.set(false, forKey: KyroSportsSupplementFlag.tennisNewsKey)
        defaults.set(LiveTVEmbeddedGuideStyle.grid.rawValue, forKey: LiveTVEmbeddedGuideStyle.defaultsKey)
        var categories = LiveTVCategoryPreferences()
        categories.appearance = .grid
        categories.grouping = .grouped
        categories.save(providerID: nil, to: defaults)

        let data = try SettingsBackupExporter.export(
            registry: source.registry, groups: Set(SettingsBackupGroup.allCases), app: app)

        let freshDefaults = UserDefaults(suiteName: suiteName + ".destination")!
        defer { freshDefaults.removePersistentDomain(forName: suiteName + ".destination") }
        let navigation = KyroGlobalNavigationStore(defaults: freshDefaults)
        let downloads = DownloadSettings(defaults: freshDefaults)
        let playback = FakeLocalPlayback()
        let destination = Rig(
            registry: SettingsBackupLiveRegistry.make(.init(
                navigation: navigation, downloads: downloads, playback: playback,
                defaults: freshDefaults, idiom: "phone", supportsPictureInPicture: true)),
            navigation: navigation, downloads: downloads, playback: playback)

        guard case .applied = try applyAll(data, to: destination) else { return XCTFail("not applied") }
        XCTAssertEqual(navigation.preferences.fourthTab, .favorites)
        XCTAssertEqual(navigation.preferences.style, .glassDock)
        XCTAssertFalse(downloads.wifiOnly)
        XCTAssertEqual(downloads.simultaneousDownloads, 4)
        XCTAssertEqual(downloads.defaultMaxStorageGB, 50)
        XCTAssertEqual(downloads.sortOption, .alphabetical)
        XCTAssertEqual(playback.bufferAhead, .extended)
        XCTAssertFalse(KyroSportsSupplementFlag.isEnabled(key: KyroSportsSupplementFlag.tennisNewsKey, defaults: freshDefaults))
        XCTAssertEqual(freshDefaults.string(forKey: LiveTVEmbeddedGuideStyle.defaultsKey), "grid")
        let loaded = LiveTVCategoryPreferences.load(providerID: nil, from: freshDefaults)
        XCTAssertEqual(loaded.appearance, .grid)
        XCTAssertEqual(loaded.grouping, .grouped)
    }

    func testRestoreLeavesProviderDataAndTransientLiveTVStateAlone() throws {
        let providerID = UUID()
        var scoped = LiveTVCategoryPreferences()
        scoped.pinned = ["Sports"]
        scoped.hidden = ["Adult"]
        scoped.recent = ["News"]
        scoped.save(providerID: providerID, to: defaults)
        defaults.set(Data("providers".utf8), forKey: "liveTV.providers.v1")
        defaults.set(["channel-1"], forKey: "liveTV.favorites.v1")
        defaults.set("nfl", forKey: "kyro.sports.selectedLeague")
        let before = defaults.dictionaryRepresentation()
        let providerKey = "\(LiveTVCategoryPreferences.key).provider.\(providerID.uuidString)"

        let rig = makeRig()
        let incomingBackup = try SettingsBackupCodec.makeDocument(
            groups: ["liveTVCategories": ["liveTV.categoryAppearance": .string("Grid"), "liveTV.categoryGrouping": .string("Grouped")]],
            schemaVersion: 1, minReaderVersion: 1, app: app, now: Date())
        guard case .applied = try applyAll(incomingBackup, to: rig) else { return XCTFail("not applied") }

        let after = defaults.dictionaryRepresentation()
        XCTAssertEqual(after[providerKey] as? Data, before[providerKey] as? Data)
        XCTAssertEqual(after["liveTV.providers.v1"] as? Data, Data("providers".utf8))
        XCTAssertEqual(after["liveTV.favorites.v1"] as? [String], ["channel-1"])
        XCTAssertEqual(after["kyro.sports.selectedLeague"] as? String, "nfl")
        XCTAssertEqual(LiveTVCategoryPreferences.load(providerID: providerID, from: defaults).pinned, ["Sports"])
    }

    func testBackupDoesNotContainLiveTVProvidersCredentialsOrServerState() throws {
        defaults.set("https://example.invalid/playlist.m3u", forKey: "serverUrl")
        defaults.set("profile-1", forKey: "profileId")
        defaults.set(Data("providers".utf8), forKey: "liveTV.providers.v1")
        let data = try SettingsBackupExporter.export(
            registry: makeRig().registry, groups: Set(SettingsBackupGroup.allCases), app: app)
        let text = String(decoding: data, as: UTF8.self)
        for forbidden in ["example.invalid", "profile-1", "providers", "serverUrl", "m3u"] {
            XCTAssertFalse(text.contains(forbidden), forbidden)
        }
    }

    func testRestoreWritesNoServerSyncedPlayerKeys() throws {
        // Only the six device-local player accessors are reachable from the registry. The synced
        // ones (quality, speed, subtitles, orientation...) have no entry to restore.
        let ids = makeRig().registry.settings.map(\.id)
        for forbidden in ["quality", "speed", "subtitle", "orientation", "gravity", "hdr", "audioLanguage", "introSkip"] {
            XCTAssertFalse(ids.contains { $0.lowercased().contains(forbidden.lowercased()) }, forbidden)
        }
    }

    func testPictureInPictureSettingIsSkippedWhenUnsupported() throws {
        let source = makeRig()
        source.playback.backgroundPlaybackEnabled = true
        let data = try SettingsBackupExporter.export(registry: source.registry, groups: [.pictureInPicture], app: app)
        let destination = makeRig(pip: false)
        let preview = SettingsBackupPlanner.preview(try SettingsBackupCodec.decode(data), registry: destination.registry)
        XCTAssertEqual(preview.totalChanges, 0)
    }

    func testDeviceSpecificGroupsStayOffUnlessChosen() throws {
        let rig = makeRig()
        rig.playback.bufferAhead = .unlimited
        let data = try SettingsBackupExporter.export(registry: rig.registry, groups: SettingsBackupGroup.defaultSelection, app: app)
        XCTAssertNil(try SettingsBackupCodec.decode(data).groups["playbackOptions"])
        XCTAssertNil(try SettingsBackupCodec.decode(data).groups["navigationLayout"])
    }

    func testDownloadsValuesOutsideTheStoreLimitsAreSkipped() throws {
        let rig = makeRig()
        let data = try SettingsBackupCodec.makeDocument(
            groups: ["downloads": ["downloads.simultaneous": .int(40), "downloads.defaultMaxStorageGB": .int(-1),
                                   "downloads.preferredFormat": .string("8k")]],
            schemaVersion: 1, minReaderVersion: 1, app: app, now: Date())
        let before = rig.downloads.simultaneousDownloads
        XCTAssertEqual(try applyAll(data, to: rig), .nothingToApply)
        XCTAssertEqual(rig.downloads.simultaneousDownloads, before)
    }
    // MARK: Build 88.1: import / apply / Undo through real stores and a real restore-point file

    private func temporaryJournal() -> (FileRestoreJournalStore, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("kyro-live-journal-\(UUID().uuidString)")
        return (FileRestoreJournalStore(url: directory.appendingPathComponent("restore-point.json")), directory)
    }

    func testImportApplyUndoTransitionsOnRealStoresSurviveReopeningTheScreen() throws {
        let (journal, directory) = temporaryJournal()
        defer { try? FileManager.default.removeItem(at: directory) }

        let source = makeRig()
        source.navigation.preferences.fourthTab = .favorites
        source.downloads.wifiOnly = false
        source.downloads.sortOption = .alphabetical
        let data = try SettingsBackupExporter.export(registry: source.registry, groups: SettingsBackupGroup.defaultSelection, app: app)

        // A destination device with its own defaults domain.
        let name = suiteName + ".dest"
        let destDefaults = UserDefaults(suiteName: name)!
        defer { destDefaults.removePersistentDomain(forName: name) }
        let navigation = KyroGlobalNavigationStore(defaults: destDefaults)
        let downloads = DownloadSettings(defaults: destDefaults)
        let playback = FakeLocalPlayback()
        let registry = SettingsBackupLiveRegistry.make(.init(
            navigation: navigation, downloads: downloads, playback: playback,
            defaults: destDefaults, idiom: "phone", supportsPictureInPicture: true))
        let originalTab = navigation.preferences.fourthTab

        let center = NotificationCenter()
        var announcements = 0
        let token = center.addObserver(forName: .kyroSettingsDidRestore, object: nil, queue: nil) { _ in announcements += 1 }
        defer { center.removeObserver(token) }

        let model = SettingsBackupModel(registry: registry, journal: journal, app: app, notifications: center)
        model.loadImport(data: data)
        XCTAssertEqual(navigation.preferences.fourthTab, originalTab, "a preview changes nothing")
        model.applySelected()
        XCTAssertEqual(navigation.preferences.fourthTab, .favorites)
        XCTAssertFalse(downloads.wifiOnly)
        XCTAssertEqual(announcements, 1)

        // The screen is closed and opened again: a new model over the same file.
        let reopened = SettingsBackupModel(registry: registry, journal: journal, app: app, notifications: center)
        XCTAssertTrue(reopened.undoAvailable)
        reopened.undo()
        XCTAssertEqual(navigation.preferences.fourthTab, originalTab)
        XCTAssertTrue(downloads.wifiOnly)
        XCTAssertEqual(downloads.sortOption, .largestFirst)
        XCTAssertFalse(reopened.undoAvailable)
        XCTAssertNil(try journal.load())
    }

    func testUnselectedGroupsLeaveEveryOtherDefaultsKeyUntouched() throws {
        let source = makeRig()
        source.navigation.preferences.fourthTab = .favorites
        source.downloads.wifiOnly = false
        defaults.set(false, forKey: KyroSportsSupplementFlag.tennisNewsKey)
        let data = try SettingsBackupExporter.export(registry: source.registry, groups: SettingsBackupGroup.defaultSelection, app: app)

        let name = suiteName + ".untouched"
        let destDefaults = UserDefaults(suiteName: name)!
        defer { destDefaults.removePersistentDomain(forName: name) }
        destDefaults.set("keep", forKey: "some.other.preference")
        let navigation = KyroGlobalNavigationStore(defaults: destDefaults)
        let downloads = DownloadSettings(defaults: destDefaults)
        let registry = SettingsBackupLiveRegistry.make(.init(
            navigation: navigation, downloads: downloads, playback: FakeLocalPlayback(),
            defaults: destDefaults, idiom: "phone", supportsPictureInPicture: true))
        let before = destDefaults.persistentDomain(forName: name) ?? [:]

        let preview = SettingsBackupPlanner.preview(try SettingsBackupCodec.decode(data), registry: registry)
        let (journal, directory) = temporaryJournal()
        defer { try? FileManager.default.removeItem(at: directory) }
        guard case .applied = SettingsBackupApplier(registry: registry, journal: journal).apply(preview: preview, selectedGroups: [.sports]) else {
            return XCTFail("not applied")
        }
        let after = destDefaults.persistentDomain(forName: name) ?? [:]
        let changed = Set(after.keys).union(before.keys).filter { (after[$0] as? NSObject) != (before[$0] as? NSObject) }
        XCTAssertEqual(changed, [KyroSportsSupplementFlag.tennisNewsKey])
        XCTAssertEqual(destDefaults.string(forKey: "some.other.preference"), "keep")
        XCTAssertEqual(navigation.preferences.fourthTab, KyroGlobalNavigationPreferences().fourthTab)
        XCTAssertTrue(downloads.wifiOnly)
    }

    func testAChangeMadeAfterARestoreSurvivesUndoOnRealStores() throws {
        let rig = makeRig()
        let incoming = try SettingsBackupCodec.makeDocument(
            groups: ["downloads": ["downloads.wifiOnly": .bool(false), "downloads.sortOption": .string("alphabetical")]],
            schemaVersion: 1, minReaderVersion: 1, app: app, now: Date())
        let (journal, directory) = temporaryJournal()
        defer { try? FileManager.default.removeItem(at: directory) }
        guard case .applied = try applyAll(incoming, to: rig, journal: journal) else { return XCTFail("not applied") }
        rig.downloads.sortOption = .recentlyAdded        // changed after the restore
        let report = SettingsBackupApplier(registry: rig.registry, journal: journal).undo()
        XCTAssertEqual(report.changedSince, ["downloads.sortOption"])
        XCTAssertEqual(rig.downloads.sortOption, .recentlyAdded)
        XCTAssertTrue(rig.downloads.wifiOnly)
    }

    func testInterruptedRestoreIsRecoveredFromARealRestorePointFile() throws {
        let rig = makeRig()
        let (journal, directory) = temporaryJournal()
        defer { try? FileManager.default.removeItem(at: directory) }
        // The app stopped after the first write: the file says "applying".
        try journal.save(RestoreJournal(state: .applying, changes: [
            AppliedChange(id: "downloads.wifiOnly", previous: .bool(true), applied: .bool(false)),
            AppliedChange(id: "downloads.sortOption", previous: .string("largestFirst"), applied: .string("alphabetical")),
        ], date: Date()))
        rig.downloads.wifiOnly = false
        let applier = SettingsBackupApplier(registry: rig.registry, journal: FileRestoreJournalStore(url: directory.appendingPathComponent("restore-point.json")))
        XCTAssertTrue(applier.needsRecovery)
        let report = applier.recoverInterruptedRestore()
        XCTAssertEqual(report.reverted, ["downloads.wifiOnly"])
        XCTAssertEqual(report.unchanged, ["downloads.sortOption"])
        XCTAssertTrue(rig.downloads.wifiOnly)
        XCTAssertFalse(applier.needsRecovery)
        XCTAssertNil(try journal.load())
    }

    func testRestoredCategoryLayoutIsWhatTheCategoryScreenReloads() throws {
        // The category screen reloads appearance and grouping from this loader when it hears the
        // restore notification, so what it sees must be the restored value and nothing of the provider's.
        let providerID = UUID()
        var scoped = LiveTVCategoryPreferences()
        scoped.appearance = .list
        scoped.pinned = ["Sports"]
        scoped.save(providerID: providerID, to: defaults)

        let rig = makeRig()
        let incoming = try SettingsBackupCodec.makeDocument(
            groups: ["liveTVCategories": ["liveTV.categoryAppearance": .string("Grid")]],
            schemaVersion: 1, minReaderVersion: 1, app: app, now: Date())
        let (journal, directory) = temporaryJournal()
        defer { try? FileManager.default.removeItem(at: directory) }
        guard case .applied = try applyAll(incoming, to: rig, journal: journal) else { return XCTFail("not applied") }

        let reloaded = LiveTVCategoryPreferences.load(providerID: providerID, from: defaults)
        XCTAssertEqual(reloaded.appearance, .grid)
        XCTAssertEqual(reloaded.pinned, ["Sports"])
    }

    func testUnknownAndUnsupportedSettingsAreSkippedOnRealStores() throws {
        let rig = makeRig(pip: false)
        let incoming = try SettingsBackupCodec.makeDocument(
            groups: ["navigation": ["navigation.fourthTab": .string("forYou"), "navigation.hologram": .bool(true)],
                     "pictureInPicture": ["pip.backgroundPlayback": .bool(true)],
                     "someFutureGroup": ["x": .int(1)]],
            schemaVersion: 2, minReaderVersion: 1, app: app, now: Date())
        let preview = SettingsBackupPlanner.preview(try SettingsBackupCodec.decode(incoming), registry: rig.registry)
        XCTAssertEqual(preview.unrecognizedGroups, 1)
        XCTAssertEqual(preview.unrecognizedSettings, 2)
        XCTAssertEqual(preview.totalChanges, 1)
        XCTAssertFalse(rig.playback.backgroundPlaybackEnabled)
    }
    // MARK: Build 88.2: the type the app registers (runs in the app's own bundle context)

    func testTheDeclaredTypeIsRegisteredInTheAppBundleAndConformsToJsonAndData() throws {
        let declarations = try XCTUnwrap(Bundle.main.object(forInfoDictionaryKey: "UTExportedTypeDeclarations") as? [[String: Any]])
        XCTAssertTrue(declarations.contains { $0["UTTypeIdentifier"] as? String == SettingsBackupFileType.exportIdentifier })
        let type = SettingsBackupFileType.exportType
        XCTAssertTrue(type.conforms(to: .json))
        XCTAssertTrue(type.conforms(to: .data))
        XCTAssertEqual(type.preferredFilenameExtension, "kyrosettings")
        XCTAssertEqual(UTType(filenameExtension: "kyrosettings")?.identifier, SettingsBackupFileType.exportIdentifier)
    }

    func testAnExportedFileMatchesTheImporterTypes() throws {
        let type = SettingsBackupFileType.exportType
        XCTAssertTrue(SettingsBackupFileType.importerTypes.contains { type.conforms(to: $0) })
    }
}
#endif
