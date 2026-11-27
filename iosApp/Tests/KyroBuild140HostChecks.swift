#if KYRO_STANDALONE_TESTS
import Foundation

// Build 140 host checks: IPTV music playback route (original address first,
// AetherEngine audio-only plan, HLS only as an advertised fallback), the Radio
// transport rules for those streams (fallback, stalls, reconnects, stale
// events), collection counts, and source contracts for the engine adapter,
// Music Sources states and the mini-player surface. Synthetic fixtures only;
// nothing here plays audio.
@main
enum KyroBuild140HostChecks {
    static var count = 0
    static func check(_ condition: Bool, _ title: String) {
        precondition(condition, title)
        count += 1
    }

    static func main() throws {
        routeSelection()
        loadPlans()
        transportRules()
        counts()
        try sourceContracts()
        print("Build 140: \(count) IPTV playback, Music Sources and mini-player checks passed.")
    }

    // MARK: Route

    static func routeSelection() {
        let ts = URL(string: "http://provider.example/live/user/pass/1234.ts")!
        let hls = URL(string: "http://provider.example/live/user/pass/1234.m3u8")!
        check(KyroIPTVAudioRoute.candidates(for: ts, isXtream: true, allowedFormats: ["ts", "m3u8"]) == [ts, hls],
              "Xtream: the original TS first, the advertised HLS second")
        check(KyroIPTVAudioRoute.candidates(for: ts, isXtream: true, allowedFormats: []) == [ts],
              "Xtream with no advertised formats: never guesses an HLS address")
        check(KyroIPTVAudioRoute.candidates(for: ts, isXtream: true, allowedFormats: ["ts"]) == [ts], "TS-only account")
        check(KyroIPTVAudioRoute.candidates(for: ts, isXtream: false, allowedFormats: ["m3u8"]) == [ts],
              "M3U playlist addresses are played as given")
        let query = URL(string: "https://cdn.example/play/1234.ts?token=abc")!
        check(KyroIPTVAudioRoute.candidates(for: query, isXtream: true, allowedFormats: ["m3u8"]).last?.absoluteString
              == "https://cdn.example/play/1234.m3u8?token=abc", "the HLS fallback keeps the query untouched")
        check(KyroIPTVAudioRoute.candidates(for: URL(string: "rtsp://x.example/a")!, isXtream: false, allowedFormats: []).isEmpty,
              "non-web streams refused")

        let provider = UUID()
        var station = KyroRadioStation(id: "\(provider.uuidString):9", name: "Music Choice Hits", streamURL: ts, resolvedURL: hls)
        station.iptv = KyroIPTVStationSource(providerID: provider, providerName: "P", channelID: station.id,
                                             collection: .musicChoice, category: "Music Choice", guideID: nil)
        check(station.playbackCandidates == [ts, hls], "station plays its own address first")
        check(station.isPlayable, "IPTV stations with no codec label are tried")
        var single = station
        single.resolvedURL = nil
        check(single.playbackCandidates == [ts], "no fallback without an advertised HLS address")
        // Radio Browser stations keep their rules (resolved first, https first).
        let radio = KyroRadioStation(id: "0b1a0a5e-2b3c-4d5e-8f90-123456789abc", name: "Jazz",
                                     streamURL: URL(string: "http://j.example/live"), resolvedURL: URL(string: "https://j.example/r"))
        check(radio.playbackCandidates.map(\.scheme) == ["https", "http"], "Internet Radio candidate order unchanged")
    }

    static func loadPlans() {
        let ts = KyroIPTVAudioLoadPlan(url: URL(string: "http://p.example/live/u/p/1.ts")!)
        check(ts.route == .transportStream && ts.isLive && ts.audioOnly && ts.softwareDecode,
              "TS: live, audio only, FFmpeg audio host")
        let hls = KyroIPTVAudioLoadPlan(url: URL(string: "https://p.example/hls/1.M3U8")!)
        check(hls.route == .hls && hls.isLive && hls.audioOnly && hls.softwareDecode,
              "HLS: same audio host, so no second Now Playing session")
        check(KyroIPTVAudioLoadPlan(url: URL(string: "http://p.example/live/u/p/1")!).route == .transportStream,
              "an extensionless address is read as a stream, like Live TV")
    }

