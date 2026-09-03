# CruiseControl

CruiseControl is a macOS X-Plane frame-performance diagnostician. It answers what is limiting performance, shows the evidence, recommends one reversible experiment, and measures whether that experiment helped.

The reachable v2 product has three screens: Live Diagnosis, Session, and Setup. Generic cleaning, file scanning, licensing, and update UI are not part of the primary workflow.

## Build, install, and launch locally

From the repository root:

```bash
./Scripts/build_install_run.sh
```

The command builds Release, ad-hoc signs the local bundle, safely replaces exactly `/Applications/CruiseControl.app`, removes quarantine only from that trusted local bundle, verifies it, and launches it. It may request administrator approval to write to `/Applications`.

Source changes require compilation. Once `/Applications/CruiseControl.app` is installed, reopening that unchanged build does not require Xcode:

```bash
open /Applications/CruiseControl.app
```

## Test and build without installing

```bash
swift test --parallel
xcodebuild -project CruiseControl.xcodeproj \
  -scheme CruiseControl \
  -configuration Debug \
  -derivedDataPath .DerivedData \
  CODE_SIGNING_ALLOWED=NO \
  build
```

## Public distribution

Public distribution requires a Developer ID Application certificate and Apple notarization credentials:

```bash
DEVELOPER_ID_APP_CERT="Developer ID Application: Name (TEAMID)" \
NOTARY_KEYCHAIN_PROFILE="cruisecontrol-notary" \
./Scripts/notarize_dmg.sh
```

The script signs with hardened runtime, notarizes and staples the app, packages and signs the DMG, notarizes and staples the DMG, and verifies each stage. The release CI deliberately fails when signing credentials are unavailable; it no longer publishes an unsigned DMG as a trusted public release.

See [the v2 baseline](docs/V2_BASELINE.md) and [notarization setup](docs/NOTARIZATION.md).
