#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
OUTPUT="$(mktemp -d /private/tmp/kyro-build133-checks.XXXXXX)"
export KYRO_TEST_TEMP="$OUTPUT"
ROOT=iosApp/iosApp/Kyro
xcrun swiftc -D KYRO_STANDALONE_TESTS -D KYRO_PODCAST_HOST_TESTS -parse-as-library -o "$OUTPUT/build133" \
  iosApp/Tests/KyroBuild133HostChecks.swift \
  "$ROOT"/Podcasts/KyroPodcast{Feed,Network,Library,Backup}.swift \
  "$ROOT"/Radio/KyroRadio{PlayerTheme,Models,BrowserClient,Library,PlaybackMachine,BackupSettings}.swift \
  "$ROOT"/Home/KyroHome{Preferences,Arrangement}.swift \
  "$ROOT"/Sports/Models/KyroSportsModels.swift \
  "$ROOT"/Sports/Providers/KyroSportsProvider.swift \
  "$ROOT"/Settings/Backup/SettingsBackupCore.swift
"$OUTPUT/build133" "$@"
git diff --exit-code b71999dd9bc8691580556856ec588233984dfabc -- \
  "$ROOT"/Radio/KyroRadioTurntable.swift \
  "$ROOT"/Radio/KyroRadioPlayer.swift \
  "$ROOT"/Radio/KyroRadioDiscoverModel.swift \
  "$ROOT"/Shell \
  iosApp/iosApp/LiveTV \
  iosApp/iosApp/Screens/Home
