#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

bash scripts/run-build129-host-checks.sh
bash scripts/run-build130-host-checks.sh
bash scripts/run-build131-host-checks.sh
bash scripts/run-build133-host-checks.sh --behavior-only
bash scripts/run-build137-host-checks.sh --behavior-only
[[ $(rg -c 'CURRENT_PROJECT_VERSION: 138$' iosApp/project.yml) == 3 ]]
[[ $(rg -c 'MARKETING_VERSION: "1\.0\.138"$' iosApp/project.yml) == 3 ]]

# Release-specific boundary: these features are intentionally unchanged.
BASE=8187da1348a95b8d0b7a05efcd152eaf0cde7721
APP=iosApp/iosApp
ROOT="$APP/Kyro"
git diff --exit-code "$BASE" -- \
  "$ROOT"/Radio/KyroRadio{Player,Turntable,PlayerTheme,PlaybackMachine,Library,DiscoverModel,BackupSettings}.swift \
  "$ROOT"/Podcasts/KyroPodcast{Player,Cassette,Downloads,Backup,DiscoverHome,Charts}.swift \
  "$ROOT"/Podcasts/KyroModernPlayers.swift \
  "$ROOT"/Home/KyroHome{Arrangement,BackupSettings,Preferences}.swift \
  "$ROOT"/LiveTVNavigation "$ROOT"/Sports/Playback "$ROOT"/Settings/Backup \
  "$ROOT"/Settings/KyroAppAppearance.swift \
  "$APP"/LiveTV ':(exclude)iosApp/iosApp/LiveTV/KyroPerformanceDiagnostics.swift' \
  "$APP"/tvOS iosApp/Signing fastlane
echo "Build 138: protected playback, player themes, navigation pills, Home arrangement and backup paths match Build 137."
