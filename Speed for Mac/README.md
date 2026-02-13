# Project Speed v1.1.1 (macOS Desktop App)

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

## Automatic LOD Governor (v1.1.1)

Project Speed can automatically adjust XP12 LOD using altitude tiers.

Default tiers:
- `GROUND` (`AGL < 1500 ft`): FPS-oriented (higher `LOD_bias_rat`)
- `TRANSITION` (`1500-10000 ft`): balanced
- `CRUISE` (`> 10000 ft`): visuals-oriented (lower `LOD_bias_rat`)

Governor behavior:
- Uses AGL when available from UDP telemetry.
- Falls back to MSL heuristic if AGL is missing.
- If altitude telemetry is unavailable, governor pauses and does not send LOD commands.
- Applies smoothing/ramping, minimum time-in-tier, command interval limit, and minimum send delta.
- Uses app-side and script-side clamp bounds for safety.

The app does not write datarefs directly. It sends localhost UDP commands to the FlyWithLua companion script running inside X-Plane.

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

## FlyWithLua Companion Setup

Install script:
- `X-Plane 12/Resources/plugins/FlyWithLua/Scripts/ProjectSpeed_Governor.lua`

Default companion endpoint:
- `127.0.0.1:49006`

Commands accepted by the script:
- `ENABLE`
- `SET_LOD <float>`
- `DISABLE`

Fallback command file (used when LuaSocket is missing):
- `/tmp/ProjectSpeed_lod_target.txt`
- Format: `<sequence>|<command>` (example: `42|SET_LOD 1.10`)

Companion behavior:
- Applies `set("sim/private/controls/reno/LOD_bias_rat", value)` with clamps.
- Stores original value on load.
- Restores original value on `DISABLE` and on script exit.

Verification:
- Check FlyWithLua log for `UDP listening on 127.0.0.1:49006` (or `using file fallback` if LuaSocket is unavailable).
- In Project Speed, LOD Governor card should show `Command status: Connected` when commands are flowing.

## UDP bind diagnostics

- Bind errors are errno-aware and concise:
  - `EADDRINUSE`: `Port <port> is already in use.`
  - `EACCES`/`EPERM`: permission denied binding to `<address>:<port>`.
  - `EADDRNOTAVAIL`: address is not available on this Mac.
  - fallback includes `errno` and `strerror`.
- Listening address reflects actual bind target:
  - `127.0.0.1:<port>` for loopback-only
  - `0.0.0.0 (all interfaces):<port>` when binding all interfaces
- Port text is displayed without grouping commas.

## Limitations

- No kernel extensions.
- No direct control of macOS scheduler internals or GPU clocks.
- Uses a private XP12 dataref (`sim/private/controls/reno/LOD_bias_rat`) through FlyWithLua only.
- UDP telemetry quality depends on X-Plane Data Output configuration.
- Force quit/telemetry visibility can be restricted by macOS process protections.
