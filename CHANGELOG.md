# Changelog

## v1.1.5 - Regulator Proof + Apply Stability Hotfix

### Changed
- Reworked Regulator Proof semantics:
  - `LOD Applied` now reflects applied-value evidence freshness (UDP ACK up to 10m, file status up to 5s).
  - `Recent Activity` now reflects recent writes/ramping and can be `NO` while still correctly applied.
- Replaced ambiguous `LOD CHANGING` label with explicit `LOD Applied` + `Recent Activity`.
- Test buttons now use relative changes from current applied/target value:
  - More FPS => higher LOD bias
  - More visuals => lower LOD bias
  - Auto-restore now returns to live active tier target after timed tests.
- Added debounced regulator config apply path (500ms) to reduce slider-drag command churn.
- Added `Use MSL if AGL unavailable` toggle for explicit fallback behavior.

### Added
- `Why not changing?` explanation block with concrete reasons.
- Tier event log (last 10 in UI) for enters/sends/ACK evidence.
- Proof panel target/applied/delta display with `On target` vs `Off target` signal.

## Unreleased - Updater Pipeline

### Added
- Interactive updater flow: `Check for Updates…` can now install updates without rebuilding in Xcode.
- GitHub Releases fallback auto-installer:
  - fetch latest release
  - find a `.zip` CruiseControl asset
  - download + extract + install + relaunch
- Writable destination fallback for updates:
  - uses current app location when writable
  - otherwise installs to `~/Applications`

### Changed
- App menu and Preferences update action now use install-capable update flow instead of check-only flow.
- Sparkle remains first priority when configured; fallback auto-installer runs when Sparkle is unavailable.

## v1.1.4 - Smart Scan + Safe Performance Cleaner

### Added
- Cleaner Suite sidebar modules:
  - Smart Scan
  - Cleaner
  - Large Files
  - Optimization
  - Quarantine
- Async Smart Scan runner with module progress reporting and cancellation.
- Quarantine batch management:
  - batch list UI
  - restore/delete by batch
  - total quarantined size display
- Trash module actions:
  - open Trash in Finder
  - empty Trash confirmation flow
- Optimization allowlist persistence and process-level allowlist action.
- `Open Applications Folder` app maintenance action.
- Sparkle-compatible update bridge path with GitHub fallback.

### Changed
- Smart Scan moved to dedicated section with review deep-links into module pages.
- Cleaner logic hardened with safe allowlist defaults and protected path exclusions.
- Large Files scanning now requires explicit scope selection.
- Memory Relief wording and controls now emphasize truthful pressure-reduction behavior.
- GitHub update endpoint normalized to the active repository.
- Version bumped to `1.1.4` (build `114`).

### Fixed
- Quarantine manifest expanded and written atomically per batch.
- Destructive actions now route through section-aware selection and confirmation dialogs.
- Port/endpoint formatting remains non-grouped numeric style.

## v1.1.3 - Regulator Proof + Bridge UX

### Added
- Header branding update: `CruiseControl by Jahrix`.
- New `Regulator Proof` panel with:
  - bridge mode (`UDP` / `File Fallback` / `None`)
  - telemetry freshness + packets/sec
  - last command + timestamp age
  - ACK status line with file-bridge expected no-ACK handling
  - applied LOD evidence from UDP ACK payload or `lod_status.txt`
  - `LOD CHANGING: YES/NO` indicator
- Bridge folder action in UI:
  - `Open Bridge Folder in Finder`
  - auto-creates `~/Library/Application Support/CruiseControl/` if missing
- Temporary test controls with auto-restore:
  - `Test: FPS Mode (shorter draw distance)` -> LOD `1.30`
  - `Test: Visual Mode (longer draw distance)` -> LOD `0.75`
  - 10s timed run with automatic restore and recent action logging

### Changed
- User-facing terminology in UI moved from `Governor` to `Regulator` (labels, cards, wizard text).
- Connection Wizard now separates:
  - X-Plane running
  - telemetry health
  - control bridge mode
  - ACK status
- File fallback bridge path standardized to:
  - `~/Library/Application Support/CruiseControl/lod_target.txt`
  - `~/Library/Application Support/CruiseControl/lod_mode.txt`
  - `~/Library/Application Support/CruiseControl/lod_status.txt` (optional Lua output)
- LOD direction labeling clarified in UI:
  - higher bias = shorter draw distance (more FPS)
  - lower bias = longer draw distance (more visuals)
- App version bumped to `1.1.3` (build `113`).

### Fixed
- Bridge status contradictions reduced by introducing shared `RegulatorControlState` in sampler/UI.
- File bridge mode no longer presents missing ACK as an automatic error in wizard/proof contexts.

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
- XP11 compatibility pass: setup guidance now explicitly references Data Set 0/20 and X-Plane 11/12 FlyWithLua install path.

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
