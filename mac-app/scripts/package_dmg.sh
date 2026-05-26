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

# Vendor non-system dylibs that the bundled subconverter engine links against
# (yaml-cpp, pcre2 from Homebrew, plus any transitive deps) so the app works on
# machines that don't have Homebrew or the matching library versions installed.
function vendor_dylibs() {
  # All variables (including the loop variable `dep`) must be `local` because
  # the function recurses to follow transitive deps, and zsh function variables
  # are dynamically scoped by default — without `local`, the inner recursion's
  # `read` would clobber the outer call's `dep` once it hits EOF.
  local binary="$1"
  local frameworks_dir="$2"
  local dep name target
  chmod u+w "$binary"

  while IFS= read -r dep; do
    [[ -z "$dep" ]] && continue
    name=$(basename "$dep")
    target="$frameworks_dir/$name"

    if [[ ! -f "$target" ]]; then
      echo "    vendor $name <= $dep"
      cp "$dep" "$target"
      chmod u+w "$target"
      install_name_tool -id "@rpath/$name" "$target"
      vendor_dylibs "$target" "$frameworks_dir"
    fi

    install_name_tool -change "$dep" "@rpath/$name" "$binary"
  done < <(
    otool -L "$binary" 2>/dev/null \
      | tail -n +2 \
      | awk '{print $1}' \
      | grep -vE '^(/usr/lib/|/System/|@)' \
      || true
  )
}

SUBCONVERTER_BINARY="$APP_PATH/Contents/Resources/subconverter"
FRAMEWORKS_DIR="$APP_PATH/Contents/Frameworks"

if [[ -f "$SUBCONVERTER_BINARY" ]]; then
  echo "==> Vendoring subconverter dylibs into Contents/Frameworks"
  mkdir -p "$FRAMEWORKS_DIR"
  vendor_dylibs "$SUBCONVERTER_BINARY" "$FRAMEWORKS_DIR"

  # The engine binary was built with absolute LC_RPATH entries into the developer's
  # build tree and Homebrew Cellar. dyld walks RPATHs in order, so a stale Homebrew
  # path that still happens to exist on the build machine will silently win over
  # the bundled copy. Strip all existing RPATHs and add the one we control.
  while IFS= read -r stale_rpath; do
    [[ -z "$stale_rpath" ]] && continue
    install_name_tool -delete_rpath "$stale_rpath" "$SUBCONVERTER_BINARY" || true
  done < <(
    otool -l "$SUBCONVERTER_BINARY" | awk '
      /^Load command/ { cmd = "" }
      $1 == "cmd" { cmd = $2 }
      cmd == "LC_RPATH" && $1 == "path" {
        sub(/^[[:space:]]*path /, "")
        sub(/ \(offset [0-9]+\)$/, "")
        print
      }
    '
  )
  install_name_tool -add_rpath "@loader_path/../Frameworks" "$SUBCONVERTER_BINARY"

  echo "==> Re-signing vendored dylibs and subconverter binary"
  for dylib in "$FRAMEWORKS_DIR"/*.dylib(N); do
    codesign --force --sign "$SIGNING_IDENTITY" --timestamp=none "$dylib"
  done
  codesign --force --sign "$SIGNING_IDENTITY" --timestamp=none "$SUBCONVERTER_BINARY"

  echo "==> Re-signing app bundle"
  codesign --force --deep --sign "$SIGNING_IDENTITY" --timestamp=none "$APP_PATH"
  codesign --verify --deep --strict "$APP_PATH"
fi

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
