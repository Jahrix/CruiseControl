# CruiseControl v1.1.4

CruiseControl is a macOS SwiftUI desktop performance companion for X-Plane on Apple Silicon.

## What it does

- Real-time system telemetry: CPU, memory pressure, compressed memory, swap, disk I/O, thermal state, top processes.
- X-Plane UDP monitoring with explicit connection states: `IDLE`, `LISTENING`, `ACTIVE`, `MISCONFIG`.
- Regulator bridge diagnostics for FlyWithLua (UDP ACK path + file fallback).
- Cleaner Suite (safe, reversible by default):
  - Smart Scan
  - Cleaner
  - Large Files
  - Optimization
  - Quarantine

## Smart Scan v1.1.4

Smart Scan runs these modules asynchronously with progress and cancellation:

1. System Junk (safe user paths only)
2. Trash Bins
3. Large Files (selected scope only)
4. Optimization
5. Optional privacy cache scan

`Run Clean` defaults to **Quarantine first**.

## Quarantine / Restore model

Quarantine root:

`~/Library/Application Support/CruiseControl/Quarantine/<timestamp>/`

Each batch writes `manifest.json` with metadata:

- `batchId`
- `createdAt`
- `totalBytes`
- entries: `originalPath`, `quarantinedPath`, `sizeBytes`, `timestamp`, optional `sha256`

From the Quarantine section you can:

- Restore batch
- Delete batch permanently
- View total quarantined size

## Memory Relief (honest behavior)

CruiseControl does **not** claim fake global RAM purges.

Memory Relief focuses on useful actions:

- shows pressure/swap/compressed memory trends
- suggests top memory offenders
- user-confirmed quit actions
- optional limited purge clears CruiseControl-owned local cache only

## Safe path policy

Included by default:

- `~/Library/Caches`
- `~/Library/Logs`
- `~/Library/Application Support/CruiseControl`
- `~/Library/Saved Application State` (itemized)
- `~/.Trash`

Excluded by default:

- `/System`
- `/Library`
- `/private/var/vm`

Advanced mode is required for out-of-allowlist actions.

## Update checks and install

- `Check for Updates…` now supports no-rebuild updates.
- Primary path: Sparkle (`SUFeedURL` + `SUPublicEDKey`) when configured.
- Fallback path: GitHub Releases auto-installer.
  - CruiseControl checks latest release, finds a `.zip` app asset, downloads it, installs to a writable app location, then relaunches.
  - If `/Applications` is not writable, it installs to `~/Applications` automatically.
- Required release asset naming: publish a zip containing `CruiseControl.app` (for example `CruiseControl-v1.1.4-macOS.zip`).
- If update check says no GitHub release published yet, create your first GitHub Release for `Jahrix/CruiseControl`.
- `Show App in Finder`, `Open Applications Folder`, and `Install to /Applications` are available in app commands and Preferences.

## Build

```bash
xcodebuild -project "/Users/Boon/Downloads/Speed for Mac/CruiseControl.xcodeproj" \
  -scheme "CruiseControl" \
  -configuration Debug \
  CODE_SIGNING_ALLOWED=NO build
```

## Bundle Identifier Migration

- Current: `jahrix.CruiseControl`
- Legacy: `jahrix.Speed-for-Mac`

macOS treats these as different app identities; old preference domains are not auto-migrated.

## Limitations

- No kernel extensions.
- No private macOS scheduler/GPU controls.
- Process terminate/force-quit can fail due permissions/app behavior.
- X-Plane companion features depend on correct sim UDP/FlyWithLua setup.
