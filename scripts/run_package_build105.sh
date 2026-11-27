#!/bin/zsh
set -euo pipefail

REPO_ROOT="/Users/paolazanetti/.t3/scratch/kyro-silo"
PROJECT_DIR="$REPO_ROOT/iosApp"
ARCHIVE_PATH="$PROJECT_DIR/artifacts/Kyro-1.0.0-105-100k-validation-unsigned-arm64.xcarchive"
LOG_PATH="$PROJECT_DIR/artifacts/kyro-b105-100k-archive.log"
STAGE_DIR="$PROJECT_DIR/artifacts/stage-105-100k"
IPA_NAME="Kyro-v1.0.0-Build105-100K-Validation-Unsigned.ipa"
IPA_PATH="$PROJECT_DIR/artifacts/$IPA_NAME"

cd "$PROJECT_DIR"
mkdir -p "$PROJECT_DIR/artifacts"

echo "=== Regenerating Xcode project with XcodeGen ==="
/opt/homebrew/bin/xcodegen generate --spec project.yml

echo "=== Starting xcodebuild archive for iOS Build 105 (100K Live TV Validation) ==="
T0=$(date +%s)
/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild archive \
  -project Silo.xcodeproj \
  -scheme Silo \
  -configuration Release \
  -destination generic/platform=iOS \
  -archivePath "$ARCHIVE_PATH" \
  -jobs 2 \
  -showBuildTimingSummary \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY='' \
  CODE_SIGN_ENTITLEMENTS="" \
  SILO_BUILD_CHANNEL=sideload \
  MARKETING_VERSION=1.0.0 \
  CURRENT_PROJECT_VERSION=105 \
  SWIFT_ACTIVE_COMPILATION_CONDITIONS='$(inherited) KYRO_LIVETV_100K_VALIDATION' \
  > "$LOG_PATH" 2>&1
echo "Archive completed in $(( $(date +%s) - T0 )) seconds"

echo "=== Proof: validation flag in Release archive compile commands ==="
if ! rg -n "KYRO_LIVETV_100K_VALIDATION" "$LOG_PATH" >/dev/null; then
  echo "Error: KYRO_LIVETV_100K_VALIDATION not found in archive log" >&2
  exit 1
fi
if ! rg -n "CompileSwift|swift-frontend|SWIFT_ACTIVE_COMPILATION_CONDITIONS" "$LOG_PATH" | rg -n "KYRO_LIVETV_100K_VALIDATION" >/dev/null; then
  echo "Warning: flag present in log but not clearly tied to CompileSwift lines; dumping nearby hits"
  rg -n "KYRO_LIVETV_100K_VALIDATION" "$LOG_PATH" | head -40
fi

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

echo "=== Verifying IPA ==="
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
[ "$PLIST_BUILD" = "105" ] || { echo "CFBundleVersion $PLIST_BUILD != 105"; exit 1; }
[ "$PLIST_VER" = "1.0.0" ] || { echo "CFBundleShortVersionString $PLIST_VER != 1.0.0"; exit 1; }
[[ "$ARCH" == *"arm64"* ]] || { echo "Architecture $ARCH does not contain arm64"; exit 1; }

CODESIGN_OUT=$(codesign -dv "$APP_PATH" 2>&1 || true)
echo "$CODESIGN_OUT" | head -20
if echo "$CODESIGN_OUT" | rg -q "Signature=adhoc|code object is not signed|not signed at all|unsigned"; then
  :
elif ! echo "$CODESIGN_OUT" | rg -q "Authority="; then
  :
else
  echo "Error: app appears signed: $CODESIGN_OUT" >&2
  exit 1
fi

SHA=$(shasum -a 256 "$IPA_PATH" | awk '{print $1}')
SIZE=$(stat -f %z "$IPA_PATH")

echo "IPA created successfully:"
echo "  Path: $IPA_PATH"
echo "  Bundle ID: $BUNDLE_ID"
echo "  Version: $PLIST_VER"
echo "  Build: $PLIST_BUILD"
echo "  Min OS: $MIN_OS"
echo "  Architectures: $ARCH"
echo "  Size: $SIZE bytes"
echo "  SHA-256: $SHA"
echo "  Label: Build 105 — Live TV State Repair + Sports Hub Profiling"
