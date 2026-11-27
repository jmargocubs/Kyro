#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
OUTPUT="$(mktemp -d /private/tmp/kyro-build136-checks.XXXXXX)"
ROOT=iosApp/iosApp/Kyro
xcrun swiftc -D KYRO_STANDALONE_TESTS -parse-as-library -o "$OUTPUT/build136" \
  iosApp/Tests/KyroBuild136HostChecks.swift \
  "$ROOT"/Radio/KyroRadio{PlayerTheme,Models,BrowserClient,Library,DiscoverModel,PlaybackMachine}.swift \
  "$ROOT"/Radio/KyroIPTVMusicClassifier.swift \
  "$ROOT"/Settings/KyroAppAppearance.swift \
  "$ROOT"/Settings/Backup/SettingsBackup{Core,Restore}.swift
"$OUTPUT/build136"
git diff --exit-code 3c3f3c9e89a0614a012f0fff80fcdf6bbad5de3c -- \
  "$ROOT"/Home "$ROOT"/Shell \
  "$ROOT"/Radio/KyroRadio{Player,PlaybackMachine,BrowserClient,Library,PlayerTheme,Turntable,BackupSettings}.swift \
  "$ROOT"/Podcasts/KyroPodcast{Player,Library,Downloads,Backup}.swift \
  ':(exclude)iosApp/iosApp/Kyro/Home/KyroHomeCustomizationView.swift' \
  iosApp/iosApp/ContentView.swift iosApp/iosApp/Control/iOS/NowPlayingShelf.swift \
  iosApp/iosApp/tvOS iosApp/Signing fastlane