    // MARK: Transport rules for IPTV streams

    static func transportRules() {
        let provider = UUID()
        let ts = URL(string: "http://provider.example/live/u/p/7.ts")!
        let hls = URL(string: "http://provider.example/live/u/p/7.m3u8")!
        var station = KyroRadioStation(id: "\(provider.uuidString):7", name: "SiriusXM Hits 1", streamURL: ts, resolvedURL: hls)
        station.iptv = KyroIPTVStationSource(providerID: provider, providerName: "P", channelID: station.id,
                                             collection: .siriusXM, category: "SiriusXM", guideID: nil)

        var machine = KyroRadioPlaybackMachine()
        var effects = machine.play(station)
        check(effects == [.recordStart, .load(candidate: 0, generation: 1)], "starts on the original address")
        // The original fails to start: the advertised HLS fallback is tried once.
        effects = machine.playerFailed(generation: 1)
        check(effects == [.load(candidate: 1, generation: 2)] && machine.state == .connecting, "startup failure tries HLS")
        // A late failure from the first load is ignored.
        check(machine.playerFailed(generation: 1).isEmpty && machine.candidate == 1, "stale engine events ignored")
        machine.playerStarted(generation: 2)
        check(machine.state == .playing, "HLS fallback plays")

        // A stall the engine can't recover reconnects with backoff, then fails clearly.
        var drops: [TimeInterval] = []
        for attempt in 1...KyroRadioPlaybackMachine.maxReconnectAttempts {
            let result = machine.playerFailed(generation: machine.generation)
            guard case .scheduleReconnect(let delay, let generation)? = result.last else {
                check(false, "reconnect \(attempt) scheduled"); return
            }
            drops.append(delay)
            check(machine.state == .reconnecting(attempt: attempt), "reconnecting \(attempt)")
            check(machine.reconnectDue(generation: generation) == [.load(candidate: 1, generation: generation)],
                  "reconnect \(attempt) reloads the address that was playing")
        }
        check(drops == [1, 2, 4], "reconnect backoff 1 s, 2 s, 4 s")
        check(machine.playerFailed(generation: machine.generation) == [.stopPlayer]
              && machine.state == .failed(.streamFailed), "then a clear failure with Retry")
        check(machine.resume() == [.load(candidate: 0, generation: machine.generation)],
              "Retry starts again from the original address")

        // A reconnect that succeeds resets the budget.
        machine.playerStarted(generation: machine.generation)
        _ = machine.playerFailed(generation: machine.generation)
        machine.playerStarted(generation: machine.generation)
        check(machine.state == .playing && machine.reconnectAttempts == 0, "a recovered stream gets a fresh budget")

        // Exclusivity and stop.
        check(machine.yieldToOtherPlayback() == [.pausePlayer] && machine.state == .paused, "Live TV or video pauses IPTV radio")
        check(machine.stop() == [.stopPlayer] && machine.station == nil, "stop ends the one session")
    }

    static func counts() {
        check(KyroIPTVMusicCounts.label(0) == "No channels", "zero")
        check(KyroIPTVMusicCounts.label(1) == "1 channel", "singular")
        check(KyroIPTVMusicCounts.label(312) == "312 channels", "plural")
        check(KyroIPTVMusicCounts.label(1_000) == "1,000+ channels" && KyroIPTVMusicCounts.label(54_000) == "1,000+ channels",
              "bounded counts read 1,000+")
    }

    // MARK: Source contracts

    static func source(_ path: String) throws -> String {
        try String(contentsOf: URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("iosApp/iosApp/" + path), encoding: .utf8)
    }

