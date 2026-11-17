#if os(iOS)
import SwiftUI
import UniformTypeIdentifiers

struct SettingsBackupFileDocument: FileDocument {
    static var readableContentTypes: [UTType] { [SettingsBackupFileType.exportType, .json] }
    var data: Data

    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

/// Settings → Account & Connections → Backup & Restore.
struct SettingsBackupView: View {
    @State private var model: SettingsBackupModel
    @State private var exportDocument: SettingsBackupFileDocument?
    @State private var showsExporter = false
    @State private var showsImporter = false
    @State private var confirmsApply = false

    init() {
        let info = Bundle.main.infoDictionary
        _model = State(initialValue: SettingsBackupModel(
            registry: SettingsBackupLiveRegistry.standard(),
            journal: FileRestoreJournalStore.standard(),
            app: SettingsBackupAppInfo(
                version: info?["CFBundleShortVersionString"] as? String ?? "",
                build: info?["CFBundleVersion"] as? String ?? "",
                platform: "iOS",
                idiom: SettingsBackupLiveRegistry.currentIdiom)))
    }

    var body: some View {
        List {
            if let banner = model.banner { bannerSection(banner) }
            if model.needsRecovery { recoverySection }
            if let preview = model.preview {
                previewSections(preview)
            } else {
                exportSections
                importSection
                if model.undoAvailable { undoSection }
            }
        }
        .settingsListChrome()
        .navigationTitle("Backup & Restore")
        .siloNavigationTitleDisplayMode(.inline)
        .siloToolbarColorSchemeDark()
        .fileExporter(
            isPresented: $showsExporter, document: exportDocument,
            contentType: SettingsBackupFileType.exportType, defaultFilename: model.exportFilename
        ) { result in
            switch result {
            case .success: model.didExport(success: true)
            case .failure(let error): model.didExport(success: false, message: error.localizedDescription)
            }
            exportDocument = nil
        }
        .fileImporter(isPresented: $showsImporter, allowedContentTypes: SettingsBackupFileType.importerTypes) { result in
            switch result {
            case .success(let url): Task { await model.loadImport(from: url) }
            case .failure: model.didExport(success: false, message: "Kyro couldn't open that file.")
            }
        }
        .confirmationDialog(
            "Apply \(model.selectedChangeCount) change\(model.selectedChangeCount == 1 ? "" : "s")?",
            isPresented: $confirmsApply, titleVisibility: .visible
        ) {
            Button("Apply Changes") { model.applySelected() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Only the groups you selected change. Everything else stays as it is, and you can undo this afterwards.")
        }
        .onAppear {
            model.refreshRestorePointState()
        }
    }

    // MARK: Sections

    private func bannerSection(_ banner: SettingsBackupModel.Banner) -> some View {
        Section {
            Label {
                Text(banner.text).fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: banner.kind == .success ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(banner.kind == .success ? Color.green : Color.orange)
            }
            .foregroundStyle(Color.siloOnSurface)
            .accessibilityElement(children: .combine)
        }
        .listRowBackground(Color.siloGroupedCell)
    }

    private var recoverySection: some View {
        Section {
            Button("Roll Back Interrupted Restore") { model.recoverInterruptedRestore() }
        } footer: {
            Text("A restore didn't finish. Rolling back puts the earlier values back for the settings it changed.")
        }
        .listRowBackground(Color.siloGroupedCell)
    }

    @ViewBuilder private var exportSections: some View {
        Section {
            ForEach(SettingsBackupGroup.portable) { group in exportToggle(group) }
        } header: {
            Text("Export")
        } footer: {
            Text("Saves these preferences to a file. It never includes sign-in details, server addresses, Live TV providers, or anything from your profile.")
        }
        .listRowBackground(Color.siloGroupedCell)

        Section {
            ForEach(SettingsBackupGroup.deviceSpecific) { group in exportToggle(group) }
        } header: {
            Text("Device-Specific (Off by Default)")
        } footer: {
            Text("These only restore onto the same kind of device, an iPhone to an iPhone or an iPad to an iPad.")
        }
        .listRowBackground(Color.siloGroupedCell)

        Section {
            Button {
                if let data = model.exportDocument() {
                    exportDocument = SettingsBackupFileDocument(data: data)
                    showsExporter = true
                }
            } label: {
                Label("Export Settings…", systemImage: "square.and.arrow.up")
            }
            .disabled(model.exportSelection.isEmpty)
            .accessibilityIdentifier("settingsBackup.export")
        }
        .listRowBackground(Color.siloGroupedCell)
    }

    private func exportToggle(_ group: SettingsBackupGroup) -> some View {
        Toggle(isOn: Binding(
            get: { model.exportSelection.contains(group) },
            set: { isOn in
                if isOn { model.exportSelection.insert(group) } else { model.exportSelection.remove(group) }
            }
        )) {
            groupLabel(group)
        }
        .tint(.siloSwitchOn)
    }

    private func groupLabel(_ group: SettingsBackupGroup) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(group.title).foregroundStyle(Color.siloOnSurface)
            Text(group.summary).font(.footnote).foregroundStyle(Color.siloSecondaryText)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var importSection: some View {
        Section {
            Button {
                showsImporter = true
            } label: {
                Label("Import Settings…", systemImage: "square.and.arrow.down")
            }
            .disabled(model.needsRecovery)
            .accessibilityIdentifier("settingsBackup.import")
        } footer: {
            Text(model.needsRecovery
                 ? "Roll back the interrupted restore before importing again."
                 : "You'll see what would change first. Nothing is applied until you confirm.")
        }
        .listRowBackground(Color.siloGroupedCell)
    }

    private var undoSection: some View {
        Section {
            Button { model.undo() } label: {
                Label("Undo Last Restore", systemImage: "arrow.uturn.backward")
            }
            .accessibilityIdentifier("settingsBackup.undo")
        } footer: {
            Text("\(model.restoreDate.map { "Restored \($0.formatted(date: .abbreviated, time: .shortened)). " } ?? "")Puts back the values the last restore changed. A setting you changed since then is left as it is.")
        }
        .listRowBackground(Color.siloGroupedCell)
    }

    // MARK: Preview

    @ViewBuilder
    private func previewSections(_ preview: RestorePreview) -> some View {
        Section {
            Text(previewSummary(preview))
                .foregroundStyle(Color.siloOnSurface)
                .fixedSize(horizontal: false, vertical: true)
        } header: {
            Text("Preview")
        } footer: {
            if preview.unrecognizedSettings > 0 {
                Text("\(preview.unrecognizedSettings) setting\(preview.unrecognizedSettings == 1 ? "" : "s") in this file aren't known to this version of Kyro and will be skipped.")
            }
        }
        .listRowBackground(Color.siloGroupedCell)

        ForEach(preview.groups) { group in
            Section {
                Toggle(isOn: Binding(
                    get: { model.importSelection.contains(group.group) },
                    set: { model.setImport(group.group, enabled: $0) }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(group.group.title).foregroundStyle(Color.siloOnSurface)
                        Text(groupStatus(group)).font(.footnote).foregroundStyle(Color.siloSecondaryText)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }
                .tint(.siloSwitchOn)
                .disabled(!group.canRestore)
                ForEach(group.items) { item in previewRow(item) }
            } header: {
                if group.group.isDeviceSpecific { Text("Device-specific") }
            }
            .listRowBackground(Color.siloGroupedCell)
        }

        Section {
            Button("Apply \(model.selectedChangeCount) Change\(model.selectedChangeCount == 1 ? "" : "s")…") {
                confirmsApply = true
            }
            .disabled(model.selectedChangeCount == 0)
            .accessibilityIdentifier("settingsBackup.apply")
            Button("Cancel Import", role: .cancel) { model.cancelImport() }
                .accessibilityIdentifier("settingsBackup.cancel")
        }
        .listRowBackground(Color.siloGroupedCell)
    }

    private func previewSummary(_ preview: RestorePreview) -> String {
        var text = preview.totalChanges == 0
            ? "This backup matches your current settings."
            : "\(preview.totalChanges) setting\(preview.totalChanges == 1 ? "" : "s") would change."
        if let app = preview.app, !app.version.isEmpty { text += " Saved by Kyro \(app.version) (\(app.build))." }
        if preview.isNewerThanSupported { text += " It was saved by a newer Kyro; only the settings this version knows are shown." }
        return text
    }

    private func groupStatus(_ group: RestorePreviewGroup) -> String {
        if let reason = group.groupUnsupportedReason { return "Not restored. \(reason)" }
        switch group.changeCount {
        case 0: return "Nothing to change"
        case 1: return "1 change"
        default: return "\(group.changeCount) changes"
        }
    }

    private func previewRow(_ item: RestorePreviewItem) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(item.title).foregroundStyle(Color.siloOnSurface)
            switch item.status {
            case .willChange:
                Text("\(item.current ?? "—") → \(item.incoming)")
                    .font(.footnote.weight(.medium)).foregroundStyle(Color.siloOnSurface.opacity(0.85))
            case .unchanged:
                Text("Already \(item.incoming). No change.")
                    .font(.footnote).foregroundStyle(Color.siloSecondaryText)
            case .unsupported(let reason):
                Text("Skipped. \(reason)").font(.footnote).foregroundStyle(Color.siloSecondaryText)
            case .invalid(let reason):
                Text("Skipped. \(reason)").font(.footnote).foregroundStyle(Color.siloSecondaryText)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText(item))
    }

    private func accessibilityText(_ item: RestorePreviewItem) -> String {
        switch item.status {
        case .willChange: "\(item.title). Will change from \(item.current ?? "unknown") to \(item.incoming)."
        case .unchanged: "\(item.title). Already \(item.incoming). No change."
        case .unsupported(let reason): "\(item.title). Skipped. \(reason)"
        case .invalid(let reason): "\(item.title). Skipped. \(reason)"
        }
    }
}
#endif
