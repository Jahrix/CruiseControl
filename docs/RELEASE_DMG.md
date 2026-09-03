# CruiseControl release workflow

## Local development

Build, ad-hoc sign, install exactly `/Applications/CruiseControl.app`, remove quarantine only from that local bundle, verify, and launch:

```bash
./Scripts/build_install_run.sh
```

This is the routine local workflow. It may request administrator approval for `/Applications`. Source changes require compilation; reopening the unchanged installed app only requires:

```bash
open /Applications/CruiseControl.app
```

## Packaging inspection only

```bash
./Scripts/build_dmg.sh
```

This builds an unsigned Release app and DMG under `dist/dmg`. The result is useful for inspecting layout but is not suitable for distribution. Do not upload it as a trusted release and do not tell users to bypass Gatekeeper.

## Public distribution

Public builds must follow the complete chain:

1. Release build.
2. Developer ID Application signing with hardened runtime and timestamp.
3. App notarization and stapling.
4. DMG creation and signing.
5. DMG notarization and stapling.
6. `codesign`, `stapler`, `spctl`, and `hdiutil` verification.

With a Keychain notary profile:

```bash
DEVELOPER_ID_APP_CERT="Developer ID Application: Name (TEAMID)" \
NOTARY_KEYCHAIN_PROFILE="cruisecontrol-notary" \
./Scripts/notarize_dmg.sh
```

The tag workflow executes the same notarization script and refuses to publish when credentials are missing. Repository secrets required by `.github/workflows/release-macos.yml` are:

- `DEVELOPER_ID_P12_BASE64`
- `DEVELOPER_ID_P12_PASSWORD`
- `DEVELOPER_ID_APP_CERT`
- `NOTARY_APPLE_ID`
- `NOTARY_TEAM_ID`
- `NOTARY_APP_PASSWORD`

After configuring those credentials, a `v*` tag runs tests, produces the signed/notarized/stapled DMG, verifies it, and only then creates the GitHub Release.

## Update limitation

Sparkle is not linked and the checked-in feed metadata is placeholder-only. The app performs a manual HTTPS release check but does not silently install a download. Automatic updates remain blocked until a signed Sparkle appcast and artifact-signature verification are configured.
