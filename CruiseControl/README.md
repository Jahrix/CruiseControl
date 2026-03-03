# CruiseControl v1.2.3 (Desktop App)

CruiseControl v1.2 centers the app around frame-time diagnostics and X-Plane companion workflows.

## Highlights

- Frame-Time Lab with Swift Charts timeline + stutter markers
- Stutter classifier (`swapThrash`, `diskStall`, `cpuSaturation`, `thermalThrottle`, `gpuBoundHeuristic`, `unknown`)
- Situation presets (`General`, `Airport`, `Cruise`) layered on top of existing workload/app-list/governor settings
- Action receipts with before/after sample snapshots
- X-Plane Advisor recommendation cards (guidance-only)
- Diagnostics export v2 payload
- Demo/Mock mode for no-sim UI/testing

## X-Plane setup

The Connection Wizard and in-app setup sheet use this exact checklist:

1. Open X-Plane > Settings > Data Output
2. Check Send network data output
3. Set IP to 127.0.0.1
4. Set Port to `49005` (or the port shown in CruiseControl)
5. Enable Data Set 0 (frame-rate) and Data Set 20 (position/altitude)

FlyWithLua bridge scripts go in `Resources/plugins/FlyWithLua/Scripts/` inside your X-Plane install folder.

## Diagnostics export v2 payload

- current snapshot + warnings + culprits
- ring-buffer samples (`MetricSample`)
- stutter events and cause summaries
- action receipts
- current workload profile
- regulator proof snapshot
- settings snapshot

## Safety and scope

- no private macOS APIs
- no kernel extensions
- no fake “RAM purge” claims
- reversible/confirmed actions where destructive

## Build

```bash
xcodebuild -project "/Users/Boon/Downloads/Speed for Mac/CruiseControl.xcodeproj" \
  -scheme "CruiseControl" \
  -configuration Debug \
  CODE_SIGNING_ALLOWED=NO build
```
