#if os(iOS)
import AVFoundation
import AVKit
import MediaPlayer
import Nuke
import NukeUI
import SwiftUI

// Build 135: Modern Stream, an artwork-led streaming player for Podcasts and
// Radio. It replaces Build 134's green recolour of the hardware players; the
// vinyl and cassette hardware stays in Crimson Noir and Classic Walnut.
//
// Live data only: no comments, no device-casting brands, no invented chapters.
// Playback position updates redraw only the timeline row.

// MARK: - Visual system

enum KyroModernStyle {
    static let crimson = Color(red: 0.90, green: 0.14, blue: 0.23)        // #E5243B accent
    static let crimsonDeep = Color(red: 0.56, green: 0.055, blue: 0.12)   // #8F0E1F
    static let burgundy = Color(red: 0.23, green: 0.03, blue: 0.06)       // #3A0710
    static let night = Color(red: 0.04, green: 0.016, blue: 0.024)        // #0A0406
    static let surface = Color(red: 0.17, green: 0.035, blue: 0.06)       // #2B0910
    static let surfaceStroke = Color.white.opacity(0.08)
    static let secondary = Color.white.opacity(0.68)
    static let tertiary = Color.white.opacity(0.45)

    /// Rich crimson at the top falling to black, with a soft highlight.
    static var background: some View {
        ZStack {
            LinearGradient(stops: [.init(color: crimsonDeep, location: 0),
                                   .init(color: burgundy, location: 0.45),
                                   .init(color: night, location: 1)],
                           startPoint: .top, endPoint: .bottom)
            RadialGradient(colors: [crimson.opacity(0.32), .clear], center: UnitPoint(x: 0.5, y: 0.0),
                           startRadius: 0, endRadius: 380)
        }
    }

    static func card(cornerRadius: CGFloat = 18) -> some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(surface.opacity(0.85))
            .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).strokeBorder(surfaceStroke))
    }

    static func time(_ seconds: Double) -> String {
        let value = Int(seconds.isFinite ? min(604_800, max(0, seconds)) : 0)
        return value >= 3600 ? String(format: "%d:%02d:%02d", value / 3600, value / 60 % 60, value % 60)
            : String(format: "%d:%02d", value / 60, value % 60)
    }

    /// SF Symbols draws the seconds into these skip glyphs only for these values.
    static func skipSymbol(back: Bool, seconds: Int) -> String {
        let base = back ? "gobackward" : "goforward"
        return [5, 10, 15, 30, 45, 60, 75, 90].contains(seconds) ? "\(base).\(seconds)" : base
    }
}

/// Large square cover art with a soft shadow.
struct KyroModernArtwork: View {
    let url: URL?
    var fallbackSymbol = "waveform"
    /// Station logos are often small marks on transparent backgrounds, so they
    /// are fitted on a dark tile instead of cropped.
    var fits = false
    @Environment(\.displayScale) private var scale

    var body: some View {
        GeometryReader { proxy in
            let side = proxy.size.width
            LazyImage(request: url.flatMap {
                PosterImageCache.displayRequest(url: $0, pointSize: CGSize(width: side, height: side), scale: scale)
            }) { state in
                if let image = state.image {
                    if fits {
                        image.resizable().scaledToFit().padding(side * 0.14)
                    } else {
                        image.resizable().scaledToFill()
                    }
                } else {
                    Image(systemName: fallbackSymbol)
                        .font(.system(size: side * 0.28, weight: .medium))
                        .foregroundStyle(KyroModernStyle.crimson)
                }
            }
            .onDisappear(.cancel)
            .frame(width: side, height: side)
            .background(LinearGradient(colors: [KyroModernStyle.surface, KyroModernStyle.night], startPoint: .top, endPoint: .bottom))
            .clipShape(RoundedRectangle(cornerRadius: side * 0.06, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: side * 0.06, style: .continuous).strokeBorder(KyroModernStyle.surfaceStroke))
        }
        .aspectRatio(1, contentMode: .fit)
        .shadow(color: .black.opacity(0.55), radius: 22, y: 14)
        .accessibilityHidden(true)
    }
}

