# Kyro X iOS 1.0.141 — device acceptance

Build 140’s IPTV audio transport remains unchanged. The player still prefers the original provider address, decodes audio only in AetherEngine and uses the same fallback and recovery policy. The brief SiriusXM stalls were not diagnosed and this change does not tune them.

## Radio state and system controls

Build 140’s Pause stopped the transport and also deactivated the app’s audio session. Radio’s registered remote Stop had a different effect: it cleared the station and released Now Playing. AetherEngine’s software audio host did not own the app’s Now Playing entry. Build 141 leaves the system session and station bound after a pause, and reconnects at the live edge on Play. It advertises play, pause and toggle to system controls rather than a destructive remote Stop. Explicit Stop is still available in the Kyro player. Neither seeking nor skipping is advertised for live streams.

- Start an IPTV station, lock the iPhone, and verify the card and artwork. Pause from the Lock Screen; the station should remain visible. Tap Play and verify the same station reconnects. Repeat from Control Center and with a Bluetooth toggle.
- Use Stop in Kyro’s player and verify it clears that station’s session. Start Podcasts, then Radio, then Live TV or Silo video. Confirm one active audio source and no stale controls from the former source.
- With the screen locked, verify background playback and check the three Radio themes. Internet Radio should still play through its existing path.

## Music Sources

The source covers use local palettes and symbols, not official logos or remote artwork. Check Internet Radio’s crimson radio, SiriusXM’s blue broadcast mark, Music Choice’s purple notes, Stingray’s teal waveform, and both fallback covers. Counts, provider labels and collection links should still match.

## Navigation

On the unified iPhone shell, Settings → Appearance & Navigation → Navigation previews the bar and lets you pin up to four destinations after the fixed Home tab. Remove an item to free a slot, then add and reorder Radio and Podcasts together. Check More for unpinned Movies, Series, Live TV, Sports, For You, Favorites and audio pages. Check Live TV’s Back button when opened from More and its return from Picture in Picture. Repeat with both floating pill styles and the mini-player visible. The legacy and iPad layouts are unchanged.

The existing fourth-tab preference loads into its former slot; Reset restores Home, Movies, Series, Sports and Live TV. A Build 141 backup preserves the full order and imports old fourth-tab values. Older builds can read the backup’s other settings but cannot apply the expanded arrangement.
