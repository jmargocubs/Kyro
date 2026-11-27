#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
OUTPUT="$(mktemp -d /private/tmp/kyro-build141-checks.XXXXXX)"
ROOT=iosApp/iosApp/Kyro
xcrun swiftc -D KYRO_STANDALONE_TESTS -parse-as-library -o "$OUTPUT/build141" \
  iosApp/Tests/KyroBuild141HostChecks.swift \
  "$ROOT"/Radio/Kyro{IPTVMusicClassifier,MusicSourceArtwork,RadioModels,RadioPlaybackMachine}.swift \
  "$ROOT"/Shell/KyroGlobalNavigation.swift \
  "$ROOT"/LiveTVNavigation/Kyro{LiveTVNavigationPreferences,LiveTVDestination,NavigationHandleTrace,LiveTVNavigationGeometry}.swift \
  "$ROOT"/Settings/Backup/{KyroPrimaryTabsBackup,SettingsBackupCore}.swift
"$OUTPUT/build141"

bash scripts/run-build129-host-checks.sh
bash scripts/run-build130-host-checks.sh
bash scripts/run-build139-host-checks.sh
bash scripts/run-build140-host-checks.sh

BASE=812c9b2485da8cd19a0cd94eeee8e988012707f1
git diff --exit-code "$BASE" -- \
  "$ROOT"/Radio/Kyro{IPTVAudioEngine,IPTVMusicClassifier,RadioModels,RadioTurntable,RadioPlayerTheme}.swift \
  "$ROOT"/Podcasts "$ROOT"/LiveTVNavigation "$ROOT"/Home \
  iosApp/iosApp/Control/iOS/NowPlayingShelf.swift iosApp/iosApp/tvOS iosApp/Signing fastlane
