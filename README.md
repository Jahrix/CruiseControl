# CruiseControl v1.2.0

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

- `General Performance` (low overhead)
- `Sim Mode` (higher cadence for sim sessions)
- X-Plane detection can suggest switching to Sim Mode

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
xcodebuild -project "/Users/Boon/Downloads/Speed for Mac/CruiseControl.xcodeproj" \
  -scheme "CruiseControl" \
  -configuration Debug \
  CODE_SIGNING_ALLOWED=NO build
```

## Versioning

- Version: `1.2.0`
- Build: `120`
- Bundle ID: `jahrix.CruiseControl`

## Limitations

- GPU utilization is heuristic unless exposed by sim telemetry.
- Process termination can fail due app permissions/state.
- X-Plane companion features depend on correct UDP/FlyWithLua setup.
- Smart Scan/Cleaner are maintenance tools, not guaranteed FPS boosters.
