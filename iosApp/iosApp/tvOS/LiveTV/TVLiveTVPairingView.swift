#if os(tvOS)
import SwiftUI
import CoreImage.CIFilterBuiltins

/// "Set up with phone": the Apple TV shows a QR and a short code, the Kyro iPhone app sends a
/// provider, and the TV user approves it here. No credentials are typed with the Siri Remote and
/// none appear in the QR.
struct TVLiveTVPairingView: View {
    @Bindable var service: LiveTVService
    @State private var receiver: TVLiveTVPairingReceiver
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focus: Focus?

    private enum Focus: Hashable { case cancel, retry, allow, decline, done }

    init(service: LiveTVService) {
        self.service = service
        _receiver = State(initialValue: TVLiveTVPairingReceiver(service: service))
    }

    var body: some View {
        ZStack {
            TVKyroAmbientBackdrop()
            content
                .padding(.horizontal, 120)
                .padding(.vertical, 70)
        }
        .onExitCommand {
            receiver.stop()
            dismiss()
        }
        .task { receiver.start() }
        .onDisappear { receiver.stop() }
    }

    @ViewBuilder
    private var content: some View {
        switch receiver.status {
        case .awaitingApproval(let summary, let deviceName):
            approval(summary: summary, deviceName: deviceName)
        case .saving:
            message(title: "Saving provider…", detail: nil, symbol: "lock.shield", showsDone: false)
        case .completed(let name):
            message(title: "Added \(name)", detail: "Kyro is loading your channels and guide.",
                    symbol: "checkmark.circle.fill", showsDone: true)
        case .failed(let failure):
            failureView(failure)
        case .unavailable:
            message(title: "Pairing is unavailable",
                    detail: "Kyro could not start a local pairing session. Check that this Apple TV is on your home network and that Local Network access is allowed for Kyro.",
                    symbol: "wifi.exclamationmark", showsDone: true, canRetry: true)
        case .idle, .starting, .waitingForPhone, .phoneConnected:
            pairing
        }
    }

    // MARK: Pairing

    private var pairing: some View {
        HStack(alignment: .top, spacing: 90) {
            VStack(spacing: 18) {
                if let link = receiver.link, let image = Self.qrImage(for: link.url.absoluteString) {
                    Image(uiImage: image)
                        .interpolation(.none)
                        .resizable()
                        .frame(width: 400, height: 400)
                        .padding(22)
                        .background(Color.white, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                        .accessibilityLabel("Pairing QR code")
                } else {
                    ProgressView().frame(width: 444, height: 444)
                }
                Text("Scan with your iPhone camera")
                    .font(.system(size: 22)).foregroundStyle(Color.siloSecondaryText)
            }

            VStack(alignment: .leading, spacing: 26) {
                Text("Set up with phone").font(.system(size: 52, weight: .heavy))
                VStack(alignment: .leading, spacing: 10) {
                    step("1", "Open Kyro on your iPhone and go to Live TV.")
                    step("2", "Choose a provider, then Send to Apple TV.")
                    step("3", "Scan this code, or enter the code below.")
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("PAIRING CODE").font(.system(size: 18, weight: .bold)).foregroundStyle(Color.siloSecondaryText)
                    Text(receiver.displayCode)
                        .font(.system(size: 64, weight: .heavy, design: .monospaced))
                        .foregroundStyle(KyroTheme.accentInk)
                        .accessibilityLabel("Pairing code \(receiver.displayCode.map(String.init).joined(separator: " "))")
                }
                Text(statusLine).font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(Color.siloOnSurface)
                Text("Expires in \(Self.clock(receiver.remaining))")
                    .font(.system(size: 22).monospacedDigit()).foregroundStyle(Color.siloSecondaryText)
                    .accessibilityLabel("Code expires in \(Int(receiver.remaining / 60)) minutes")
                Text("Your credentials are sent encrypted and are never shown in the code.")
                    .font(.system(size: 19)).foregroundStyle(Color.siloSecondaryText)
                HStack(spacing: 24) {
                    Button("Cancel") { receiver.cancel() }.focused($focus, equals: .cancel)
                    Button("New Code") { receiver.start() }.focused($focus, equals: .retry)
                }
            }
        }
        .task { focus = .cancel }
    }

    private var statusLine: String {
        switch receiver.status {
        case .phoneConnected(let name): "\(name) connected. Choose a provider on your iPhone."
        case .starting, .idle: "Starting…"
        default: "Waiting for your iPhone…"
        }
    }

    private func step(_ number: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            Text(number).font(.system(size: 24, weight: .heavy)).foregroundStyle(KyroTheme.accentInk)
            Text(text).font(.system(size: 26)).foregroundStyle(Color.siloOnSurface)
        }
    }

    // MARK: Approval

    private func approval(summary: LiveTVPairingPayload.Summary, deviceName: String) -> some View {
        VStack(alignment: .leading, spacing: 26) {
            Text("Add this provider?").font(.system(size: 52, weight: .heavy))
            VStack(alignment: .leading, spacing: 12) {
                Text(summary.name).font(.system(size: 40, weight: .bold))
                Text("\(summary.kind == .xtream ? "Xtream Codes" : "M3U playlist") · \(summary.host)")
                    .font(.system(size: 26)).foregroundStyle(Color.siloSecondaryText)
                Text("Sent by \(deviceName)").font(.system(size: 24)).foregroundStyle(Color.siloSecondaryText)
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.siloSurface, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            Text("Only allow this if you just sent it from your own iPhone. Credentials are saved in the Apple TV keychain.")
                .font(.system(size: 22)).foregroundStyle(Color.siloSecondaryText)
            Text("Expires in \(Self.clock(receiver.remaining))")
                .font(.system(size: 22).monospacedDigit()).foregroundStyle(Color.siloSecondaryText)
            HStack(spacing: 24) {
                Button("Allow") { receiver.approve() }.focused($focus, equals: .allow)
                Button("Decline") { receiver.decline() }.focused($focus, equals: .decline)
            }
        }
        .task { focus = .allow }
    }

    // MARK: Result

    private func failureView(_ failure: LiveTVPairingFailure) -> some View {
        message(title: failure == .cancelled ? "Pairing cancelled" : "Pairing did not finish",
                detail: failure.userMessage, symbol: "exclamationmark.triangle.fill",
                showsDone: true, canRetry: true)
    }

    private func message(title: String, detail: String?, symbol: String, showsDone: Bool, canRetry: Bool = false) -> some View {
        VStack(spacing: 24) {
            Image(systemName: symbol).font(.system(size: 80)).foregroundStyle(KyroTheme.accentInk)
            Text(title).font(.system(size: 46, weight: .heavy))
            if let detail {
                Text(detail).font(.system(size: 26)).foregroundStyle(Color.siloSecondaryText).multilineTextAlignment(.center)
            }
            HStack(spacing: 24) {
                if canRetry { Button("Try Again") { receiver.start() }.focused($focus, equals: .retry) }
                if showsDone { Button("Done") { receiver.stop(); dismiss() }.focused($focus, equals: .done) }
            }
        }
        .frame(maxWidth: .infinity)
        .task { focus = canRetry ? .retry : .done }
    }

    // MARK: Helpers

    static func clock(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.up)))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    static func qrImage(for text: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)),
              let cgImage = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}
#endif
