# Project Speed v1.1.1

macOS desktop helper for flight sim performance monitoring and altitude-driven LOD automation on Apple Silicon.

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

Session Overview should show:
- `Listening on <address>:<port>`
- `Packets/sec`
- `Last packet received`

## LOD Governor setup

1. Copy `Scripts/ProjectSpeed_Governor.lua` to:
   `X-Plane 12/Resources/plugins/FlyWithLua/Scripts/ProjectSpeed_Governor.lua`
2. In Project Speed LOD Governor card, confirm bridge host/port match script settings (default `127.0.0.1:49006`).
3. Enable LOD Governor and verify command status.

Detailed product notes and limitations are in `Speed for Mac/README.md`.
