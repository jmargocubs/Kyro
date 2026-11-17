#if os(iOS)
import AVKit
import Foundation
import UIKit

// Build 88: the one place that names which Kyro settings a backup may carry.
//
// Every entry reads and writes through the store that already owns the setting. Nothing here
// touches the server, the Keychain, a provider, a library ID or a profile, and a setting that is not
// listed cannot be exported or restored. Excluded on purpose: server/profile/family values,
// Live TV providers and their credentials, provider-specific pins and hidden categories, recent
// categories, favorites, the selected Sports league or screen, experimental and internal flags,
// diagnostics, and authentication or pairing state.

/// The device-local player preferences a backup may carry, as their own setters. The synced player
/// settings (quality, speed, subtitles and so on) are deliberately absent: writing those enqueues a
/// server write.
@MainActor
protocol LocalPlaybackPreferences: AnyObject {
    var bufferAhead: BufferAheadMode { get set }
    var losslessAudioEnabled: Bool { get set }
    var backgroundPlaybackEnabled: Bool { get set }
    var deinterlaceMode: DeinterlacePreference { get set }
    var deinterlaceFieldRate: DeinterlaceFieldRatePreference { get set }
    var trueHDAtmosEnabled: Bool { get set }
}

@MainActor
final class PlayerSettingsLocalPlayback: LocalPlaybackPreferences {
    private let settings: PlayerSettings
    init(settings: PlayerSettings = .shared) { self.settings = settings }

    var bufferAhead: BufferAheadMode {
        get { settings.bufferAhead }
        set { settings.setBufferAhead(newValue) }
    }
    var losslessAudioEnabled: Bool {
        get { settings.losslessAudioEnabled }
        set { settings.setLosslessAudioEnabled(newValue) }
    }
    var backgroundPlaybackEnabled: Bool {
        get { settings.backgroundPlaybackEnabled }
        set { settings.setBackgroundPlaybackEnabled(newValue) }
    }
    var deinterlaceMode: DeinterlacePreference {
        get { settings.deinterlaceMode }
        set { settings.setDeinterlaceMode(newValue) }
    }
    var deinterlaceFieldRate: DeinterlaceFieldRatePreference {
        get { settings.deinterlaceFieldRate }
        set { settings.setDeinterlaceFieldRate(newValue) }
    }
    var trueHDAtmosEnabled: Bool {
        get { settings.trueHDAtmosEnabled }
        set { settings.setTrueHDAtmosEnabled(newValue) }
    }
}

enum SettingsBackupLiveRegistry {
    struct Dependencies {
        var navigation: KyroGlobalNavigationStore
        var downloads: DownloadSettings
        var playback: LocalPlaybackPreferences
        var defaults: UserDefaults
        var idiom: String
        var supportsPictureInPicture: Bool
    }

    private struct InvalidValue: Error {}

    @MainActor
    static var currentIdiom: String { UIDevice.current.userInterfaceIdiom == .pad ? "pad" : "phone" }

    @MainActor
    static func standard() -> SettingsBackupRegistry {
        make(Dependencies(
            navigation: KyroGlobalNavigationStore.shared,
            downloads: DownloadSettings.shared,
            playback: PlayerSettingsLocalPlayback(),
            defaults: .standard,
            idiom: currentIdiom,
            supportsPictureInPicture: AVPictureInPictureController.isPictureInPictureSupported()))
    }

