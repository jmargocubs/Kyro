#!/bin/bash
# Build 140 host checks: IPTV music playback route and load plan, Radio
# transport rules for IPTV streams, Music Sources counts and states, and the
# mini-player surface. Synthetic fixtures only; nothing here plays audio.
set -euo pipefail
cd "$(dirname "$0")/.."
OUTPUT="$(mktemp -d /private/tmp/kyro-build140-checks.XXXXXX)"
ROOT=iosApp/iosApp/Kyro
xcrun swiftc -D KYRO_STANDALONE_TESTS -parse-as-library -o "$OUTPUT/build140" \
  iosApp/Tests/KyroBuild140HostChecks.swift \
  "$ROOT"/Radio/KyroIPTVMusicClassifier.swift \
  "$ROOT"/Radio/KyroRadio{PlayerTheme,Models,BrowserClient,Library,PlaybackMachine,BackupSettings}.swift \
  "$ROOT"/Home/KyroHome{Preferences,Arrangement}.swift \
  "$ROOT"/Sports/Models/KyroSportsModels.swift \
  "$ROOT"/Sports/Providers/KyroSportsProvider.swift \
  "$ROOT"/Settings/Backup/SettingsBackupCore.swift \
  "$ROOT"/Settings/Backup/SettingsBackupRestore.swift
"$OUTPUT/build140"