/// The large white circular play/pause control.
private struct KyroModernPrimaryButton: View {
    let symbol: String?
    let isBusy: Bool
    let label: String
    let action: () -> Void
    @ScaledMetric(relativeTo: .largeTitle) private var diameter: CGFloat = 76

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().fill(.white)
                if isBusy {
                    ProgressView().tint(KyroModernStyle.night).controlSize(.large)
                } else if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: diameter * 0.38, weight: .bold))
                        .foregroundStyle(KyroModernStyle.night)
                }
            }
            .frame(width: diameter, height: diameter)
            .shadow(color: KyroModernStyle.crimson.opacity(0.35), radius: 16, y: 6)
            .contentShape(Circle())
        }
        .buttonStyle(KyroModernPressStyle())
        .accessibilityLabel(label)
    }
}

/// White glyph controls around the primary button.
private struct KyroModernIconButton: View {
    let symbol: String
    let label: String
    var size: CGFloat = 26
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .medium))
                .foregroundStyle(.white)
                .frame(minWidth: 48, minHeight: 48)
                .contentShape(Rectangle())
        }
        .buttonStyle(KyroModernPressStyle())
        .accessibilityLabel(label)
    }
}

private struct KyroModernPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .opacity(configuration.isPressed ? 0.8 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// System volume, in white over a crimson track.
private struct KyroModernVolume: UIViewRepresentable {
    func makeUIView(context: Context) -> MPVolumeView {
        let view = MPVolumeView()
        view.accessibilityLabel = "Volume"
        style(view)
        return view
    }

    func updateUIView(_ view: MPVolumeView, context: Context) { style(view) }

    private func style(_ view: MPVolumeView) {
        for case let slider as UISlider in view.subviews {
            slider.minimumTrackTintColor = UIColor(KyroModernStyle.crimson)
            slider.maximumTrackTintColor = UIColor.white.withAlphaComponent(0.22)
            slider.thumbTintColor = .white
        }
    }
}

/// Theme choice from the player itself, so the session stays open.
private struct KyroModernThemePicker: View {
    let selection: KyroRadioPlayerTheme
    let select: (KyroRadioPlayerTheme) -> Void
    var body: some View {
        Picker("Player Appearance", selection: Binding(get: { selection }, set: select)) {
            ForEach(KyroRadioPlayerTheme.allCases) { Text($0.title).tag($0) }
        }
    }
}

// MARK: - Podcast player

struct KyroPodcastModernPlayer: View {
    let entry: PodcastEntry
    let player: KyroPodcastPlayer
    @Environment(\.dismiss) private var dismiss
    @State private var panel: Panel?
    @State private var chapters: [PodcastFeedService.Chapters.Chapter] = []
    @State private var notesExpanded = false
    private let library = KyroPodcastLibrary.shared
    private let downloads = KyroPodcastDownloads.shared

    enum Panel: String, Identifiable { case queue, chapters; var id: String { rawValue } }

    var body: some View {
        GeometryReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 22) {
                    header
                    KyroModernArtwork(url: entry.artwork)
                        .frame(maxWidth: min(proxy.size.width - 48, proxy.size.height * 0.44))
                        .frame(maxWidth: .infinity)
                    titles
                    KyroPodcastModernTimeline(player: player, chapters: chapters)
                    transport
                    utilityRow
                    notes
                }
                .frame(maxWidth: 560)
                .padding(.horizontal, 24)
                .padding(.top, 10)
                .padding(.bottom, 32)
                .frame(maxWidth: .infinity)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .foregroundStyle(.white)
        .tint(KyroModernStyle.crimson)
        .background(KyroModernStyle.background.ignoresSafeArea())
        .environment(\.colorScheme, .dark)
        .task(id: entry.id) { await loadChapters() }
        .sheet(item: $panel) { item in
            NavigationStack {
                switch item {
                case .queue: KyroPodcastQueueView()
                case .chapters: KyroPodcastModernChapters(chapters: chapters, player: player)
                }
            }
            .environment(\.colorScheme, .dark)
        }
        .accessibilityIdentifier("kyroModernPodcastPlayer")
    }

    private func loadChapters() async {
        chapters = []
        guard let url = entry.episode.chaptersURL,
              let loaded = try? await PodcastFeedService.shared.chapters(at: url), !Task.isCancelled else { return }
        chapters = loaded.sorted { $0.startTime < $1.startTime }
    }

    private var header: some View {
        HStack {
            KyroModernIconButton(symbol: "chevron.down", label: "Close", size: 20) { dismiss() }
            Spacer()
            Text(entry.showTitle)
                .font(.headline)
                .lineLimit(1)
                .accessibilityAddTraits(.isHeader)
            Spacer()
            Menu {
                Button(library.saved.contains(entry.id) ? "Unsave Episode" : "Save Episode",
                       systemImage: library.saved.contains(entry.id) ? "bookmark.fill" : "bookmark") { library.toggleSaved(entry) }
                Button(library.progress[entry.id]?.played == true ? "Mark Unplayed" : "Mark Played", systemImage: "checkmark.circle") {
                    library.mark(entry, played: library.progress[entry.id]?.played != true)
                }
                downloadAction
                Button("Episode Queue", systemImage: "list.number") { panel = .queue }
                if !chapters.isEmpty { Button("Chapters", systemImage: "list.bullet.rectangle") { panel = .chapters } }
                Divider()
                Menu("Player Appearance", systemImage: "paintpalette") {
                    KyroModernThemePicker(selection: library.preferences.theme, select: library.selectTheme)
                }
                Divider()
                Button("Stop Playback", systemImage: "stop.fill", role: .destructive) { player.stop(); dismiss() }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 20, weight: .bold))
                    .frame(width: 48, height: 48)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Episode Options")
        }
    }

    @ViewBuilder
    private var downloadAction: some View {
        if case .downloading = downloads.status[entry.id] {
            Button("Cancel Download", systemImage: "xmark.circle") { downloads.cancel(entry) }
        } else if downloads.hasDownload(entry) {
            Button("Remove Download", systemImage: "trash", role: .destructive) { downloads.remove(entry) }
        } else {
            Button("Download Episode", systemImage: "arrow.down.circle") {
                downloads.start(entry, wifiOnly: library.preferences.wifiOnly)
            }
        }
    }

    private var titles: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !chapters.isEmpty {
                Button { panel = .chapters } label: {
                    Label("Chapters", systemImage: "list.bullet")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(Capsule().fill(Color.black.opacity(0.35)))
                }
                .buttonStyle(.plain)
            }
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(entry.episode.title)
                        .font(.title2.weight(.bold))
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                    HStack(spacing: 8) {
                        KyroPodcastArtwork(url: entry.showArtwork ?? entry.artwork, size: 22)
                        Text(entry.showTitle).font(.body).foregroundStyle(KyroModernStyle.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                Button { library.toggleSaved(entry) } label: {
                    Image(systemName: library.saved.contains(entry.id) ? "bookmark.fill" : "bookmark")
                        .font(.title3)
                        .foregroundStyle(library.saved.contains(entry.id) ? KyroModernStyle.crimson : .white)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(library.saved.contains(entry.id) ? "Unsave Episode" : "Save Episode")
            }
            if player.state == .failed {
                Label("This episode couldn’t play. Tap Play to retry.", systemImage: "exclamationmark.circle")
                    .font(.footnote).foregroundStyle(KyroModernStyle.secondary)
            } else if player.state == .loading || (player.state == .playing && !player.isAdvancing) {
                Label("Buffering…", systemImage: "ellipsis").font(.footnote).foregroundStyle(KyroModernStyle.secondary)
            }
        }
    }

    private var transport: some View {
        let running = player.state == .playing || player.state == .loading
        let back = library.preferences.back, forward = library.preferences.forward
        return HStack {
            Menu {
                ForEach(PodcastPreferences.speeds, id: \.self) { speed in
                    Button {
                        var prefs = library.preferences
                        prefs.speed = speed
                        player.updatePreferences(prefs)
                    } label: {
                        if library.preferences.speed == speed { Label(speed.formatted() + "×", systemImage: "checkmark") }
                        else { Text(speed.formatted() + "×") }
                    }
                }
            } label: {
                Text(library.preferences.speed.formatted() + "×")
                    .font(.title3.weight(.bold).monospacedDigit())
                    .frame(minWidth: 48, minHeight: 48)
            }
            .accessibilityLabel("Playback Speed")
            .accessibilityValue(library.preferences.speed.formatted() + "×")
            Spacer()
            KyroModernIconButton(symbol: KyroModernStyle.skipSymbol(back: true, seconds: back), label: "Back \(back) seconds", size: 30) {
                player.skip(-Double(back))
            }
            Spacer()
            KyroModernPrimaryButton(symbol: running ? "pause.fill" : "play.fill", isBusy: false,
                                    label: running ? "Pause" : "Play", action: player.toggle)
            Spacer()
            KyroModernIconButton(symbol: KyroModernStyle.skipSymbol(back: false, seconds: forward), label: "Forward \(forward) seconds", size: 30) {
                player.skip(Double(forward))
            }
            Spacer()
            Menu {
                ForEach(PodcastPreferences.sleepOptions, id: \.self) { minutes in
                    Button(KyroPodcastSettings.sleepLabel(minutes)) { player.setSleep(minutes) }
                }
            } label: {
                Image(systemName: player.sleep == .off ? "moon" : "moon.fill")
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(player.sleep == .off ? .white : KyroModernStyle.crimson)
                    .frame(minWidth: 48, minHeight: 48)
            }
            .accessibilityLabel("Sleep Timer")
            .accessibilityValue(player.sleep == .off ? "Off" : "On")
        }
    }

    private var utilityRow: some View {
        HStack(spacing: 4) {
            KyroAudioOutputPicker(tint: .white, activeTint: KyroModernStyle.crimson)
                .frame(width: 44, height: 44)
                .accessibilityLabel("Audio output, AirPlay and Bluetooth")
            Text("Audio Output").font(.subheadline).foregroundStyle(KyroModernStyle.secondary)
            Spacer()
            if let link = shareLink {
                ShareLink(item: link, subject: Text(entry.episode.title), message: Text("\(entry.episode.title) — \(entry.showTitle)")) {
                    Image(systemName: "square.and.arrow.up").frame(width: 44, height: 44)
                }
                .accessibilityLabel("Share Episode")
            }
            Button { panel = .queue } label: {
                Image(systemName: "list.bullet").frame(width: 44, height: 44)
            }
            .accessibilityLabel("Episode Queue")
        }
        .font(.title3)
        .buttonStyle(.plain)
    }

    /// The episode's public media address; downloads stay on the device.
    private var shareLink: URL? { PodcastAddress.url(entry.episode.media.absoluteString) }

    @ViewBuilder
    private var notes: some View {
        let summary = entry.episode.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        VStack(alignment: .leading, spacing: 10) {
            Text("Episode Notes").font(.headline)
            HStack(spacing: 6) {
                if let date = entry.episode.published { Text(date, format: .dateTime.month(.abbreviated).day().year()) }
                if let duration = entry.episode.duration, duration > 0 { Text("· " + KyroModernStyle.time(duration)) }
                if entry.episode.explicit { Text("· Explicit") }
            }
            .font(.caption).foregroundStyle(KyroModernStyle.tertiary)
            if summary.isEmpty {
                Text("This episode has no description.").font(.subheadline).foregroundStyle(KyroModernStyle.secondary)
            } else {
                Text(summary)
                    .font(.subheadline)
                    .foregroundStyle(KyroModernStyle.secondary)
                    .lineLimit(notesExpanded ? nil : 6)
                    .textSelection(.enabled)
                if summary.count > 280 {
                    Button(notesExpanded ? "Show Less" : "Show More") { notesExpanded.toggle() }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(KyroModernStyle.crimson)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(KyroModernStyle.card())
    }
}

/// Position, elapsed and remaining time and the current chapter. The only
/// view that observes the half-second playback clock.
private struct KyroPodcastModernTimeline: View {
    let player: KyroPodcastPlayer
    let chapters: [PodcastFeedService.Chapters.Chapter]
    @State private var draft: Double?

    var body: some View {
        let clock = player.clock
        let duration = max(clock.duration, 0)
        let value = min(max(0, draft ?? clock.position), max(duration, 1))
        VStack(spacing: 6) {
            KyroModernScrubber(value: value, duration: duration, enabled: duration > 0 && player.state != .failed && player.state != .loading,
                               onDrag: { draft = $0 }, onCommit: { committed in
                                   player.seek(committed)
                                   draft = nil
                               })
            .accessibilityLabel("Playback Position")
            .accessibilityValue("\(KyroModernStyle.time(value)) of \(KyroModernStyle.time(duration))")
            .accessibilityAdjustableAction { direction in
                if direction == .increment { player.skip(15) } else if direction == .decrement { player.skip(-15) }
            }
            HStack(alignment: .firstTextBaseline) {
                Text(KyroModernStyle.time(value))
                Spacer()
                if let chapter = Self.chapter(at: value, in: chapters) {
                    Text(chapter).lineLimit(1).foregroundStyle(.white.opacity(0.85))
                    Spacer()
                }
                Text(duration > 0 ? "−" + KyroModernStyle.time(max(0, duration - value)) : "--:--")
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(KyroModernStyle.tertiary)
        }
    }

    /// The chapter playing at `seconds`, from the episode's own chapter data.
    static func chapter(at seconds: Double, in chapters: [PodcastFeedService.Chapters.Chapter]) -> String? {
        chapters.last { $0.startTime <= seconds }?.title
    }
}

/// A slim crimson progress track with a white thumb.
private struct KyroModernScrubber: View {
    let value: Double
    let duration: Double
    let enabled: Bool
    let onDrag: (Double) -> Void
    let onCommit: (Double) -> Void
    @State private var dragging = false

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let fraction = duration > 0 ? min(max(value / duration, 0), 1) : 0
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.22)).frame(height: dragging ? 8 : 5)
                Capsule().fill(KyroModernStyle.crimson).frame(width: max(0, width * fraction), height: dragging ? 8 : 5)
                Circle().fill(.white)
                    .frame(width: dragging ? 22 : 16, height: dragging ? 22 : 16)
                    .shadow(color: .black.opacity(0.4), radius: 3, y: 1)
                    .offset(x: max(0, min(width - 16, width * fraction - 8)))
            }
            .frame(height: 28)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { gesture in
                guard enabled, width > 0 else { return }
                dragging = true
                onDrag(min(max(gesture.location.x / width, 0), 1) * duration)
            }.onEnded { gesture in
                guard enabled, width > 0 else { dragging = false; return }
                dragging = false
                onCommit(min(max(gesture.location.x / width, 0), 1) * duration)
            })
            .animation(.easeOut(duration: 0.15), value: dragging)
        }
        .frame(height: 28)
        .opacity(enabled ? 1 : 0.5)
    }
}

