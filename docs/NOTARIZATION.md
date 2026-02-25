# CruiseControl Optional Signing + Notarization

This flow is optional. Local beta builds can still ship/test without Apple signing.

## What this does

`./Scripts/notarize_dmg.sh` will:

1. Build `CruiseControl.app` (if needed)
2. Sign the app with your Developer ID Application certificate
3. Package a versioned DMG (`CruiseControl-<version>-<build>.dmg`)
4. Sign the DMG
5. Submit the DMG to Apple notarization
6. Staple the notarization ticket to the DMG

## Required setup

You need:

- A Developer ID Application certificate in Keychain
- `xcrun notarytool` available (Xcode)

And environment variables:

1. Always required:

```bash
export DEVELOPER_ID_APP_CERT="Developer ID Application: Your Name (TEAMID)"
```

2. Choose one auth mode:

Keychain profile (recommended):

```bash
export NOTARY_KEYCHAIN_PROFILE="cruisecontrol-notary"
```

or Apple ID credentials:

```bash
export APPLE_ID="you@example.com"
export TEAM_ID="YOURTEAMID"
export APP_PASSWORD="app-specific-password"
```

## Run

```bash
./Scripts/notarize_dmg.sh
```

## Useful overrides

- `APP_PATH`: app bundle to sign/package (defaults to `build/Build/Products/Release/CruiseControl.app`)
- `DMG_PATH`: specific DMG path to notarize/sign (defaults to newest `dist/dmg/CruiseControl-*.dmg`)
- `REBUILD_APP=1`: force rebuilding the app before signing

## If script exits early

That is expected when credentials are missing. The script prints setup steps and exits cleanly.

Local unsigned DMG is always available through:

```bash
./Scripts/build_dmg.sh
```
