# CruiseControl v1.1.3

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

## Connection Wizard (X-Plane + Lua)

In CruiseControl, the Connection Wizard verifies:

1. X-Plane process detection.
2. UDP telemetry state + last packet age + packet rate.
3. Control bridge mode (`UDP`, `File Fallback`, or `None`).
4. ACK state (`ACK OK`, `Waiting`, or expected no-ACK in file mode).

Helpful actions:

- `Copy 127.0.0.1:<telemetry-port>`
- `Copy Lua listen port`
- `Test PING`
- `Open Bridge Folder in Finder`

## X-Plane UDP setup

In X-Plane:

1. `Settings > Data Output`
2. Check `Send network data output`
3. Set IP to `127.0.0.1`
4. Set Port to CruiseControl listening port (default `49005`)
5. Enable Data Set 0 (frame-rate) and Data Set 20 (position/altitude)

Ports are shown without grouping commas (for example `49005`, not `49,005`).

## Regulator bridge folder (file fallback)

CruiseControl uses this folder for file bridge mode:

- `~/Library/Application Support/CruiseControl/`

Files:

- `lod_target.txt` (app writes target LOD)
- `lod_mode.txt` (app writes enable/disable)
- `lod_status.txt` (optional, Lua writes current state/evidence)

## Test controls

In `Regulator Proof` and `LOD Regulator`:

- `Test: FPS Mode (shorter draw distance)` sends temporary LOD bias `1.30`.
- `Test: Visual Mode (longer draw distance)` sends temporary LOD bias `0.75`.
- Tests run for 10 seconds, then auto-restore to the active Regulator target (or neutral fallback).

## Proof Panel interpretation

`Regulator Proof` shows:

- Bridge mode (`UDP`, `File Fallback`, `None`)
- Telemetry freshness + packets/sec
- Last command + age
- ACK line (or expected no-ACK in file mode)
- Applied LOD evidence:
  - UDP ACK payload when available
  - File bridge `lod_status.txt` values when available
- `LOD CHANGING: YES/NO`

`LOD CHANGING` is `YES` when ACK-applied values are changing (UDP) or file bridge status updates/LOD changes are observed.

## FlyWithLua protocol

Companion script path:

- `X-Plane 11/12/Resources/plugins/FlyWithLua/Scripts/`

Command protocol:

- App -> Lua: `PING`, `ENABLE`, `DISABLE`, `SET_LOD <float>`
- Lua -> App: `PONG`, `ACK ENABLE`, `ACK DISABLE`, `ACK SET_LOD <float>`, `ERR <message>`

Dataref applied by Lua:

- `sim/private/controls/reno/LOD_bias_rat`

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
- X-Plane telemetry and Regulator behavior depend on correct sim/data output setup.
