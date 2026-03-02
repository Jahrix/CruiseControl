# CruiseControl DMG Release Workflow

This document shows the fastest path to produce a distributable DMG for CruiseControl.

## Prerequisites

- Full Xcode installed
- `xcodebuild` available in your shell

If `xcodebuild` fails because CommandLineTools is selected:

```bash
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
```

## Build DMG (default local flow)

From repo root:

```bash
./Scripts/build_dmg.sh
```

What this script does:

1. Builds `CruiseControl.app` (Release, unsigned local build)
2. Stages a DMG folder with:
   - `CruiseControl.app`
   - `Applications` symlink
3. Creates a versioned DMG file:
   - `dist/dmg/CruiseControl-<version>-<build>.dmg`

Version/build comes from `CruiseControl.app/Contents/Info.plist`:
- `CFBundleShortVersionString` -> `<version>`
- `CFBundleVersion` -> `<build>`

## Optional Finder layout cosmetics

To attempt icon positioning inside the DMG window:

```bash
DMG_COSMETIC=1 ./Scripts/build_dmg.sh
```

If Finder scripting fails, DMG creation still succeeds.

## Verify DMG contents quickly

```bash
LATEST_DMG="$(ls -t dist/dmg/CruiseControl-*.dmg | head -n 1)"
MOUNT_POINT="$(mktemp -d /tmp/cruisecontrol-dmg.XXXXXX)"
hdiutil attach "$LATEST_DMG" -mountpoint "$MOUNT_POINT" -nobrowse
ls -la "$MOUNT_POINT"
hdiutil detach "$MOUNT_POINT"
```

You should see:
- `CruiseControl.app`
- `Applications -> /Applications`

## Install test

1. Open the generated DMG.
2. Drag `CruiseControl.app` into `Applications`.
3. Launch `/Applications/CruiseControl.app`.

For unsigned local builds, macOS may warn on first run. Use right-click `Open` once.

## Optional signing + notarization

Local DMG creation is intentionally non-blocking and does not require Apple signing credentials.

When you are ready to sign/notarize, use:
- [NOTARIZATION.md](./NOTARIZATION.md)
- `./Scripts/notarize_dmg.sh`

## CI build + release tags

GitHub Actions covers two release paths:

- Every pull request to `main` and every push to `main` runs an unsigned macOS build.
- Every tag push matching `v*` builds a versioned DMG via `Scripts/build_dmg.sh`.
- If notarization secrets are configured, the release workflow runs `Scripts/notarize_dmg.sh`.
- The release workflow uploads the DMG as both a workflow artifact and a GitHub Release asset.

To publish a release:

```bash
git tag vX.Y.Z
git push origin main --tags
```

Expected output from the release workflow:

- `dist/dmg/CruiseControl-<version>-<build>.dmg`
- A workflow artifact containing that DMG
- A GitHub Release for the tag with the DMG attached

Supported release secrets:

- `DEVELOPER_ID_APP_CERT`
- `NOTARY_KEYCHAIN_PROFILE`
- `APPLE_ID`
- `TEAM_ID`
- `APP_PASSWORD`

If those secrets are missing, DMG packaging still completes and notarization is skipped cleanly.

## Troubleshooting

### DMG not generated

- Confirm the app exists at `build/Build/Products/Release/CruiseControl.app`
- Re-run `./Scripts/build_dmg.sh` and inspect the first failing command

### App fails to open after copying to `/Applications`

- Confirm path: `/Applications/CruiseControl.app`
- For unsigned local testing only:

```bash
xattr -dr com.apple.quarantine /Applications/CruiseControl.app
```
