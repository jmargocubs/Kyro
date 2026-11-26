#if os(iOS)
import AVKit
import MediaPlayer
import SwiftUI

struct KyroPodcastPresentation: ViewModifier {
    private let player = KyroPodcastPlayer.shared
    func body(content: Content) -> some View {
        content.sheet(isPresented: Binding(get: { player.isShowingNowPlaying && player.hasSession },
                                           set: { player.isShowingNowPlaying = $0 })) {
            if let entry = player.current {
                KyroPodcastCassettePlayer(entry: entry, player: player)
                    .presentationDetents([.large]).presentationDragIndicator(.visible)
            }
        }
    }
}

struct KyroPodcastMiniPlayer: View {
    let style: NowPlayingBarStyle
    @Environment(\.nowPlayingAccessoryIsInline) private var isInline
    private let player = KyroPodcastPlayer.shared

    var body: some View {
        if let entry = player.current {
            HStack(spacing: 12) {
                Button { player.isShowingNowPlaying = true } label: {
                    HStack(spacing: 10) {
                        KyroPodcastArtwork(url: entry.artwork, size: isInline ? 34 : 46, decodeSize: 46)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.episode.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                            if !isInline {
                                Text(player.state == .failed ? "Playback failed · tap Play to retry" : entry.showTitle)
                                    .font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        Spacer(minLength: 0)
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityHint("Opens cassette player")
                KyroPodcastMiniTransport(player: player)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, isInline ? 4 : 8)
            .modifier(NowPlayingBarChrome(style: style))
            .padding(.horizontal, style == .card ? 16 : 0)
            .padding(.bottom, style == .card ? 8 : 0)
            .accessibilityIdentifier("kyroPodcastMiniPlayer")
        }
    }
}

private struct KyroPodcastMiniTransport: View {
    let player: KyroPodcastPlayer
    private let library = KyroPodcastLibrary.shared

    var body: some View {
        let canPause = player.state == .playing || player.state == .loading
        Button(action: player.toggle) {
            Image(systemName: canPause ? "pause.fill" : "play.fill")
                .font(.body.weight(.semibold))
                .frame(width: 44, height: 44)
                .modifier(KyroAudioMiniTransportFinish(theme: library.preferences.theme))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(canPause ? "Pause" : "Play")
    }
}

private struct KyroPodcastCassettePlayer: View {
    let entry: PodcastEntry
    let player: KyroPodcastPlayer
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var visible = false
    @State private var wood: UIImage?
    @State private var dialog: Panel?
    @State private var draftPosition: Double?
    private let library = KyroPodcastLibrary.shared

    enum Panel: String, Identifiable { case queue, chapters; var id: String { rawValue } }
    private var palette: KyroRadioPlayerPalette { .of(library.preferences.theme) }

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                header
                KyroCassetteDeck(entry: entry, palette: palette, wood: wood, player: player,
                                 state: player.state, playing: player.isAdvancing, visible: visible && dialog == nil,
                                 active: scenePhase == .active,
                                 reduceMotion: reduceMotion, draftPosition: draftPosition)
                KyroPodcastEpisodePanel(entry: entry, player: player, palette: palette, draftPosition: $draftPosition)
                KyroCassetteControls(entry: entry, player: player, palette: palette)
                outputControls
            }.frame(maxWidth: 520).padding(.horizontal, 18).padding(.top, 12).padding(.bottom, 24)
                .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
        .foregroundStyle(palette.headerText)
        .tint(palette.isModern ? palette.edgeGlow : palette.controlIcon)
        .background(LinearGradient(colors: [palette.backgroundTop, palette.backgroundBottom],
                                   startPoint: .topLeading, endPoint: .bottomTrailing).ignoresSafeArea())
        .environment(\.colorScheme, .dark)
        .onAppear { visible = true }
        .onDisappear { visible = false }
        .onChange(of: entry.id) { _, _ in draftPosition = nil; dialog = nil }
        .task(id: library.preferences.theme) {
            if palette.usesWood, wood == nil { wood = await KyroRadioTextures.wood(width: 960, height: 560) }
        }
        .sheet(item: $dialog) { item in
            NavigationStack {
                switch item {
                case .queue: KyroPodcastQueueView()
                case .chapters: KyroCassetteChapters(url: entry.episode.chaptersURL, player: player)
                }
            }
        }
        .accessibilityIdentifier("kyroCassettePlayer")
    }

    private var header: some View {
        HStack {
            Button("Close", systemImage: "chevron.down") { dismiss() }
                .labelStyle(.iconOnly)
                .buttonStyle(KyroHardwareButtonStyle(palette: palette, diameter: 44))
            Spacer()
            VStack(spacing: 4) {
                AppWordmarkView(placement: .compactHeader)
                Text("PODCASTS")
                    .font(.caption2.weight(.medium)).tracking(3)
                    .foregroundStyle(palette.headerText.opacity(0.85))
            }
            Spacer()
            KyroAudioThemeMenu(selection: library.preferences.theme, palette: palette, select: library.selectTheme)
        }
    }

    private var outputControls: some View {
        HStack(spacing: 8) {
            KyroCassetteVolume(tint: palette.isModern ? palette.edgeGlow : palette.controlIcon)
                .frame(height: 40)
            KyroAudioOutputPicker(tint: palette.controlIcon, activeTint: palette.miniAccent)
                .frame(width: 44, height: 44)
                .accessibilityLabel("Audio output, AirPlay and Bluetooth")
            if entry.episode.chaptersURL != nil {
                Button("Chapters", systemImage: "list.bullet.rectangle") { dialog = .chapters }
                    .labelStyle(.iconOnly).frame(width: 44, height: 44)
            }
            Button("Queue", systemImage: "list.number") { dialog = .queue }
                .labelStyle(.iconOnly).frame(width: 44, height: 44)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 10)
        .background(Color.black.opacity(0.20), in: .rect(cornerRadius: 14))
    }
}

private struct KyroPodcastEpisodePanel: View {
    let entry: PodcastEntry
    let player: KyroPodcastPlayer
    let palette: KyroRadioPlayerPalette
    @Binding var draftPosition: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(entry.showTitle)
                .font(.subheadline.weight(.semibold)).foregroundStyle(palette.panelSecondary)
            Text(entry.episode.title)
                .font(.system(.title2, design: palette.titleDesign, weight: .bold))
                .foregroundStyle(palette.panelPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            if player.state == .failed {
                Label("This episode couldn’t play. Tap Play to retry.", systemImage: "exclamationmark.circle")
                    .font(.footnote).foregroundStyle(palette.panelPrimary)
            } else if player.state == .loading || (player.state == .playing && !player.isAdvancing) {
                Label("Buffering…", systemImage: "ellipsis")
                    .font(.footnote).foregroundStyle(palette.panelSecondary)
            }
            KyroCassetteTimeline(player: player, palette: palette, draftPosition: $draftPosition)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background { palette.panel() }
    }
}

private struct KyroCassetteDeck: View {
    let entry: PodcastEntry
    let palette: KyroRadioPlayerPalette
    let wood: UIImage?
    let player: KyroPodcastPlayer
    let state: KyroPodcastPlayer.State
    let playing: Bool
    let visible: Bool
    let active: Bool
    let reduceMotion: Bool
    let draftPosition: Double?

    var body: some View {
        VStack(spacing: 9) {
            HStack {
                Text("STEREO").tracking(4)
                Spacer()
                Circle().fill(playing ? palette.lamp : palette.metalDark).frame(width: 7, height: 7)
                    .shadow(color: playing ? palette.lamp : .clear, radius: 5)
                Text(playing ? "PLAY" : state == .failed ? "ERROR" : (state == .loading || state == .playing) ? "LOAD" : "STANDBY")
            }
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .foregroundStyle(palette.controlIcon)
            KyroCassetteShell(entry: entry, palette: palette, player: player, playing: playing,
                              visible: visible, active: active, reduceMotion: reduceMotion, draftPosition: draftPosition)
            HStack {
                Image(systemName: "minus.circle.fill")
                Spacer()
                Text(palette.isModern ? "KYRO X  /  STREAM SERIES" : "HIGH FIDELITY  •  TYPE II").tracking(1).lineLimit(1)
                Spacer()
                Image(systemName: "minus.circle.fill")
            }
            .font(.system(size: 10, weight: .medium, design: .monospaced))
            .foregroundStyle(palette.metalLight)
        }
        .padding(13)
        .background {
            let shape = RoundedRectangle(cornerRadius: 20)
            shape.fill(LinearGradient(colors: [palette.plinthTop, palette.plinthBottom],
                                      startPoint: .top, endPoint: .bottom))
                .overlay {
                    if palette.usesWood, let wood {
                        Image(uiImage: wood).resizable().scaledToFill().opacity(0.78)
                            .frame(maxWidth: .infinity, maxHeight: .infinity).clipped()
                    }
                }
                .clipShape(shape)
                .overlay(shape.strokeBorder(palette.plinthEdge, lineWidth: 1))
        }
        .shadow(color: .black.opacity(0.55), radius: 10, y: 8)
        .accessibilityHidden(true)
    }
}

private struct KyroCassetteShell: View {
    let entry: PodcastEntry
    let palette: KyroRadioPlayerPalette
    let player: KyroPodcastPlayer
    let playing: Bool
    let visible: Bool
    let active: Bool
    let reduceMotion: Bool
    let draftPosition: Double?

    var body: some View {
        VStack(spacing: 7) {
            HStack(spacing: 8) {
                KyroPodcastArtwork(url: entry.showArtwork ?? entry.artwork, size: 38)
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.showTitle).font(.system(.subheadline, design: palette.titleDesign, weight: .semibold)).lineLimit(2)
                    Text("PODCAST SERIES").tracking(1.5).font(.system(size: 9, weight: .semibold, design: .monospaced))
                }
                Spacer(minLength: 2)
                Text("A").font(.system(size: 21, weight: .heavy, design: .monospaced)).padding(.horizontal, 5)
            }
            .foregroundStyle(Color(uiColor: palette.labelInk))
            .padding(8)
            .background(Color(uiColor: palette.label), in: .rect(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color(uiColor: palette.labelRing).opacity(0.55)))
            KyroTapeWindow(palette: palette, player: player, playing: playing, visible: visible,
                           active: active, reduceMotion: reduceMotion, draftPosition: draftPosition)
            HStack(spacing: 7) {
                Circle().fill(palette.metalLinear).frame(width: 6, height: 6)
                RoundedRectangle(cornerRadius: 3).fill(.black.gradient).frame(maxWidth: 100).frame(height: 15)
                    .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(.white.opacity(0.18)))
                Circle().fill(palette.metalLinear).frame(width: 6, height: 6)
            }.padding(.top, 2)
        }
        .padding(11)
        .background(LinearGradient(colors: [palette.isModern ? palette.plinthTop : Color(white: 0.24), .black, palette.plinthBottom],
                                   startPoint: .top, endPoint: .bottom), in: .rect(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.19)))
        .overlay(RoundedRectangle(cornerRadius: 10).inset(by: 3).strokeBorder(.black.opacity(0.8)))
    }
}

