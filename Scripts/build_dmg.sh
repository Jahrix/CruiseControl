#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

PROJECT_PATH="${REPO_ROOT}/CruiseControl.xcodeproj"
SCHEME="CruiseControl"
DERIVED_DATA_PATH="${REPO_ROOT}/build"
APP_PATH="${DERIVED_DATA_PATH}/Build/Products/Release/CruiseControl.app"

DIST_DIR="${REPO_ROOT}/dist"
STAGE_DIR="${DIST_DIR}/stage"
DMG_DIR="${DIST_DIR}/dmg"

VOLUME_NAME="CruiseControl"
DMG_PATH="${DMG_DIR}/CruiseControl.dmg"
TEMP_RW_DMG="${DMG_DIR}/CruiseControl-temp.dmg"

function log_info() {
  printf "[build_dmg] %s\n" "$1"
}

function log_warn() {
  printf "[build_dmg][warn] %s\n" "$1"
}

if ! command -v xcodebuild >/dev/null 2>&1; then
  echo "xcodebuild not found. Install Xcode and run: sudo xcode-select -s /Applications/Xcode.app/Contents/Developer"
  exit 1
fi

if [[ ! -d "${PROJECT_PATH}" ]]; then
  echo "Project not found at ${PROJECT_PATH}"
  exit 1
fi

mkdir -p "${DIST_DIR}" "${DMG_DIR}"
rm -rf "${STAGE_DIR}"
mkdir -p "${STAGE_DIR}"

log_info "Building Release app (${SCHEME})"
xcodebuild -project "${PROJECT_PATH}" \
  -scheme "${SCHEME}" \
  -configuration Release \
  -derivedDataPath "${DERIVED_DATA_PATH}" \
  CODE_SIGNING_ALLOWED=NO \
  build

if [[ ! -d "${APP_PATH}" ]]; then
  echo "Expected app not found: ${APP_PATH}"
  exit 1
fi

APP_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${APP_PATH}/Contents/Info.plist" 2>/dev/null || true)"
if [[ -z "${APP_VERSION}" ]]; then
  APP_VERSION="unknown"
fi
DMG_PATH="${DMG_DIR}/CruiseControl-${APP_VERSION}.dmg"
TEMP_RW_DMG="${DMG_DIR}/CruiseControl-${APP_VERSION}-temp.dmg"

log_info "Preparing DMG staging folder"
cp -R "${APP_PATH}" "${STAGE_DIR}/CruiseControl.app"
ln -s /Applications "${STAGE_DIR}/Applications"
rm -f "${DMG_PATH}" "${TEMP_RW_DMG}"

if [[ "${DMG_COSMETIC:-0}" == "1" ]]; then
  log_info "Creating read-write DMG for Finder layout"
  hdiutil create -volname "${VOLUME_NAME}" \
    -srcfolder "${STAGE_DIR}" \
    -ov -format UDRW \
    "${TEMP_RW_DMG}"

  ATTACH_OUTPUT="$(hdiutil attach -readwrite -noverify -noautoopen "${TEMP_RW_DMG}")"
  DEVICE="$(printf "%s\n" "${ATTACH_OUTPUT}" | awk '/\/dev\// {print $1; exit}')"

  if [[ -n "${DEVICE}" ]]; then
    log_info "Applying Finder layout"
    osascript >/dev/null 2>&1 <<APPLESCRIPT || log_warn "Could not apply Finder window cosmetics; continuing with plain layout."
tell application "Finder"
  tell disk "${VOLUME_NAME}"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set bounds of container window to {120, 120, 720, 520}
    set viewOptions to the icon view options of container window
    set arrangement of viewOptions to not arranged
    set icon size of viewOptions to 128
    set position of item "CruiseControl.app" of container window to {170, 230}
    set position of item "Applications" of container window to {430, 230}
    close
    open
    update without registering applications
    delay 1
    close
  end tell
end tell
APPLESCRIPT

    hdiutil detach "${DEVICE}" -force >/dev/null
  else
    log_warn "Failed to resolve mounted DMG device; skipping cosmetics finalization."
  fi

  log_info "Converting DMG to compressed UDZO"
  hdiutil convert "${TEMP_RW_DMG}" -format UDZO -o "${DMG_PATH}" >/dev/null
  rm -f "${TEMP_RW_DMG}"
else
  log_info "Creating compressed DMG"
  hdiutil create -volname "${VOLUME_NAME}" \
    -srcfolder "${STAGE_DIR}" \
    -ov -format UDZO \
    "${DMG_PATH}" >/dev/null
fi

log_info "DMG created: ${DMG_PATH}"
