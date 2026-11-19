#if os(iOS) || KYRO_STANDALONE_TESTS
import Foundation
import Observation

/// The state behind Settings → Account & Connections → Backup & Restore. Importing only ever loads
/// a preview; nothing is written until `applySelected()`.
@MainActor @Observable
final class SettingsBackupModel {
    struct Banner: Equatable {
        enum Kind: Equatable { case success, warning, failure }
        let kind: Kind
        let text: String
    }

    var exportSelection: Set<SettingsBackupGroup> = SettingsBackupGroup.defaultSelection
    private(set) var preview: RestorePreview?
    var importSelection: Set<SettingsBackupGroup> = []
    private(set) var selectedSettingIDs: Set<String> = []
    private(set) var lastRestoredCount: Int?
    private(set) var banner: Banner?
    private(set) var undoAvailable = false
    private(set) var needsRecovery = false
    private(set) var restoreDate: Date?

    @ObservationIgnored private let registry: SettingsBackupRegistry
    @ObservationIgnored private let applier: SettingsBackupApplier
    @ObservationIgnored private let app: SettingsBackupAppInfo
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let notifications: NotificationCenter

    var availablePortableGroups: [SettingsBackupGroup] {
        SettingsBackupGroup.portable.filter { !registry.settings(in: $0).isEmpty }
    }

    var availableDeviceGroups: [SettingsBackupGroup] {
        SettingsBackupGroup.deviceSpecific.filter { !registry.settings(in: $0).isEmpty }
    }

    init(
        registry: SettingsBackupRegistry,
        journal: RestoreJournalStoring,
        app: SettingsBackupAppInfo,
        now: @escaping () -> Date = Date.init,
        notifications: NotificationCenter = .default
    ) {
        self.notifications = notifications
        self.registry = registry
        self.exportSelection = SettingsBackupGroup.defaultSelection.filter { !registry.settings(in: $0).isEmpty }
        self.applier = SettingsBackupApplier(registry: registry, journal: journal, now: now)
        self.app = app
        self.now = now
        refreshRestorePointState()
    }

    // MARK: Export

    func exportDocument() -> Data? {
        do {
            let data = try SettingsBackupExporter.export(registry: registry, groups: exportSelection, app: app, now: now())
            banner = nil
            return data
        } catch {
            banner = Banner(kind: .failure, text: error.localizedDescription)
            return nil
        }
    }

    /// The same backup as `exportDocument()`, as text for the clipboard.
    func exportText() -> String? {
        exportDocument().map { String(decoding: $0, as: UTF8.self) }
    }

    func didCopyExport() {
        banner = Banner(kind: .success, text: "Settings copied as text. Paste them into Backup & Restore → Paste Backup Text. The text has no sign-in details, server addresses or Live TV providers.")
    }

