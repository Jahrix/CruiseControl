# Overnight Telemetry Maintenance Report

## Scope

Stabilized X-Plane UDP `DATA` telemetry ingestion only. No UI, navigation,
roadmap, dependency, licensing, update, commit, or push changes were made.

## Investigation and hypothesis

The telemetry parser correctly validates the `DATA\0` header, 36-byte records,
Data Set 0, FPS limits, and optional CPU/GPU timings. The receive loop, however,
used a 2,048-byte UDP buffer. A valid X-Plane `DATA` datagram can contain many
36-byte records. A packet larger than that buffer was truncated by `recv`, then
rejected as an incomplete/malformed record despite containing valid telemetry.

## Root cause found and fix

The UDP receive buffer was too small for a valid multi-record `DATA` datagram.
`XPlaneUDPReceiver` now uses one reusable 65,535-byte buffer for each read
event, which preserves a complete UDP payload and avoids per-packet buffer
allocation.

## Files changed

- `CruiseControl/Services/XPlaneUDPReceiver.swift` — increased the receiver
  datagram capacity.
- `Tests/CruiseControlCoreTests/CoreTests.swift` — added a regression test for
  a valid packet larger than the previous 2,048-byte limit, with Data Set 0
  following many unrelated records.
- `OVERNIGHT_REPORT.md` — this report.

Pre-existing uncommitted workspace changes were preserved and not altered beyond
the telemetry receiver line noted above.

## Tests added

`TelemetryParserTests.testParsesFrameRateAfterMoreThanLegacyReceiverBufferSize`
constructs a 2,093-byte valid `DATA` packet and verifies that Data Set 0 is
found and decoded after 57 other records.

## Tests executed

```text
swift test --filter TelemetryParserTests
```

Result: passed — 5 tests, 0 failures.

## Build result

```text
xcodebuild -project CruiseControl.xcodeproj -scheme CruiseControl \
  -configuration Debug -derivedDataPath /private/tmp/CruiseControl-telemetry-build \
  CODE_SIGNING_ALLOWED=NO build
```

Result: passed. The Debug app executable was produced at
`/private/tmp/CruiseControl-telemetry-build/Build/Products/Debug/CruiseControl.app`.

## Remaining warnings

Xcode reported only its environment-level warning about multiple matching macOS
destinations and selected the first one. No compiler warnings or telemetry build
errors were reported.

## Remaining real X-Plane validation

Automated tests validate packet framing and decoding but cannot confirm a real
X-Plane Data Output configuration, host firewall behavior, or the exact packet
sets emitted by the installed X-Plane version.

## Manual test procedure for tomorrow

1. Build and launch CruiseControl.
2. In X-Plane, open **Settings → Data Output** and enable network output to the
   Mac running CruiseControl, using the configured UDP port (default `49005`).
3. Enable **Data Set 0 / Frame rate**. Optionally enable **Data Set 20 /
   Position** to populate altitude; CPU/GPU timing fields are read from Data Set
   0 when X-Plane supplies them.
4. In CruiseControl, enable UDP listening and verify its host/port match the
   X-Plane destination. Use `127.0.0.1` when both apps are on the same Mac, or
   `0.0.0.0` when receiving from another machine.
5. Start a flight and verify the connection state becomes active, FPS and frame
   time update continuously, and CPU/GPU timings appear when provided.
6. Enable additional X-Plane Data Output rows (enough to produce a packet above
   2,048 bytes) and confirm telemetry remains active rather than reporting a
   malformed/truncated packet.
7. Disable Data Set 0 and confirm CruiseControl reports that the frame-rate data
   set is missing; re-enable it and confirm recovery.

## Recommended next step

Perform the manual X-Plane test above and capture one raw UDP packet if any
version-specific decoding issue remains. Do not begin further roadmap work until
that real-simulator check is complete.
