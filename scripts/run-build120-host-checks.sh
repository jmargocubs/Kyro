#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
OUTPUT="$(mktemp -d /private/tmp/kyro-build120-checks.XXXXXX)"
echo "Host check binaries: $OUTPUT"
xcrun swiftc -D KYRO_STANDALONE_TESTS -parse-as-library -o "$OUTPUT/build120" \
  iosApp/Tests/KyroBuild120HostChecks.swift \
  iosApp/iosApp/Kyro/Home/KyroHomePreferences.swift \
  iosApp/iosApp/Kyro/Home/KyroHomeBackupSettings.swift \
  iosApp/iosApp/Kyro/Shell/TabDockScrollRange.swift \
  iosApp/iosApp/Kyro/Sports/Models/KyroSportsModels.swift \
  iosApp/iosApp/Kyro/Sports/Providers/KyroSportsProvider.swift \
  iosApp/iosApp/Kyro/Settings/Backup/SettingsBackupCore.swift \
  iosApp/iosApp/Kyro/Settings/Backup/SettingsBackupRestore.swift
"$OUTPUT/build120"
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