private struct KyroPodcastModernChapters: View {
    let chapters: [PodcastFeedService.Chapters.Chapter]
    let player: KyroPodcastPlayer
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List(chapters) { chapter in
            Button {
                player.seek(chapter.startTime)
                dismiss()
            } label: {
                HStack {
                    Text(chapter.title ?? "Chapter").lineLimit(2)
                    Spacer()
                    Text(KyroModernStyle.time(chapter.startTime)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Chapters").navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
    }
}

// MARK: - Radio player

/// Modern Stream for live radio: no progress, skipping or shuffle, because a
/// live stream has none.
struct KyroRadioModernPlayer: View {
    let player: KyroRadioPlayer
    @Environment(\.dismiss) private var dismiss
    @State private var routeName = KyroRadioAudioRoute.currentName()
    private let library = KyroRadioLibrary.shared
    private let appearance = KyroRadioPlayerAppearance.shared

    var body: some View {
        GeometryReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 22) {
                    header
                    KyroModernArtwork(url: player.station?.favicon, fallbackSymbol: "dot.radiowaves.left.and.right", fits: true)
                        .frame(maxWidth: min(proxy.size.width - 48, proxy.size.height * 0.44))
                        .frame(maxWidth: .infinity)
                    KyroRadioModernInfo(player: player)
                    controls
                    volume
                }
                .frame(maxWidth: 560)
                .padding(.horizontal, 24)
                .padding(.top, 10)
                .padding(.bottom, 32)
                .frame(maxWidth: .infinity, minHeight: proxy.size.height, alignment: .top)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .foregroundStyle(.white)
        .tint(KyroModernStyle.crimson)
        .background(KyroModernStyle.background.ignoresSafeArea())
        .environment(\.colorScheme, .dark)
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification).receive(on: RunLoop.main)) { _ in
            routeName = KyroRadioAudioRoute.currentName()
        }
        .accessibilityIdentifier("kyroRadioNowPlaying")
    }

