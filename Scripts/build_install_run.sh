#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
PROJECT_PATH="${REPO_ROOT}/CruiseControl.xcodeproj"
DERIVED_DATA_PATH="${REPO_ROOT}/.build/local"
BUILT_APP="${DERIVED_DATA_PATH}/Build/Products/Release/CruiseControl.app"
ENTITLEMENTS_PATH="${REPO_ROOT}/CruiseControl/CruiseControl.entitlements"
TARGET_APP="/Applications/CruiseControl.app"
STAGING_APP="/Applications/.CruiseControl.installing.app"
BACKUP_APP="/Applications/.CruiseControl.previous.app"

if [[ ! -d "${PROJECT_PATH}" ]]; then
  echo "error: CruiseControl.xcodeproj was not found at ${PROJECT_PATH}" >&2
  exit 1
fi
if ! command -v xcodebuild >/dev/null 2>&1; then
  echo "error: xcodebuild is unavailable. Install Xcode and select it with xcode-select." >&2
  exit 1
fi

echo "[1/6] Building CruiseControl (Release)"
xcodebuild \
  -project "${PROJECT_PATH}" \
  -scheme CruiseControl \
  -configuration Release \
  -derivedDataPath "${DERIVED_DATA_PATH}" \
  CODE_SIGNING_ALLOWED=NO \
  build \
  -quiet

if [[ ! -d "${BUILT_APP}" ]]; then
  echo "error: Release build succeeded but ${BUILT_APP} does not exist." >&2
  exit 1
fi

echo "[2/6] Applying an ad-hoc signature for this local build"
/usr/bin/codesign --force --sign - --entitlements "${ENTITLEMENTS_PATH}" "${BUILT_APP}"
/usr/bin/codesign --verify --deep --strict --verbose=2 "${BUILT_APP}"

USE_ADMIN=0
if [[ ! -w /Applications ]]; then
  echo "Administrator approval is required only to replace ${TARGET_APP}."
  /usr/bin/sudo -v
  USE_ADMIN=1
fi

run_admin() {
  if [[ "${USE_ADMIN}" == "1" ]]; then
    /usr/bin/sudo "$@"
  else
    "$@"
  fi
}

echo "[3/6] Staging the exact application bundle"
run_admin /bin/rm -rf "${STAGING_APP}"
run_admin /usr/bin/ditto "${BUILT_APP}" "${STAGING_APP}"
run_admin /usr/bin/codesign --verify --deep --strict --verbose=2 "${STAGING_APP}"

if /usr/bin/pgrep -x CruiseControl >/dev/null 2>&1; then
  echo "[4/6] Asking the installed CruiseControl instance to quit"
  /usr/bin/osascript -e 'tell application id "jahrix.CruiseControl" to quit'
  for _attempt in {1..10}; do
    if ! /usr/bin/pgrep -x CruiseControl >/dev/null 2>&1; then
      break
    fi
    /bin/sleep 1
  done
  if /usr/bin/pgrep -x CruiseControl >/dev/null 2>&1; then
    echo "error: CruiseControl did not quit; the existing app was not replaced." >&2
    run_admin /bin/rm -rf "${STAGING_APP}"
    exit 1
  fi
else
  echo "[4/6] No running CruiseControl instance needs to quit"
fi

echo "[5/6] Installing ${TARGET_APP}"
run_admin /bin/rm -rf "${BACKUP_APP}"
if [[ -e "${TARGET_APP}" ]]; then
  run_admin /bin/mv "${TARGET_APP}" "${BACKUP_APP}"
fi

if ! run_admin /bin/mv "${STAGING_APP}" "${TARGET_APP}"; then
  if [[ -e "${BACKUP_APP}" ]]; then
    run_admin /bin/mv "${BACKUP_APP}" "${TARGET_APP}"
  fi
  echo "error: Installation failed; the previous app was restored when available." >&2
  exit 1
fi

run_admin /usr/bin/xattr -dr com.apple.quarantine "${TARGET_APP}"
run_admin /usr/bin/codesign --verify --deep --strict --verbose=2 "${TARGET_APP}"
run_admin /bin/rm -rf "${BACKUP_APP}"

echo "[6/6] Launching ${TARGET_APP}"
/usr/bin/open "${TARGET_APP}"
echo "Installed and launched ${TARGET_APP}"