private struct KyroTapeWindow: View {
    let palette: KyroRadioPlayerPalette
    let player: KyroPodcastPlayer
    let playing, visible, active, reduceMotion: Bool
    let draftPosition: Double?
    var body: some View {
        let clock = player.clock
        let fraction = draftPosition.map { clock.duration > 0 ? $0 / clock.duration : 0 } ?? clock.fraction
        let tape = PodcastCassetteMotion.tapeSizes(fraction: fraction)
        let seeking = clock.seeking || draftPosition != nil
        let spins = PodcastCassetteMotion.spins(playing: playing, seeking: seeking,
            visible: visible, active: active, reduceMotion: reduceMotion)
        GeometryReader { geometry in
            let diameter = min(67, geometry.size.width * 0.30)
            ZStack {
                RoundedRectangle(cornerRadius: 12).fill(Color(white: 0.065))
                Capsule().fill(LinearGradient(colors: [palette.isModern ? palette.edgeGlow.opacity(0.38) :
                                                        Color(red: 0.33, green: 0.18, blue: 0.11), .black],
                                               startPoint: .top, endPoint: .bottom))
                    .frame(width: geometry.size.width * 0.55, height: 5)
                    .offset(y: 16)
                HStack {
                    reel(tape.0, diameter: diameter, spins: spins, seeking: seeking)
                    Spacer(minLength: 1)
                    reel(tape.1, diameter: diameter, spins: spins, seeking: seeking)
                }.padding(.horizontal, geometry.size.width * 0.10)
                RoundedRectangle(cornerRadius: 12)
                    .fill(LinearGradient(colors: [.white.opacity(0.19), .clear, palette.sheen],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                RoundedRectangle(cornerRadius: 12).strokeBorder(palette.isModern ? palette.panelStroke : .white.opacity(0.28))
            }
        }.frame(height: 78)
    }

    private func reel(_ amount: Double, diameter: CGFloat, spins: Bool, seeking: Bool) -> some View {
        ZStack {
            Circle().strokeBorder(palette.metalMid.opacity(0.25), lineWidth: 1).frame(width: diameter, height: diameter)
            Circle()
                .fill(RadialGradient(colors: [Color(white: 0.12), Color(red: 0.24, green: 0.12, blue: 0.07), .black],
                                     center: .center, startRadius: 0, endRadius: diameter * 0.49 * amount))
                .frame(width: diameter * amount, height: diameter * amount)
            Circle().strokeBorder(.white.opacity(0.13), lineWidth: 1).frame(width: diameter * amount, height: diameter * amount)
            KyroCassetteHubRotation(spins: spins, fast: seeking,
                                    color: UIColor(palette.isModern ? palette.lamp : palette.metalLight))
                .frame(width: diameter * 0.36, height: diameter * 0.36)
        }.frame(width: diameter, height: diameter)
    }
}

/// Only a CALayer transform runs between playback ticks, not a timeline view,
/// canvas, timer, or SwiftUI animation at display refresh rate.
private struct KyroCassetteHubRotation: UIViewRepresentable {
    let spins: Bool
    let fast: Bool
    let color: UIColor

    func makeUIView(context: Context) -> Hub { Hub() }
    func updateUIView(_ view: Hub, context: Context) { view.update(spins: spins, fast: fast, color: color) }
    static func dismantleUIView(_ view: Hub, coordinator: ()) { view.update(spins: false, fast: false, color: .gray) }

    final class Hub: UIView {
        private let sprocket = CAShapeLayer()
        private var fast = false
        private var spinning = false

        init() {
            super.init(frame: .zero)
            layer.addSublayer(sprocket)
            isUserInteractionEnabled = false
        }
        required init?(coder: NSCoder) { nil }
        override func layoutSubviews() {
            super.layoutSubviews()
            guard !bounds.isEmpty, bounds != sprocket.bounds else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            sprocket.bounds = bounds
            sprocket.position = CGPoint(x: bounds.midX, y: bounds.midY)
            let path = UIBezierPath(ovalIn: bounds.insetBy(dx: 1, dy: 1))
            let center = CGPoint(x: bounds.midX, y: bounds.midY)
            let radius = min(bounds.width, bounds.height) * 0.33
            path.append(UIBezierPath(arcCenter: center, radius: radius, startAngle: 0,
                                     endAngle: .pi * 2, clockwise: false))
            for spoke in 0..<6 {
                let angle = CGFloat(spoke) * .pi / 3
                let center = CGPoint(x: center.x + cos(angle) * radius, y: center.y + sin(angle) * radius)
                path.append(UIBezierPath(ovalIn: CGRect(x: center.x - 1.7, y: center.y - 1.7, width: 3.4, height: 3.4)))
            }
            sprocket.fillRule = .evenOdd
            sprocket.path = path.cgPath
            CATransaction.commit()
        }

        func update(spins: Bool, fast: Bool, color: UIColor) {
            if sprocket.fillColor != color.cgColor { sprocket.fillColor = color.cgColor }
            guard spinning != spins || self.fast != fast else { return }
            spinning = spins; self.fast = fast
            let phase = (sprocket.presentation() ?? sprocket).value(forKeyPath: "transform.rotation.z") as? Double ?? 0
            sprocket.removeAnimation(forKey: "reel")
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            sprocket.setValue(phase, forKeyPath: "transform.rotation.z")
            CATransaction.commit()
            if spins {
                let animation = CABasicAnimation(keyPath: "transform.rotation.z")
                animation.fromValue = phase
                animation.toValue = phase + Double.pi * 2
                animation.duration = fast ? 0.28 : 1.6
                animation.repeatCount = .infinity
                sprocket.add(animation, forKey: "reel")
            }
        }
    }
}

private struct KyroCassetteTimeline: View {
    let player: KyroPodcastPlayer
    let palette: KyroRadioPlayerPalette
    @Binding var draftPosition: Double?

    var body: some View {
        let clock = player.clock
        let value = draftPosition ?? clock.position
        VStack(spacing: 3) {
            Slider(value: Binding(get: { min(max(0, value), max(1, clock.duration)) }, set: { draftPosition = $0 }),
                   in: 0...max(1, clock.duration), onEditingChanged: { editing in
                if editing { draftPosition = clock.position }
                else if let value = draftPosition { player.seek(value); draftPosition = nil }
            })
            .disabled(clock.duration <= 0 || player.state == .loading || player.state == .failed)
            .tint(palette.isModern ? palette.edgeGlow : palette.panelPrimary)
            .accessibilityLabel("Playback Position")
            .accessibilityAdjustableAction { direction in
                if direction == .increment { player.skip(15) }
                else if direction == .decrement { player.skip(-15) }
            }
            HStack {
                Text(Self.time(value))
                Spacer()
                Text(Self.time(clock.duration))
            }
            .font(.caption.weight(.medium).monospacedDigit())
            .foregroundStyle(palette.panelSecondary)
        }
    }

    private static func time(_ seconds: Double) -> String {
        let value = Int(seconds.isFinite ? min(604_800, max(0, seconds)) : 0)
        return value >= 3600 ? String(format: "%d:%02d:%02d", value / 3600, value / 60 % 60, value % 60)
            : String(format: "%d:%02d", value / 60, value % 60)
    }
}

private struct KyroCassetteControls: View {
    let entry: PodcastEntry
    let player: KyroPodcastPlayer
    let palette: KyroRadioPlayerPalette
    private let library = KyroPodcastLibrary.shared

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                metalKey("Back \(library.preferences.back) seconds", icon: "gobackward", seconds: library.preferences.back) {
                    player.skip(-Double(library.preferences.back))
                }
                let running = player.state == .playing || player.state == .loading
                metalKey(running ? "Pause" : "Play", icon: running ? "pause.fill" : "play.fill", primary: true, action: player.toggle)
                metalKey("Forward \(library.preferences.forward) seconds", icon: "goforward", seconds: library.preferences.forward) {
                    player.skip(Double(library.preferences.forward))
                }
            }
            HStack(spacing: 6) {
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
                        .monospacedDigit().frame(maxWidth: .infinity, minHeight: 44)
                }
                .accessibilityLabel("Playback Speed")
                .accessibilityValue(library.preferences.speed.formatted() + "×")
                Menu {
                    ForEach(PodcastPreferences.sleepOptions, id: \.self) { minutes in
                        Button(KyroPodcastSettings.sleepLabel(minutes)) { player.setSleep(minutes) }
                    }
                } label: {
                    Label("Sleep Timer", systemImage: player.sleep == .off ? "moon" : "moon.fill")
                        .labelStyle(.iconOnly).frame(maxWidth: .infinity, minHeight: 44)
                }
                Button {
                    library.toggleSaved(entry)
                } label: {
                    Label(library.saved.contains(entry.id) ? "Unsave Episode" : "Save Episode",
                          systemImage: library.saved.contains(entry.id) ? "bookmark.fill" : "bookmark")
                        .labelStyle(.iconOnly).frame(maxWidth: .infinity, minHeight: 44)
                }
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(palette.controlIcon)
            .tint(palette.controlIcon)
            .background {
                let shape = RoundedRectangle(cornerRadius: 14)
                shape.fill(palette.plinthTop).overlay(shape.strokeBorder(palette.plinthEdge))
            }
        }
    }

    private func metalKey(_ title: String, icon: String, seconds: Int? = nil,
                          primary: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: primary ? 24 : 18, weight: .semibold))
                if let seconds { Text(String(seconds)).font(.caption.monospacedDigit().bold()) }
            }
            .foregroundStyle(primary ? palette.transportInk : palette.controlIcon)
            .frame(maxWidth: .infinity, minHeight: 54)
            .background {
                let key = RoundedRectangle(cornerRadius: palette.isModern ? 18 : 12)
                let surface = LinearGradient(colors: primary
                    ? (palette.isModern ? [palette.lamp, palette.edgeGlow] : [palette.metalLight, palette.metalMid])
                    : [palette.plinthTop, palette.plinthBottom], startPoint: .top, endPoint: .bottom)
                key.fill(surface)
                    .overlay(key.strokeBorder(primary && palette.isModern ? palette.lamp : palette.metalMid, lineWidth: 0.8))
                    .shadow(color: primary ? palette.edgeGlow.opacity(0.22) : .black.opacity(0.4), radius: 5, y: 3)
            }
        }.buttonStyle(.plain).accessibilityLabel(title)
    }
}