    @MainActor
    static func make(_ d: Dependencies) -> SettingsBackupRegistry {
        var settings: [BackupSetting] = []

        // MARK: Navigation (portable)
        settings.append(enumSetting(
            "navigation.fourthTab", .navigation, "Fourth tab",
            label: { (tab: KyroFourthTab) in tab.title },
            read: { d.navigation.preferences.fourthTab },
            write: { d.navigation.preferences.fourthTab = $0 }))

        // MARK: Live TV categories (portable). Appearance and grouping only: pins, hidden and
        // recent categories are per provider and never leave the device.
        settings.append(enumSetting(
            "liveTV.categoryAppearance", .liveTVCategories, "Category layout",
            label: { (value: LiveTVCategoryAppearance) in value.rawValue },
            read: { LiveTVCategoryPreferences.load(providerID: nil, from: d.defaults).appearance },
            write: { value in
                var preferences = LiveTVCategoryPreferences.load(providerID: nil, from: d.defaults)
                preferences.appearance = value
                preferences.save(providerID: nil, to: d.defaults)
            }))
        settings.append(enumSetting(
            "liveTV.categoryGrouping", .liveTVCategories, "Category grouping",
            label: { (value: LiveTVCategoryGrouping) in value.rawValue },
            read: { LiveTVCategoryPreferences.load(providerID: nil, from: d.defaults).grouping },
            write: { value in
                var preferences = LiveTVCategoryPreferences.load(providerID: nil, from: d.defaults)
                preferences.grouping = value
                preferences.save(providerID: nil, to: d.defaults)
            }))

        // MARK: Guide layout (portable)
        settings.append(enumSetting(
            "liveTV.guideStyle", .guideLayout, "Watch screen guide",
            label: { (style: LiveTVEmbeddedGuideStyle) in style.title },
            read: { LiveTVEmbeddedGuideStyle.resolve(stored: d.defaults.string(forKey: LiveTVEmbeddedGuideStyle.defaultsKey)) },
            write: { d.defaults.set($0.rawValue, forKey: LiveTVEmbeddedGuideStyle.defaultsKey) }))

        // MARK: Sports sources (portable). The selected league, category and per-league tab are
        // session state and are not included.
        let sportsFlags: [(String, String, String)] = [
            ("sports.soccerSupplement", "Soccer extra statistics", KyroSportsSupplementFlag.defaultsKey),
            ("sports.wtaStats", "WTA match statistics", KyroSportsSupplementFlag.wtaStatsKey),
            ("sports.tennisNews", "Tennis news", KyroSportsSupplementFlag.tennisNewsKey),
            ("sports.atpStats", "ATP match statistics", KyroSportsSupplementFlag.tmlStatsKey),
            ("sports.tennisPlayerInfo", "Tennis player info", KyroSportsSupplementFlag.tennisPlayerInfoKey),
        ]
        for (id, title, key) in sportsFlags {
            settings.append(boolSetting(
                id, .sports, title,
                read: { KyroSportsSupplementFlag.isEnabled(key: key, defaults: d.defaults) },
                write: { d.defaults.set($0, forKey: key) }))
        }

        // MARK: Downloads (portable)
        settings.append(enumSetting(
            "downloads.preferredFormat", .downloads, "Download quality",
            label: { (format: DownloadFormat) in format.displayName },
            read: { DownloadFormat(rawValue: d.downloads.preferredFormat) ?? .original },
            write: { d.downloads.preferredFormat = $0.rawValue }))
        settings.append(boolSetting(
            "downloads.wifiOnly", .downloads, "Download on Wi-Fi only",
            read: { d.downloads.wifiOnly }, write: { d.downloads.wifiOnly = $0 }))
        settings.append(boolSetting(
            "downloads.defaultDeleteWatched", .downloads, "Delete after watching",
            read: { d.downloads.defaultDeleteWatched }, write: { d.downloads.defaultDeleteWatched = $0 }))
        settings.append(intSetting(
            "downloads.defaultMaxStorageGB", .downloads, "Storage limit", range: 0...1000,
            label: { $0 == 0 ? "Unlimited" : "\($0) GB" },
            read: { d.downloads.defaultMaxStorageGB }, write: { d.downloads.defaultMaxStorageGB = $0 }))
        settings.append(enumSetting(
            "downloads.sortOption", .downloads, "Downloads sort order",
            label: { (option: DownloadSortOption) in option.displayName },
            read: { d.downloads.sortOption },
            write: { d.downloads.sortOption = $0 }))
        settings.append(boolSetting(
            "downloads.keepWatched", .downloads, "Keep watched downloads",
            read: { d.downloads.keepWatchedDownloads }, write: { d.downloads.keepWatchedDownloads = $0 }))
        settings.append(intSetting(
            "downloads.simultaneous", .downloads, "Simultaneous downloads",
            range: 1...(DownloadSettings.simultaneousDownloadChoices.last ?? 4),
            read: { d.downloads.simultaneousDownloads }, write: { d.downloads.simultaneousDownloads = $0 }))

        // MARK: Playback options (device-specific)
        settings.append(enumSetting(
            "playback.bufferAhead", .playbackOptions, "Buffer ahead",
            label: { (mode: BufferAheadMode) in mode.label },
            read: { d.playback.bufferAhead }, write: { d.playback.bufferAhead = $0 }))
        settings.append(boolSetting(
            "playback.losslessAudio", .playbackOptions, "Lossless audio bridge",
            read: { d.playback.losslessAudioEnabled }, write: { d.playback.losslessAudioEnabled = $0 }))

        // MARK: Picture in Picture (device-specific)
        settings.append(boolSetting(
            "pip.backgroundPlayback", .pictureInPicture, "Keep playing in the background",
            unsupported: { d.supportsPictureInPicture ? nil : "Picture in Picture isn't available on this device." },
            read: { d.playback.backgroundPlaybackEnabled }, write: { d.playback.backgroundPlaybackEnabled = $0 }))

        // MARK: Advanced audio & video (device-specific)
        settings.append(enumSetting(
            "advancedAV.deinterlaceMode", .advancedAudioVideo, "Deinterlacing",
            label: { (mode: DeinterlacePreference) in mode.label },
            read: { d.playback.deinterlaceMode }, write: { d.playback.deinterlaceMode = $0 }))
        settings.append(enumSetting(
            "advancedAV.deinterlaceFieldRate", .advancedAudioVideo, "Deinterlace motion",
            label: { (rate: DeinterlaceFieldRatePreference) in rate.label },
            read: { d.playback.deinterlaceFieldRate }, write: { d.playback.deinterlaceFieldRate = $0 }))
        settings.append(boolSetting(
            "advancedAV.trueHDAtmos", .advancedAudioVideo, "TrueHD Atmos and DTS:X heights",
            read: { d.playback.trueHDAtmosEnabled }, write: { d.playback.trueHDAtmosEnabled = $0 }))

        // MARK: Navigation layout & appearance (device-specific). Saved screen positions are
        // coordinates for one device and are never exported.
        settings.append(enumSetting(
            "nav.style", .navigationLayout, "Navigation style",
            label: { (style: KyroNavigationPresentationStyle) in
                switch style { case .classic: "Classic"; case .glassDock: "Glass Dock"; case .thumbFan: "Thumb Fan" }
            },
            read: { d.navigation.preferences.style }, write: { d.navigation.preferences.style = $0 }))
        settings.append(enumSetting(
            "nav.startingEdge", .navigationLayout, "Starting edge",
            label: { (edge: KyroNavigationEdge) in edge.title },
            read: { d.navigation.preferences.startingEdge }, write: { d.navigation.preferences.startingEdge = $0 }))
        settings.append(enumSetting(
            "nav.idleBehavior", .navigationLayout, "When idle",
            label: { (value: KyroLiveTVNavigationIdleBehavior) in value.title },
            read: { d.navigation.preferences.idleBehavior }, write: { d.navigation.preferences.idleBehavior = $0 }))
        settings.append(boolSetting(
            "nav.autoCollapse", .navigationLayout, "Collapse automatically",
            read: { d.navigation.preferences.autoCollapse }, write: { d.navigation.preferences.autoCollapse = $0 }))
        settings.append(boolSetting(
            "nav.haptics", .navigationLayout, "Haptics",
            read: { d.navigation.preferences.hapticsEnabled }, write: { d.navigation.preferences.hapticsEnabled = $0 }))
        settings.append(boolSetting(
            "nav.thumbScrubbing", .navigationLayout, "Thumb scrubbing",
            read: { d.navigation.preferences.thumbScrubbing }, write: { d.navigation.preferences.thumbScrubbing = $0 }))
        settings.append(boolSetting(
            "nav.allowsDragging", .navigationLayout, "Drag to reposition",
            read: { d.navigation.preferences.allowsDragging }, write: { d.navigation.preferences.allowsDragging = $0 }))

        return SettingsBackupRegistry(settings: settings, deviceIdiom: d.idiom)
    }

