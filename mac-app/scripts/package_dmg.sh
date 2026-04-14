#!/bin/zsh

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)

PROJECT_PATH="$REPO_ROOT/mac-app/SubConfigStudio.xcodeproj"
SCHEME="${SCHEME:-SubConfigStudio}"
CONFIGURATION="${CONFIGURATION:-Release}"
APP_NAME="${APP_NAME:-clashconvert}"
VOLUME_NAME="${VOLUME_NAME:-clashconvert Installer}"
BUILD_ROOT="${BUILD_ROOT:-$REPO_ROOT/mac-app/build}"
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-$BUILD_ROOT/DerivedData}"
ARCHIVE_PATH="${ARCHIVE_PATH:-$BUILD_ROOT/$APP_NAME.xcarchive}"
STAGING_PATH="${STAGING_PATH:-$BUILD_ROOT/dmg-root}"
DMG_PATH="${DMG_PATH:-$BUILD_ROOT/$APP_NAME.dmg}"

function require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "error: missing required command '$1'" >&2
    exit 1
  fi
}

require_command xcodebuild
require_command hdiutil
require_command codesign
require_command ditto
require_command rsync

mkdir -p "$BUILD_ROOT"
rm -rf "$ARCHIVE_PATH" "$STAGING_PATH" "$DMG_PATH"

echo "==> Archiving $APP_NAME with Xcode automatic signing"
xcodebuild \
  -project "$PROJECT_PATH" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -destination "platform=macOS" \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  -archivePath "$ARCHIVE_PATH" \
  -allowProvisioningUpdates \
  archive

APP_PATH="$ARCHIVE_PATH/Products/Applications/$APP_NAME.app"
if [[ ! -d "$APP_PATH" ]]; then
  echo "error: archived app not found at $APP_PATH" >&2
  exit 1
fi

echo "==> Verifying archived app signature"
codesign --verify --deep --strict "$APP_PATH"

if [[ -z "${SIGNING_IDENTITY:-}" ]]; then
  CODESIGN_DETAILS="$(codesign -d --verbose=4 "$APP_PATH" 2>&1 || true)"
  while IFS= read -r line; do
    if [[ "$line" == Authority=* ]]; then
      SIGNING_IDENTITY="${line#Authority=}"
      break
    fi
  done <<< "$CODESIGN_DETAILS"
fi

if [[ -z "$SIGNING_IDENTITY" ]]; then
  echo "error: failed to infer signing identity from archived app." >&2
  echo "hint: export SIGNING_IDENTITY='Apple Development: Your Name (TEAMID)' and rerun." >&2
  exit 1
fi

echo "==> Using signing identity: $SIGNING_IDENTITY"

mkdir -p "$STAGING_PATH"
rsync -a "$APP_PATH" "$STAGING_PATH/"
ln -s /Applications "$STAGING_PATH/Applications"

echo "==> Building DMG at $DMG_PATH"
hdiutil create \
  -volname "$VOLUME_NAME" \
  -srcfolder "$STAGING_PATH" \
  -ov \
  -format UDZO \
  "$DMG_PATH"

echo "==> Signing DMG with the same identity"
codesign --force --sign "$SIGNING_IDENTITY" --timestamp=none "$DMG_PATH"

echo "==> Final artifacts"
echo "App archive: $ARCHIVE_PATH"
echo "Signed app:  $APP_PATH"
echo "Signed DMG:  $DMG_PATH"
echo
echo "Note: this script uses your current Xcode automatic signing setup."
echo "      For wider macOS distribution you will still need notarization."
