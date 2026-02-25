#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

PROJECT_PATH="${REPO_ROOT}/CruiseControl.xcodeproj"
SCHEME="CruiseControl"
DERIVED_DATA_PATH="${REPO_ROOT}/build"
APP_PATH="${APP_PATH:-${DERIVED_DATA_PATH}/Build/Products/Release/CruiseControl.app}"
DMG_PATH="${DMG_PATH:-}"

DEVELOPER_ID_APP_CERT="${DEVELOPER_ID_APP_CERT:-}"
NOTARY_KEYCHAIN_PROFILE="${NOTARY_KEYCHAIN_PROFILE:-}"
APPLE_ID="${APPLE_ID:-}"
TEAM_ID="${TEAM_ID:-}"
APP_PASSWORD="${APP_PASSWORD:-}"

function log_info() {
  printf "[notarize_dmg] %s\n" "$1"
}

function log_warn() {
  printf "[notarize_dmg][warn] %s\n" "$1"
}

function fail_with_setup_instructions() {
  cat <<'EOF'
[notarize_dmg] Signing/notarization is not configured.

Configure one of these authentication modes:
1) Keychain profile (recommended):
   - export NOTARY_KEYCHAIN_PROFILE="your-profile-name"
   - create profile: xcrun notarytool store-credentials ...

2) App Store Connect credentials:
   - export APPLE_ID="you@example.com"
   - export TEAM_ID="YOURTEAMID"
   - export APP_PASSWORD="app-specific-password"

And always configure signing identity:
   - export DEVELOPER_ID_APP_CERT="Developer ID Application: Your Name (TEAMID)"

Then run:
   ./Scripts/notarize_dmg.sh

Local builds are still available without notarization:
   ./Scripts/build_dmg.sh
EOF
  exit 2
}

if [[ -z "${DEVELOPER_ID_APP_CERT}" ]]; then
  fail_with_setup_instructions
fi

if [[ -z "${NOTARY_KEYCHAIN_PROFILE}" ]]; then
  if [[ -z "${APPLE_ID}" || -z "${TEAM_ID}" || -z "${APP_PASSWORD}" ]]; then
    fail_with_setup_instructions
  fi
fi

if ! command -v xcodebuild >/dev/null 2>&1; then
  echo "xcodebuild not found. Install Xcode and set xcode-select."
  exit 1
fi
if ! command -v codesign >/dev/null 2>&1; then
  echo "codesign not found."
  exit 1
fi
if ! command -v xcrun >/dev/null 2>&1; then
  echo "xcrun not found."
  exit 1
fi
if [[ ! -d "${PROJECT_PATH}" ]]; then
  echo "Project not found at ${PROJECT_PATH}"
  exit 1
fi

if [[ ! -d "${APP_PATH}" || "${REBUILD_APP:-0}" == "1" ]]; then
  log_info "Building app (Release, unsigned)"
  xcodebuild -project "${PROJECT_PATH}" \
    -scheme "${SCHEME}" \
    -configuration Release \
    -derivedDataPath "${DERIVED_DATA_PATH}" \
    CODE_SIGNING_ALLOWED=NO \
    build
fi

if [[ ! -d "${APP_PATH}" ]]; then
  echo "Expected app not found: ${APP_PATH}"
  exit 1
fi

log_info "Signing app bundle"
codesign --force --deep --options runtime --timestamp --sign "${DEVELOPER_ID_APP_CERT}" "${APP_PATH}"
codesign --verify --deep --strict --verbose=2 "${APP_PATH}"

log_info "Packaging signed app into DMG"
SKIP_BUILD=1 APP_SOURCE_PATH="${APP_PATH}" "${REPO_ROOT}/Scripts/build_dmg.sh"

if [[ -z "${DMG_PATH}" ]]; then
  DMG_PATH="$(ls -t "${REPO_ROOT}"/dist/dmg/CruiseControl-*.dmg 2>/dev/null | head -n 1 || true)"
fi
if [[ -z "${DMG_PATH}" || ! -f "${DMG_PATH}" ]]; then
  echo "DMG not found. Set DMG_PATH or run build_dmg first."
  exit 1
fi

log_info "Signing DMG"
codesign --force --timestamp --sign "${DEVELOPER_ID_APP_CERT}" "${DMG_PATH}"
codesign --verify --verbose=2 "${DMG_PATH}" || log_warn "DMG signature verification returned a warning."

log_info "Submitting DMG for notarization"
if [[ -n "${NOTARY_KEYCHAIN_PROFILE}" ]]; then
  xcrun notarytool submit "${DMG_PATH}" --keychain-profile "${NOTARY_KEYCHAIN_PROFILE}" --wait
else
  xcrun notarytool submit "${DMG_PATH}" \
    --apple-id "${APPLE_ID}" \
    --team-id "${TEAM_ID}" \
    --password "${APP_PASSWORD}" \
    --wait
fi

log_info "Stapling notarization ticket"
xcrun stapler staple "${DMG_PATH}"

log_info "Notarization flow completed: ${DMG_PATH}"
