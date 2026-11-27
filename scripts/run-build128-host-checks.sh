#!/bin/bash
# Build 128 Radio host checks, plus the Settings Backup codec and unified
# checks (which the Build 121 script runs only after its own checks pass).
# Pass --live-sample <file> to decode a saved live Radio Browser response.
set -euo pipefail
cd "$(dirname "$0")/.."
OUTPUT="$(mktemp -d /private/tmp/kyro-build128-checks.XXXXXX)"
xcrun swiftc -D KYRO_STANDALONE_TESTS -parse-as-library -o "$OUTPUT/build128" \
  iosApp/Tests/KyroBuild128HostChecks.swift \
  iosApp/iosApp/Kyro/Radio/KyroRadioModels.swift \
  iosApp/iosApp/Kyro/Radio/KyroIPTVMusicClassifier.swift \
  iosApp/iosApp/Kyro/Radio/KyroRadioBrowserClient.swift \
  iosApp/iosApp/Kyro/Radio/KyroRadioLibrary.swift \
  iosApp/iosApp/Kyro/Radio/KyroRadioDiscoverModel.swift \
  iosApp/iosApp/Kyro/Radio/KyroRadioPlaybackMachine.swift \
  iosApp/iosApp/Kyro/Radio/KyroRadioBackupSettings.swift \
  iosApp/iosApp/Kyro/Radio/KyroRadioPlayerTheme.swift \
  iosApp/iosApp/Kyro/Home/KyroHomePreferences.swift \
  iosApp/iosApp/Kyro/Home/KyroHomeArrangement.swift \
  iosApp/iosApp/Kyro/Home/KyroHomeBackupSettings.swift \
  iosApp/iosApp/Kyro/Sports/Models/KyroSportsModels.swift \
  iosApp/iosApp/Kyro/Sports/Providers/KyroSportsProvider.swift \
  iosApp/iosApp/Kyro/Settings/Backup/SettingsBackupCore.swift \
  iosApp/iosApp/Kyro/Settings/Backup/SettingsBackupRestore.swift
"$OUTPUT/build128" "$@"
xcrun swiftc -D KYRO_STANDALONE_TESTS -parse-as-library -o "$OUTPUT/backup-codec" \
  iosApp/Tests/SettingsBackupCodecHostChecks.swift \
  iosApp/iosApp/Kyro/Settings/Backup/SettingsBackupCore.swift
"$OUTPUT/backup-codec"
xcrun swiftc -D KYRO_STANDALONE_TESTS -parse-as-library -o "$OUTPUT/backup-unified" \
  iosApp/Tests/SettingsBackupUnifiedHostChecks.swift \
  iosApp/iosApp/Kyro/Settings/Backup/SettingsBackupCore.swift \
  iosApp/iosApp/Kyro/Settings/Backup/SettingsBackupRestore.swift \
  iosApp/iosApp/Kyro/Settings/Backup/SettingsBackupRemote.swift \
  iosApp/iosApp/Kyro/Settings/Backup/SettingsBackupModel.swift
"$OUTPUT/backup-unified"
