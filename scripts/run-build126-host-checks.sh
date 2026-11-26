#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
OUTPUT="$(mktemp -d /private/tmp/kyro-build126-checks.XXXXXX)"
xcrun swiftc -D KYRO_STANDALONE_TESTS -parse-as-library -o "$OUTPUT/build126" \
  iosApp/Tests/KyroBuild126HostChecks.swift \
  iosApp/iosApp/Kyro/Home/KyroHomePreferences.swift \
  iosApp/iosApp/Kyro/Home/KyroHomeArrangement.swift \
  iosApp/iosApp/Kyro/Home/KyroHomeBackupSettings.swift \
  iosApp/iosApp/Kyro/Sports/KyroSportsDirectory.swift \
  iosApp/iosApp/Kyro/Sports/Soccer/KyroSoccerCompetitionRegistry.swift \
  iosApp/iosApp/Kyro/Sports/Models/KyroSportsModels.swift \
  iosApp/iosApp/Kyro/Sports/Providers/KyroSportsProvider.swift \
  iosApp/iosApp/Kyro/Settings/Backup/SettingsBackupCore.swift \
  iosApp/iosApp/Kyro/Settings/Backup/SettingsBackupRestore.swift
"$OUTPUT/build126" "$@"
