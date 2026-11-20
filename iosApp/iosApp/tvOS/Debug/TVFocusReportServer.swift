#if os(tvOS) && (DEBUG || KYRO_FOCUS_DIAGNOSTICS)
import SwiftUI
import Network
import Darwin

/// Explicit, foreground-only, authenticated one-shot export of a frozen sanitized report.
/// HTTP is not encrypted: use only a trusted LAN. No credentials or session cookies are used.
@MainActor
final class TVFocusReportServer: ObservableObject {
    static let shared = TVFocusReportServer()
    @Published private(set) var address = ""
    @Published private(set) var code = ""
    @Published private(set) var status = "Not sharing"
    private var listener: NWListener?
    private var connections: [UUID: NWConnection] = [:]
    private var downloadingConnections: Set<UUID> = []
    private var expiry: Task<Void, Never>?
    private var snapshot = Data()
    private var attempts = 0
    private var generation = UUID()
    private var authorized = false
    private var downloaded = false
    private var downloadToken = ""
    private var expired = false

    func start() {
        stop()
        guard TVRemoteFocusInspector.shared.enabled else { status = "Enable capture first"; return }
        guard let ip = Self.lanAddress() else { status = "No private IPv4 LAN address. Join a trusted Wi-Fi/Ethernet network."; return }
        do {
            snapshot = try TVRemoteFocusInspector.shared.report()
            authorized = false
            downloaded = false
            expired = false
            downloadToken = UUID().uuidString.lowercased()
            code = String(format: "%08d", UInt32.random(in: 0...99_999_999))
            attempts = 0
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(ip), port: .any)
            parameters.includePeerToPeer = false
            let server = try NWListener(using: parameters)
            let session = generation
            server.stateUpdateHandler = { [weak self, weak server] state in
                Task { @MainActor in
                    guard let self, self.generation == session else { return }
                    switch state {
                    case .ready:
                        if let port = server?.port { self.address = "http://\(ip):\(port.rawValue)" }
                        self.status = "Ready for one download; expires in 2 minutes"
                    case .failed:
                        self.stop(); self.status = "Network export failed. Check Local Network permission and LAN."
                    default: break
                    }
                }
            }
            server.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in
                    guard let self, self.generation == session else { connection.cancel(); return }
                    self.accept(connection)
                }
            }
            listener = server
            status = "Starting…"
            server.start(queue: .main)
            expiry = Task { [weak self] in
                try? await Task.sleep(for: .seconds(120))
                guard !Task.isCancelled else { return }
                self?.expireSession()
            }
        } catch {
            stop(); status = "Could not prepare diagnostic export"
        }
    }

    func stop() {
        generation = UUID()
        expiry?.cancel(); expiry = nil
        listener?.cancel(); listener = nil
        connections.values.forEach { $0.cancel() }; connections.removeAll()
        downloadingConnections.removeAll()
        snapshot = Data(); code = ""; address = ""; status = "Not sharing"
        authorized = false
        downloaded = false
        downloadToken = ""
        expired = false
    }

    private func accept(_ connection: NWConnection) {
        guard connections.count < 4, attempts < 5 else { connection.cancel(); return }
        // No remote/public clients, even if a router is forwarding a port.
        guard case .hostPort(let host, _) = connection.endpoint,
              Self.isPrivateIPv4(String(describing: host)) else { connection.cancel(); return }
        let id = UUID()
        connections[id] = connection
        connection.start(queue: .main)
        receive(connection, id: id, accumulated: Data())
        Task { [weak self, weak connection] in
            try? await Task.sleep(for: .seconds(5))
            guard let self, self.connections[id] != nil, !self.downloadingConnections.contains(id) else { return }
            connection?.cancel(); self.connections.removeValue(forKey: id)
        }
    }

    private func receive(_ connection: NWConnection, id: UUID, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, complete, error in
            Task { @MainActor in
                guard let self, self.connections[id] != nil else { return }
                var bytes = accumulated
                if let data { bytes.append(data) }
                guard bytes.count <= 4096, error == nil else { self.close(id); return }
                guard let text = String(data: bytes, encoding: .utf8) else { self.close(id); return }
                guard let separator = text.range(of: "\r\n\r\n") else {
                    if complete { self.close(id) } else { self.receive(connection, id: id, accumulated: bytes) }
                    return
                }
                let head = String(text[..<separator.lowerBound])
                let body = String(text[separator.upperBound...])
                let lines = head.components(separatedBy: "\r\n")
                let method = lines.first ?? ""
                let hosts = lines.filter { $0.lowercased().hasPrefix("host:") }
                let expectedHost = self.address.replacingOccurrences(of: "http://", with: "")
                guard hosts.count == 1,
                      hosts[0].dropFirst(5).trimmingCharacters(in: .whitespaces) == expectedHost,
                      !lines.contains(where: { $0.lowercased().hasPrefix("origin:") && $0.dropFirst(7).trimmingCharacters(in: .whitespaces) != self.address }) else {
                    self.close(id); return
                }
                if self.expired {
                    self.send(connection, id: id, status: "410 Gone", type: "text/html; charset=utf-8",
                              data: Data(Self.errorPage("This sharing session expired. Start a new share from the Apple TV.").utf8))
                    return
                }
                if method == "GET / HTTP/1.1" {
                    let page = """
                    <!doctype html><meta name="viewport" content="width=device-width"><title>Kyro focus report</title>
                    <h1>Kyro focus diagnostics</h1><p>Trusted LAN only. Enter the eight digits shown on your Apple TV. One download; five attempts maximum.</p>
                    <form method="POST" action="/authenticate"><label for="code">Eight-digit access code</label> <input id="code" name="code" type="password" inputmode="numeric" pattern="[0-9]{8}" maxlength="8" autocomplete="off" required><button>Continue</button></form>
                    """
                    self.send(connection, id: id, status: "200 OK", type: "text/html; charset=utf-8", data: Data(page.utf8))
                    return
                }
                if method == "GET /download/\(self.downloadToken) HTTP/1.1" {
                    guard self.authorized, !self.downloaded, !self.snapshot.isEmpty else {
                        self.send(connection, id: id, status: "403 Forbidden", type: "text/html; charset=utf-8", data: Data(Self.errorPage("This sharing session has expired or the report was already downloaded.").utf8)); return
                    }
                    // Authentication happened before the two-minute deadline. From this point
                    // expiry is suspended; the in-flight transfer must not be canceled.
                    self.expiry?.cancel(); self.expiry = nil
                    self.downloaded = true
                    self.downloadingConnections.insert(id)
                    self.send(connection, id: id, status: "200 OK", type: "application/json; charset=utf-8", data: self.snapshot, download: true)
                    return
                }
                guard method == "POST /authenticate HTTP/1.1",
                      !lines.contains(where: { $0.lowercased().hasPrefix("transfer-encoding:") }),
                      lines.filter({ $0.lowercased().hasPrefix("content-length:") }).count == 1,
                      let lengthLine = lines.first(where: { $0.lowercased().hasPrefix("content-length:") }),
                      let length = Int(lengthLine.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)),
                      (0...128).contains(length) else {
                    self.send(connection, id: id, status: "404 Not Found", type: "text/plain", data: Data()); return
                }
                guard body.utf8.count >= length else {
                    if complete { self.close(id) } else { self.receive(connection, id: id, accumulated: bytes) }
                    return
                }
                self.attempts += 1
                guard !self.code.isEmpty, body == "code=\(self.code)" else {
                    self.send(connection, id: id, status: "403 Forbidden", type: "text/html; charset=utf-8",
                              data: Data(Self.errorPage("Incorrect access code. Return to the Apple TV and check the code.").utf8),
                              stopAfter: self.attempts >= 5)
                    return
                }
                guard !self.snapshot.isEmpty else {
                    self.send(connection, id: id, status: "410 Gone", type: "text/html; charset=utf-8", data: Data(Self.errorPage("The frozen report is empty or no longer available.").utf8)); return
                }
                // Authorization is one-shot and bound to this LAN-only session. A confirmation
                // page gives Safari an ordinary, explicit attachment navigation to download.
                self.code = ""
                self.authorized = true
                self.expiry?.cancel(); self.expiry = nil
                let page = """
                <!doctype html><meta name="viewport" content="width=device-width"><title>Report ready</title>
                <h1>Report ready</h1><p>Your access code was accepted. The sanitized report is ready to download.</p>
                <form method="GET" action="/download/\(self.downloadToken)"><button type="submit">Download JSON</button></form>
                """
                self.send(connection, id: id, status: "200 OK", type: "text/html; charset=utf-8", data: Data(page.utf8))
            }
        }
    }

    private func send(_ connection: NWConnection, id: UUID, status: String, type: String, data: Data,
                      download: Bool = false, stopAfter: Bool = false) {
        var headers = "HTTP/1.1 \(status)\r\nContent-Type: \(type)\r\nContent-Length: \(data.count)\r\nConnection: close\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\nContent-Security-Policy: default-src 'none'; form-action 'self'; frame-ancestors 'none'\r\nReferrer-Policy: no-referrer\r\n"
        if download { headers += "Content-Disposition: attachment; filename=\"Kyro-TV-focus-diagnostic.json\"\r\n" }
        var response = Data((headers + "\r\n").utf8); response.append(data)
        let session = generation
        connection.send(content: response, completion: .contentProcessed { [weak self] error in
            Task { @MainActor in
                guard let self, self.generation == session else { return }
                self.close(id)
                if download { self.stop(); self.status = error == nil ? "Report sent; sharing stopped" : "Transfer failed; sharing stopped" }
                else if stopAfter { self.stop(); self.status = "Sharing stopped after five incorrect attempts" }
            }
        })
    }

    private func close(_ id: UUID) {
        downloadingConnections.remove(id)
        connections.removeValue(forKey: id)?.cancel()
    }

    private func expireSession() {
        guard !expired else { return }
        expired = true
        code = ""
        snapshot = Data()
        authorized = false
        status = "Sharing expired"
        // Keep the listener briefly so a stale Safari page receives an explicit 410 response.
        // It never serves report bytes after expiry and is then shut down automatically.
        let session = generation
        expiry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(60))
            guard !Task.isCancelled, let self, self.generation == session else { return }
            self.stop()
            self.status = "Sharing expired"
        }
    }

    private static func errorPage(_ message: String) -> String {
        "<!doctype html><meta name=\"viewport\" content=\"width=device-width\"><title>Report unavailable</title><h1>Report unavailable</h1><p>\(message)</p>"
    }

    private static func isPrivateIPv4(_ value: String) -> Bool {
        let parts = value.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4, parts.allSatisfy({ (0...255).contains($0) }) else { return false }
        return parts[0] == 10 || (parts[0] == 172 && (16...31).contains(parts[1])) || (parts[0] == 192 && parts[1] == 168)
    }

    private static func lanAddress() -> String? {
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0 else { return nil }
        defer { freeifaddrs(interfaces) }
        var cursor = interfaces
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            guard let address = entry.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_INET),
                  String(cString: entry.pointee.ifa_name).hasPrefix("en") else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                let ip = String(cString: host)
                if isPrivateIPv4(ip) { return ip }
            }
        }
        return nil
    }
}

