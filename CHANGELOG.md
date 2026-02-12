# Changelog

## v1.1.0 - Governor Mode + UDP Session Overview

### Added
- Governor Mode with altitude-based tier logic:
  - `GROUND` for low altitude
  - `CLIMB/DESCENT` for mid altitude
  - `CRUISE` for high altitude
- User-configurable governor thresholds, per-tier LOD targets, and clamp bounds.
- Governor UDP bridge command sender in macOS app.
- FlyWithLua script: `Scripts/ProjectSpeed_Governor.lua` to receive UDP commands and apply LOD safely.
- UDP session status model and UI:
  - `IDLE`, `LISTENING`, `ACTIVE`, `MISCONFIG`
  - last packet time, packets/sec, listen address, and setup guidance.

### Changed
- Default X-Plane UDP listening port changed to `49005`.
- Session Overview now uses explicit no-comma port formatting (e.g., `49010`, not `49,010`).
- Sim overview now reports clearer UDP diagnostics and packet state.

### Improved
- Diagnostics export includes UDP state and Governor status.
- Governor policy implemented with testable pure selection functions.
- App version bumped to `1.1.0`.
