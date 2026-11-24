#if os(tvOS)
import Foundation
import Network
import Observation
import UIKit
import os

/// Receives a Live TV provider from the Kyro iPhone app on the local network.
///
/// The TV listens on a random TCP port, advertises it over Bonjour with the public session id, and
/// shows a QR and a short code. Everything security-relevant lives in `LiveTVPairingSession`; this
/// class owns the sockets, the countdown and the hand-off to the existing provider store. The
/// provider is saved only after the TV user presses Allow.
@MainActor
@Observable
final class TVLiveTVPairingReceiver {
    enum Status: Equatable {
        case idle
        case starting
        case waitingForPhone
        case phoneConnected(deviceName: String)
        case awaitingApproval(LiveTVPairingPayload.Summary, deviceName: String)
        case saving
        case completed(providerName: String)
        case failed(LiveTVPairingFailure)
        case unavailable
    }

    private(set) var status: Status = .idle
    private(set) var link: LiveTVPairingLink?
    private(set) var displayCode = ""
    private(set) var remaining: TimeInterval = 0

    private let service: LiveTVService
    @ObservationIgnored private var session: LiveTVPairingSession?
    @ObservationIgnored private var listener: NWListener?
    @ObservationIgnored private var connection: NWConnection?
    @ObservationIgnored private var buffer = LiveTVPairingFrameBuffer()
    @ObservationIgnored private var countdown: Task<Void, Never>?
    /// Static text only: provider data never reaches the log.
    private static let log = Logger(subsystem: "com.cubbiestream.kyro", category: "livetv-pairing")

    init(service: LiveTVService) { self.service = service }

    var isFinished: Bool {
        switch status {
        case .completed, .failed, .unavailable: true
        default: false
        }
    }

    // MARK: Lifecycle

    /// Begins a fresh session. Any session in progress is cancelled first, so a code is never reused.
    func start() {
        teardown()
        let tvName = UIDevice.current.name
        session = LiveTVPairingSession(tvName: tvName)
        displayCode = session?.displayCode ?? ""
        link = nil
        status = .starting
        startListener()
        startCountdown()
    }

    func cancel() {
        session?.cancel()
        sendAndClose(.failure(.cancelled))
        finish(.failed(.cancelled))
    }

    func stop() { teardown(); status = .idle }

    /// The TV user pressed Allow.
    func approve() {
        guard var current = session else { return }
        guard case .awaitingApproval = status else { return }
        let result = current.approve(now: Date())
        session = current
        switch result {
        case .failure(let failure):
            sendAndClose(.failure(failure))
            finish(.failed(failure))
        case .success(let payload):
            status = .saving
            save(payload)
        }
    }

    /// The TV user pressed Decline.
    func decline() {
        session?.reject()
        sendAndClose(.failure(.rejected))
        finish(.failed(.rejected))
    }

    // MARK: Saving

    private func save(_ payload: LiveTVPairingPayload) {
        do {
            let id = try service.savePairedProvider(payload)
            Self.log.notice("Pairing completed; provider saved")
            send(LiveTVPairingFrame(type: .result, ok: true))
            closeConnectionSoon()
            finish(.completed(providerName: payload.name))
            // The channel catalog and guide load through the same path a typed provider uses.
            Task { await service.startSetup(providerID: id) }
        } catch {
            Self.log.error("Pairing failed to save provider")
            send(LiveTVPairingFrame(type: .result, ok: false, error: .invalidProvider))
            closeConnectionSoon()
            finish(.failed(.invalidProvider))
        }
    }

    // MARK: Network