private struct KyroCassetteVolume: UIViewRepresentable {
    let tint: Color

    func makeUIView(context: Context) -> MPVolumeView {
        let view = MPVolumeView()
        view.showsRouteButton = false
        view.accessibilityLabel = "Volume"
        return view
    }
    func updateUIView(_ view: MPVolumeView, context: Context) {
        for case let slider as UISlider in view.subviews {
            slider.minimumTrackTintColor = UIColor(tint)
        }
    }
}

private struct KyroCassetteChapters: View {
    let url: URL?
    let player: KyroPodcastPlayer
    @State private var chapters: [PodcastFeedService.Chapters.Chapter] = []
    @State private var loading = true
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            if loading { ProgressView("Loading Chapters…") }
            else if chapters.isEmpty { Text("No chapters are available.").foregroundStyle(.secondary) }
            ForEach(chapters) { chapter in
                Button(chapter.title ?? "Chapter at \(Int(min(604_800, chapter.startTime))) seconds") {
                    player.seek(chapter.startTime); dismiss()
                }
            }
        }
        .navigationTitle("Chapters").navigationBarTitleDisplayMode(.inline)
        .task(id: url) {
            if let url { chapters = (try? await PodcastFeedService.shared.chapters(at: url)) ?? [] }
            loading = false
        }
    }
}
#endif