    static func sourceContracts() throws {
        let engine = try source("Kyro/Radio/KyroIPTVAudioEngine.swift")
        let player = try source("Kyro/Radio/KyroRadioPlayer.swift")
        let music = try source("Kyro/Radio/KyroIPTVMusic.swift")
        let views = try source("Kyro/Radio/KyroRadioViews.swift")
        let podcast = try source("Kyro/Podcasts/KyroPodcastCassette.swift")
        let theme = try source("KyroTheme/KyroTheme.swift")
        let shelf = try source("Control/iOS/NowPlayingShelf.swift")

        // Engine adapter.
        check(engine.contains("LoadOptions(isLive: plan.isLive, audioOnly: plan.audioOnly")
              && engine.contains("preferredDecodePath: plan.softwareDecode ? .software : .automatic"),
              "IPTV loads use the live audio-only plan")
        check(!engine.contains("ownsSoftwareNowPlaying = true") && !engine.contains("audioNowPlayingSession"),
              "the engine never takes Now Playing from Radio")
        check(engine.contains("AetherAudioSessionOwnership.Claim(engine: engine)")
              && engine.contains("canReleaseSharedSession(excluding:"), "shared audio session ownership respected")
        check(!engine.contains("url.absoluteString") && !engine.contains("\\(url"), "stream addresses are never logged")
        check(!engine.contains("transcod") || engine.contains("nothing is transcoded"), "no transcoding")

        // Player integration: one session, AVPlayer kept for Radio Browser.
        check(player.contains("if station.iptv != nil {\n            startIPTV(url, generation: generation)"),
              "IPTV stations go to AetherEngine")
        check(player.contains("let item = AVPlayerItem(asset: AVURLAsset(url: url))")
              && player.contains("item.preferredForwardBufferDuration = 8"), "Internet Radio's AVPlayer path is unchanged")
        check(player.contains("iptvEngine?.stop(releaseAudioSession: false)"), "every teardown stops the IPTV engine too")
        check(player.contains("guard generation == machine.generation, machine.isActive else { return }"),
              "engine events from an earlier load are ignored")
        check(player.contains("KyroPlaybackExclusivity.shared.register(self, source: .radio)")
              && player.contains("SharedNowPlayingArbiter.shared.claim(self"), "exclusivity and Lock Screen stay with Radio")
        check(music.contains("guard let original = candidates.first else { return nil }")
              && music.contains("LiveTVChannel(id: source.channelID, guideID: source.guideID, name: station.name, streamURL: stream"),
              "Watch in Live TV uses the channel's own address")

        // Music Sources states.
        check(music.contains("ProgressView(\"Loading channels…\")") && music.contains("\"Source Unavailable\"")
              && music.contains("browser.isLoading || !browser.hasLoaded"), "collection loading, unavailable and empty states")
        check(music.contains("Finding music channels in your IPTV providers…"), "Discover shows classification progress")
        check(music.contains("KyroIPTVMusicCounts.label(count)"), "one count format on Discover and collection pages")
        check(music.contains("filter { $0.count(collection) > 0 }.flatMap"), "providers without the collection are skipped")

        // Mini-player.
        let chrome = theme.components(separatedBy: "struct KyroAudioMiniChrome").last?
            .components(separatedBy: "enum KyroAudioMiniLayout").first ?? ""
        check(!chrome.contains("Material") && !chrome.contains(".blur(") && !chrome.contains("siloGlass"),
              "Signature card draws no backdrop blur")
        check(chrome.contains(".opacity(0.97)") && chrome.contains("NowPlayingBarChrome(style: style)"),
              "near-opaque Signature card; Classic keeps Silo chrome")
        for (name, code) in [("radio", views), ("podcast", podcast)] {
            check(code.contains("KyroAudioMiniLayout.artworkSize(inline: isInline)")
                  && code.contains("KyroAudioMiniLayout.cardSideMargin") && code.contains("KyroAudioMiniChrome(style: style)"),
                  "\(name) bar uses the shared layout")
        }
        check(views.contains("keyboardWillShowNotification") && views.contains("if !isKeyboardVisible {"),
              "the page bar still steps aside for the keyboard")
        check(shelf.contains("} else if KyroRadioPlayer.shared.hasSession {\n            KyroRadioMiniPlayerView(style: style)"),
              "one Now Playing shelf, no duplicate bars")
    }
}
#endif
