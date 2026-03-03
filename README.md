# CruiseControl v1.2.3

CruiseControl is a macOS SwiftUI performance copilot for X-Plane sessions.

## Positioning

CruiseControl v1.2 is **Frame-Time Lab + X-Plane Companion**:
- measure
- diagnose
- act (user-approved)
- verify with receipts/proof

It is not a fake RAM cleaner and does not use private macOS control paths.

## Core v1.2 sections

- Overview
- Frame-Time Lab
- Top Processes
- Profiles
- X-Plane
- Diagnostics
- Smart Scan
- Large Files
- Quarantine

## Frame-Time Lab

- Swift Charts timeline with selectable windows (`5m`, `10m`, `30m`)
- Pressure Index + CPU trend lines
- stutter markers (RuleMark)
- stutter classifier (cause + confidence + evidence)
- culprit ranking for last 10 minutes

## Profiles

- Situation presets:
  - `General`: current default behavior with General Performance workload
  - `Airport`: Sim Mode workload + performance-oriented app-list preset + conservative ground LOD targets
  - `Cruise`: Sim Mode workload + user choice between performance-oriented or visuals-oriented cruise targets
- Situation presets persist and only remap existing workload/app-list/governor settings

## Actions + receipts

Every key action can record an `ActionReceipt` with:
- action kind and params
- before/after samples
- outcome message

Examples:
- quit / force-quit process
- open bridge folder
- export diagnostics bundle
- pause scan policy toggles

## X-Plane Companion

### Regulator + proof
- `LOD Applied` and `Recent Activity` are tracked separately
- bridge modes: UDP ACK, File fallback, or disconnected
- proof includes target/applied/delta, evidence age, and reasons

### Setup checklist
Use the same setup text shown in the Connection Wizard:
1. Open X-Plane > Settings > Data Output
2. Check Send network data output
3. Set IP to 127.0.0.1
4. Set Port to `49005` (or the port shown in CruiseControl)
5. Enable Data Set 0 (frame-rate) and Data Set 20 (position/altitude)

FlyWithLua bridge location:
- Open your X-Plane folder, then go to `Resources/plugins/FlyWithLua/Scripts/`
- Install FlyWithLua first if that folder does not exist yet

### Advisor
Guidance cards are recommendations only:
- symptom -> likely cause -> recommended change -> why
- CruiseControl does not auto-edit X-Plane graphics config in v1.2

## Diagnostics export v2

Export JSON bundle includes:
- recent metric samples ring buffer
- stutter events + cause summaries
- action receipts
- profile + settings snapshot
- regulator proof snapshot

## Demo/Mock mode

- Toggle in Preferences and Diagnostics checklist
- inject synthetic stutter/sample data for UI validation without X-Plane

## Safety model

- no private APIs / no kernel extensions
- user-confirmed destructive operations
- quarantine-first cleaning flow
- safe path allowlist defaults for maintenance features

## Build

```bash
xcodebuild -project "/Users/Boon/Downloads/CruiseControl/CruiseControl.xcodeproj" \
  -scheme "CruiseControl" \
  -configuration Debug \
  CODE_SIGNING_ALLOWED=NO build
```

## Versioning

- Version: `1.2.3`
- Build: `123`
- Bundle ID: `jahrix.CruiseControl`

## Limitations

- GPU metrics are shown only when sim telemetry provides GPU timing; otherwise GPU is marked unavailable (no fabricated utilization).
- Process actions can fail; CruiseControl shows the reason and offers an Activity Monitor fallback.
- X-Plane companion features include a Connection Wizard with copyable X-Plane Data Output and FlyWithLua setup blocks.
- Cleaner is maintenance-oriented; recommendations appear only when pressure/swap or low-space conditions suggest it may help.
