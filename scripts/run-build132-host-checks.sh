#!/bin/bash
# Build 132 host checks: player theme persistence and backup, turntable motion
# rules, source contracts, and that the protected Radio files are unchanged
# since Build 131.
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
# The stream engine, discovery, library, mini-player slot, Home and Sports stay as Build 131 left them.
BASE=2b06e11112b6eff34b08c32c6a448bfe3cc294a7
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
)
if git diff --quiet "$BASE" -- "${PROTECTED[@]}"; then
  echo "Protected Radio engine, mini-player slot, Home, Sports, Live TV and shell files: unchanged since Build 131."
else
  echo "Protected files changed since Build 131:" >&2
  git diff --stat "$BASE" -- "${PROTECTED[@]}" >&2
  exit 1
fi
