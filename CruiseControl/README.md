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

## Sparkle placeholders

Add these in `Info.plist` for Sparkle path:

- `SUFeedURL`
- `SUPublicEDKey`

If not configured, CruiseControl falls back to GitHub release API checks.
