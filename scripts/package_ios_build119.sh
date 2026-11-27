#!/bin/zsh
set -euo pipefail

REPO_ROOT="/Users/paolazanetti/.t3/scratch/kyro-silo"
PROJECT_DIR="$REPO_ROOT/iosApp"
ARCHIVE_PATH="$PROJECT_DIR/artifacts/Kyro-1.0.119-119-unsigned-arm64.xcarchive"
LOG_PATH="$PROJECT_DIR/artifacts/kyro-ios-b119-archive.log"
STAGE_DIR="$PROJECT_DIR/artifacts/stage-ios-119"
IPA_NAME="Kyro-iOS-v1.0.119-Build119-Unsigned.ipa"
IPA_PATH="$PROJECT_DIR/artifacts/$IPA_NAME"
DOWNLOADS_DIR="/Users/paolazanetti/Downloads"

cd "$REPO_ROOT"

echo "=== Checking out kyro/ios-recovered ==="
git checkout kyro/ios-recovered
EXPECTED_SHA="7341542d"
ACTUAL_SHA=$(git rev-parse HEAD)
case "$ACTUAL_SHA" in
  "$EXPECTED_SHA"*) echo "OK: checkout resolved to $ACTUAL_SHA" ;;
  *) echo "Error: expected $EXPECTED_SHA, got $ACTUAL_SHA" >&2; exit 1 ;;
esac

cd "$PROJECT_DIR"
mkdir -p "$PROJECT_DIR/artifacts"
rm -rf "$ARCHIVE_PATH" "$IPA_PATH" "$STAGE_DIR"

echo "=== Regenerating Xcode project with XcodeGen ==="
/opt/homebrew/bin/xcodegen generate --spec project.yml

echo "=== Starting xcodebuild archive for iOS Build 119 ==="
T0=$(date +%s)
xcodebuild archive \
  -project Silo.xcodeproj \
  -scheme Silo \
  -configuration Release \
  -destination "generic/platform=iOS" \
  -archivePath "$ARCHIVE_PATH" \
  -jobs 2 \
  -showBuildTimingSummary \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY='' \
  CODE_SIGN_ENTITLEMENTS="" \
  SILO_BUILD_CHANNEL=sideload \
  MARKETING_VERSION="1.0.119" \
  CURRENT_PROJECT_VERSION="119" \
  > "$LOG_PATH" 2>&1
echo "Archive completed in $(( $(date +%s) - T0 )) seconds"

echo "=== Validating archive and packaging IPA ==="
APP_PATH="$ARCHIVE_PATH/Products/Applications/Silo.app"
if [ ! -d "$APP_PATH" ]; then
  echo "Error: Silo.app not found at $APP_PATH" >&2
  exit 1
fi

rm -rf "$STAGE_DIR"
mkdir -p "$STAGE_DIR/Payload"
cp -R "$APP_PATH" "$STAGE_DIR/Payload/"

python3 "$REPO_ROOT/scripts/ci/validate-subtitle-packaging.py" "$STAGE_DIR/Payload/Silo.app"

cd "$STAGE_DIR"
zip -qry "$IPA_PATH" Payload
rm -rf "$STAGE_DIR"

echo "=== Verifying IPA integrity ==="
unzip -t "$IPA_PATH" >/dev/null
unzip -l "$IPA_PATH" | grep -q "Payload/Silo.app/Info.plist"
if unzip -l "$IPA_PATH" | grep -q embedded.mobileprovision; then
  echo "Error: unexpected embedded provisioning profile" >&2
  exit 1
fi

PLIST="$APP_PATH/Info.plist"
BUNDLE_ID=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$PLIST")
MIN_OS=$(/usr/libexec/PlistBuddy -c 'Print :MinimumOSVersion' "$PLIST" 2>/dev/null || echo n/a)
PLIST_BUILD=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PLIST")
PLIST_VER=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")
ARCH=$(lipo -archs "$APP_PATH/Silo")
SUPPORTED_PLATFORM=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleSupportedPlatforms:0' "$PLIST")

[ "$BUNDLE_ID" = "com.cubbiestream.kyro" ] || { echo "CFBundleIdentifier $BUNDLE_ID != com.cubbiestream.kyro"; exit 1; }
[ "$SUPPORTED_PLATFORM" = "iPhoneOS" ] || { echo "supported platform $SUPPORTED_PLATFORM != iPhoneOS"; exit 1; }
[ "$PLIST_BUILD" = "119" ] || { echo "CFBundleVersion $PLIST_BUILD != 119"; exit 1; }
[ "$PLIST_VER" = "1.0.119" ] || { echo "CFBundleShortVersionString $PLIST_VER != 1.0.119"; exit 1; }
[[ "$ARCH" == *"arm64"* ]] || { echo "Architecture $ARCH does not contain arm64"; exit 1; }

echo "=== Verifying embedded plugins/extensions ==="
PLUGINS_DIR="$APP_PATH/PlugIns"
if [ -d "$PLUGINS_DIR" ]; then
  ls -la "$PLUGINS_DIR"
  test -d "$PLUGINS_DIR/SiloDownloadsActivity.appex"
  test -d "$PLUGINS_DIR/SiloNotificationService.appex"
fi

echo "=== Verifying unsigned status ==="
CODESIGN_OUT=$(codesign -dv "$APP_PATH" 2>&1 || true)
echo "$CODESIGN_OUT" | head -10

echo "=== Checking absence of IPTV VOD catalog functionality in binary ==="
if nm -g "$APP_PATH/Silo" 2>/dev/null | grep -i "XtreamVOD" | grep -v "LiveTVLegacyVODCleanup" >/dev/null; then
  echo "Error: unexpected XtreamVOD symbols found in Silo binary" >&2
  exit 1
fi

echo "=== Checking embedded AetherEngine 7.56 dependencies ==="
if nm -g "$APP_PATH/Silo" 2>/dev/null | grep -i "AetherEngine" >/dev/null; then
  echo "OK: AetherEngine symbols present in binary"
else
  echo "Error: AetherEngine symbols missing from binary" >&2
  exit 1
fi

echo "=== Verifying Production 100K Live TV channel capacity ==="
if grep -q "productionMaximumChannels = 100_000" "$REPO_ROOT/iosApp/iosApp/LiveTV/LiveTVModels.swift"; then
  echo "OK: 100K production maximum channels verified in LiveTVModels.swift"
else
  echo "Error: 100K production limit not found in LiveTVModels.swift" >&2
  exit 1
fi

SHA=$(shasum -a 256 "$IPA_PATH" | awk '{print $1}')
SIZE=$(stat -f %z "$IPA_PATH")

cp -p "$IPA_PATH" "$DOWNLOADS_DIR/$IPA_NAME"

echo "=== iOS IPA Created Successfully ==="
echo "  IPA Path: $IPA_PATH"
echo "  Downloads Path: $DOWNLOADS_DIR/$IPA_NAME"
echo "  Source Commit: $ACTUAL_SHA"
echo "  Bundle ID: $BUNDLE_ID"
echo "  Version: $PLIST_VER"
echo "  Build: $PLIST_BUILD"
echo "  Min OS: $MIN_OS"
echo "  Architectures: $ARCH"
echo "  Size: $SIZE bytes"
echo "  SHA-256: $SHA"
