# CruiseControl DMG Release Workflow

This repo includes a local DMG packager for CruiseControl.

Note: this repository already used an uppercase `Scripts/` directory, so the packager is `./Scripts/build_dmg.sh`.

## One-command build

From repo root:

```bash
./Scripts/build_dmg.sh
```

The script will:
- Build `CruiseControl.app` in Release mode using Xcode (`CODE_SIGNING_ALLOWED=NO`)
- Stage files into `dist/stage/`
- Create a versioned DMG: `dist/dmg/CruiseControl-<version>.dmg`

Output app path used by script:
- `build/Build/Products/Release/CruiseControl.app`

Output DMG path:
- `dist/dmg/CruiseControl-<version>.dmg`

## Optional DMG window cosmetics

Enable simple Finder icon positioning:

```bash
DMG_COSMETIC=1 ./Scripts/build_dmg.sh
```

This is optional and non-blocking. If Finder scripting fails, DMG creation continues.

## Install flow

1. Open `dist/dmg/CruiseControl-<version>.dmg`
2. Drag `CruiseControl.app` to `Applications`
3. Launch from `Applications`

## Gatekeeper notes (unsigned local builds)

Unsigned local builds can show “cannot be opened” warnings.

Preferred:
- Right-click app -> `Open` -> confirm `Open`

If needed for local testing only:

```bash
xattr -dr com.apple.quarantine /Applications/CruiseControl.app
```

## Optional future: Developer ID signing + notarization

When ready for public distribution:
- Sign app with Developer ID Application certificate
- Notarize with `notarytool`
- Staple notarization ticket
- Rebuild/sign DMG as needed

These steps are intentionally not enforced in the local script.

## Troubleshooting

### `xcodebuild` requires full Xcode

If you see CommandLineTools errors:

```bash
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
```

### App does not open after copy

- Confirm app exists at `/Applications/CruiseControl.app`
- Use right-click `Open`
- Remove quarantine attribute (local testing only) shown above

### DMG not generated

- Ensure the app exists at `build/Build/Products/Release/CruiseControl.app`
- Re-run script and check first failing command
