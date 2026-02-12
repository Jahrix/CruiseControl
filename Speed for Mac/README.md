# Project Speed v1.1.0 (macOS Desktop App)

Project Speed is a desktop performance companion for X-Plane on Apple Silicon.

## What it does

- Live telemetry: CPU, memory pressure trend, compressed memory, swap + delta, disk throughput, free disk, thermal state.
- X-Plane UDP session overview with clear runtime state:
  - `IDLE` (listening disabled)
  - `LISTENING` (no packets yet)
  - `ACTIVE` (valid packets flowing)
  - `MISCONFIG` (packets are invalid / wrong dataset)
- Process diagnostics and actions: show in Activity Monitor, quit, and force quit (with confirmation).
- Sim Mode profiles (Balanced/Aggressive/Streaming) with app allowlist/blocklist/do-not-touch policy.
- Diagnostics export to JSON.

## Governor Mode (Altitude-based LOD policy)

Governor Mode determines a policy tier from altitude and sends LOD targets to a FlyWithLua bridge.

Default tiers:
- `GROUND` (`AGL < 1500 ft`): aggressive FPS-oriented LOD target.
- `CLIMB/DESCENT` (`1500-10000 ft`): moderate target.
- `CRUISE` (`> 10000 ft`): visuals-first target (bounded by safety clamp).

Governor behavior:
- Uses AGL when available from telemetry.
- Falls back to a simple MSL heuristic when AGL is unavailable.
- Applies clamp min/max for safety.
- Sends UDP command messages to FlyWithLua script (`Scripts/ProjectSpeed_Governor.lua`) running inside X-Plane.

## Build and run

1. Open `Speed for Mac.xcodeproj` in Xcode.
2. Ensure deployment target is macOS 13+.
3. Build and run.
4. App launches as a regular desktop app (Dock + main window).

## How to enable X-Plane UDP output

In X-Plane:
1. `Settings > Data Output`
2. Check `Send network data output`
3. Set IP to `127.0.0.1`
4. Set Port to Project Speed listening port (default `49005`)
5. Enable frame-rate and position datasets

Project Speed shows:
- Listening address
- Last packet received
- Packets/sec
- X-Plane detected yes/no

## Governor FlyWithLua bridge setup

1. Copy `Scripts/ProjectSpeed_Governor.lua` into your X-Plane FlyWithLua Scripts directory.
2. Keep Governor bridge host/port in app aligned with script defaults (`127.0.0.1:49006`) or edit both.
3. The script restores original LOD when Governor is disabled or script exits.

## Repository

This project can be maintained in a private GitHub repo. See commands below in the root `CHANGELOG.md`/release notes workflow.

## Limitations

- No kernel extensions.
- No direct control of macOS scheduler internals or GPU clocks.
- GPU utilization is not exposed with a stable public API for this use case.
- UDP telemetry quality depends on X-Plane Data Output configuration.
- Force quit/telemetry visibility can be restricted by macOS process protections.
