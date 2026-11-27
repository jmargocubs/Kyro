# Build 140 readiness: IPTV music playback, Music Sources and mini-player

Version 1.0.140 (140), iOS only, on `kyro/ios-recovered`. Builds on Build 139 (`33c5423364f8c64f120bf90fcae16cb86a4c84fc`). It is not packaged, pushed or tested on a device, and no IPTV stream was played on the Mac.

## IPTV music playback

### What Build 139 did (confirmed in code)
- **Different stream:** for Xtream accounts, Radio rewrote the channel's `.ts` address to `.m3u8`, even when the account never advertised HLS. That plays the provider's on-demand HLS segmenter, not the stream Kyro Live TV and other IPTV apps read.
- **Short buffer:** it used AVPlayer with `preferredForwardBufferDuration = 8`. That is less than one typical 10-second live IPTV segment, so any delivery jitter stalls playback.
- **Slow fallback:** an account without HLS waited for the 20-second startup timeout before trying the original address.
- **Full rebuild on every drop:** any AVPlayer failure, or the playlist reporting an end, tore the player down and rebuilt it.

Kyro Live TV plays the same channels from their original address through AetherEngine (FFmpeg). The likely cause of the poor sound and frequent buffering is this route difference, not the provider. The code shows the route difference. The audio difference has not been measured.

### Build 140 architecture
- **Engine:** IPTV music channels play through `KyroIPTVAudioEngine`, an AetherEngine adapter that uses:
  - the channel's original address, unchanged, the same one Watch in Live TV uses
  - `isLive: true`, so the engine reconnects a dropped connection and never reads one as the end of the stream
  - `audioOnly: true`, so video is never decoded
  - `preferredDecodePath: .software`, the FFmpeg audio host, which reads raw MPEG-TS, decodes AAC, MP2, AC-3 and E-AC-3 at the source's own rate, and has no Now Playing session of its own
- **HLS fallback:** the `.m3u8` variant is tried only when the account lists `m3u8`, and only if the original address fails to start.
- **Session:** `KyroRadioPlayer` still owns the station, the playback machine, history, favorites, Lock Screen and Control Center controls, and playback exclusivity, so Radio keeps one session. All three player themes and the mini-player read the same state.
- **Stalls:** if a playing stream waits 20 seconds, including the engine's own reconnects, Radio reconnects with 1, 2 and 4 second backoff, then shows Retry.
- **Internet Radio and Podcasts:** their engines are unchanged.
- **Logs:** the route, decoder label and track count are logged, never the address.

### Unverified on a device
Background audio, AirPlay and Bluetooth routing, Lock Screen controls, and the actual audio quality and buffering of SiriusXM, Music Choice and Stingray channels.

## Music Sources
- **Collection pages:** show "Loading channels…" until the first page returns, instead of a brief "No Channels".
- **Unavailable sources:** a collection with no enabled provider shows "Source Unavailable".
- **Counts:** each collection page shows a count and its providers. Discover and collection pages use one count format ("1 channel", "312 channels", "1,000+ channels").
- **Discover:** shows progress while the first classification runs.
- **Paging:** providers without the collection are skipped.
- **Classifier:** unchanged. Manual classification and provider selection are untouched.

## Mini-player
- **Signature card:** the card on pushed Radio and Podcast pages and the iOS 18 tab bar is near-opaque (97%), with one hairline edge and a drop shadow. Build 139 laid a 78% fill over a backdrop-sampling glass and drew two borders.
- **iOS 26 tab accessory:** keeps the system Liquid Glass with a light crimson cast.
- **Classic appearance:** keeps Silo's chrome.
- **Shared layout:** the Radio and Podcast bars use `KyroAudioMiniLayout`, with 44 pt artwork (32 pt inline), 12 pt spacing, a 40 pt control inside a 44 pt tap target, and 12 pt side margins.
- **IPTV status line:** a playing IPTV channel shows "Live · collection · provider".
- **Unchanged:** keyboard handling and the single shelf.

## Validation
- `scripts/run-build140-host-checks.sh`: 54 checks covering the route, load plan, transport rules for IPTV streams, counts and source contracts.
- `scripts/run-build139-host-checks.sh`: 127 checks. Its route expectations were updated to the Build 140 order.
- Builds 121, 128, 130, 131, 133 and 138 pass. The file-freeze checks in Builds 132 and 135–137 were already stale.
- Generic iOS Release build with `-jobs 2` and `CODE_SIGNING_ALLOWED=NO`: succeeded.
