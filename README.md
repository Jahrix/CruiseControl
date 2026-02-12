# Project Speed

macOS desktop helper for flight sim performance monitoring on Apple Silicon.

## Build

1. Open `Speed for Mac.xcodeproj` in Xcode.
2. Select scheme `Speed for Mac`.
3. Build and Run.

## X-Plane UDP setup

1. In Project Speed, keep `Listen for X-Plane UDP` enabled and choose a port (default `49005`).
2. In X-Plane: `Settings > Data Output`.
3. Enable `Send network data output`.
4. Set destination IP `127.0.0.1` and destination port to the same Project Speed port.
5. Enable frame-rate and position datasets for telemetry.

The app Session Overview should show:
- `Listening on <address>:<port>`
- `Packets/sec`
- `Last packet received`

Detailed product notes and limitations are in `Speed for Mac/README.md`.