    var exportFilename: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return "Kyro Settings \(formatter.string(from: now()))"
    }

    func didExport(success: Bool, message: String? = nil) {
        banner = success
            ? Banner(kind: .success, text: "Settings exported. The file has no sign-in details, server addresses or Live TV providers.")
            : Banner(kind: .failure, text: message ?? "The export wasn't saved.")
    }

    // MARK: Import

    /// Reads a chosen file with a hard size limit, then validates it. The read is coordinated, so a
    /// file that is only a placeholder in iCloud Drive is downloaded first, and it runs off the main
    /// actor so a slow download never freezes the screen. Reading stops one byte past the limit so a
    /// file that grows while it is read cannot exceed it.
    func loadImport(from url: URL) async {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try await Task.detached(priority: .userInitiated) { try Self.readBackupFile(at: url) }.value
            loadImport(data: data)
        } catch let error as SettingsBackupError {
            reject(error)
        } catch {
            reject(.unreadable)
        }
    }

    nonisolated static func readBackupFile(at url: URL) throws -> Data {
        var coordinationError: NSError?
        var outcome: Result<Data, Error> = .failure(SettingsBackupError.unreadable)
        NSFileCoordinator(filePresenter: nil).coordinate(
            readingItemAt: url, options: [.withoutChanges], error: &coordinationError
        ) { readableURL in
            outcome = Result {
                if let size = try? readableURL.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                   size > SettingsBackupSafety.maxFileBytes {
                    throw SettingsBackupError.tooLarge
                }
                let handle = try FileHandle(forReadingFrom: readableURL)
                defer { try? handle.close() }
                return try handle.read(upToCount: SettingsBackupSafety.maxFileBytes + 1) ?? Data()
            }
        }
        if coordinationError != nil { throw SettingsBackupError.unreadable }
        return try outcome.get()
    }

    func loadImport(data: Data) {
        do {
            try loadPreview(data)
        } catch let error as SettingsBackupError {
            reject(error)
        } catch {
            reject(.malformed)
        }
    }

    /// Loads a backup pasted as text, through the same decoder, size limit, integrity check and
    /// preview as a file. Returns nil when the preview is ready, or the reason the text was refused.
    /// A refusal is returned rather than shown as a banner, so the paste screen can show it in place.
    func loadImport(text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            guard trimmed.utf8.count <= SettingsBackupSafety.maxFileBytes else { throw SettingsBackupError.tooLarge }
            try loadPreview(Data(trimmed.utf8))
            return nil
        } catch {
            preview = nil
            importSelection = []
            selectedSettingIDs = []
            return Self.pastedTextMessage(error as? SettingsBackupError ?? .malformed)
        }
    }

    private func loadPreview(_ data: Data) throws {
        let incoming = try SettingsBackupCodec.decode(data)
        let result = SettingsBackupPlanner.preview(incoming, registry: registry)
        preview = result
        importSelection = Set(result.groups.filter { $0.canRestore && !$0.group.isDeviceSpecific }.map(\.group))
        selectedSettingIDs = Set(result.groups.filter { importSelection.contains($0.group) }
            .flatMap { $0.items.filter { $0.status == .willChange }.map(\.id) })
        lastRestoredCount = nil
        banner = nil
    }

    /// File errors talk about "this file"; pasted text gets wording that fits what the person did.
    nonisolated static func pastedTextMessage(_ error: SettingsBackupError) -> String {
        switch error {
        case .tooLarge:
            "This text is too long to be a Kyro settings backup. A backup is at most \(SettingsBackupSafety.maxFileBytes / 1024) KB."
        case .empty:
            "Paste the backup text first."
        case .malformed, .notABackup, .unreadable:
            "This text isn't a Kyro settings backup. Paste the whole backup, from the first { to the last }."
        default:
            error.localizedDescription
        }
    }

    private func reject(_ error: SettingsBackupError) {
        preview = nil
        importSelection = []
        selectedSettingIDs = []
        banner = Banner(kind: .failure, text: error.localizedDescription)
    }

    /// Drops the loaded backup. Nothing was written, so there is nothing to undo.
    func cancelImport() {
        preview = nil
        importSelection = []
        selectedSettingIDs = []
    }

    func setImport(_ group: SettingsBackupGroup, enabled: Bool) {
        guard preview?.groups.first(where: { $0.group == group })?.canRestore == true else { return }
        if enabled { importSelection.insert(group) } else { importSelection.remove(group) }
        let ids = preview?.groups.first(where: { $0.group == group })?.items
            .filter { $0.status == .willChange }.map(\.id) ?? []
        for id in ids {
            if enabled { selectedSettingIDs.insert(id) } else { selectedSettingIDs.remove(id) }
        }
    }

    func setImport(_ id: String, enabled: Bool) {
        guard let group = preview?.groups.first(where: { $0.items.contains(where: { $0.id == id && $0.status == .willChange }) }),
              group.groupUnsupportedReason == nil else { return }
        if enabled { selectedSettingIDs.insert(id) } else { selectedSettingIDs.remove(id) }
        if group.items.contains(where: { selectedSettingIDs.contains($0.id) }) {
            importSelection.insert(group.group)
        } else {
            importSelection.remove(group.group)
        }
    }

    var selectedChangeCount: Int {
        selectedSettingIDs.count
    }

    // MARK: Apply, undo, recovery

    func applySelected() {
        guard let preview, selectedChangeCount > 0 else { return }
        switch applier.apply(preview: preview, selectedGroups: importSelection, selectedIDs: selectedSettingIDs) {
        case .nothingToApply:
            banner = Banner(kind: .warning, text: "Nothing needed to change.")
        case .applied(let changes, let undoable):
            lastRestoredCount = changes.count
            banner = Banner(kind: .success, text: undoable
                ? "Restored \(changes.count) setting\(changes.count == 1 ? "" : "s"). You can undo this."
                : "Restored \(changes.count) setting\(changes.count == 1 ? "" : "s"). Undo isn't available because Kyro couldn't keep a restore point.")
            self.preview = nil
            importSelection = []
            selectedSettingIDs = []
        case .failed(_, let reason, let rollback):
            if rollback.isComplete {
                banner = Banner(kind: .failure, text: "\(reason) Your earlier settings were put back.")
            } else {
                banner = Banner(kind: .failure, text: "\(reason) Kyro couldn't put back: \(titles(rollback.unrestored)). Reopen this screen to try again.")
            }
            self.preview = nil
            importSelection = []
            selectedSettingIDs = []
        }
        // Any outcome may have written values, even a rolled-back one, so screens reload either way.
        notifications.post(name: .kyroSettingsDidRestore, object: nil)
        refreshRestorePointState()
    }

    func undo() {
        let report = applier.undo()
        banner = undoBanner(report, verb: "Undid")
        notifications.post(name: .kyroSettingsDidRestore, object: nil)
        refreshRestorePointState()
    }

    func recoverInterruptedRestore() {
        let report = applier.recoverInterruptedRestore()
        banner = undoBanner(report, verb: "Rolled back")
        notifications.post(name: .kyroSettingsDidRestore, object: nil)
        refreshRestorePointState()
    }

    func refreshRestorePointState() {
        undoAvailable = applier.undoAvailable
        needsRecovery = applier.needsRecovery
        restoreDate = undoAvailable ? applier.restorePointDate : nil
    }

    private func undoBanner(_ report: UndoReport, verb: String) -> Banner {
        if !report.failed.isEmpty {
            let done = report.reverted.isEmpty ? "" : "\(verb) \(report.reverted.count). "
            return Banner(kind: .failure, text: "\(done)Kyro couldn't put back: \(titles(report.failed)). Try again.")
        }
        var parts: [String] = []
        if !report.reverted.isEmpty {
            parts.append("\(verb) \(report.reverted.count) setting\(report.reverted.count == 1 ? "" : "s").")
        }
        if !report.unchanged.isEmpty {
            parts.append("\(report.unchanged.count) already had the earlier value.")
        }
        if !report.changedSince.isEmpty {
            parts.append("Left \(titles(report.changedSince)) as it is now, because you changed it again.")
        }
        if parts.isEmpty { parts.append("Nothing needed to change.") }
        return Banner(kind: report.changedSince.isEmpty ? .success : .warning, text: parts.joined(separator: " "))
    }

    private func titles(_ ids: [String]) -> String {
        ids.map { registry.setting(id: $0)?.title ?? $0 }.joined(separator: ", ")
    }
}
#endif
