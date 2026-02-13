# Changelog

## v1.1.2 - Memory Relief + ACK + Smart Scan

### Added
- Memory Pressure Relief panel with:
  - pressure/swap/compressed memory visibility
  - top memory process suggestions
  - user-confirmed close selected apps action
- FlyWithLua ACK handshake plumbing and UI:
  - command/ACK tracking for `PING`, `ENABLE`, `DISABLE`, `SET_LOD`
  - explicit governor ACK state (`Connected`, `No ACK`, `ACK OK`, paused/disabled)
- Connection Wizard card with actionable checks:
  - X-Plane detection
  - UDP endpoint + packet rate status
  - FlyWithLua handshake test (`PING`/`PONG`)
- Stutter Detective:
  - heuristic stutter event capture
  - culprit ranking snapshots and what-to-fix context
- Mini history features:
  - ring-buffer history support up to 30 minutes
  - lightweight sparkline charts for CPU/swap/disk/governor ACK
  - selectable duration: `10m` / `20m` / `30m`
- Per-airport governor profile model:
  - ICAO keyed profile overrides
  - JSON import/export support
  - default example profiles (heavy hub / medium / GA field)
- Smart Scan suite (safe scope):
  - system junk (user-safe paths)
  - trash bins
  - large files (user-selected roots)
  - optimization and optional privacy modules
- Quarantine safety model:
  - move selected files to app quarantine folder
  - manifest JSON for restore
  - restore + permanent delete actions
- App maintenance service:
  - show app in Finder
  - install to `/Applications`
  - GitHub Releases update check action

### Changed
- App version bumped to `1.1.2` (build `112`).
- Bundle identifier migrated from `jahrix.Speed-for-Mac` to `jahrix.CruiseControl`.
- Migration note: settings under `~/Library/Preferences/jahrix.Speed-for-Mac.plist` are not auto-imported into the new domain.
- App delegate now applies combined runtime config from settings + v1.1.2 feature store.
- Documentation refreshed for ACK protocol, wizard flow, and quarantine safety.

### Fixed
- `V112FeatureStore` now imports `Combine` for `ObservableObject`/`@Published` conformance.
- Governor runtime status fields in sampler are now published so UI updates correctly.

## v1.1.1 - Automatic LOD Governor

### Added
- Automatic LOD Governor with altitude tiers:
  - `GROUND` (< 1500 ft AGL)
  - `TRANSITION` (1500-10000 ft AGL)
  - `CRUISE` (> 10000 ft AGL)
- Governor behavior controls in app settings:
  - minimum time in tier (anti-flap hysteresis)
  - ramp duration
  - minimum command interval
  - minimum send delta
- LOD Governor status card values:
  - AGL
  - active tier
  - tier target
  - ramp value
  - last sent LOD
  - command status (`Connected` / `Not connected`)
- `Test send` action for single LOD command validation.
- Setup panel for FlyWithLua companion install path and troubleshooting.
- Companion script command protocol support:
  - `ENABLE`
  - `SET_LOD <float>`
  - `DISABLE`
- File fallback channel (`/tmp/CruiseControl_lod_target.txt`) when LuaSocket is unavailable in FlyWithLua.
- Debug self-tests for tier selection pure function.

### Changed
- Governor UI renamed to `LOD Governor` and expanded with full tuning controls.
- Script-side safety clamp defaults widened to `0.20...3.00`.
- Governor now pauses on telemetry loss/inactive sim and stops command spam.

### Fixed
- Governor commands now ramp smoothly instead of hard-jumping on tier changes.
- Tier switching now respects minimum hold time to reduce rapid flapping.
- LOD commands are rate-limited and delta-limited before send.
- App version bumped to `1.1.1`.

## v1.1.0 - Governor Mode + UDP Session Overview

### Added
- Governor Mode with altitude-based tier logic.
- User-configurable governor thresholds, per-tier LOD targets, and clamp bounds.
- Governor UDP bridge command sender in macOS app.
- FlyWithLua script: `Scripts/CruiseControl_Governor.lua` to receive UDP commands and apply LOD safely.
- UDP session status model and UI (`IDLE`, `LISTENING`, `ACTIVE`, `MISCONFIG`).

### Changed
- Default X-Plane UDP listening port changed to `49005`.
- Session Overview now uses explicit no-comma port formatting (e.g., `49010`, not `49,010`).

### Fixed
- UDP socket error reporting now maps real `errno` values for bind/setup failures.
- Bind failure text no longer always reports "port already in use".
- Session Overview listen address now reflects the actual bind target (`127.0.0.1` vs `0.0.0.0 (all interfaces)`).
- Stale bind error text is cleared after successful listener startup.
