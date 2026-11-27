#!/bin/bash
# Build 132 host checks: player theme persistence and backup, turntable motion
# rules, source contracts, and that the protected Radio files are unchanged
# since accepted Build 133.
set -euo pipefail
cd "$(dirname "$0")/.."
OUTPUT="$(mktemp -d /private/tmp/kyro-build132-checks.XXXXXX)"
xcrun swiftc -D KYRO_STANDALONE_TESTS -parse-as-library -o "$OUTPUT/build132" \
  iosApp/Tests/KyroBuild132HostChecks.swift \
  iosApp/iosApp/Kyro/Radio/KyroRadioPlayerTheme.swift \
  iosApp/iosApp/Kyro/Radio/KyroRadioModels.swift \
  iosApp/iosApp/Kyro/Radio/KyroRadioBrowserClient.swift \
  iosApp/iosApp/Kyro/Radio/KyroRadioLibrary.swift \
  iosApp/iosApp/Kyro/Radio/KyroRadioPlaybackMachine.swift \
  iosApp/iosApp/Kyro/Radio/KyroRadioBackupSettings.swift \
  iosApp/iosApp/Kyro/Home/KyroHomePreferences.swift \
  iosApp/iosApp/Kyro/Home/KyroHomeArrangement.swift \
  iosApp/iosApp/Kyro/Home/KyroHomeBackupSettings.swift \
  iosApp/iosApp/Kyro/Sports/Models/KyroSportsModels.swift \
  iosApp/iosApp/Kyro/Sports/Providers/KyroSportsProvider.swift \
  iosApp/iosApp/Kyro/Settings/Backup/SettingsBackupCore.swift \
  iosApp/iosApp/Kyro/Settings/Backup/SettingsBackupRestore.swift
"$OUTPUT/build132"
# The stream engine, discovery, library, mini-player slot, Home and Sports stay as accepted in Build 133.
BASE=aa16b77868a1546dc0aaadad50e6d098e4fa58cd
PROTECTED=(
  iosApp/iosApp/Kyro/Radio/KyroRadioPlayer.swift
  iosApp/iosApp/Kyro/Radio/KyroRadioPlaybackMachine.swift
  iosApp/iosApp/Kyro/Radio/KyroRadioBrowserClient.swift
  iosApp/iosApp/Kyro/Radio/KyroRadioDiscoverModel.swift
  iosApp/iosApp/Kyro/Radio/KyroRadioLibrary.swift
  iosApp/iosApp/Control/iOS/NowPlayingShelf.swift
  iosApp/iosApp/Kyro/Home
  iosApp/iosApp/Kyro/Sports
  iosApp/iosApp/LiveTV
  iosApp/iosApp/Kyro/Shell
  iosApp/iosApp/Screens/Home
  # Build 136 adds presentation-only hooks here; the rest stays protected.
  ':(exclude)iosApp/iosApp/Kyro/Sports/KyroSportsHubView.swift'
  ':(exclude)iosApp/iosApp/LiveTV/Guide/LiveTVGuideView.swift'
  ':(exclude)iosApp/iosApp/LiveTV/Home/LiveTVHomeContent.swift'
  ':(exclude)iosApp/iosApp/LiveTV/LiveTVViews.swift'
  ':(exclude)iosApp/iosApp/Screens/Home/HomeView.swift'
  ':(exclude)iosApp/iosApp/Kyro/Sports/KyroSportsSettingsView.swift'
  ':(exclude)iosApp/iosApp/Kyro/Home/KyroHomeCustomizationView.swift'
)
if git diff --quiet "$BASE" -- "${PROTECTED[@]}"; then
  echo "Protected Radio engine, mini-player slot, Home, Sports, Live TV and shell files: unchanged since Build 133."
else
  echo "Protected files changed since Build 133:" >&2
  git diff --stat "$BASE" -- "${PROTECTED[@]}" >&2
  exit 1
fi
