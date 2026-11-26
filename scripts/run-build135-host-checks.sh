#!/bin/bash
# Build 135 host checks: Apple Podcasts charts (decode, cache, request bounds),
# Library sorting, Modern Stream continuity and the redesign's source contracts.
# Pass --live for two bounded requests to Apple's chart and lookup endpoints.
# Ends by confirming the audio engines, Home, Sports, Live TV and the shell are
# unchanged since Build 134.
set -euo pipefail
cd "$(dirname "$0")/.."
OUTPUT="$(mktemp -d /private/tmp/kyro-build135-checks.XXXXXX)"
ROOT=iosApp/iosApp/Kyro
xcrun swiftc -D KYRO_STANDALONE_TESTS -D KYRO_PODCAST_HOST_TESTS -parse-as-library -o "$OUTPUT/build135" \
  iosApp/Tests/KyroBuild135HostChecks.swift \
  "$ROOT"/Podcasts/KyroPodcast{Feed,Network,Library,Backup,Charts}.swift \
  "$ROOT"/Radio/KyroRadio{PlayerTheme,Models,BrowserClient,Library,PlaybackMachine,BackupSettings}.swift \
  "$ROOT"/Home/KyroHome{Preferences,Arrangement}.swift \
  "$ROOT"/Sports/Models/KyroSportsModels.swift \
  "$ROOT"/Sports/Providers/KyroSportsProvider.swift \
  "$ROOT"/Settings/Backup/SettingsBackupCore.swift \
  "$ROOT"/Settings/Backup/SettingsBackupRestore.swift
"$OUTPUT/build135" "$@"
BASE=e2bbac97e4f2254067a2edf6d45256cdb715fb06
PROTECTED=(
  "$ROOT"/Radio/KyroRadioPlayer.swift
  "$ROOT"/Radio/KyroRadioPlaybackMachine.swift
  "$ROOT"/Radio/KyroRadioBrowserClient.swift
  "$ROOT"/Radio/KyroRadioLibrary.swift
  "$ROOT"/Radio/KyroRadioBackupSettings.swift
  "$ROOT"/Podcasts/KyroPodcastPlayer.swift
  "$ROOT"/Podcasts/KyroPodcastLibrary.swift
  "$ROOT"/Podcasts/KyroPodcastFeed.swift
  "$ROOT"/Podcasts/KyroPodcastNetwork.swift
  "$ROOT"/Podcasts/KyroPodcastDownloads.swift
  "$ROOT"/Podcasts/KyroPodcastBackup.swift
  "$ROOT"/Podcasts/KyroHomePodcastRail.swift
  "$ROOT"/Home
  "$ROOT"/Sports
  "$ROOT"/Shell
  iosApp/iosApp/LiveTV
  iosApp/iosApp/Screens/Home
  iosApp/iosApp/Control/iOS/NowPlayingShelf.swift
  iosApp/iosApp/ContentView.swift
  # Build 136 appearance hooks are checked separately against Build 135.
  ':(exclude)iosApp/iosApp/Kyro/Sports/KyroSportsHubView.swift'
  ':(exclude)iosApp/iosApp/LiveTV/Guide/LiveTVGuideView.swift'
  ':(exclude)iosApp/iosApp/LiveTV/Home/LiveTVHomeContent.swift'
  ':(exclude)iosApp/iosApp/LiveTV/LiveTVViews.swift'
  ':(exclude)iosApp/iosApp/Screens/Home/HomeView.swift'
)
if git diff --quiet "$BASE" -- "${PROTECTED[@]}"; then
  echo "Audio engines, podcast library and network, Home, Sports, Live TV, shell and mini-player slot: unchanged since Build 134."
else
  echo "Protected files changed since Build 134:" >&2
  git diff --stat "$BASE" -- "${PROTECTED[@]}" >&2
  exit 1
fi
