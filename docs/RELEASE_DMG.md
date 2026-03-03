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

## Closed Beta Install Notes

1. Download the DMG from GitHub Releases.
2. Open the DMG and drag `CruiseControl.app` into `Applications`.
3. Launch `/Applications/CruiseControl.app`.
4. If macOS says the app is damaged:
   - right-click `CruiseControl.app` and choose `Open`, or
   - run:

```bash
xattr -dr com.apple.quarantine /Applications/CruiseControl.app
```

For closed beta distribution, upload the DMG directly to GitHub Releases. Do not re-zip the `.app`.

## CI build + release tags

GitHub Actions covers two release paths:

- Every pull request and every push to `main` runs an unsigned macOS Debug build.
- Every tag push matching `v*` builds a versioned DMG via `Scripts/build_dmg.sh`.
- The release workflow uploads the DMG as both a workflow artifact and a GitHub Release asset.
- Tags containing `rc` are published as GitHub prereleases.

To publish a release:

```bash
git tag vX.Y.Z
git push origin vX.Y.Z
```

Expected output from the release workflow:

- `dist/dmg/CruiseControl-<version>-<build>.dmg`
- A workflow artifact containing that DMG
- A GitHub Release for the tag with the DMG attached

## Publishing v1.1.3-rc3

1. Merge to `main`
2. `git tag v1.1.3-rc3`
3. `git push origin v1.1.3-rc3`
4. GitHub Actions will build the DMG and publish the prerelease automatically

Closed beta Gatekeeper note:

- Right-click `CruiseControl.app` and choose `Open` once, or run:

```bash
xattr -dr com.apple.quarantine /Applications/CruiseControl.app
```

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
