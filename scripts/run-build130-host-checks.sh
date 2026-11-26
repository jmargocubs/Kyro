#!/bin/bash
# Build 130 host checks: Radio state isolation, the pushed Radio page's Now
# Playing bar policy, and mini-player / Home / sports sizing source contracts.
set -euo pipefail
cd "$(dirname "$0")/.."
OUTPUT="$(mktemp -d /private/tmp/kyro-build130-checks.XXXXXX)"
xcrun swiftc -D KYRO_STANDALONE_TESTS -parse-as-library -o "$OUTPUT/build130" \
  iosApp/Tests/KyroBuild130HostChecks.swift \
  iosApp/iosApp/Kyro/Shell/KyroGlobalNavigation.swift \
  iosApp/iosApp/Kyro/LiveTVNavigation/KyroLiveTVNavigationPreferences.swift \
  iosApp/iosApp/Kyro/LiveTVNavigation/KyroLiveTVDestination.swift \
  iosApp/iosApp/Kyro/LiveTVNavigation/KyroNavigationHandleTrace.swift \
  iosApp/iosApp/Kyro/Radio/KyroRadioModels.swift \
  iosApp/iosApp/Kyro/Radio/KyroRadioPlaybackMachine.swift
"$OUTPUT/build130"
