# CruiseControl v2 baseline

## Reality audit

The archive contains one macOS application target (`CruiseControl`) with Debug and Release configurations, SwiftUI entry through `CruiseControlApp`, and no original test target. `AppDelegate` owns a single `PerformanceSampler`, settings, feature state, licensing, status-bar behavior, and an optional overlay. The sampler previously combined host metrics, process enumeration, UDP transport, packet parsing, frame heuristics, governor I/O, session reports, and UI publication on one utility queue. The original primary view was 6,733 lines and exposed thirteen navigation destinations.

What genuinely worked:

- A nonblocking UDP socket listened for X-Plane `DATA` packets.
- Sample/history arrays had time and count caps.
- The app avoided fabricating GPU utilization when timing was absent in the old UI.
- Release/DMG scripts failed on shell errors and the notarization script used Apple tooling.
- License payloads were locally verified and stored in Keychain.

What was unsafe, incomplete, or misleading:

- Packet parsing guessed several field positions, accepted partial records, used wall time for freshness, and discarded the documented CPU/GPU timing fields.
- “GPU Bound (Heuristic)” could be emitted without GPU timing evidence.
- No parser, reconnection, staleness, percentile, classification, or long-session tests existed.
- Generic host “pressure,” cleaner, scan, process, governor, and update behavior dominated an FPS product.
- The release workflow publicly uploaded an unsigned DMG while documentation described it as distributable.
- Sparkle metadata contains placeholders and Sparkle is not linked; seamless automatic updates are not configured.
- The in-app GitHub downloader checked transport and file size but did not verify a signed artifact. It only revealed the file, but it should remain out of the product path until identity verification exists.

## Keep / cut / demote

| Area | Decision | Reason |
|---|---|---|
| X-Plane UDP transport | Keep and harden | It supplies the evidence the product exists to interpret. |
| Frame time, CPU time, GPU time | Keep | These support defensible bottleneck conclusions. |
| Bounded session samples and export | Keep | They prove a result and support before/after comparison. |
| Generic file scan, cleaner, large files, quarantine | Cut from product | They do not explain X-Plane frame time. Physical source removal can follow after migration tests cover any shared support code. |
| Decorative pressure score and broad dashboards | Cut from reachable UI | They compete with the diagnosis and imply precision unsupported by X-Plane timing. |
| Governor / automatic LOD bridge | Demote and isolate | It can become a later experiment executor, but it must not be the diagnosis. |
| Process enumeration | Disable in the live sampling loop | Enumerating every process distorts the measurement and does not prove the frame limiter. |
| Licensing | Demote to Settings | Core diagnosis remains useful without a license server. |
| Updating | Demote to Settings/menu infrastructure | It must stay outside measurement and cannot install unverified payloads. |
| Status bar and overlay | Postpone | Useful only after the main diagnosis is reliable and independently profiled. |

## v2 information architecture

1. **Live Diagnosis** — current FPS and frame time, stable-window trend, one bottleneck, confidence, evidence, one experiment, and before/after result.
2. **Session** — stable frame-time graph, median/p95/p99 when meaningful, spike count, bottleneck changes, and JSON report export.
3. **Setup** — exact X-Plane connection state, Data Output instructions, packet evidence, and a diagnostic connection test.

Settings contains telemetry port, manual update access, and licensing. None is primary navigation.

## Diagnostic rule contract

All sustained rules use a fresh 20-second window with at least 15 samples spanning at least 12 seconds.

| Rule | Required evidence | Threshold | Invalid when | Experiment |
|---|---|---|---|---|
| Simulator/main thread | X-Plane CPU and GPU frame times on ≥75% of samples | median CPU ≥1.12× GPU and ≥72% of total frame time | stale, short, or missing timing window | Reduce world objects one step; compare 30 seconds. |
| GPU | X-Plane CPU and GPU frame times on ≥75% of samples | median GPU ≥1.12× CPU and ≥72% of total frame time | stale, short, or missing timing window | Reduce anti-aliasing one step; compare 30 seconds. |
| Host CPU pressure | Host CPU and X-Plane frame time | median host CPU ≥88% and frame time ≥20 ms | stale or incomplete window | Quit the highest-CPU nonessential app; compare 30 seconds. |
| Instability | Frame-time distribution with p95 | spike frequency ≥5% and p95 ≥1.25× median | fewer than 20 samples or stale window | Pause one sync/recording tool; compare spike frequency. |
| Synchronization/cap | CPU/GPU timing plus low dispersion | within 0.35 FPS of a common cap, MAD ≤2.5%, both processors have ≥22% headroom | missing CPU/GPU timing | Change cap/V-Sync one step; compare pacing. |

Anything else returns **Insufficient evidence**. Confidence increases only with timing coverage and dominance, not decimal precision.

## Remaining roadmap

1. Move the legacy governor and host-metric code out of `PerformanceSampler`; make the v2 session store the sole runtime owner.
2. Add an X-Plane plugin/dataref transport if Data Output compatibility differs across supported simulator releases.
3. Record diagnosis duration, packet-loss estimates, and repeated experiments across launches.
4. Profile Release idle/active CPU, energy, allocations, and chart redraws during a real one-hour flight.
5. Physically delete legacy scan/cleaner/update-download UI after shared types are extracted.
6. Configure real Developer ID and notarization secrets; replace placeholder Sparkle metadata only if a signed appcast is adopted.

## External verification still required

- Real X-Plane 11/12 packets and process lifecycle on supported macOS versions.
- Firewall/Local Network behavior for signed and notarized builds.
- Developer ID/notarization CI using repository secrets.
- A one-hour Instruments run and a repeated in-sim camera/settings comparison.

## Local performance check

The installed Release build was profiled while idle. The original live loop queried free disk capacity every second and repeatedly invoked Workspace Services process discovery, producing roughly 6% observed CPU on the test Mac. Disk capacity is now refreshed at most once per minute, process discovery at most once per five seconds, and valid UDP traffic bypasses process discovery. A post-change steady-state profile is part of the release verification; active-flight energy and one-hour memory behavior still require real X-Plane.