    private func startListener() {
        do {
            let listener = try NWListener(using: .tcp)
            if let session {
                listener.service = NWListener.Service(
                    name: session.tvName, type: LiveTVPairing.bonjourType,
                    txtRecord: NWTXTRecord(["v": String(LiveTVPairing.version), "sid": session.sessionIDString,
                                            "n": session.tvName]))
            }
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in self?.listenerStateChanged(state) }
            }
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in self?.accept(connection) }
            }
            self.listener = listener
            listener.start(queue: .main)
        } catch {
            Self.log.error("Pairing listener could not start")
            finish(.unavailable)
        }
    }

    private func listenerStateChanged(_ state: NWListener.State) {
        switch state {
        case .ready:
            guard let session, let port = listener?.port?.rawValue,
                  let host = Self.localIPv4Address() else {
                finish(.unavailable)
                return
            }
            link = LiveTVPairingLink(sessionID: session.sessionIDString, code: session.code, host: host, port: port)
            if status == .starting { status = .waitingForPhone }
        case .failed, .cancelled:
            if !isFinished, !(session?.isTerminal ?? true) { finish(.unavailable) }
        default:
            break
        }
    }

    private func accept(_ new: NWConnection) {
        // One phone per session. A second connection is dropped without touching the session, so
        // it cannot interrupt or take over a pairing in progress.
        guard connection == nil, !(session?.isTerminal ?? true) else {
            new.cancel()
            return
        }
        connection = new
        buffer = LiveTVPairingFrameBuffer()
        new.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                if case .failed = state { self?.connectionDropped(new) }
                if case .cancelled = state { self?.connectionDropped(new) }
            }
        }
        new.start(queue: .main)
        receive(on: new)
    }

    private func connectionDropped(_ dropped: NWConnection) {
        guard connection === dropped else { return }
        connection = nil
        // A phone that disconnects before delivering frees the session for another attempt only
        // while it is still listening; a half-finished handshake is not resumable.
        if case .phoneConnected = status { finish(.failed(.cancelled)) }
    }

    private func receive(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, isComplete, error in
            Task { @MainActor in
                guard let self, self.connection === connection else { return }
                if let data, !data.isEmpty { self.consume(data) }
                if error == nil, !isComplete, self.connection === connection { self.receive(on: connection) }
            }
        }
    }

    private func consume(_ data: Data) {
        do {
            for frame in try buffer.append(data) { handle(frame) }
        } catch {
            sendAndClose(.failure(.invalidMessage))
        }
    }

    private func handle(_ frame: LiveTVPairingFrame) {
        guard var current = session else { return }
        let now = Date()
        switch frame.type {
        case .hello:
            switch current.handleHello(frame, now: now) {
            case .success(let ack):
                send(ack)
                if case .phoneConnected(let name) = current.phase { status = .phoneConnected(deviceName: name) }
            case .failure(let failure):
                sendFailure(failure, session: current)
            }
        case .deliver:
            switch current.handleDelivery(frame, now: now) {
            case .success(let summary):
                if case .awaitingApproval(_, let name) = current.phase {
                    status = .awaitingApproval(summary, deviceName: name)
                }
            case .failure(let failure):
                sendFailure(failure, session: current)
            }
        default:
            sendFailure(.invalidMessage, session: current)
        }
        session = current
        if current.isTerminal, !isFinished { finish(Self.status(for: current.phase)) }
    }

    private func sendFailure(_ failure: LiveTVPairingFailure, session: LiveTVPairingSession) {
        // Wrong proofs and bad messages close the connection; the session survives until its
        // attempt limit or expiry unless it already ended.
        sendAndClose(.failure(failure))
    }

    private func send(_ frame: LiveTVPairingFrame) {
        guard let connection, let data = try? LiveTVPairingFrameBuffer.encode(frame) else { return }
        connection.send(content: data, completion: .contentProcessed { _ in })
    }

    private func sendAndClose(_ frame: LiveTVPairingFrame) {
        send(frame)
        closeConnectionSoon()
    }

    private func closeConnectionSoon() {
        let closing = connection
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            closing?.cancel()
            if self?.connection === closing { self?.connection = nil }
        }
    }

    // MARK: Countdown and teardown

    private func startCountdown() {
        countdown?.cancel()
        countdown = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self, var current = self.session else { return }
                current.tick(now: Date())
                self.session = current
                self.remaining = current.remaining(at: Date())
                if current.isTerminal, !self.isFinished {
                    self.sendAndClose(.failure(.expired))
                    self.finish(Self.status(for: current.phase))
                    return
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    /// Ends the session: stops listening and advertising and drops the phone connection.
    private func finish(_ final: Status) {
        status = final
        listener?.cancel()
        listener = nil
        countdown?.cancel()
        countdown = nil
        link = nil
    }

    private func teardown() {
        countdown?.cancel()
        countdown = nil
        listener?.cancel()
        listener = nil
        connection?.cancel()
        connection = nil
        session = nil
        link = nil
        buffer = LiveTVPairingFrameBuffer()
    }

    private static func status(for phase: LiveTVPairingSession.Phase) -> Status {
        switch phase {
        case .expired: .failed(.expired)
        case .cancelled: .failed(.cancelled)
        case .failed(let failure): .failed(failure)
        case .completed: .failed(.sessionClosed)
        default: .failed(.cancelled)
        }
    }

    // MARK: Local address

    /// The TV's private IPv4 address on the active interface, for the QR.
    static func localIPv4Address() -> String? {
        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0, let first = pointer else { return nil }
        defer { freeifaddrs(pointer) }
        var fallback: String?
        for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(entry.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0,
                  entry.pointee.ifa_addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(entry.pointee.ifa_addr, socklen_t(entry.pointee.ifa_addr.pointee.sa_len),
                              &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let address = String(cString: host)
            guard LiveTVPairingLink.isLocalHost(address) else { continue }
            if String(cString: entry.pointee.ifa_name).hasPrefix("en") { return address }
            fallback = fallback ?? address
        }
        return fallback
    }
}
#endif
