#if os(iOS)
import SwiftUI
import KyroIdentity
import KyroProviders

/// An entry into the existing media-server setup, not a replacement Movies/Series interface.
/// Passwords remain in this view only until the authentication task completes.
struct KyroJellyfinSetupView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppRouter.self) private var router
    @State private var url = ""
    @State private var username = ""
    @State private var password = ""
    @State private var busy = false
    @State private var errorText: String?
    @State private var accounts: [ProviderAccount] = []
    @State private var reconnecting: ProviderAccountRef?
    @State private var removing: ProviderAccountRef?
    var onConnected: (() -> Void)?
    var onSiloSelected: (() -> Void)?

    private let connections = KyroJellyfinConnections.shared

    var body: some View {
        NavigationStack {
            Form {
                Section("Jellyfin") {
                    if reconnecting == nil {
                        TextField("Server URL", text: $url)
                            .textContentType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                            .accessibilityIdentifier("jellyfinServerURL")
                    } else {
                        Text(accounts.first(where: { $0.id == reconnecting?.id })?.endpoint ?? "Jellyfin")
                            .foregroundStyle(.secondary)
                    }
                    TextField("Username", text: $username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("jellyfinUsername")
                    SecureField("Password", text: $password)
                        .accessibilityIdentifier("jellyfinPassword")
                    Button(reconnecting == nil ? "Connect Jellyfin" : "Reconnect Jellyfin") {
                        Task { await connect() }
                    }
                    .disabled(busy || username.isEmpty || password.isEmpty || (reconnecting == nil && url.isEmpty))
                    .accessibilityIdentifier("jellyfinConnect")
                    if busy { ProgressView() }
                    if let errorText { Text(errorText).foregroundStyle(.red) }
                }
                if !accounts.isEmpty {
                    Section("Saved Jellyfin servers") {
                        ForEach(accounts, id: \.id) { account in
                            let ref = ProviderAccountRef(id: account.id, kind: .jellyfin)
                            VStack(alignment: .leading, spacing: 6) {
                                Text(account.label)
                                Text(connections.connectionErrors[ref] ??
                                     (connections.connectedAccounts.contains(ref) ? "Connected" : "Saved"))
                                    .font(.footnote).foregroundStyle(.secondary)
                                HStack {
                                    Button("Reconnect") { reconnecting = ref; errorText = nil }
                                    Spacer()
                                    Button("Remove", role: .destructive) { removing = ref }
                                }
                                .buttonStyle(.borderless)
                            }
                        }
                    }
                }
                Section("Other media servers") {
                    Button("Connect Silo") {
                        dismiss()
                        onSiloSelected?()
                        router.resetToServerSetup()
                    }
                }
            }
            .navigationTitle("Add Media Server")
            .toolbar { ToolbarItem(placement: .cancellationAction) {
                Button("Done") { dismiss() }
            } }
            .confirmationDialog("Remove this Jellyfin server?", isPresented: Binding(
                get: { removing != nil }, set: { if !$0 { removing = nil } })) {
                    Button("Remove Server", role: .destructive) {
                        guard let ref = removing else { return }
                        removing = nil
                        Task {
                            do { try await connections.remove(ref); await reload() }
                            catch { errorText = error.localizedDescription }
                        }
                    }
                } message: {
                    Text("Kyro profiles, PINs, and other providers will stay intact.")
                }
        }
        .task { await connections.restore(); await reload() }
    }

    private func reload() async {
        accounts = (try? await KyroLocalIdentityRuntime.shared.providerRegistry()?.storedAccounts())?
            .filter { $0.provider == ProviderKind.jellyfin.rawValue } ?? []
    }

    private func connect() async {
        busy = true
        errorText = nil
        defer { busy = false; password = "" }
        do {
            if let reconnecting {
                try await connections.reconnect(reconnecting, username: username, password: password)
            } else {
                _ = try await connections.connect(url: url, username: username, password: password)
            }
            await reload()
            onConnected?()
            dismiss()
        } catch {
            // The client maps transport and HTTP failures to nonsecret errors.
            errorText = error.localizedDescription
        }
    }
}
#endif