struct TVFocusInspectorSettings: View {
    @ObservedObject private var inspector = TVRemoteFocusInspector.shared
    @ObservedObject private var export = TVFocusReportServer.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("REMOTE & FOCUS INSPECTOR — DIAGNOSTIC BUILD").font(.headline)
            Button(inspector.enabled ? "Stop capture" : "Start fresh capture") { inspector.setEnabled(!inspector.enabled) }
            Button(inspector.overlayVisible ? "Hide inspector (keep recording)" : "Show inspector") { inspector.toggleOverlay() }
            Button("Share frozen report on trusted LAN (2 minutes)") { export.start() }
                .disabled(!inspector.enabled)
            if !export.address.isEmpty {
                HStack(spacing: 28) {
                    QRCodeView(content: export.address, size: 220)
                        .padding(12).background(Color.white)
                    VStack(alignment: .leading) {
                        Text(export.address)
                        Text("One-time code: \(export.code)").font(.title3.monospacedDigit())
                        Text("iPhone: scan QR, enter code, download JSON.\nHTTP is not encrypted. Trusted LAN only.\nQR contains only the local address, not the code.")
                    }
                }
                Button("Stop sharing now") { export.stop() }
            }
            Text(export.status).font(.caption)
            Text("Capture is off by default; 512 events maximum. Backgrounding stops capture and sharing. Unknown causes remain unknown.").font(.caption)
        }
        .buttonStyle(TVSettingsPaneRowStyle())
        .onDisappear { export.stop() }
    }
}
#endif
