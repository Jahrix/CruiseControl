# CruiseControl v1.1.4 (Desktop App)

CruiseControl combines simulator telemetry and a safe Cleaner Suite.

## v1.1.4 highlights

- New sidebar sections: Smart Scan, Cleaner, Large Files, Optimization, Quarantine.
- Async Smart Scan with per-module progress + cancel.
- Hardened quarantine batches with restore/delete and manifest metadata.
- Large Files scanning is scope-required (no full-disk default scans).
- Optimization allowlist to avoid suggesting trusted apps.
- Memory Relief messaging updated to be explicit and credible.
- Update checks: Sparkle-configured path + GitHub fallback.

## Cleaner safety model

Default allowlist:

- `~/Library/Caches`
- `~/Library/Logs`
- `~/Library/Application Support/CruiseControl`
- `~/Library/Saved Application State`
- `~/.Trash`

Default exclusions:

- `/System`
- `/Library`
- `/private/var/vm`

Quarantine-first is the default clean flow.

## Updates

- `Check for Updates…` supports no-rebuild updates.
- Sparkle path: configure `SUFeedURL` and `SUPublicEDKey` in `Info.plist`.
- GitHub fallback path: CruiseControl fetches latest release metadata, downloads a `.zip` app asset, installs to a writable app location, and relaunches.
- If `/Applications` is not writable, fallback install target is `~/Applications`.
- Release requirement for fallback updater: publish a zip that contains `CruiseControl.app`.
- If updater says no GitHub release is published, create your first release in `Jahrix/CruiseControl`.
