#!/bin/zsh
set -euo pipefail

REPO_ROOT="/Users/paolazanetti/.t3/scratch/kyro-silo"
PROJECT_DIR="$REPO_ROOT/iosApp"
ARCHIVE_PATH="$PROJECT_DIR/artifacts/Kyro-tvOS-1.0.108-108-unsigned-arm64.xcarchive"
LOG_PATH="$PROJECT_DIR/artifacts/kyro-tvos-b108-archive.log"
STAGE_DIR="$PROJECT_DIR/artifacts/stage-tvos-108"
IPA_NAME="Kyro-tvOS-v1.0.108-Build108-Unsigned.ipa"
IPA_PATH="$PROJECT_DIR/artifacts/$IPA_NAME"
DOWNLOADS_DIR="/Users/paolazanetti/Downloads"

cd "$REPO_ROOT"

echo "=== Checking out kyro/tvos-recovered ==="
git checkout kyro/tvos-recovered
EXPECTED_SHA="0443c60d"
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

echo "=== Starting xcodebuild archive for tvOS Build 108 ==="
T0=$(date +%s)
xcodebuild archive \
  -project Silo.xcodeproj \
  -scheme SiloTV \
  -configuration Release \
  -destination "generic/platform=tvOS" \
  -archivePath "$ARCHIVE_PATH" \
  -jobs 2 \
  -showBuildTimingSummary \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY='' \
  CODE_SIGN_ENTITLEMENTS="" \
  SILO_USER_INDEPENDENT_KEYCHAIN=NO \
  SILO_TV_BUNDLE_ID=com.cubbiestream.kyro.tvos \
  SILO_TOPSHELF_BUNDLE_ID=com.cubbiestream.kyro.tvos.topshelf \
  SILO_BUILD_CHANNEL=sideload \
  MARKETING_VERSION="1.0.108" \
  CURRENT_PROJECT_VERSION="108" \
  > "$LOG_PATH" 2>&1
echo "Archive completed in $(( $(date +%s) - T0 )) seconds"

echo "=== Validating archive and packaging IPA ==="
APP_PATH="$ARCHIVE_PATH/Products/Applications/SiloTV.app"
if [ ! -d "$APP_PATH" ]; then
  echo "Error: SiloTV.app not found at $APP_PATH" >&2
  exit 1
fi

echo "=== Stamping CFBundleDisplayName to Kyro Build 108 ==="
/usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName Kyro Build 108" "$APP_PATH/Info.plist"

rm -rf "$STAGE_DIR"
mkdir -p "$STAGE_DIR/Payload"
cp -R "$APP_PATH" "$STAGE_DIR/Payload/"

python3 "$REPO_ROOT/scripts/ci/validate-subtitle-packaging.py" "$STAGE_DIR/Payload/SiloTV.app"

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
    if "Payload/SiloTV.app/Info.plist" not in names:
        sys.exit("Error: Payload/SiloTV.app/Info.plist not found in IPA")
    embedded = [n for n in names if "embedded.mobileprovision" in n]
    if embedded:
        sys.exit(f"Error: unexpected embedded provisioning profile: {embedded}")
    topshelf = [n for n in names if "Payload/SiloTV.app/PlugIns/SiloTVTopShelf.appex" in n]
    if not topshelf:
        sys.exit("Error: SiloTVTopShelf.appex not found in IPA")

def plist_val(key, path=plist_path):
    return subprocess.check_output(["/usr/libexec/PlistBuddy", "-c", f"Print :{key}", path]).decode().strip()

bundle_id = plist_val("CFBundleIdentifier")
display_name = plist_val("CFBundleDisplayName")
version = plist_val("CFBundleShortVersionString")
build = plist_val("CFBundleVersion")
min_os = plist_val("MinimumOSVersion")
platform = plist_val("CFBundleSupportedPlatforms:0")

if bundle_id != "com.cubbiestream.kyro.tvos":
    sys.exit(f"Error: Bundle ID {bundle_id} != com.cubbiestream.kyro.tvos")
if display_name != "Kyro Build 108":
    sys.exit(f"Error: Display Name {display_name} != Kyro Build 108")
if version != "1.0.108":
    sys.exit(f"Error: Version {version} != 1.0.108")
if build != "108":
    sys.exit(f"Error: Build {build} != 108")
if platform != "AppleTVOS":
    sys.exit(f"Error: Platform {platform} != AppleTVOS")

# Check TopShelf extension bundle ID
topshelf_plist = os.path.join(app_path, "PlugIns/SiloTVTopShelf.appex/Info.plist")
ts_bundle_id = plist_val("CFBundleIdentifier", topshelf_plist)
if ts_bundle_id != "com.cubbiestream.kyro.tvos.topshelf":
    sys.exit(f"Error: Top Shelf Bundle ID {ts_bundle_id} != com.cubbiestream.kyro.tvos.topshelf")

# Check archs
archs = subprocess.check_output(["lipo", "-archs", os.path.join(app_path, "SiloTV")]).decode().strip()
if "arm64" not in archs:
    sys.exit(f"Error: Architecture {archs} does not contain arm64")

# Check unsigned
codesign_out = subprocess.run(["codesign", "-dv", app_path], capture_output=True, text=True).stderr
if "Authority=" in codesign_out:
    sys.exit(f"Error: app appears signed: {codesign_out}")

# Check VOD absence
nm_vod = subprocess.run(f"nm -g {os.path.join(app_path, 'SiloTV')} | grep -i XtreamVOD | grep -v LiveTVLegacyVODCleanup || true", shell=True, capture_output=True, text=True).stdout.strip()
if nm_vod:
    sys.exit(f"Error: unexpected XtreamVOD symbols in SiloTV: {nm_vod}")

# Check AetherEngine dependencies
otool_aether = subprocess.run(f"otool -L {os.path.join(app_path, 'SiloTV')} | grep -i AetherLib || true", shell=True, capture_output=True, text=True).stdout.strip()
if not otool_aether:
    sys.exit("Error: AetherLib dependencies not found in SiloTV binary")

with open(ipa_path, "rb") as f:
    data = f.read()
sha = hashlib.sha256(data).hexdigest()
size = len(data)

print(f"=== tvOS IPA Created Successfully ===")
print(f"  IPA Path: {ipa_path}")
print(f"  Source Commit: $ACTUAL_SHA")
print(f"  Bundle ID: {bundle_id}")
print(f"  Top Shelf Bundle ID: {ts_bundle_id}")
print(f"  Display Name: {display_name}")
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