    // MARK: Builders

    @MainActor
    private static func boolSetting(
        _ id: String, _ group: SettingsBackupGroup, _ title: String,
        unsupported: @escaping @MainActor () -> String? = { nil },
        read: @escaping @MainActor () -> Bool,
        write: @escaping @MainActor (Bool) -> Void
    ) -> BackupSetting {
        BackupSetting(
            id: id, group: group, title: title,
            validate: { if case .bool = $0 { true } else { false } },
            read: { .bool(read()) },
            write: { value in
                guard case .bool(let flag) = value else { throw InvalidValue() }
                write(flag)
            },
            unsupportedReason: unsupported,
            label: { if case .bool(let flag) = $0 { flag ? "On" : "Off" } else { $0.plainText } })
    }

    @MainActor
    private static func intSetting(
        _ id: String, _ group: SettingsBackupGroup, _ title: String, range: ClosedRange<Int>,
        label: @escaping @MainActor (Int) -> String = { String($0) },
        read: @escaping @MainActor () -> Int,
        write: @escaping @MainActor (Int) -> Void
    ) -> BackupSetting {
        BackupSetting(
            id: id, group: group, title: title,
            validate: { if case .int(let number) = $0 { range.contains(number) } else { false } },
            read: { .int(read()) },
            write: { value in
                guard case .int(let number) = value, range.contains(number) else { throw InvalidValue() }
                write(number)
            },
            label: { if case .int(let number) = $0 { label(number) } else { $0.plainText } })
    }

    @MainActor
    private static func enumSetting<E: RawRepresentable & CaseIterable>(
        _ id: String, _ group: SettingsBackupGroup, _ title: String,
        label: @escaping @MainActor (E) -> String,
        read: @escaping @MainActor () -> E,
        write: @escaping @MainActor (E) -> Void
    ) -> BackupSetting where E.RawValue == String {
        BackupSetting(
            id: id, group: group, title: title,
            validate: { if case .string(let raw) = $0 { E(rawValue: raw) != nil } else { false } },
            read: { .string(read().rawValue) },
            write: { value in
                guard case .string(let raw) = value, let parsed = E(rawValue: raw) else { throw InvalidValue() }
                write(parsed)
            },
            label: { value in
                if case .string(let raw) = value, let parsed = E(rawValue: raw) { label(parsed) } else { value.plainText }
            })
    }
}
#endif
