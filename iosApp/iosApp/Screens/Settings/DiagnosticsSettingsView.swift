#if os(iOS)
import SwiftUI

struct DiagnosticsSettingsView: View {
    @Bindable var model: DiagnosticsViewModel
    let profile: UserProfile?
    @Environment(\.locale) private var locale

    var body: some View {
        List {
            availabilitySection
            loggingSection
            pendingSection
            manualSection
            sentHistorySection
        }
        .settingsListChrome()
        .navigationTitle(Text(.settingsDiagnostics))
        .siloNavigationTitleDisplayMode(.inline)
        .siloToolbarColorSchemeDark()
        .task {
            await model.load(profile: profile)
        }
    }

    private var availabilitySection: some View {
        Section {
            LabeledContent {
                Text(model.featureState.title)
            } label: {
                Text(.diagnosticsRowStatus)
            }
            .accessibilityElement(children: .combine)
            LabeledContent {
                Text(model.destinationServerName)
            } label: {
                Text(.diagnosticsRowDestination)
            }
            .accessibilityElement(children: .combine)
        } header: {
            Text(.diagnosticsSectionFeatureState)
        } footer: {
            if model.featureState == .offline {
                Text(.diagnosticsAvailabilityOfflineDetail)
            }
        }
        .listRowBackground(Color.siloGroupedCell)
    }

    private var loggingSection: some View {
        Section {
            Toggle("Debug Logging", isOn: $model.debugLoggingEnabled)
                .tint(.siloSwitchOn)
        } footer: {
            Text("Technical logging is stored on this device. Crash-report consent and sharing destination are managed under Privacy.")
        }
        .listRowBackground(Color.siloGroupedCell)
    }

    private var pendingSection: some View {
        Section {
            if model.pendingReports.isEmpty {
                Text(.diagnosticsPendingNone)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(model.pendingReports) { report in
                    NavigationLink {
                        DiagnosticsReportDetailView(report: report, model: model)
                    } label: {
                        DiagnosticsPendingReportRow(report: report)
                    }
                    .swipeActions {
                        Button(.diagnosticsEraseConfirm, role: .destructive) {
                            Task { await model.delete(report) }
                        }
                    }
                }
            }
        } header: {
            Text(.diagnosticsSectionPending(model.pendingReports.count))
        }
        .listRowBackground(Color.siloGroupedCell)
    }

    private var manualSection: some View {
        Section {
            Button(.settingsDiagnosticsSend, systemImage: "paperplane.fill") {
                Task { await model.createAndSendManualReport() }
            }
            .disabled(!model.featureState.isUploadAvailable || model.isWorking)

            if !model.debugLoggingEnabled {
                Label(
                    .diagnosticsSendDebugOffFooterTv,
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.footnote)
                .foregroundStyle(.orange)
            }

            if model.isWorking {
                ProgressView {
                    Text(.diagnosticsPreparing)
                }
            }

            if let notice = model.notice {
                Text(verbatim: notice.text(in: locale))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        } footer: {
            if model.selectedDestination == .hosted {
                Text(.diagnosticsManualHostedFooter)
            } else {
                Text(.diagnosticsManualSelfHostedFooter)
            }
        }
        .listRowBackground(Color.siloGroupedCell)
    }

    private var sentHistorySection: some View {
        Section {
            if model.sentHistory.isEmpty {
                Text(.diagnosticsSentHistoryNone)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(model.sentHistory) { item in
                    LabeledContent {
                        Text(item.sentAtDate ?? .distantPast, format: .dateTime.month().day().hour().minute())
                            .foregroundStyle(.secondary)
                    } label: {
                        Text(verbatim: item.shortID)
                            .textSelection(.enabled)
                    }
                    .contextMenu {
                        Button(.diagnosticsCopyId, systemImage: "doc.on.doc") {
                            UIPasteboard.general.string = item.shortID
                        }
                    }
                }
            }
        } header: {
            Text(.diagnosticsSectionSentHistory)
        }
        .listRowBackground(Color.siloGroupedCell)
    }

}

private extension DiagnosticsSentReport {
    var sentAtDate: Date? {
        DiagnosticsDates.date(from: sentAt)
    }
}
#endif