    private var header: some View {
        HStack {
            KyroModernIconButton(symbol: "chevron.down", label: "Close", size: 20) { dismiss() }
            Spacer()
            Text("Internet Radio").font(.headline).accessibilityAddTraits(.isHeader)
            Spacer()
            Menu {
                Menu("Player Appearance", systemImage: "paintpalette") {
                    KyroModernThemePicker(selection: appearance.theme, select: appearance.select)
                }
                Button("Stop Playback", systemImage: "stop.fill", role: .destructive) { player.stop(); dismiss() }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 20, weight: .bold))
                    .frame(width: 48, height: 48)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Station Options")
        }
    }

    private var controls: some View {
        HStack {
            if let station = player.station {
                KyroModernIconButton(symbol: library.isFavorite(station.id) ? "heart.fill" : "heart",
                                     label: library.isFavorite(station.id) ? "Remove from Library" : "Save to Library") {
                    library.toggleFavorite(station)
                }
                .foregroundStyle(library.isFavorite(station.id) ? KyroModernStyle.crimson : .white)
            } else {
                Color.clear.frame(width: 48, height: 48)
            }
            Spacer()
            KyroModernPrimaryButton(symbol: transportSymbol, isBusy: isConnecting, label: transportLabel, action: transport)
            Spacer()
            KyroModernIconButton(symbol: "stop.fill", label: "Stop") { player.stop(); dismiss() }
        }
        .padding(.horizontal, 12)
    }

    private var volume: some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: "speaker.fill").foregroundStyle(KyroModernStyle.secondary).accessibilityHidden(true)
                KyroModernVolume().frame(height: 34)
                Image(systemName: "speaker.wave.3.fill").foregroundStyle(KyroModernStyle.secondary).accessibilityHidden(true)
            }
            HStack(spacing: 4) {
                KyroAudioOutputPicker(tint: .white, activeTint: KyroModernStyle.crimson)
                    .frame(width: 44, height: 44)
                    .accessibilityLabel("Audio output, AirPlay and Bluetooth")
                Text("Playing on \(routeName)").font(.subheadline).foregroundStyle(KyroModernStyle.secondary)
                Spacer()
                if let format = player.station?.formatLine {
                    Text(format).font(.caption.monospacedDigit()).foregroundStyle(KyroModernStyle.tertiary)
                }
            }
        }
    }

    private var isConnecting: Bool {
        switch player.state {
        case .connecting, .reconnecting: true
        default: false
        }
    }

    private var transportSymbol: String {
        switch player.state {
        case .failed: "arrow.clockwise"
        case .playing: "pause.fill"
        default: "play.fill"
        }
    }

    private var transportLabel: String {
        switch player.state {
        case .playing: "Pause"
        case .failed: "Try Again"
        case .connecting, .reconnecting: "Connecting"
        case .idle, .paused: "Play"
        }
    }

    private func transport() {
        if case .failed = player.state, let station = player.station {
            player.play(station)
        } else {
            player.togglePlayPause()
        }
    }
}

