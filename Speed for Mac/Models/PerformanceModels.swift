import Foundation
import AppKit

enum MemoryPressureLevel: String, Codable {
    case green
    case yellow
    case red

    var displayName: String {
        rawValue.capitalized
    }

    var score: Int {
        switch self {
        case .green:
            return 0
        case .yellow:
            return 1
        case .red:
            return 2
        }
    }
}

enum MemoryPressureTrend: String, Codable {
    case rising
    case falling
    case stable

    var icon: String {
        switch self {
        case .rising:
            return "↑"
        case .falling:
            return "↓"
        case .stable:
            return "→"
        }
    }
}

enum SamplingIntervalOption: String, Codable, CaseIterable, Identifiable {
    case halfSecond = "0.5s"
    case oneSecond = "1s"
    case twoSeconds = "2s"

    var id: String { rawValue }

    var seconds: TimeInterval {
        switch self {
        case .halfSecond:
            return 0.5
        case .oneSecond:
            return 1.0
        case .twoSeconds:
            return 2.0
        }
    }
}

enum XPlaneUDPConnectionState: String, Codable {
    case idle
    case listening
    case active
    case misconfig

    var displayName: String {
        rawValue.uppercased()
    }
}

struct XPlaneUDPStatus: Codable {
    var state: XPlaneUDPConnectionState
    var listenHost: String
    var listenPort: Int
    var lastPacketDate: Date?
    var lastValidPacketDate: Date?
    var packetsPerSecond: Double
    var totalPackets: UInt64
    var invalidPackets: UInt64
    var detail: String?

    static func idle(host: String = "127.0.0.1", port: Int = 49005) -> XPlaneUDPStatus {
        XPlaneUDPStatus(
            state: .idle,
            listenHost: host,
            listenPort: port,
            lastPacketDate: nil,
            lastValidPacketDate: nil,
            packetsPerSecond: 0,
            totalPackets: 0,
            invalidPackets: 0,
            detail: "UDP listening is disabled."
        )
    }
}

struct SimTelemetrySnapshot: Codable {
    var source: String
    var fps: Double?
    var frameTimeMS: Double?
    var altitudeAGLFeet: Double?
    var altitudeMSLFeet: Double?
    var lastPacketDate: Date?
}

struct PerformanceSnapshot {
    var cpuUserPercent: Double
    var cpuSystemPercent: Double
    var memoryPressure: MemoryPressureLevel
    var memoryPressureTrend: MemoryPressureTrend
    var compressedMemoryBytes: UInt64
    var swapUsedBytes: UInt64
    var swapDelta5MinBytes: Int64
    var diskReadMBps: Double
    var diskWriteMBps: Double
    var freeDiskBytes: UInt64
    var ioPressureLikely: Bool
    var thermalState: ProcessInfo.ThermalState
    var lastUpdated: Date?
    var xplaneTelemetry: SimTelemetrySnapshot?
    var udpStatus: XPlaneUDPStatus
    var governorStatusLine: String

    var cpuTotalPercent: Double {
        cpuUserPercent + cpuSystemPercent
    }
}

extension PerformanceSnapshot {
    static let empty = PerformanceSnapshot(
        cpuUserPercent: 0,
        cpuSystemPercent: 0,
        memoryPressure: .green,
        memoryPressureTrend: .stable,
        compressedMemoryBytes: 0,
        swapUsedBytes: 0,
        swapDelta5MinBytes: 0,
        diskReadMBps: 0,
        diskWriteMBps: 0,
        freeDiskBytes: 0,
        ioPressureLikely: false,
        thermalState: .nominal,
        lastUpdated: nil,
        xplaneTelemetry: nil,
        udpStatus: .idle(),
        governorStatusLine: "Governor: Disabled"
    )
}

struct ProcessSample: Identifiable, Hashable, Codable {
    let pid: Int32
    let name: String
    let bundleIdentifier: String?
    let cpuPercent: Double
    let memoryBytes: UInt64
    let sampledAt: Date

    var id: String {
        "\(pid)-\(name)"
    }
}

struct MetricHistoryPoint: Identifiable, Codable {
    let timestamp: Date
    let cpuTotalPercent: Double
    let swapUsedBytes: UInt64
    let memoryPressure: MemoryPressureLevel

    var id: Date { timestamp }
}

struct AlertFlags: Equatable {
    var memoryPressureRed: Bool
    var thermalCritical: Bool
    var swapRisingFast: Bool
}
