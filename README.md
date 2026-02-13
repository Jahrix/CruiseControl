# CruiseControl v1.1.2

CruiseControl is a macOS SwiftUI desktop performance companion for X-Plane on Apple Silicon.

## What it does

- Monitors CPU, memory pressure, compressed memory, swap, disk I/O, thermal state, and top processes.
- Tracks X-Plane UDP telemetry with clear connection state (`IDLE`, `LISTENING`, `ACTIVE`, `MISCONFIG`).
- Provides user-approved actions only (quit/force quit with confirmation, guidance, diagnostics export).
- Uses a FlyWithLua companion for in-sim LOD control. The macOS app does not write XP private datarefs directly.

## Build and run

1. Open `CruiseControl.xcodeproj` in Xcode.
2. Select scheme `CruiseControl`.
3. Build and Run.
4. For an installable copy, use `Preferences > Install to /Applications`.

## Bundle Identifier Migration

- New bundle identifier: `jahrix.CruiseControl`
- Previous bundle identifier: `jahrix.Speed-for-Mac`
- macOS treats this as a different app identity. Existing settings in `~/Library/Preferences/jahrix.Speed-for-Mac.plist` are not auto-imported.
- If both app copies are installed, keep only CruiseControl in `/Applications` to avoid duplicate notifications or Launch Services entries.


## Connection Wizard (X-Plane + Lua)

In CruiseControl, the Connection Wizard verifies:

1. X-Plane process detection.
2. UDP telemetry endpoint and packet rate.
3. FlyWithLua ACK handshake state.

Helpful actions:

- `Copy 127.0.0.1:<telemetry-port>`
- `Copy Lua listen port`
- `Test PING` (expects `PONG`)

## X-Plane UDP setup

In X-Plane:

1. `Settings > Data Output`
2. Check `Send network data output`
3. Set IP to `127.0.0.1`
4. Set Port to CruiseControl listening port (default `49005`)
5. Enable frame-rate and position datasets

Ports are shown without grouping commas (for example `49005`, not `49,005`).

## FlyWithLua ACK protocol

Script path:

- `X-Plane 12/Resources/plugins/FlyWithLua/Scripts/CruiseControl_Governor.lua`

Command protocol:

- App -> Lua:
  - `PING`
  - `ENABLE`
  - `DISABLE`
  - `SET_LOD <float>`
- Lua -> App:
  - `PONG`
  - `ACK ENABLE`
  - `ACK DISABLE`
  - `ACK SET_LOD <float>`
  - `ERR <message>`

The script applies and clamps:

- `sim/private/controls/reno/LOD_bias_rat`

It stores original LOD on load and restores on disable/exit.

## Smart Scan + Quarantine safety model

Smart Scan is non-destructive by default and reports:

- System junk candidates in user-safe paths (`~/Library/Caches`, `~/Library/Logs`, app-local cache)
- Trash items
- Large files in user-selected folders only
- Optimization signals (CPU hogs)
- Optional user privacy caches

Quarantine behavior:

- Moves selected files to `~/Library/Application Support/CruiseControl/Quarantine/<timestamp>/`
- Writes `manifest.json` for restore
- Restore and permanent delete are explicit user actions
- By default, quarantine is restricted to safe allowlisted directories
- Advanced Mode is required for non-allowlisted paths

## Memory Pressure Relief (what it is and is not)

CruiseControl does not do fake global RAM cleaning. It provides:

- Pressure/swap/compressed-memory visibility
- Suggestions to close heavy apps
- User-confirmed quit actions
- Optional limited purge attempt that only clears CruiseControl local caches

## Limitations

- No kernel extensions.
- No private macOS APIs.
- No scheduler/GPU clock control.
- Process actions can fail due sandboxing, app protections, or permissions.
- X-Plane telemetry and governor behavior depend on correct sim/data output setup.