/// Station, live state and the stream's own song metadata.
private struct KyroRadioModernInfo: View {
    let player: KyroRadioPlayer

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                status
                Spacer()
            }
            Text(player.station?.name ?? "")
                .font(.title2.weight(.bold))
                .lineLimit(3)
                .accessibilityAddTraits(.isHeader)
            if let track = player.track, player.state == .playing {
                VStack(alignment: .leading, spacing: 2) {
                    Text(track.title).font(.headline).lineLimit(2)
                    if let artist = track.artist {
                        Text(artist).font(.body).foregroundStyle(KyroModernStyle.secondary).lineLimit(2)
                    }
                }
                .accessibilityElement(children: .combine)
            } else if case .failed(let error) = player.state {
                Label(error.message, systemImage: "exclamationmark.circle")
                    .font(.footnote).foregroundStyle(KyroModernStyle.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let location = player.station?.location, !location.isEmpty {
                Text(location).font(.body).foregroundStyle(KyroModernStyle.secondary).lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var status: some View {
        switch player.state {
        case .playing:
            Label("LIVE", systemImage: "dot.radiowaves.left.and.right")
                .font(.caption.weight(.bold))
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(Capsule().fill(KyroModernStyle.crimson))
        case .connecting:
            Text("CONNECTING").font(.caption.weight(.semibold)).tracking(1).foregroundStyle(KyroModernStyle.secondary)
        case .reconnecting(let attempt):
            Text("RECONNECTING \(attempt)/\(KyroRadioPlaybackMachine.maxReconnectAttempts)")
                .font(.caption.weight(.semibold)).tracking(1).foregroundStyle(KyroModernStyle.secondary)
        case .paused:
            Text("PAUSED").font(.caption.weight(.semibold)).tracking(1).foregroundStyle(KyroModernStyle.secondary)
        case .failed:
            Text("UNAVAILABLE").font(.caption.weight(.semibold)).tracking(1).foregroundStyle(KyroModernStyle.crimson)
        case .idle:
            Text("STOPPED").font(.caption.weight(.semibold)).tracking(1).foregroundStyle(KyroModernStyle.secondary)
        }
    }
}
#endif
