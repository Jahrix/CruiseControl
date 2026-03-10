# CruiseControl — Product Spec (macOS Flight Performance Lab + X-Plane Companion)

**Owner:** Jah (Jahrix)  
**Repo:** `jahrix/cruisecontrol`  
**Platform:** macOS (Apple Silicon + Intel)  
**Primary Sim Target:** X-Plane 12 (support XP11 where feasible)  
**Distribution:** Notarized DMG (Developer ID) + GitHub Releases  
**Positioning:** *Proof-driven performance lab: measure → diagnose → apply safe fixes → verify with receipts.*

---

## 1. Product Summary

CruiseControl is a macOS desktop app that improves X-Plane session smoothness by:

1) **Measuring performance truthfully** (frame-time, stutters, memory pressure/swap, CPU/thermal, top processes).  
2) **Diagnosing likely bottlenecks** (GPU-bound vs CPU-bound vs memory/swap-thrash) with clear confidence.  
3) **Applying user-approved, reversible actions** (profiles, fix packs, LOD regulation) and recording **proof/receipts** that changes actually occurred.

CruiseControl is explicitly **not** a “magic FPS booster.” It is instrumentation + controlled interventions.

---

## 2. Goals and Non-Goals

### Goals
- Reduce perceived stutter and stabilize frame-time consistency during X-Plane sessions.
- Provide **evidence-based** guidance, not placebo tweaks.
- Offer safe, reversible “Fix Packs” with explicit user confirmation and receipts.
- Reduce support burden with a self-test wizard and hardened support pack generation.
- Deliver a premium-feeling macOS experience (UI polish, typography, themes).

### Non-Goals
- No kernel extensions, no private APIs, no invasive system mods.
- No background daemons that persist without consent.
- No “silent auto-update install” claims without a proper signing/notarization story.
- No deep Windows support in v1.x (Windows is a future roadmap item via cross-platform core).

---

## 3. Target Users

### Hobbyists
- Want smoother landings at busy airports.
- Prefer “Simple Mode” and clear recommendations.
- Low tolerance for complex settings.

### Serious Simmers
- Fly payware aircraft, heavy sceneries, online networks (VATSIM/IVAO), long-haul.
- Want detailed bottleneck analysis and reproducible profiles.
- Want proof that settings were applied and what changed.

---

## 4. Core Value Proposition

**CruiseControl is the tool that tells you _why_ you’re stuttering and proves what fixes worked.**

### Key Differentiators
- **Frame-time lab** (not just FPS): stutter episodes, grouping, cooldowns, culprit ranking.
- **System-aware on macOS:** memory pressure + swap thrash + CPU/thermal signals.
- **Proof model:** “Applied” vs “Observed” tracked separately with receipts.
- **Wizard + self-test:** verifies UDP, bridge, and proof/ACK before blaming the user.
- **Fix Packs:** safe, reversible action bundles with confirmation + receipts.

---

## 5. Product Architecture (High-Level)

### A) Flight Performance Lab (macOS)
- Sampling pipeline with bounded cadence and CPU budget mode.
- Snapshot model persisted per-session with retention controls.
- Visualization: frame-time chart, stutter episodes timeline, culprit ranking.
- System signals:
  - Memory pressure / swap
  - CPU utilization + thermal/budget hints
  - Top processes (CPU/memory/impact)

### B) X-Plane Companion
- UDP telemetry receiver (existing): `Services/XPlaneUDPReceiver.swift`
- Bridge to apply LOD regulator changes:
  - FlyWithLua using `sim/private/controls/reno/LOD_bias_rat`
  - Optional file fallback bridge if UDP/LuaSocket not available

### C) Proof / Receipts Model
Two distinct streams:
- **Recent Activity (Observed):** telemetry events, attempted actions.
- **Applied (Proved):** ACK/file receipt indicates the change was actually applied.

---

## 6. Key Features

### 6.1 Dashboard (Always Truthful)
- Status strip shows system pressure/bottleneck even when sim is not live.
- Never display “Idle” if meaningful system metrics exist.

**Status states (examples):**
- Memory pressure high / swap active
- CPU sustained high / thermal constrained
- GPU-bound suspected (based on frame-time patterns)
- No data (only if sampling truly inactive)

### 6.2 Frame-Time Lab
- Real-time frame-time chart (ms).
- Stutter episode detection:
  - episode grouping + cooldowns
  - severity score
  - “culprit ranking” (process/activity correlation)

### 6.3 Memory Pressure + Swap Thrash Detection
- Detect swap thrash patterns and warn:
  - “LOD can’t fix swapping” trust UX
- Recommend reversible actions (lower texture res, reduce object density, etc.).

### 6.4 Top Processes
- Consistent sampling of top CPU/memory processes.
- Must populate reliably even when sim isn’t live.

