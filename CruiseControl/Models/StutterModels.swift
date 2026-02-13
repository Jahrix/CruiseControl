import Foundation

enum GovernorAckState: String, Codable {
    case connected = "Connected"
    case noAck = "No ACK"
    case ackOK = "ACK OK"
    case paused = "Paused"
    case disabled = "Disabled"

    var displayName: String { rawValue }

    var score: Double {
        switch self {
        case .ackOK:
            return 1.0
        case .connected:
            return 0.75
        case .paused:
            return 0.5
        case .disabled:
            return 0.25
        case .noAck:
            return 0.0
        }
    }
}

struct StutterHeuristicConfig: Codable {
    var frameTimeSpikeMS: Double
    var fpsDropThreshold: Double
    var cpuSpikePercent: Double
    var diskSpikeMBps: Double
    var swapJumpBytes: UInt64

    static let `default` = StutterHeuristicConfig(
        frameTimeSpikeMS: 45,
        fpsDropThreshold: 15,
        cpuSpikePercent: 18,
        diskSpikeMBps: 140,
        swapJumpBytes: 128 * 1_024 * 1_024
    )
}

struct StutterEvent: Identifiable, Codable {
    let id: UUID
    let timestamp: Date
    let reason: String
    let rankedCulprits: [String]
    let memoryPressure: MemoryPressureLevel
    let swapUsedBytes: UInt64
    let compressedMemoryBytes: UInt64
    let diskReadMBps: Double
    let diskWriteMBps: Double
    let thermalStateRaw: String
    let telemetryPacketsPerSecond: Double
    let telemetryFreshnessSeconds: Double
    let topCPUProcesses: [ProcessSample]
    let topMemoryProcesses: [ProcessSample]

    init(
        timestamp: Date,
        reason: String,
        rankedCulprits: [String],
        memoryPressure: MemoryPressureLevel,
        swapUsedBytes: UInt64,
        compressedMemoryBytes: UInt64,
        diskReadMBps: Double,
        diskWriteMBps: Double,
        thermalStateRaw: String,
        telemetryPacketsPerSecond: Double,
        telemetryFreshnessSeconds: Double,
        topCPUProcesses: [ProcessSample],
        topMemoryProcesses: [ProcessSample]
    ) {
        self.id = UUID()
        self.timestamp = timestamp
        self.reason = reason
        self.rankedCulprits = rankedCulprits
        self.memoryPressure = memoryPressure
        self.swapUsedBytes = swapUsedBytes
        self.compressedMemoryBytes = compressedMemoryBytes
        self.diskReadMBps = diskReadMBps
        self.diskWriteMBps = diskWriteMBps
        self.thermalStateRaw = thermalStateRaw
        self.telemetryPacketsPerSecond = telemetryPacketsPerSecond
        self.telemetryFreshnessSeconds = telemetryFreshnessSeconds
        self.topCPUProcesses = topCPUProcesses
        self.topMemoryProcesses = topMemoryProcesses
    }
}

enum HistoryDurationOption: String, CaseIterable, Identifiable, Codable {
    case tenMinutes = "10m"
    case twentyMinutes = "20m"
    case thirtyMinutes = "30m"

    var id: String { rawValue }

    var seconds: TimeInterval {
        switch self {
        case .tenMinutes:
            return 600
        case .twentyMinutes:
            return 1_200
        case .thirtyMinutes:
            return 1_800
        }
    }
}
