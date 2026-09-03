# CruiseControl Signing + Notarization

This flow is required for any build distributed to other users. Ad-hoc signing is only for trusted local development on the Mac that built the app.

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
- `SKIP_APP_BUILD=1`: explicitly package an existing `APP_PATH` instead of rebuilding (use only in a controlled CI stage)

## If script exits early

That is expected when credentials are missing. The script prints setup steps and fails before building or signing.

An unsigned DMG can be produced for internal packaging inspection only. It is not a public release and does not provide a seamless Gatekeeper or update experience:

```bash
./Scripts/build_dmg.sh
```
