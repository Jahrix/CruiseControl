# CruiseControl v1.1.2 (Desktop App)

CruiseControl is a Swift/SwiftUI desktop app for monitoring and guiding flight-sim performance on macOS.

## Highlights in v1.1.2

- Memory Pressure Relief panel with safe user-confirmed process actions.
- Lua ACK handshake UI (`Connected` / `No ACK` / `ACK OK`) with `PING` test.
- Connection Wizard for X-Plane UDP + FlyWithLua setup validation.
- Stutter Detective event capture and culprit ranking.
- Mini history charts with 10m / 20m / 30m ranges.
- Per-airport governor profile system with JSON import/export.
- Smart Scan modules + quarantine/restore workflow.
- App maintenance actions: reveal app, install to `/Applications`, update check.

## LOD Governor architecture

CruiseControl computes target LOD from altitude tiers and sends commands to a FlyWithLua script.

The app does not write X-Plane private datarefs directly.

FlyWithLua script applies:

- `set("sim/private/controls/reno/LOD_bias_rat", value)`

with clamping and restore-on-disable/exit behavior.

## Build

1. Open `CruiseControl.xcodeproj`.
2. Build + Run.
3. In app settings, verify telemetry and governor ports.

## Bundle Identifier Migration

- New bundle identifier: `jahrix.CruiseControl`
- Previous bundle identifier: `jahrix.Speed-for-Mac`
- macOS treats this as a different app identity. Existing settings in `~/Library/Preferences/jahrix.Speed-for-Mac.plist` are not auto-imported.
- If both app copies are installed, keep only CruiseControl in `/Applications` to avoid duplicate notifications or Launch Services entries.


## Safety constraints

- Monitoring + user-approved automation only.
- No protected kernel/scheduler/GPU controls.
- Memory cleaner is pressure relief guidance, not a fake global cache purge.
