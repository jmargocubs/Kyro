#!/bin/zsh
set -e

PROJECT_DIR="/Users/paolazanetti/.t3/scratch/kyro-silo/iosApp"
ARCHIVE_PATH="$PROJECT_DIR/artifacts/Kyro-1.0.0-90-unsigned-arm64.xcarchive"
LOG_PATH="$PROJECT_DIR/artifacts/kyro-b90-archive.log"
STAGE_DIR="$PROJECT_DIR/artifacts/stage-90"
IPA_NAME="Kyro-v1.0.0-Build90-Unsigned.ipa"
IPA_PATH="$PROJECT_DIR/artifacts/$IPA_NAME"
DOWNLOADS_DIR="/Users/paolazanetti/Downloads"

cd "$PROJECT_DIR"

echo "=== Starting xcodebuild archive for iOS Build 90 ==="
/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild archive \
  -project Silo.xcodeproj \
  -scheme Silo \
  -configuration Release \
  -destination generic/platform=iOS \
  -archivePath "$ARCHIVE_PATH" \
  -jobs 1 \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_ENTITLEMENTS="" \
  SILO_BUILD_CHANNEL=sideload \
  MARKETING_VERSION=1.0.0 \
  CURRENT_PROJECT_VERSION=90 \
  > "$LOG_PATH" 2>&1

echo "=== Packaging $IPA_NAME ==="
APP_PATH="$ARCHIVE_PATH/Products/Applications/Silo.app"
if [ ! -d "$APP_PATH" ]; then
  echo "Error: Silo.app not found at $APP_PATH" >&2
  exit 1
fi

rm -rf "$STAGE_DIR"
mkdir -p "$STAGE_DIR/Payload"
cp -R "$APP_PATH" "$STAGE_DIR/Payload/"
cd "$STAGE_DIR"
zip -qry "$IPA_PATH" Payload
rm -rf "$STAGE_DIR"

cp -p "$IPA_PATH" "$DOWNLOADS_DIR/$IPA_NAME"

echo "=== Successfully created $IPA_PATH and copied to $DOWNLOADS_DIR ==="
