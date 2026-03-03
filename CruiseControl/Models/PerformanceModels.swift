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
        switch self {
        case .idle:
            return "Offline"
        case .listening:
            return "Listening"
        case .active:
            return "Live"
        case .misconfig:
            return "Error"
        }
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
    var cpuFrameTimeMS: Double?
    var gpuFrameTimeMS: Double?
    var altitudeAGLFeet: Double?
    var altitudeMSLFeet: Double?
    var nearestAirportICAO: String?
    var lastPacketDate: Date?
}

struct TelemetryCapabilities {
    var hasSimCpuFrameTime: Bool
    var hasSimGpuFrameTime: Bool
    var hasAGL: Bool
    var hasMSL: Bool
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
        governorStatusLine: "Regulator: Disabled"
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
    let diskReadMBps: Double
    let diskWriteMBps: Double
    let thermalStateRawValue: Int
    let governorTargetLOD: Double?
    let governorAckState: GovernorAckState

    var id: Date { timestamp }
}

enum ProfileKind: String, Codable, CaseIterable, Identifiable {
    case generalPerformance
    case simMode

    var id: String { rawValue }

    var title: String {
        switch self {
        case .generalPerformance:
            return "General Performance"
        case .simMode:
            return "Sim Mode"
        }
    }

    var preferredSamplingInterval: TimeInterval {
        switch self {
        case .generalPerformance:
            return 1.0
        case .simMode:
            return 0.5
        }
    }

    var minimumSamplingInterval: TimeInterval {
        switch self {
        case .generalPerformance:
            return 1.0
        case .simMode:
            return 0.5
        }
    }

    var maximumSamplingInterval: TimeInterval {
        switch self {
        case .generalPerformance:
            return 2.0
        case .simMode:
            return 1.0
        }
    }
}

enum SituationPresetType: String, Codable, CaseIterable, Identifiable {
    case general
    case airport
    case cruise

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .general:
            return "General"
        case .airport:
            return "Airport"
        case .cruise:
            return "Cruise"
        }
    }
}

enum CruiseSituationStyle: String, Codable, CaseIterable, Identifiable {
    case performance
    case visuals

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .performance:
            return "Performance"
        case .visuals:
            return "Visuals"
        }
    }
}

struct SituationGovernorTargetPreset {
    var groundMaxAGLFeet: Double
    var cruiseMinAGLFeet: Double
    var targetLODGround: Double
    var targetLODClimbDescent: Double
    var targetLODCruise: Double
    var clampMinLOD: Double
    var clampMaxLOD: Double
}

struct SituationPresetConfig {
    var workloadProfile: ProfileKind
    var selectedProfile: SimModeProfileType
    var pauseBackgroundScansDuringSim: Bool
    var governorTargets: SituationGovernorTargetPreset
}

extension SituationPresetType {
    func config(cruiseStyle: CruiseSituationStyle) -> SituationPresetConfig {
        switch self {
        case .general:
            return SituationPresetConfig(
                workloadProfile: .generalPerformance,
                selectedProfile: .balanced,
                pauseBackgroundScansDuringSim: false,
                governorTargets: SituationGovernorTargetPreset(
                    groundMaxAGLFeet: 1_500,
                    cruiseMinAGLFeet: 10_000,
                    targetLODGround: 1.45,
                    targetLODClimbDescent: 1.15,
                    targetLODCruise: 0.95,
                    clampMinLOD: 0.20,
                    clampMaxLOD: 3.00
                )
            )
        case .airport:
            return SituationPresetConfig(
                workloadProfile: .simMode,
                selectedProfile: .aggressive,
                pauseBackgroundScansDuringSim: true,
                governorTargets: SituationGovernorTargetPreset(
                    groundMaxAGLFeet: 2_000,
                    cruiseMinAGLFeet: 11_000,
                    targetLODGround: 1.55,
                    targetLODClimbDescent: 1.20,
                    targetLODCruise: 0.95,
                    clampMinLOD: 0.30,
                    clampMaxLOD: 2.60
                )
            )
        case .cruise:
            switch cruiseStyle {
            case .performance:
                return SituationPresetConfig(
                    workloadProfile: .simMode,
                    selectedProfile: .balanced,
                    pauseBackgroundScansDuringSim: true,
                    governorTargets: SituationGovernorTargetPreset(
                        groundMaxAGLFeet: 1_500,
                        cruiseMinAGLFeet: 9_000,
                        targetLODGround: 1.35,
                        targetLODClimbDescent: 1.05,
                        targetLODCruise: 0.90,
                        clampMinLOD: 0.20,
                        clampMaxLOD: 2.40
                    )
                )
            case .visuals:
                return SituationPresetConfig(
                    workloadProfile: .simMode,
                    selectedProfile: .streaming,
                    pauseBackgroundScansDuringSim: true,
                    governorTargets: SituationGovernorTargetPreset(
                        groundMaxAGLFeet: 1_500,
                        cruiseMinAGLFeet: 9_000,
                        targetLODGround: 1.20,
                        targetLODClimbDescent: 0.95,
                        targetLODCruise: 0.75,
                        clampMinLOD: 0.20,
                        clampMaxLOD: 2.10
                    )
                )
            }
        }
    }
}

struct ProcessImpact: Identifiable, Codable, Hashable {
    let pid: Int32
    let name: String
    let cpu: Double
    let residentBytes: UInt64
    let impactScore: Double

    var id: String { "\(pid)-\(name)" }
}

struct MetricSample: Identifiable, Codable {
    let timestamp: Date
    let cpuTotal: Double
    let memPressure: MemoryPressureLevel
    let swapUsed: UInt64
    let swapDelta: Int64
    let diskRead: Double
    let diskWrite: Double
    let thermalRawValue: Int
    let pressureIndex: Double
    let topProcessImpacts: [ProcessImpact]

    var id: Date { timestamp }

    var thermalState: ProcessInfo.ThermalState {
        ProcessInfo.ThermalState(rawValue: thermalRawValue) ?? .nominal
    }
}

enum ActionKind: String, Codable {
    case quitApp
    case forceQuitApp
    case pauseBackgroundScans
    case openBridgeFolder
    case exportDiagnostics
    case createSupportPack
    case cleanerAction
}

struct ActionReceipt: Identifiable, Codable {
    let id: UUID
    let timestamp: Date
    let profile: ProfileKind
    let kind: ActionKind
    let params: [String: String]
    let before: MetricSample?
    let after: MetricSample?
    let outcome: Bool
    let message: String

    init(
        timestamp: Date,
        profile: ProfileKind,
        kind: ActionKind,
        params: [String: String],
        before: MetricSample?,
        after: MetricSample?,
        outcome: Bool,
        message: String
    ) {
        self.id = UUID()
        self.timestamp = timestamp
        self.profile = profile
        self.kind = kind
        self.params = params
        self.before = before
        self.after = after
        self.outcome = outcome
        self.message = message
    }
}

struct AlertFlags: Equatable {
    var memoryPressureRed: Bool
    var thermalCritical: Bool
    var swapRisingFast: Bool
}
