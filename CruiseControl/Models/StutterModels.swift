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

enum RegulatorControlState {
    case disconnected
    case udpNoAck
    case udpAckOK(lastAck: Date, payload: String)
    case fileBridge(lastUpdate: Date)

    var modeLabel: String {
        switch self {
        case .disconnected:
            return "None"
        case .udpNoAck, .udpAckOK:
            return "UDP"
        case .fileBridge:
            return "File Fallback"
        }
    }
}

enum TelemetryLiveState: String, Codable {
    case offline
    case listening
    case live
    case stale

    var displayName: String {
        rawValue.capitalized
    }
}

enum RegulatorEvidenceSource: String, Codable {
    case udpAck
    case fileStatus
    case unknown
}

struct SessionSnapshot: Codable {
    var capturedAt: Date
    var sessionStartAt: Date?
    var sessionEndAt: Date?
    var telemetrySummary: TelemetrySummary
    var regulatorSummary: RegulatorSummary
    var governorAckOkCount: Int?
    var ackTimeoutCount: Int?

    struct TelemetrySummary: Codable {
        var totalPackets: UInt64
        var avgPacketsPerSec: Double?
        var lastValidPacketAt: Date?
    }

    struct RegulatorSummary: Codable {
        var lastTarget: Double?
        var lastApplied: Double?
        var lastDelta: Double?
        var lastAckAt: Date?
        var evidenceSource: RegulatorEvidenceSource
        var bridgeMode: String
        var appliedOK: Bool
        var activityRecent: Bool
        var reasons: [String]
    }
}

struct RegulatorActionLog: Identifiable {
    let id = UUID()
    let timestamp: Date
    let message: String
}

struct RegulatorProofState {
    var bridgeModeLabel: String
    var lodApplied: Bool
    var recentActivity: Bool
    var onTarget: Bool
    var targetLOD: Double?
    var appliedLOD: Double?
    var deltaToTarget: Double?
    var lastSentAt: Date?
    var lastEvidenceAt: Date?
    var evidenceLine: String?
    var reasons: [String]
    var hasSimData: Bool
    var lastSessionTargetLOD: Double?
    var lastSessionAppliedLOD: Double?
    var lastSessionAt: Date?

    static let empty = RegulatorProofState(
        bridgeModeLabel: "None",
        lodApplied: false,
        recentActivity: false,
        onTarget: false,
        targetLOD: nil,
        appliedLOD: nil,
        deltaToTarget: nil,
        lastSentAt: nil,
        lastEvidenceAt: nil,
        evidenceLine: nil,
        reasons: [],
        hasSimData: false,
        lastSessionTargetLOD: nil,
        lastSessionAppliedLOD: nil,
        lastSessionAt: nil
    )
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

struct StutterCauseSummary: Identifiable, Codable {
    let cause: StutterCause
    let count: Int
    let averageConfidence: Double

    var id: String { cause.rawValue }
}

struct SessionReport: Codable {
    let sessionStartAt: Date
    let sessionEndAt: Date
    let durationSeconds: Int
    let avgPressureIndex: Double
    let maxPressureIndex: Double
    let stutterEpisodesCount: Int
    let topCauses: [TopCause]
    let worstWindow: WorstWindow?
    let actionsTakenSummary: ActionsTakenSummary
    let advisorTriggersSummary: AdvisorTriggersSummary?
    let keyRecommendations: [String]

    struct TopCause: Codable, Identifiable {
        let cause: String
        let count: Int

        var id: String { cause }
    }

    struct WorstWindow: Codable {
        let startAt: Date
        let endAt: Date
        let reason: String
    }

    struct ActionsTakenSummary: Codable {
        let count: Int
        let topActions: [ActionBreakdown]

        struct ActionBreakdown: Codable, Identifiable {
            let action: String
            let count: Int

            var id: String { action }
        }
    }

    struct AdvisorTriggersSummary: Codable {
        let count: Int
        let topTriggers: [String]
    }
}

enum StutterCause: String, Codable, CaseIterable {
    case swapThrash
    case diskStall
    case cpuSaturation
    case thermalThrottle
    case gpuBoundHeuristic
    case unknown

    var displayName: String {
        switch self {
        case .swapThrash:
            return "Swap Thrash"
        case .diskStall:
            return "Disk Stall"
        case .cpuSaturation:
            return "CPU Saturation"
        case .thermalThrottle:
            return "Thermal Throttle"
        case .gpuBoundHeuristic:
            return "GPU Bound (Heuristic)"
        case .unknown:
            return "Unknown"
        }
    }
}

enum StutterMetricAvailability: String, Codable {
    case full
    case partial
    case unavailable

    var displayName: String {
        switch self {
        case .full:
            return "Full"
        case .partial:
            return "Partial"
        case .unavailable:
            return "Unavailable"
        }
    }
}

struct StutterEvent: Identifiable, Codable {
    let id: UUID
    let timestamp: Date
    let severity: Double
    let classification: StutterCause
    let confidence: Double
    let metricAvailability: StutterMetricAvailability
    let evidencePoints: [String]
    let windowRef: String

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
        topMemoryProcesses: [ProcessSample],
        severity: Double,
        classification: StutterCause,
        confidence: Double,
        metricAvailability: StutterMetricAvailability = .full,
        evidencePoints: [String],
        windowRef: String
    ) {
        self.id = UUID()
        self.timestamp = timestamp
        self.severity = severity
        self.classification = classification
        self.confidence = confidence
        self.metricAvailability = metricAvailability
        self.evidencePoints = evidencePoints
        self.windowRef = windowRef
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

struct StutterEpisode: Identifiable, Codable {
    let id: UUID
    let cause: StutterCause
    let startAt: Date
    let endAt: Date
    let count: Int
    let peakSeverity: Double
    let avgConfidence: Double
    let evidenceSummary: [String]
}

enum HistoryDurationOption: String, CaseIterable, Identifiable, Codable {
    case tenMinutes = "10m"
    case thirtyMinutes = "30m"
    case sixtyMinutes = "60m"

    var id: String { rawValue }

    var seconds: TimeInterval {
        switch self {
        case .tenMinutes:
            return 600
        case .thirtyMinutes:
            return 1_800
        case .sixtyMinutes:
            return 3_600
        }
    }
}
