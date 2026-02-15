# CruiseControl v1.2.0 (Desktop App)

CruiseControl v1.2 centers the app around frame-time diagnostics and X-Plane companion workflows.

## Highlights

- Frame-Time Lab with Swift Charts timeline + stutter markers
- Stutter classifier (`swapThrash`, `diskStall`, `cpuSaturation`, `thermalThrottle`, `gpuBoundHeuristic`, `unknown`)
- Workload Profiles (`General Performance`, `Sim Mode`)
- Action receipts with before/after sample snapshots
- X-Plane Advisor recommendation cards (guidance-only)
- Diagnostics export v2 payload
- Demo/Mock mode for no-sim UI/testing

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
