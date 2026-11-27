#!/bin/bash
# Build 139 host checks: IPTV music classification and false positives, manual
# overrides, hidden categories, multiple providers, large-catalog bounds, the
# audio playback route, Radio favorite/history routing, Settings Backup, audio
# shelf limits and source contracts. Synthetic fixtures only.
set -euo pipefail
cd "$(dirname "$0")/.."
OUTPUT="$(mktemp -d /private/tmp/kyro-build139-checks.XXXXXX)"
ROOT=iosApp/iosApp/Kyro
xcrun swiftc -D KYRO_STANDALONE_TESTS -parse-as-library -o "$OUTPUT/build139" \
  iosApp/Tests/KyroBuild139HostChecks.swift \
  "$ROOT"/Radio/KyroIPTVMusicClassifier.swift \
  "$ROOT"/Radio/KyroRadio{PlayerTheme,Models,BrowserClient,Library,PlaybackMachine,BackupSettings}.swift \
  "$ROOT"/Home/KyroHome{Preferences,Arrangement}.swift \
  "$ROOT"/Sports/Models/KyroSportsModels.swift \
  "$ROOT"/Sports/Providers/KyroSportsProvider.swift \
  "$ROOT"/Settings/Backup/SettingsBackupCore.swift \
  "$ROOT"/Settings/Backup/SettingsBackupRestore.swift
"$OUTPUT/build139"
