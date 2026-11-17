#if os(iOS)
import SwiftUI
import Network
import Observation

extension LiveTVPairingLink: Identifiable {
    var id: String { sessionID }
}

/// Receives a scanned pairing link (from the system Camera or any `kyro://livetv-pair` URL) and
/// holds it until the send screen is on screen.
@MainActor
@Observable
final class KyroSendToAppleTVInbox {
    static let shared = KyroSendToAppleTVInbox()
    var link: LiveTVPairingLink?
    private init() {}

    /// Returns true when the URL was a pairing link and has been taken.
    @discardableResult
    func receive(_ url: URL) -> Bool {
        guard let link = LiveTVPairingLink(url: url) else { return false }
        self.link = link
        return true
    }
}

/// Presents the send screen over the whole app when a pairing link arrives.
struct KyroSendToAppleTVPresenter: ViewModifier {
    @State private var inbox = KyroSendToAppleTVInbox.shared

    func body(content: Content) -> some View {
        content.sheet(item: Binding(get: { inbox.link }, set: { if $0 == nil { inbox.link = nil } })) { link in
            KyroSendToAppleTVView(service: .shared, link: link)
        }
    }
}

/// A Live TV settings row that opens the send screen without a scanned link.
struct KyroSendToAppleTVRow: View {
    @Bindable var service: LiveTVService
    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented = true
        } label: {
            Label("Send provider to Apple TV", systemImage: "appletv")
        }
        .sheet(isPresented: $isPresented) {
            KyroSendToAppleTVView(service: service, link: nil)
        }
    }
}

/// Sends a saved Live TV provider to an Apple TV, so nothing long is typed with the Siri Remote.
///
/// The phone authenticates the TV first. Nothing leaves the phone until the person has seen the
/// code, picked a provider and tapped Send, and the Apple TV still asks its own user to Allow.
struct KyroSendToAppleTVView: View {
    @Bindable var service: LiveTVService
    let link: LiveTVPairingLink?

    @Environment(\.dismiss) private var dismiss
    @State private var client = LiveTVPairingClient()
    @State private var browser = LiveTVPairingBrowser()
    @State private var selectedTV: LiveTVPairingBrowser.TV?
    @State private var codeInput = ""
    @State private var providerID: UUID?
    @State private var usedCode = ""

    var body: some View {
        NavigationStack {
            Form {
                switch client.state {
                case .idle: chooser
                case .connecting: progress("Connecting to your Apple TV…")
                case .ready(let tvName): readyToSend(tvName: tvName)
                case .sending: progress("Waiting for approval on your Apple TV…")
                case .sent: result(title: "Sent to Apple TV", detail: "Kyro is loading your channels there.", isError: false)
                case .failed(let failure): result(title: "Pairing did not finish", detail: failure.userMessage, isError: true)
                }
            }
            .navigationTitle("Send to Apple TV")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(client.isFinished ? "Done" : "Cancel") {
                        if !client.isFinished { client.cancel() }
                        dismiss()
                    }
                }
            }
        }
        .task {
            providerID = providerID ?? service.selectedProviderID ?? service.providers.first?.id
            if let link {
                connect(link)
            } else {
                browser.start()
            }
        }
        .onDisappear {
            browser.stop()
            if !client.isFinished { client.cancel() }
        }
        .interactiveDismissDisabled(isBusy)
    }

    private var isBusy: Bool {
        switch client.state {
        case .connecting, .sending: true
        default: false
        }
    }

    // MARK: Steps

    @ViewBuilder
    private var chooser: some View {
        Section {
            if browser.tvs.isEmpty {
                HStack(spacing: 12) {
                    ProgressView()
                    Text(browser.isDenied ? "Allow Local Network access for Kyro in Settings." : "Looking for Apple TVs…")
                        .foregroundStyle(.secondary)
                }
            }
            ForEach(browser.tvs) { tv in
                Button {
                    selectedTV = tv
                } label: {
                    HStack {
                        Label(tv.name, systemImage: "appletv")
                        Spacer()
                        if selectedTV == tv { Image(systemName: "checkmark.circle.fill") }
                    }
                }
                .foregroundStyle(.primary)
            }
        } header: {
            Text("Apple TV")
        } footer: {
            Text("On your Apple TV, open Live TV → Providers → Set up with phone. Or scan the QR code there with the iPhone camera.")
        }
        Section {
            TextField("ABCDE-FGHJK", text: $codeInput)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .font(.system(.title3, design: .monospaced))
            Button("Connect") {
                if let selectedTV { connect(tv: selectedTV) }
            }
            .disabled(selectedTV == nil || !LiveTVPairingCrypto.isWellFormed(code: codeInput))
        } header: {
            Text("Code from your TV")
        }
    }

    @ViewBuilder
    private func readyToSend(tvName: String) -> some View {
        Section {
            ForEach(service.providers) { provider in
                Button {
                    providerID = provider.id
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(provider.name)
                            Text(provider.kind == .xtream ? "Xtream Codes" : "M3U playlist")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if providerID == provider.id { Image(systemName: "checkmark.circle.fill") }
                    }
                }
                .foregroundStyle(.primary)
            }
        } header: {
            Text("Provider to send")
        } footer: {
            Text("Check that your \(tvName) shows the code \(LiveTVPairingCrypto.displayCode(usedCode)). Your credentials are encrypted and only leave this iPhone when you tap Send.")
        }
        Section {
            Button("Send to \(tvName)") { sendSelected() }
                .disabled(providerID == nil)
        }
    }

    private func progress(_ text: String) -> some View {
        Section {
            HStack(spacing: 12) { ProgressView(); Text(text) }
        }
    }

    private func result(title: String, detail: String, isError: Bool) -> some View {
        Section {
            Label(title, systemImage: isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(isError ? Color.orange : Color.green)
            Text(detail).foregroundStyle(.secondary)
            if isError, link == nil {
                Button("Try Again") { client.cancel(); resetToChooser() }
            }
        }
    }

    // MARK: Actions

    private func connect(_ link: LiveTVPairingLink) {
        usedCode = link.code
        let host = NWEndpoint.Host(link.host)
        guard let port = NWEndpoint.Port(rawValue: link.port) else { return }
        client.connect(to: .hostPort(host: host, port: port), sessionID: link.sessionID, code: link.code)
    }

    private func connect(tv: LiveTVPairingBrowser.TV) {
        usedCode = codeInput
        client.connect(to: tv.endpoint, sessionID: tv.sessionID, code: codeInput)
    }

    private func sendSelected() {
        guard let providerID, let payload = service.pairingPayload(for: providerID) else { return }
        client.send(payload)
    }

    private func resetToChooser() {
        client = LiveTVPairingClient()
        selectedTV = nil
        codeInput = ""
        browser.start()
    }
}
#endif