### 6.5 X-Plane Connection Wizard + Self-Test Checklist
- Step-by-step connection verification:
  - UDP listening
  - UDP live telemetry
  - Bridge OK (LuaSocket / fallback)
  - Proof OK (ACK/file receipt received)

### 6.6 Airport Assist / Situations Profiles
- Profiles: General / Airport / Cruise
- Wizard-guided setup
- Applies safe preset tuning and regulator behavior

### 6.7 Fix Packs (User Approved)
- Bundles of reversible actions that address common scenarios:
  - “Heavy Airport Arrival”
  - “Long Haul Stability”
  - “Swap Thrash Recovery”
- Each Fix Pack logs:
  - what changed
  - why
  - receipts (proof that it applied)

### 6.8 Support Pack Generator (Hardened)
- Allowlist-based diagnostics collection
- Must never include:
  - `.git/`, DerivedData, caches, build outputs
  - keychains, ssh keys, tokens/secrets
  - symlinks
  - absolute user paths (redact `$HOME`)
- Review contents step before zipping
- Manifest includes included files + omissions + sizes + hashes

---

## 7. Monetization and Packaging

### Tiering (Recommended)
**Free**
- Dashboard + monitoring
- Frame-time lab + stutter episodes
- Memory pressure + swap
- Top processes
- Session summary export

**Pro (one-time, target $39)**
- Situations profiles + wizard
- Airport Assist
- Fix Packs + receipts/proof
- Regulator automation with proof model
- Support Pack generator (hardened)

### Licensing (Phase 1)
**Offline signed key (no login).**
- Key is verified locally and stored in Keychain.
- Pro gating via `ProGate`.

**Phase 2 (later)**
- Optional activation count limits (2–3 devices) with lightweight server.

---

## 8. Update System (Trust-Critical)

### Update Source
- GitHub Releases: `jahrix/cruisecontrol`

### Requirements
- Always display the repo being checked:
  - “Checking updates from jahrix/cruisecontrol”
  - endpoint shown inline
- Never map errors to “no releases”:
  - Offline, 404, 401, 403 rate limit, 403 forbidden, generic API errors, empty releases
- Use `GET /repos/jahrix/cruisecontrol/releases`
  - ignore drafts
  - ignore prereleases unless user opts in
- Update UX:
  - “Open Latest Release”
  - “Download Latest DMG” (DMG preferred, ZIP fallback)
  - Save to `~/Downloads`, avoid overwrite using `-1`, `-2` suffixing
- Closed beta guidance (until notarized):
  - right-click Open
  - copyable quarantine removal command:
    - `xattr -dr com.apple.quarantine "/Applications/CruiseControl.app"`

---

## 9. Distribution (macOS)

### Target: “No issues” path
- Join Apple Developer Program
- Sign with Developer ID
- Notarize and staple artifacts
- Ship notarized DMG via GitHub Releases

### Beta Reality
- Gatekeeper friction expected until notarized
- App must never promise silent auto-update installation if unsigned/unnotarized

---

## 10. Safety Model

- No private APIs
- No kernel extensions
- Any destructive action requires explicit user confirmation
- All actions logged with receipts where applicable
- Fail-safe behavior: if a signal is missing or uncertain, report uncertainty and do not apply risky actions

---

## 11. UX / Design Requirements

- Premium typography for hero header
- 16 “royal” themes (later milestone)
- Remove “goofy font vibes”
- Clear status messaging: concise, truthful, non-alarmist
- “Proof model” UI clarity:
  - Applied vs Recent Activity clearly separated

---

## 12. Roadmap (CC-1231..CC-1237)

- **CC-1231:** Airport Assist simple mode
- **CC-1232:** Fix Packs + “LOD can’t fix swapping” UX
- **CC-1233:** Situations profiles (General/Airport/Cruise)
- **CC-1234:** Wizard copy/polish + self-test checklist
- **CC-1235:** Overlay decision (optional)
- **CC-1236:** Session share summary / replay
- **CC-1237:** Premium typography + royal themes

---

## 13. Acceptance Criteria (Definition of Done)

### Build
- `xcodebuild ... CODE_SIGNING_ALLOWED=NO build` succeeds on clean checkout
- No Swift 6 isolation warnings introduced (under `-default-isolation=MainActor`)

### Truthfulness
- Status strip never shows “Idle” when metrics exist
- Update panel always shows repo + endpoint
- Error classification never collapses into “no releases”

### Reliability
- Top Processes populates consistently
- Sampling cadence stays bounded and stable

### Security / Hygiene
- Support Pack cannot include `.git/`, caches, secrets, symlinks, absolute paths
- Support Pack includes manifest with omissions and size caps

---

## 14. Open Questions

- Windows strategy: cross-platform core extraction timeline (C++/Rust service vs later rewrite)
- Default Pro feature list at launch (which surfaces are must-have vs “coming soon”)
- Final pricing and intro offer (Founders discount vs standard)

---