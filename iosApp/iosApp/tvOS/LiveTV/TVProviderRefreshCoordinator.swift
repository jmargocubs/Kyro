#if os(tvOS)
import Foundation
import Observation
import SwiftUI

/// What a manual refresh of an existing provider should fetch.
enum TVProviderRefreshScope: Equatable {
    case all, liveOnly
}

/// One manual provider refresh at a time, with immediate in-page feedback. It never uses the
/// full-screen onboarding presentation, so playback and navigation are not interrupted, and its
/// state lives outside the view so it stays coherent when the user leaves and returns.
@MainActor
@Observable
final class TVProviderRefreshCoordinator {
    static let shared = TVProviderRefreshCoordinator()

    enum Phase: Equatable {
        case idle
        case running(providerID: UUID, scope: TVProviderRefreshScope)
        case finished(providerID: UUID, succeeded: Bool, message: String)
    }

    enum Start: Equatable { case started, alreadyRunning, nothingToRefresh(String) }

    private(set) var phase: Phase = .idle
    private var work: Task<Void, Never>?

    var isRunning: Bool { if case .running = phase { true } else { false } }

    func isRunning(providerID: UUID) -> Bool {
        if case .running(let id, _) = phase { return id == providerID }
        return false
    }

    func dismissResult() {
        if case .finished = phase { phase = .idle }
    }

    /// Starts exactly one refresh and returns immediately. A second request while one is running
    /// is refused, and the caller shows that instead of silently doing nothing.
    @discardableResult
    func refresh(providerID: UUID, scope: TVProviderRefreshScope = .all,
                 liveTV: LiveTVService) -> Start {
        guard !isRunning, work == nil,
              liveTV.importProgress?.isTerminal != false else { return .alreadyRunning }
        guard liveTV.providers.contains(where: { $0.id == providerID }) else {
            return .nothingToRefresh("This provider is no longer available.")
        }
        phase = .running(providerID: providerID, scope: scope)
        work = Task { [weak self] in
            var failures: [String] = []
            await liveTV.refresh(providerID: providerID, presentation: .compact)
            if let progress = liveTV.importProgress, progress.providerID == providerID,
               progress.stage == .failed || progress.stage == .cancelled {
                failures.append("Live TV: \(progress.message ?? "refresh failed")")
            }
            if liveTV.importProgress?.providerID == providerID,
               liveTV.importProgress?.isOnboarding == false { liveTV.clearFinishedImport() }
            guard let self else { return }
            self.work = nil
            let message: String
            if failures.isEmpty {
                let count = liveTV.providers.first(where: { $0.id == providerID })?.channelCount ?? 0
                message = "Refreshed · \(count.formatted()) channels"
            } else {
                message = failures.joined(separator: " ")
            }
            self.phase = .finished(providerID: providerID, succeeded: failures.isEmpty, message: message)
        }
        return .started
    }

    /// Lets tests await the refresh that `refresh` started.
    func waitForCompletion() async { await work?.value }
}

/// The status line under each connected provider.
enum TVProviderSummary {
    static func line(for provider: LiveTVProvider) -> String {
        let kindLabel = provider.kind == .xtream ? "Xtream Codes" : "M3U"
        return "\(kindLabel) · \(provider.channelCount.formatted()) channels"
    }
}

/// One-line, non-focusable refresh indicator for the Live TV page during a background refresh.
struct TVCompactLiveRefreshLine: View {
    let progress: LiveTVImportProgress

    var body: some View {
        HStack(spacing: 14) {
            ProgressView().scaleEffect(0.7)
            Text(label).font(.system(size: 22, weight: .semibold))
            if progress.stage == .importing, let fraction = progress.count.fraction {
                Text("\(Int((fraction * 100).rounded(.down)))%")
                    .font(.system(size: 22, weight: .bold).monospacedDigit())
            }
        }
        .foregroundStyle(Color.siloSecondaryText)
        .accessibilityIdentifier("liveTV.compactRefresh")
    }

