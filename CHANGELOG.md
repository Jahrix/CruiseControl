# Changelog

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
- File fallback channel (`/tmp/ProjectSpeed_lod_target.txt`) when LuaSocket is unavailable in FlyWithLua.
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
- FlyWithLua script: `Scripts/ProjectSpeed_Governor.lua` to receive UDP commands and apply LOD safely.
- UDP session status model and UI (`IDLE`, `LISTENING`, `ACTIVE`, `MISCONFIG`).

### Changed
- Default X-Plane UDP listening port changed to `49005`.
- Session Overview now uses explicit no-comma port formatting (e.g., `49010`, not `49,010`).

### Fixed
- UDP socket error reporting now maps real `errno` values for bind/setup failures.
- Bind failure text no longer always reports "port already in use".
- Session Overview listen address now reflects the actual bind target (`127.0.0.1` vs `0.0.0.0 (all interfaces)`).
- Stale bind error text is cleared after successful listener startup.
