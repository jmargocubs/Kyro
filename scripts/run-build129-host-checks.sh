#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
OUTPUT="$(mktemp -d /private/tmp/kyro-build129-checks.XXXXXX)"
xcrun swiftc -D KYRO_STANDALONE_TESTS -parse-as-library -o "$OUTPUT/build129" \
  iosApp/Tests/KyroBuild129HostChecks.swift \
  iosApp/iosApp/Kyro/Shell/KyroGlobalNavigation.swift \
  iosApp/iosApp/Kyro/LiveTVNavigation/KyroLiveTVNavigationPreferences.swift \
  iosApp/iosApp/Kyro/LiveTVNavigation/KyroLiveTVDestination.swift \
  iosApp/iosApp/Kyro/LiveTVNavigation/KyroNavigationHandleTrace.swift \
  iosApp/iosApp/LiveTV/LiveTVModels.swift \
  iosApp/iosApp/Shared/AetherAudioSessionOwnership.swift \
  iosApp/iosApp/Shared/KyroLifecycleJournal.swift \
  iosApp/iosApp/Kyro/Radio/KyroRadioModels.swift \
  iosApp/iosApp/Kyro/Radio/KyroIPTVMusicClassifier.swift \
  iosApp/iosApp/Kyro/Radio/KyroRadioPlaybackMachine.swift
"$OUTPUT/build129"