    private var label: String {
        switch progress.stage {
        case .connecting: "Refreshing \(progress.providerName) · Connecting"
        case .downloading: "Refreshing \(progress.providerName) · Downloading channels"
        case .importing: "Refreshing \(progress.providerName) · Importing channels"
        case .categories: "Refreshing \(progress.providerName) · Preparing categories"
        case .guide: "Refreshing \(progress.providerName) · Preparing TV Guide"
        case .saving: "Refreshing \(progress.providerName) · Saving"
        case .ready, .failed, .cancelled: "Refreshing \(progress.providerName)"
        }
    }
}

/// Compact, non-modal progress for a manual refresh. Sits at the top of the Providers page.
struct TVProviderRefreshPanel: View {
    let coordinator: TVProviderRefreshCoordinator
    @Bindable var service: LiveTVService

    var body: some View {
        switch coordinator.phase {
        case .idle:
            EmptyView()
        case .running(let providerID, _):
            panel(symbol: "arrow.triangle.2.circlepath", tint: KyroTheme.accentInk) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Refreshing \(providerName(providerID)) · \(activity(providerID))")
                        .font(.system(size: 26, weight: .semibold))
                    if let fraction = fraction(providerID) {
                        HStack(spacing: 16) {
                            ProgressView(value: fraction).tint(KyroTheme.accentInk)
                            Text("\(Int((fraction * 100).rounded(.down)))%")
                                .font(.system(size: 22, weight: .bold).monospacedDigit())
                        }
                    } else {
                        ProgressView().tint(KyroTheme.accentInk)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if let detail = countLine(providerID) {
                        Text(detail).font(.system(size: 20)).foregroundStyle(Color.siloSecondaryText)
                    }
                }
            }
            .accessibilityIdentifier("providers.refreshProgress")
        case .finished(_, let succeeded, let message):
            panel(symbol: succeeded ? "checkmark.circle.fill" : "exclamationmark.triangle.fill",
                  tint: succeeded ? KyroTheme.accentInk : KyroTheme.live) {
                Text(message).font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(succeeded ? Color.primary : KyroTheme.live)
                    .lineLimit(3)
            }
            .accessibilityIdentifier("providers.refreshResult")
        }
    }

    private func panel<Content: View>(symbol: String, tint: Color,
                                      @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 20) {
            Image(systemName: symbol).font(.system(size: 34, weight: .semibold)).foregroundStyle(tint)
            content()
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.siloSurface.opacity(0.92), in: RoundedRectangle(cornerRadius: 20))
    }

    private func providerName(_ id: UUID) -> String {
        service.providers.first(where: { $0.id == id })?.name ?? "provider"
    }

    private func liveProgress(_ id: UUID) -> LiveTVImportProgress? {
        guard let progress = service.importProgress, progress.providerID == id, !progress.isTerminal else { return nil }
        return progress
    }

    private func activity(_ id: UUID) -> String {
        if let live = liveProgress(id) {
            switch live.stage {
            case .connecting: return "Connecting"
            case .downloading: return "Downloading Live TV channels"
            case .importing: return "Importing Live TV channels"
            case .categories: return "Preparing channel categories"
            case .guide: return "Preparing TV Guide"
            case .saving: return "Saving channels"
            case .ready, .failed, .cancelled: return "Finishing Live TV"
            }
        }
        return "Starting"
    }

    private func fraction(_ id: UUID) -> Double? {
        if let live = liveProgress(id) { return live.stage == .importing ? live.count.fraction : nil }
        return nil
    }

    private func countLine(_ id: UUID) -> String? {
        if let live = liveProgress(id), live.count.processed > 0 {
            if let total = live.count.total {
                return "\(live.count.processed.formatted()) / \(total.formatted()) channel records"
            }
            return "\(live.count.processed.formatted()) channel records processed"
        }
        return nil
    }
}
#endif
