#!/bin/zsh
set -euo pipefail

REPO_ROOT="/Users/paolazanetti/.t3/scratch/kyro-silo"
PROJECT_DIR="$REPO_ROOT/iosApp"
ARCHIVE_PATH="$PROJECT_DIR/artifacts/Kyro-1.0.127-127-unsigned-arm64.xcarchive"
LOG_PATH="$PROJECT_DIR/artifacts/kyro-ios-b127-archive.log"
STAGE_DIR="$PROJECT_DIR/artifacts/stage-ios-127"
IPA_NAME="Kyro-iOS-v1.0.127-Build127-Unsigned.ipa"
IPA_PATH="$PROJECT_DIR/artifacts/$IPA_NAME"
DOWNLOADS_DIR="/Users/paolazanetti/Downloads"

cd "$REPO_ROOT"

echo "=== Checking out kyro/ios-recovered ==="
git checkout kyro/ios-recovered
EXPECTED_SHA="e2364732"
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

echo "=== Starting xcodebuild archive for iOS Build 127 ==="
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
  MARKETING_VERSION="1.0.127" \
  CURRENT_PROJECT_VERSION="127" \
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

echo "=== Verifying IPA via Python ==="
python3 - << EOF
import zipfile, subprocess, os, hashlib, sys

ipa_path = "$IPA_PATH"
app_path = "$APP_PATH"
plist_path = os.path.join(app_path, "Info.plist")

with zipfile.ZipFile(ipa_path) as z:
    names = set(z.namelist())
    if "Payload/Silo.app/Info.plist" not in names:
        sys.exit("Error: Payload/Silo.app/Info.plist not found in IPA")
    embedded = [n for n in names if "embedded.mobileprovision" in n]
    if embedded:
        sys.exit(f"Error: unexpected embedded provisioning profile: {embedded}")
    downloads_act = [n for n in names if "Payload/Silo.app/PlugIns/SiloDownloadsActivity.appex" in n]
    notif_svc = [n for n in names if "Payload/Silo.app/PlugIns/SiloNotificationService.appex" in n]
    if not downloads_act:
        sys.exit("Error: SiloDownloadsActivity.appex not found in IPA")
    if not notif_svc:
        sys.exit("Error: SiloNotificationService.appex not found in IPA")
    if "Payload/Silo.app/AetherEngine_AetherEngine.bundle/Info.plist" not in names:
        sys.exit("Error: AetherEngine_AetherEngine.bundle not found in IPA")

def plist_val(key, path=plist_path):
    return subprocess.check_output(["/usr/libexec/PlistBuddy", "-c", f"Print :{key}", path]).decode().strip()

bundle_id = plist_val("CFBundleIdentifier")
version = plist_val("CFBundleShortVersionString")
build = plist_val("CFBundleVersion")
min_os = plist_val("MinimumOSVersion")
platform = plist_val("CFBundleSupportedPlatforms:0")

if bundle_id != "com.cubbiestream.kyro":
    sys.exit(f"Error: Bundle ID {bundle_id} != com.cubbiestream.kyro")
if version != "1.0.127":
    sys.exit(f"Error: Version {version} != 1.0.127")
if build != "127":
    sys.exit(f"Error: Build {build} != 127")
if platform != "iPhoneOS":
    sys.exit(f"Error: Platform {platform} != iPhoneOS")

# Check archs
archs = subprocess.check_output(["lipo", "-archs", os.path.join(app_path, "Silo")]).decode().strip()
if "arm64" not in archs:
    sys.exit(f"Error: Architecture {archs} does not contain arm64")

# Check unsigned
codesign_out = subprocess.run(["codesign", "-dv", app_path], capture_output=True, text=True).stderr
if "Authority=" in codesign_out:
    sys.exit(f"Error: app appears signed: {codesign_out}")

# Check VOD absence
nm_vod = subprocess.run(f"nm -g {os.path.join(app_path, 'Silo')} | grep -i XtreamVOD | grep -v LiveTVLegacyVODCleanup || true", shell=True, capture_output=True, text=True).stdout.strip()
if nm_vod:
    sys.exit(f"Error: unexpected XtreamVOD symbols in Silo: {nm_vod}")

# Check AetherEngine dependencies
otool_aether = subprocess.run(f"otool -L {os.path.join(app_path, 'Silo')} | grep -i AetherLib || true", shell=True, capture_output=True, text=True).stdout.strip()
if not otool_aether:
    sys.exit("Error: AetherLib dependencies not found in Silo binary")

required_aether_libs = [
    "AetherLibavcodec", "AetherLibavformat", "AetherLibavutil",
    "AetherLibswresample", "AetherLibswscale", "AetherLibavfilter",
    "AetherLibdav1d", "AetherLibzimg", "AetherLibzvbi"
]
for lib in required_aether_libs:
    if lib not in otool_aether:
        sys.exit(f"Error: {lib} missing from dynamic link dependencies")

# Check AetherEngine version in Package.resolved
pkg_resolved = "$REPO_ROOT/iosApp/Silo.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
with open(pkg_resolved) as f:
    pkg_content = f.read()
if "f470d8dc610537929c83ef31877287e9d2ad9d28" not in pkg_content:
    sys.exit("Error: AetherEngine revision f470d8dc not found in Package.resolved")

with open(ipa_path, "rb") as f:
    data = f.read()
sha = hashlib.sha256(data).hexdigest()
size = len(data)

print(f"=== iOS IPA Created Successfully ===")
print(f"  IPA Path: {ipa_path}")
print(f"  Source Commit: $ACTUAL_SHA")
print(f"  Bundle ID: {bundle_id}")
print(f"  Version: {version}")
print(f"  Build: {build}")
print(f"  Min OS: {min_os}")
print(f"  Platform: {platform}")
print(f"  Architectures: {archs}")
print(f"  Size: {size} bytes")
print(f"  SHA-256: {sha}")
EOF

cp -p "$IPA_PATH" "$DOWNLOADS_DIR/$IPA_NAME"
echo "Copied to $DOWNLOADS_DIR/$IPA_NAME"
