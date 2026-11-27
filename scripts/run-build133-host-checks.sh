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
  "$ROOT"/Settings/Backup/SettingsBackupCore.swift \
  "$ROOT"/Settings/Backup/SettingsBackupRestore.swift
"$OUTPUT/build133" "$@"
git diff --exit-code aa16b77868a1546dc0aaadad50e6d098e4fa58cd -- \
  "$ROOT"/Radio/KyroRadioPlayer.swift \
  "$ROOT"/Radio/KyroRadioDiscoverModel.swift \
  "$ROOT"/Podcasts/KyroPodcast{Player,Backup,Downloads}.swift \
  "$ROOT"/Podcasts/KyroHomePodcastRail.swift \
  "$ROOT"/Shell \
  iosApp/iosApp/LiveTV \
  iosApp/iosApp/Screens/Home \
  ':(exclude)iosApp/iosApp/LiveTV/Guide/LiveTVGuideView.swift' \
  ':(exclude)iosApp/iosApp/LiveTV/Home/LiveTVHomeContent.swift' \
  ':(exclude)iosApp/iosApp/LiveTV/LiveTVViews.swift' \
  ':(exclude)iosApp/iosApp/Screens/Home/HomeView.swift'
