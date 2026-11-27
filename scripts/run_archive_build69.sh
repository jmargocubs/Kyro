#!/bin/zsh
set -e

PROJECT_DIR="/Users/paolazanetti/.t3/scratch/kyro-silo/iosApp"
ARCHIVE_PATH="$PROJECT_DIR/artifacts/Kyro-1.0.0-69-unsigned-arm64.xcarchive"
LOG_PATH="$PROJECT_DIR/artifacts/kyro-b69-archive.log"

cd "$PROJECT_DIR"

/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild archive \
  -project Silo.xcodeproj \
  -scheme Silo \
  -configuration Release \
  -destination generic/platform=iOS \
  -archivePath "$ARCHIVE_PATH" \
  -jobs 2 \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGN_ENTITLEMENTS="" \
  SILO_BUILD_CHANNEL=sideload \
  MARKETING_VERSION=1.0.0 \
  CURRENT_PROJECT_VERSION=69 \
  'SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) KYRO_INTERNAL_EPG_STORAGE_TOGGLE' \
  > "$LOG_PATH" 2>&1
