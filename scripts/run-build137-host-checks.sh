#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
OUTPUT="$(mktemp -d /private/tmp/kyro-build137-checks.XXXXXX)"
ROOT=iosApp/iosApp/Kyro
xcrun swiftc -D KYRO_PODCAST_HOST_TESTS -parse-as-library -o "$OUTPUT/build137" \
  iosApp/Tests/KyroBuild137HostChecks.swift \
  "$ROOT"/Podcasts/KyroPodcast{Feed,Network,Charts}.swift
if [[ ${1:-} == --live ]]; then
  perl -e 'alarm shift; exec @ARGV' 150 "$OUTPUT/build137" --live
else
  "$OUTPUT/build137"
fi
if [[ ${1:-} == --behavior-only ]]; then exit 0; fi
git diff --exit-code d47d4da37030d03850dd521554fc76846e47b7b0 -- \
  "$ROOT"/Podcasts/KyroPodcast{Player,Library,Downloads,Backup}.swift \
  "$ROOT"/Podcasts/KyroModernPlayers.swift \
  "$ROOT"/Radio/KyroRadio{Player,PlaybackMachine,Library,Turntable,PlayerTheme,BackupSettings}.swift \
  "$ROOT"/Settings/KyroAppAppearance.swift "$ROOT"/Settings/Backup \
  "$ROOT"/Home/KyroHomeShelves.swift "$ROOT"/Shell "$ROOT"/LiveTVNavigation \
  iosApp/iosApp/ContentView.swift iosApp/iosApp/Control/iOS/NowPlayingShelf.swift \
  iosApp/iosApp/LiveTV iosApp/iosApp/Screens/Home iosApp/iosApp/tvOS iosApp/Signing fastlane
