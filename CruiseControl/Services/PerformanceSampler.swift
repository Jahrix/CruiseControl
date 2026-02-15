import Foundation
import AppKit
import Combine
import UniformTypeIdentifiers

struct DiagnosticsExportOutcome {
    let success: Bool
    let fileURL: URL?
    let message: String
}

final class PerformanceSampler: ObservableObject {
    @Published private(set) var snapshot: PerformanceSnapshot = .empty
    @Published private(set) var topCPUProcesses: [ProcessSample] = []
    @Published private(set) var topMemoryProcesses: [ProcessSample] = []
    @Published private(set) var warnings: [String] = []
    @Published private(set) var culprits: [String] = []
    @Published private(set) var history: [MetricHistoryPoint] = []
    @Published private(set) var isSimActive: Bool = false
    @Published private(set) var alertFlags = AlertFlags(memoryPressureRed: false, thermalCritical: false, swapRisingFast: false)
    @Published private(set) var configuredIntervalSeconds: TimeInterval = 1.0
    @Published private(set) var governorDecision: GovernorDecision?
    @Published private(set) var governorCurrentTier: GovernorTier?
    @Published private(set) var governorCurrentTargetLOD: Double?
    @Published private(set) var governorSmoothedTargetLOD: Double?
    @Published private(set) var governorActiveAGLFeet: Double?
    @Published private(set) var governorLastSentLOD: Double?
    @Published private(set) var governorCommandStatus: String = "Not connected"
    @Published private(set) var governorPauseReason: String?
    @Published private(set) var governorAckState: GovernorAckState = .noAck
    @Published private(set) var governorLastCommandText: String?
    @Published private(set) var governorLastCommandDate: Date?
    @Published private(set) var governorLastACKText: String?
    @Published private(set) var governorLastACKDate: Date?
    @Published private(set) var regulatorControlState: RegulatorControlState = .disconnected
    @Published private(set) var regulatorFileBridgeStatus: GovernorFileBridgeStatus?
    @Published private(set) var regulatorLODChanging: Bool = false
    @Published private(set) var regulatorProofState: RegulatorProofState = .empty
    @Published private(set) var regulatorWhyNotChanging: [String] = []
    @Published private(set) var regulatorTierEvents: [RegulatorActionLog] = []
    @Published private(set) var regulatorRecentActions: [RegulatorActionLog] = []
    @Published private(set) var regulatorTestActive: Bool = false
    @Published private(set) var regulatorTestCountdownSeconds: Int = 0
    @Published private(set) var stutterEvents: [StutterEvent] = []
    @Published private(set) var metricSamples: [MetricSample] = []
    @Published private(set) var actionReceipts: [ActionReceipt] = []
    @Published private(set) var workloadProfile: ProfileKind = .generalPerformance
    @Published private(set) var stutterCauseSummaries: [StutterCauseSummary] = []
    private let processScanner = ProcessScanner()
    private let queue = DispatchQueue(label: "CruiseControl.PerformanceSampler", qos: .utility)
    private let xPlaneReceiver = XPlaneUDPReceiver()
    private let governorBridge = GovernorCommandBridge()

    private var timer: DispatchSourceTimer?
    private var sampleCount: UInt64 = 0
    private var previousCPUTicks: host_cpu_load_info_data_t?
    private var previousSwapUsedBytes: UInt64 = 0
    private var previousDiskIO: DiskIOSnapshot?
    private var previousDiskSampleDate: Date?

    private var historyBuffer: [MetricHistoryPoint] = []
    private var metricSampleBuffer: [MetricSample] = []
    private var actionReceiptBuffer: [ActionReceipt] = []

    private var smoothedUserCPU: Double = 0
    private var smoothedSystemCPU: Double = 0

    private var samplingIntervalSeconds: TimeInterval = 1.0
    private var smoothingAlpha: Double = 0.35
    private var profileMode: ProfileKind = .generalPerformance
    private var demoMockModeEnabled: Bool = false

    private var udpListeningEnabled: Bool = true
    private var xPlaneUDPPort: Int = 49_005

    private var governorConfig: GovernorPolicyConfig = .default
    private var governorPreviouslyEnabled = false

    private var governorLockedTier: GovernorTier?
    private var governorLockedTierSince: Date?
    private var governorSmoothedLODInternal: Double?
    private var governorCurrentTierTargetLODInternal: Double?
    private var governorLastUpdateAt: Date?

    private struct RegulatorTestSession {
        var startedAt: Date
        var endsAt: Date
        var fallbackRestoreLOD: Double
        var modeLabel: String
    }

    private var pendingRegulatorTest: RegulatorTestSession?
    private var lastObservedAckAppliedLOD: Double?
    private var lastAckAppliedLODChangeAt: Date?
    private var lastObservedFileStatusLOD: Double?
    private var lastFileLODChangeAt: Date?
    private var lastLoggedTier: GovernorTier?
    private var lastLoggedAckAt: Date?
    private var lastLoggedFileStatusUpdateAt: Date?
    private var lastSessionTargetLOD: Double?
    private var lastSessionAppliedLOD: Double?
    private var lastSessionAt: Date?

    private var stutterHeuristics: StutterHeuristicConfig = .default
    private var stutterBuffer: [StutterEvent] = []
    private var previousFrameTimeMS: Double?
    private var previousFPS: Double?
    private var previousCPUTotalPercent: Double?
    private var previousThermalState: ProcessInfo.ThermalState = .nominal

    func configureSampling(interval: TimeInterval, alpha: Double) {
        let clampedInterval = max(0.25, min(interval, 2.0))
        let clampedAlpha = min(max(alpha, 0.05), 0.95)

        if profileMode == .simMode {
            samplingIntervalSeconds = min(clampedInterval, ProfileKind.simMode.preferredSamplingInterval)
        } else {
            samplingIntervalSeconds = max(clampedInterval, ProfileKind.generalPerformance.preferredSamplingInterval)
        }
        smoothingAlpha = clampedAlpha

        Task { @MainActor in
            configuredIntervalSeconds = clampedInterval
        }

        guard timer != nil else { return }
        restartTimer()
    }

    func configureXPlaneUDP(enabled: Bool, port: Int) {
        udpListeningEnabled = enabled
        xPlaneUDPPort = min(max(port, 1_024), 65_535)
        xPlaneReceiver.configure(enabled: udpListeningEnabled, port: xPlaneUDPPort, queue: queue)
    }

    func configureGovernor(config: GovernorPolicyConfig) {
        governorConfig = config

        if !config.enabled, governorPreviouslyEnabled {
            _ = governorBridge.sendDisable(host: config.commandHost, port: config.commandPort)
            governorPreviouslyEnabled = false
        }

        if !config.enabled {
            resetGovernorRuntimeState()
        }
    }

    func configureStutterHeuristics(_ config: StutterHeuristicConfig) {
        stutterHeuristics = config
    }

    func configureWorkloadProfile(_ profile: ProfileKind) {
        profileMode = profile
        Task { @MainActor in
            workloadProfile = profile
        }

        if profile == .simMode {
            samplingIntervalSeconds = min(samplingIntervalSeconds, profile.preferredSamplingInterval)
        } else {
            samplingIntervalSeconds = max(samplingIntervalSeconds, profile.preferredSamplingInterval)
        }

        guard timer != nil else { return }
        restartTimer()
    }

    func configureDemoMockMode(enabled: Bool) {
        demoMockModeEnabled = enabled
    }

    func start() {
        guard timer == nil else { return }

        xPlaneReceiver.configure(enabled: udpListeningEnabled, port: xPlaneUDPPort, queue: queue)
        restartTimer()
    }

    func stop() {
        timer?.cancel()
        timer = nil
        xPlaneReceiver.stop()

        if governorPreviouslyEnabled {
            _ = governorBridge.sendDisable(host: governorConfig.commandHost, port: governorConfig.commandPort)
            governorPreviouslyEnabled = false
        }
    }

    deinit {
        timer?.cancel()
        xPlaneReceiver.stop()
    }

    @MainActor
    func isSamplingStale(at referenceDate: Date = Date()) -> Bool {
        guard let lastUpdated = snapshot.lastUpdated else { return true }
        let staleAfter = max(configuredIntervalSeconds * 2.5, 3.0)
        return referenceDate.timeIntervalSince(lastUpdated) > staleAfter
    }

    @MainActor
    func computeProofState(now: Date = Date()) -> RegulatorProofState {
        var state = regulatorProofState
        if let lastSend = state.lastSentAt {
            state.recentActivity = state.recentActivity || now.timeIntervalSince(lastSend) <= 20
        }
        return state
    }

    @MainActor
    func exportDiagnostics(settingsSnapshot: [String: String] = [:]) -> DiagnosticsExportOutcome {
        struct ExportReport: Codable {
            let generatedAt: Date
            let profile: String
            let simActive: Bool
            let snapshot: SnapshotBody
            let proof: ProofBody
            let warnings: [String]
            let culprits: [String]
            let topCPUProcesses: [ProcessSample]
            let topMemoryProcesses: [ProcessSample]
            let recentHistory: [MetricHistoryPoint]
            let recentSamples: [MetricSample]
            let stutterEvents: [StutterEvent]
            let stutterCauseSummaries: [StutterCauseSummary]
            let actionReceipts: [ActionReceipt]
            let governorDecision: GovernorDecision?
            let settingsSnapshot: [String: String]

            struct SnapshotBody: Codable {
                let cpuUserPercent: Double
                let cpuSystemPercent: Double
                let memoryPressure: String
                let memoryPressureTrend: String
                let compressedMemoryBytes: UInt64
                let swapUsedBytes: UInt64
                let swapDelta5MinBytes: Int64
                let diskReadMBps: Double
                let diskWriteMBps: Double
                let freeDiskBytes: UInt64
                let ioPressureLikely: Bool
                let thermalState: String
                let lastUpdated: Date?
                let xPlaneTelemetrySource: String?
                let xPlaneFPS: Double?
                let xPlaneFrameTimeMS: Double?
                let altitudeAGLFeet: Double?
                let altitudeMSLFeet: Double?
                let udpState: String
                let udpListenAddress: String
                let udpPacketsPerSecond: Double
                let udpTotalPackets: UInt64
                let udpInvalidPackets: UInt64
                let udpDetail: String?
                let governorStatusLine: String
                let governorAckState: String
                let governorLastCommand: String?
                let governorLastACK: String?
            }

            struct ProofBody: Codable {
                let bridgeModeLabel: String
                let lodApplied: Bool
                let recentActivity: Bool
                let onTarget: Bool
                let targetLOD: Double?
                let appliedLOD: Double?
                let deltaToTarget: Double?
                let lastSentAt: Date?
                let lastEvidenceAt: Date?
                let evidenceLine: String?
                let reasons: [String]
            }
        }

        let proof = computeProofState(now: Date())
        let report = ExportReport(
            generatedAt: Date(),
            profile: workloadProfile.rawValue,
            simActive: isSimActive,
            snapshot: .init(
                cpuUserPercent: snapshot.cpuUserPercent,
                cpuSystemPercent: snapshot.cpuSystemPercent,
                memoryPressure: snapshot.memoryPressure.rawValue,
                memoryPressureTrend: snapshot.memoryPressureTrend.rawValue,
                compressedMemoryBytes: snapshot.compressedMemoryBytes,
                swapUsedBytes: snapshot.swapUsedBytes,
                swapDelta5MinBytes: snapshot.swapDelta5MinBytes,
                diskReadMBps: snapshot.diskReadMBps,
                diskWriteMBps: snapshot.diskWriteMBps,
                freeDiskBytes: snapshot.freeDiskBytes,
                ioPressureLikely: snapshot.ioPressureLikely,
                thermalState: thermalStateDescription(snapshot.thermalState),
                lastUpdated: snapshot.lastUpdated,
                xPlaneTelemetrySource: snapshot.xplaneTelemetry?.source,
                xPlaneFPS: snapshot.xplaneTelemetry?.fps,
                xPlaneFrameTimeMS: snapshot.xplaneTelemetry?.frameTimeMS,
                altitudeAGLFeet: snapshot.xplaneTelemetry?.altitudeAGLFeet,
                altitudeMSLFeet: snapshot.xplaneTelemetry?.altitudeMSLFeet,
                udpState: snapshot.udpStatus.state.rawValue,
                udpListenAddress: "\(snapshot.udpStatus.listenHost):\(snapshot.udpStatus.listenPort)",
                udpPacketsPerSecond: snapshot.udpStatus.packetsPerSecond,
                udpTotalPackets: snapshot.udpStatus.totalPackets,
                udpInvalidPackets: snapshot.udpStatus.invalidPackets,
                udpDetail: snapshot.udpStatus.detail,
                governorStatusLine: snapshot.governorStatusLine,
                governorAckState: governorAckState.rawValue,
                governorLastCommand: governorLastCommandText,
                governorLastACK: governorLastACKText
            ),
            proof: .init(
                bridgeModeLabel: proof.bridgeModeLabel,
                lodApplied: proof.lodApplied,
                recentActivity: proof.recentActivity,
                onTarget: proof.onTarget,
                targetLOD: proof.targetLOD,
                appliedLOD: proof.appliedLOD,
                deltaToTarget: proof.deltaToTarget,
                lastSentAt: proof.lastSentAt,
                lastEvidenceAt: proof.lastEvidenceAt,
                evidenceLine: proof.evidenceLine,
                reasons: proof.reasons
            ),
            warnings: warnings,
            culprits: culprits,
            topCPUProcesses: topCPUProcesses,
            topMemoryProcesses: topMemoryProcesses,
            recentHistory: Array(history.suffix(1800)),
            recentSamples: Array(metricSamples.suffix(1800)),
            stutterEvents: Array(stutterEvents.suffix(120)),
            stutterCauseSummaries: stutterCauseSummaries,
            actionReceipts: Array(actionReceipts.suffix(120)),
            governorDecision: governorDecision,
            settingsSnapshot: settingsSnapshot
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        do {
            let data = try encoder.encode(report)

            let formatter = DateFormatter()
            formatter.dateFormat = "yyyyMMdd-HHmmss"
            let suggestedName = "CruiseControl-diagnostics-v2-\(formatter.string(from: Date())).json"

            let panel = NSSavePanel()
            panel.title = "Export Diagnostics"
            panel.message = "Choose where to save your diagnostics report."
            panel.nameFieldStringValue = suggestedName
            panel.canCreateDirectories = true
            panel.showsTagField = false
            panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first

            if #available(macOS 11.0, *) {
                panel.allowedContentTypes = [UTType.json]
            } else {
                panel.allowedFileTypes = ["json"]
            }

            guard panel.runModal() == .OK, let fileURL = panel.url else {
                return DiagnosticsExportOutcome(success: false, fileURL: nil, message: "Diagnostics export cancelled.")
            }

            let directoryURL = fileURL.deletingLastPathComponent()
            let access = directoryURL.startAccessingSecurityScopedResource()
            defer {
                if access { directoryURL.stopAccessingSecurityScopedResource() }
            }

            try data.write(to: fileURL, options: .atomic)
            return DiagnosticsExportOutcome(success: true, fileURL: fileURL, message: "Diagnostics exported to \(fileURL.path).")
        } catch {
            return DiagnosticsExportOutcome(success: false, fileURL: nil, message: "Failed to export diagnostics: \(error.localizedDescription)")
        }
    }

    private func restartTimer() {
        timer?.cancel()

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: samplingIntervalSeconds, leeway: .milliseconds(120))
        timer.setEventHandler { [weak self] in
            self?.sample()
        }
        self.timer = timer
        timer.resume()
    }

    private func sample() {
        sampleCount += 1
        let now = Date()

        let cpu = readCPU()
        let memorySnapshot = SystemMetricsReader.readMemorySnapshot()
        let swapUsedBytes = SystemMetricsReader.readSwapUsedBytes() ?? previousSwapUsedBytes
        let thermal = ProcessInfo.processInfo.thermalState
        let memoryPressure = inferMemoryPressure(memorySnapshot: memorySnapshot, swapUsedBytes: swapUsedBytes)
        let compressedBytes = memorySnapshot?.compressedBytes ?? 0

        let diskIO = SystemMetricsReader.readDiskIOSnapshot()
        let diskRate = computeDiskRates(current: diskIO, now: now)
        let freeDiskBytes = SystemMetricsReader.readFreeDiskBytes() ?? 0

        let udpSnapshot = xPlaneReceiver.snapshot(now: now)
        let udpStatus = udpSnapshot.status
        let telemetry = udpSnapshot.telemetry

        var scannedProcesses: [ProcessSample]? = nil
        let processScanModulo = max(Int((1.0 / samplingIntervalSeconds).rounded()), 1)
        if sampleCount % UInt64(processScanModulo) == 0 {
            scannedProcesses = processScanner.sampleProcesses()
        }

        let processDetected = isXPlaneProcessRunning(processes: scannedProcesses)
        let simActive = processDetected || udpStatus.state == .active


        let swapDelta5Min = computeSwapDelta(windowSeconds: 300, now: now)
        let swapRapidIncrease = computeSwapDelta(windowSeconds: 90, now: now) > Int64(256 * 1_024 * 1_024)
        let pressureTrend = inferMemoryTrend()

        let ioPressureLikely =
            (diskRate.readMBps + diskRate.writeMBps) > 120.0 &&
            swapRapidIncrease &&
            memoryPressure == .red

        maybeCompleteRegulatorTestIfNeeded(now: now)
        let governorResult = evaluateGovernor(telemetry: telemetry, udpStatus: udpStatus, simActive: simActive, now: now)
        let fileBridgeStatus = governorBridge.readFileBridgeStatus()
        let controlState = deriveRegulatorControlState(now: now, fileBridgeStatus: fileBridgeStatus)
        maybeLogBridgeEvents(now: now, fileBridgeStatus: fileBridgeStatus)
        let proofState = buildRegulatorProofState(
            now: now,
            simActive: simActive,
            controlState: controlState,
            fileBridgeStatus: fileBridgeStatus,
            governorResult: governorResult
        )
        let lodChanging = proofState.recentActivity
        let testCountdown = pendingRegulatorTest.map { max(Int(ceil($0.endsAt.timeIntervalSince(now))), 0) } ?? 0

        let historyPoint = MetricHistoryPoint(
            timestamp: now,
            cpuTotalPercent: cpu.user + cpu.system,
            swapUsedBytes: swapUsedBytes,
            memoryPressure: memoryPressure,
            diskReadMBps: diskRate.readMBps,
            diskWriteMBps: diskRate.writeMBps,
            thermalStateRawValue: thermal.rawValue,
            governorTargetLOD: governorResult.smoothedLOD,
            governorAckState: governorResult.ackState
        )
        historyBuffer.append(historyPoint)

        let sourceProcesses = scannedProcesses ?? topCPUProcesses
        let processImpacts = Array(
            sourceProcesses
                .map {
                    ProcessImpact(
                        pid: $0.pid,
                        name: $0.name,
                        cpu: $0.cpuPercent,
                        residentBytes: $0.memoryBytes,
                        impactScore: ($0.cpuPercent * 1.7) + (Double($0.memoryBytes) / 1_073_741_824.0 * 9.0)
                    )
                }
                .sorted { $0.impactScore > $1.impactScore }
                .prefix(5)
        )

        let pressureIndex = pressureIndexScore(
            cpuTotal: cpu.user + cpu.system,
            memoryPressure: memoryPressure,
            swapDelta5Min: swapDelta5Min,
            diskReadMBps: diskRate.readMBps,
            diskWriteMBps: diskRate.writeMBps,
            thermalState: thermal
        )

        let metricSample = MetricSample(
            timestamp: now,
            cpuTotal: cpu.user + cpu.system,
            memPressure: memoryPressure,
            swapUsed: swapUsedBytes,
            swapDelta: swapDelta5Min,
            diskRead: diskRate.readMBps,
            diskWrite: diskRate.writeMBps,
            thermalRawValue: thermal.rawValue,
            pressureIndex: pressureIndex,
            topProcessImpacts: processImpacts
        )
        metricSampleBuffer.append(metricSample)
        if demoMockModeEnabled {
            appendDemoMetricSample(now: now)
        }

        trimHistory(reference: now)

        var warningItems = buildWarnings(
            memoryPressure: memoryPressure,
            thermalState: thermal,
            swapRapidIncrease: swapRapidIncrease,
            ioPressureLikely: ioPressureLikely,
            freeDiskBytes: freeDiskBytes,
            topCPUProcesses: scannedProcesses ?? topCPUProcesses,
            simActive: simActive,
            udpStatus: udpStatus
        )

        if governorResult.ackState == .noAck {
            warningItems.append("Regulator bridge has no ACK from FlyWithLua. Use Connection Wizard > Test PING.")
        }

        let culpritItems = buildCulprits(
            memoryPressure: memoryPressure,
            thermalState: thermal,
            swapRapidIncrease: swapRapidIncrease,
            ioPressureLikely: ioPressureLikely,
            freeDiskBytes: freeDiskBytes,
            topCPUProcesses: scannedProcesses ?? topCPUProcesses,
            simTelemetry: telemetry
        )

        if let stutterEvent = detectStutterEvent(
            now: now,
            cpuTotalPercent: cpu.user + cpu.system,
            memoryPressure: memoryPressure,
            compressedBytes: compressedBytes,
            swapUsedBytes: swapUsedBytes,
            diskReadMBps: diskRate.readMBps,
            diskWriteMBps: diskRate.writeMBps,
            thermalState: thermal,
            telemetry: telemetry,
            udpStatus: udpStatus,
            rankedCulprits: culpritItems,
            topCPU: Array((scannedProcesses ?? topCPUProcesses).prefix(5)),
            topMemory: Array((scannedProcesses ?? topMemoryProcesses).prefix(5))
        ) {
            stutterBuffer.append(stutterEvent)
            if stutterBuffer.count > 120 {
                stutterBuffer.removeFirst(stutterBuffer.count - 120)
            }
        }

        Task { @MainActor in
            snapshot = PerformanceSnapshot(
                cpuUserPercent: cpu.user,
                cpuSystemPercent: cpu.system,
                memoryPressure: memoryPressure,
                memoryPressureTrend: pressureTrend,
                compressedMemoryBytes: compressedBytes,
                swapUsedBytes: swapUsedBytes,
                swapDelta5MinBytes: swapDelta5Min,
                diskReadMBps: diskRate.readMBps,
                diskWriteMBps: diskRate.writeMBps,
                freeDiskBytes: freeDiskBytes,
                ioPressureLikely: ioPressureLikely,
                thermalState: thermal,
                lastUpdated: now,
                xplaneTelemetry: telemetry,
                udpStatus: udpStatus,
                governorStatusLine: governorResult.statusLine
            )

            if let scannedProcesses {
                topCPUProcesses = Array(
                    scannedProcesses
                        .filter { $0.cpuPercent > 0.1 }
                        .sorted { $0.cpuPercent > $1.cpuPercent }
                        .prefix(5)
                )

                topMemoryProcesses = Array(
                    scannedProcesses
                        .sorted { $0.memoryBytes > $1.memoryBytes }
                        .prefix(5)
                )
            }

            isSimActive = simActive || demoMockModeEnabled
            warnings = warningItems
            culprits = culpritItems
            history = historyBuffer
            metricSamples = metricSampleBuffer
            stutterCauseSummaries = recentStutterCauseRanking(lastMinutes: 10)
            governorDecision = governorResult.decision
            governorCurrentTier = governorResult.currentTier
            governorCurrentTargetLOD = governorResult.currentTargetLOD
            governorSmoothedTargetLOD = governorResult.smoothedLOD
            governorActiveAGLFeet = governorResult.activeAGLFeet
            governorLastSentLOD = governorResult.lastSentLOD
            governorCommandStatus = governorResult.commandStatus
            governorPauseReason = governorResult.pauseReason
            governorAckState = governorResult.ackState
            governorLastCommandText = governorResult.lastCommand
            governorLastCommandDate = governorBridge.lastCommandAt
            governorLastACKText = governorResult.lastACK
            governorLastACKDate = governorResult.lastACKDate
            regulatorControlState = controlState
            regulatorFileBridgeStatus = fileBridgeStatus
            regulatorLODChanging = lodChanging
            regulatorProofState = proofState
            regulatorWhyNotChanging = proofState.reasons
            regulatorTierEvents = Array(regulatorTierEvents.suffix(10))
            regulatorTestActive = pendingRegulatorTest != nil
            regulatorTestCountdownSeconds = testCountdown
            stutterEvents = stutterBuffer

            alertFlags = AlertFlags(
                memoryPressureRed: memoryPressure == .red,
                thermalCritical: thermal == .serious || thermal == .critical,
                swapRisingFast: swapRapidIncrease
            )
        }

        previousSwapUsedBytes = swapUsedBytes
    }

    private func evaluateGovernor(
        telemetry: SimTelemetrySnapshot?,
        udpStatus: XPlaneUDPStatus,
        simActive: Bool,
        now: Date
    ) -> (
        decision: GovernorDecision?,
        statusLine: String,
        currentTier: GovernorTier?,
        currentTargetLOD: Double?,
        smoothedLOD: Double?,
        activeAGLFeet: Double?,
        lastSentLOD: Double?,
        commandStatus: String,
        ackState: GovernorAckState,
        lastCommand: String?,
        lastACK: String?,
        lastACKDate: Date?,
        pauseReason: String?,
        reasons: [String],
        rampInProgress: Bool
    ) {
        func pausedResult(reason: String, reasons: [String]) -> (
            decision: GovernorDecision?,
            statusLine: String,
            currentTier: GovernorTier?,
            currentTargetLOD: Double?,
            smoothedLOD: Double?,
            activeAGLFeet: Double?,
            lastSentLOD: Double?,
            commandStatus: String,
            ackState: GovernorAckState,
            lastCommand: String?,
            lastACK: String?,
            lastACKDate: Date?,
            pauseReason: String?,
            reasons: [String],
            rampInProgress: Bool
        ) {
            _ = governorBridge.sendDisable(host: governorConfig.commandHost, port: governorConfig.commandPort)
            governorBridge.setPausedState()
            governorPreviouslyEnabled = false
            resetGovernorRuntimeState()
            return (
                nil,
                "Regulator: \(reason)",
                nil,
                nil,
                nil,
                nil,
                governorBridge.lastSentLOD,
                GovernorAckState.paused.displayName,
                .paused,
                governorBridge.lastCommand,
                governorBridge.lastAckMessage,
                governorBridge.lastAckAt,
                reason,
                reasons,
                false
            )
        }

        guard governorConfig.enabled else {
            if governorPreviouslyEnabled {
                _ = governorBridge.sendDisable(host: governorConfig.commandHost, port: governorConfig.commandPort)
                governorPreviouslyEnabled = false
            }
            governorBridge.setDisabledState()
            resetGovernorRuntimeState()
            return (
                nil,
                "Regulator: Disabled",
                nil,
                nil,
                nil,
                nil,
                governorBridge.lastSentLOD,
                GovernorAckState.disabled.displayName,
                .disabled,
                governorBridge.lastCommand,
                governorBridge.lastAckMessage,
                governorBridge.lastAckAt,
                nil,
                [],
                false
            )
        }

        if let test = pendingRegulatorTest, now < test.endsAt {
            let remaining = max(Int(ceil(test.endsAt.timeIntervalSince(now))), 0)
            return (
                nil,
                "Regulator test active (\(test.modeLabel), \(remaining)s remaining)",
                governorLockedTier,
                governorSmoothedLODInternal,
                governorSmoothedLODInternal,
                governorActiveAGLFeet,
                governorBridge.lastSentLOD,
                governorBridge.commandStatusText(now: now),
                governorBridge.ackState,
                governorBridge.lastCommand,
                governorBridge.lastAckMessage,
                governorBridge.lastAckAt,
                nil,
                ["Timed test active; temporary override in progress."],
                false
            )
        }

        guard simActive else {
            return pausedResult(reason: "No sim data; regulator paused", reasons: ["No telemetry packets."])
        }

        guard udpStatus.state == .active else {
            return pausedResult(reason: "No sim data; regulator paused", reasons: ["No telemetry packets."])
        }

        guard let telemetry else {
            return pausedResult(reason: "No sim data; regulator paused", reasons: ["No telemetry packets."])
        }

        let resolved = GovernorPolicyEngine.resolveAGL(
            telemetry: telemetry,
            useMSLFallbackWhenAGLUnavailable: governorConfig.useMSLFallbackWhenAGLUnavailable
        )
        guard let aglFeet = resolved.feet else {
            var reasons = ["AGL unavailable; regulator paused."]
            if telemetry.altitudeMSLFeet != nil, !governorConfig.useMSLFallbackWhenAGLUnavailable {
                reasons.append("MSL fallback disabled.")
            }
            return pausedResult(reason: "AGL unavailable; regulator paused", reasons: reasons)
        }

        governorPreviouslyEnabled = true
        var reasons: [String] = []

        if resolved.source == .mslHeuristic {
            reasons.append("Waiting for AGL; using MSL fallback.")
        }

        let candidateTier = GovernorPolicyEngine.selectTier(
            aglFeet: aglFeet,
            groundMaxAGLFeet: governorConfig.clampedGroundMax,
            cruiseMinAGLFeet: governorConfig.clampedCruiseMin
        )

        if let lockedTier = governorLockedTier,
           let lockedSince = governorLockedTierSince,
           candidateTier != lockedTier {
            let holdElapsed = now.timeIntervalSince(lockedSince)
            if holdElapsed >= governorConfig.minimumTierHoldSeconds {
                governorLockedTier = candidateTier
                governorLockedTierSince = now
            } else {
                let holdRemaining = max(governorConfig.minimumTierHoldSeconds - holdElapsed, 0)
                reasons.append("Min time in tier not satisfied (\(Int(ceil(holdRemaining)))s remaining).")
            }
        } else if governorLockedTier == nil {
            governorLockedTier = candidateTier
            governorLockedTierSince = now
        }

        let effectiveTier = governorLockedTier ?? candidateTier
        let tierTarget = governorConfig.targetLOD(for: effectiveTier)
        governorCurrentTierTargetLODInternal = tierTarget

        if lastLoggedTier != effectiveTier {
            lastLoggedTier = effectiveTier
            logTierEvent(
                "Entered \(effectiveTier.rawValue) (AGL \(Int(aglFeet))ft) -> Target \(String(format: "%.2f", tierTarget))",
                at: now
            )
        }

        if governorSmoothedLODInternal == nil {
            governorSmoothedLODInternal = tierTarget
        } else if let previousLOD = governorSmoothedLODInternal {
            let deltaSeconds = max(now.timeIntervalSince(governorLastUpdateAt ?? now), 0)
            let smoothing = max(governorConfig.smoothingDurationSeconds, 0.1)
            let factor = min(deltaSeconds / smoothing, 1.0)
            let nextLOD = previousLOD + (tierTarget - previousLOD) * factor
            governorSmoothedLODInternal = governorConfig.clampLOD(nextLOD)
        }

        governorLastUpdateAt = now
        let smoothedLOD = governorConfig.clampLOD(governorSmoothedLODInternal ?? tierTarget)
        let rampInProgress = abs(smoothedLOD - tierTarget) > max(governorConfig.minimumCommandDelta, 0.01)

        let previousSentLOD = governorBridge.lastSentLOD
        let sendResult = governorBridge.send(
            lod: smoothedLOD,
            tier: effectiveTier,
            host: governorConfig.commandHost,
            port: governorConfig.commandPort,
            now: now,
            minimumInterval: governorConfig.minimumCommandIntervalSeconds,
            minimumDelta: governorConfig.minimumCommandDelta
        )

        if sendResult.sent {
            let sendDelta = abs(smoothedLOD - (previousSentLOD ?? smoothedLOD))
            logTierEvent(
                "Sent \(String(format: "%.3f", smoothedLOD)) (Δ \(String(format: "%.3f", sendDelta)))",
                at: now
            )
        } else if let skipReason = sendResult.skipReason {
            reasons.append(skipReason)
        }

        if sendResult.ackState == .noAck, !governorBridge.usingFileFallback {
            reasons.append("Bridge disconnected / no ACK recent.")
        }

        let thresholdsText = String(
            format: "GROUND < %.0fft, TRANSITION %.0f-%.0fft, CRUISE > %.0fft",
            governorConfig.clampedGroundMax,
            governorConfig.clampedGroundMax,
            governorConfig.clampedCruiseMin,
            governorConfig.clampedCruiseMin
        )

        let decision = GovernorDecision(
            tier: effectiveTier,
            resolvedAGLFeet: aglFeet,
            resolvedAltitudeSource: resolved.source,
            targetLOD: tierTarget,
            thresholdsText: thresholdsText
        )

        var statusLine = decision.statusLine + String(format: " | Ramp: %.2f", smoothedLOD)
        if resolved.source == .mslHeuristic {
            statusLine += " | AGL fallback: MSL heuristic"
        }
        if let bridgeError = sendResult.error {
            statusLine += " | Bridge: \(bridgeError)"
        }

        let orderedReasons = Array(NSOrderedSet(array: reasons)) as? [String] ?? reasons

        return (
            decision,
            statusLine,
            effectiveTier,
            tierTarget,
            smoothedLOD,
            aglFeet,
            governorBridge.lastSentLOD,
            sendResult.statusText,
            sendResult.ackState,
            governorBridge.lastCommand,
            governorBridge.lastAckMessage,
            governorBridge.lastAckAt,
            nil,
            orderedReasons,
            rampInProgress
        )
    }

    private func resetGovernorRuntimeState() {
        governorLockedTier = nil
        governorLockedTierSince = nil
        governorSmoothedLODInternal = nil
        governorCurrentTierTargetLODInternal = nil
        governorLastUpdateAt = nil
        lastLoggedTier = nil
    }

    private func deriveRegulatorControlState(now: Date, fileBridgeStatus: GovernorFileBridgeStatus?) -> RegulatorControlState {
        if governorBridge.usingFileFallback,
           let updateDate = fileBridgeStatus?.lastUpdateDate ?? governorBridge.lastFileBridgeWriteAt,
           now.timeIntervalSince(updateDate) < 20 {
            return .fileBridge(lastUpdate: updateDate)
        }

        if governorBridge.ackState == .ackOK,
           let lastAck = governorBridge.lastAckAt {
            return .udpAckOK(lastAck: lastAck, payload: governorBridge.lastAckMessage ?? "ACK")
        }

        if governorConfig.enabled || governorBridge.lastCommandAt != nil {
            if governorBridge.ackState == .disabled {
                return .disconnected
            }
            return .udpNoAck
        }

        return .disconnected
    }

    private func evaluateRegulatorLODChanging(now: Date, controlState: RegulatorControlState, fileBridgeStatus: GovernorFileBridgeStatus?) -> Bool {
        if let appliedLOD = governorBridge.lastAckAppliedLOD {
            if let previous = lastObservedAckAppliedLOD, abs(previous - appliedLOD) >= 0.01 {
                lastAckAppliedLODChangeAt = now
            }
            lastObservedAckAppliedLOD = appliedLOD
        }

        if let currentLOD = fileBridgeStatus?.currentLOD {
            if let previous = lastObservedFileStatusLOD, abs(previous - currentLOD) >= 0.01 {
                lastFileLODChangeAt = now
            }
            lastObservedFileStatusLOD = currentLOD
        }

        switch controlState {
        case .udpAckOK:
            guard let changedAt = lastAckAppliedLODChangeAt else { return false }
            return now.timeIntervalSince(changedAt) <= 20
        case .fileBridge(let updateDate):
            let changedRecently = lastFileLODChangeAt.map { now.timeIntervalSince($0) <= 20 } ?? false
            let updatedRecently = now.timeIntervalSince(updateDate) <= max(samplingIntervalSeconds * 4.0, 6.0)
            return changedRecently || updatedRecently
        case .udpNoAck, .disconnected:
            return false
        }
    }

    private func maybeLogBridgeEvents(now: Date, fileBridgeStatus: GovernorFileBridgeStatus?) {
        if let ackAt = governorBridge.lastAckAt,
           lastLoggedAckAt != ackAt {
            lastLoggedAckAt = ackAt

            if let applied = governorBridge.lastAckAppliedLOD {
                logTierEvent("ACK applied \(String(format: "%.2f", applied))", at: ackAt)
            } else if let payload = governorBridge.lastAckMessage {
                logTierEvent("ACK \(payload)", at: ackAt)
            }
        }

        if let updateAt = fileBridgeStatus?.lastUpdateDate,
           lastLoggedFileStatusUpdateAt != updateAt {
            lastLoggedFileStatusUpdateAt = updateAt

            if let current = fileBridgeStatus?.currentLOD {
                logTierEvent("File status current \(String(format: "%.2f", current))", at: updateAt)
            }
        }
    }

    private func buildRegulatorProofState(
        now: Date,
        simActive: Bool,
        controlState: RegulatorControlState,
        fileBridgeStatus: GovernorFileBridgeStatus?,
        governorResult: (
            decision: GovernorDecision?,
            statusLine: String,
            currentTier: GovernorTier?,
            currentTargetLOD: Double?,
            smoothedLOD: Double?,
            activeAGLFeet: Double?,
            lastSentLOD: Double?,
            commandStatus: String,
            ackState: GovernorAckState,
            lastCommand: String?,
            lastACK: String?,
            lastACKDate: Date?,
            pauseReason: String?,
            reasons: [String],
            rampInProgress: Bool
        )
    ) -> RegulatorProofState {
        let target = governorResult.currentTargetLOD ?? governorResult.smoothedLOD
        var applied: Double?
        var evidenceDate: Date?
        var evidenceLine: String?
        var evidenceFresh = false

        switch controlState {
        case .udpAckOK(let lastAck, let payload):
            applied = governorBridge.lastAckAppliedLOD ?? parseAppliedLOD(from: payload)
            evidenceDate = lastAck
            evidenceLine = payload
            evidenceFresh = applied != nil && now.timeIntervalSince(lastAck) <= 600

        case .fileBridge(let lastUpdate):
            applied = fileBridgeStatus?.currentLOD
            evidenceDate = fileBridgeStatus?.lastUpdateDate ?? fileBridgeStatus?.fileModifiedDate ?? lastUpdate
            let freshness = evidenceDate.map { now.timeIntervalSince($0) <= 5 } ?? false
            evidenceFresh = applied != nil && freshness
            evidenceLine = fileBridgeStatus?.rawText?.replacingOccurrences(of: "\n", with: " | ")
            if let rawEvidence = evidenceLine, rawEvidence.count > 140 {
                evidenceLine = String(rawEvidence.prefix(140)) + "..."
            }

        case .udpNoAck, .disconnected:
            evidenceFresh = false
        }

        let delta = (target != nil && applied != nil) ? abs((target ?? 0) - (applied ?? 0)) : nil
        let onTarget = (delta ?? .greatestFiniteMagnitude) <= 0.05
        let recentBySend = governorBridge.lastSentAt.map { now.timeIntervalSince($0) <= 20 } ?? false
        let recentActivity = evaluateRegulatorLODChanging(now: now, controlState: controlState, fileBridgeStatus: fileBridgeStatus)
            || governorResult.rampInProgress
            || recentBySend

        if simActive {
            if let target {
                lastSessionTargetLOD = target
                lastSessionAt = now
            }
            if let applied {
                lastSessionAppliedLOD = applied
                lastSessionAt = now
            }
        }

        var reasons = governorResult.reasons

        if !recentActivity {
            reasons.append("Stable target; no recent writes needed.")
        }

        if !evidenceFresh {
            switch controlState {
            case .udpNoAck:
                reasons.append("Bridge disconnected / no ACK recent.")
            case .fileBridge:
                reasons.append("No fresh file-bridge status evidence.")
            case .disconnected:
                reasons.append("Bridge disconnected.")
            case .udpAckOK:
                reasons.append("ACK evidence is stale.")
            }
        }

        if let delta, evidenceFresh, !onTarget {
            reasons.append("Off target (Δ \(String(format: "%.3f", delta))).")
        }

        if !simActive {
            reasons.append("No sim data.")
        }

        let orderedReasons = Array(NSOrderedSet(array: reasons)) as? [String] ?? reasons

        return RegulatorProofState(
            bridgeModeLabel: controlState.modeLabel,
            lodApplied: evidenceFresh,
            recentActivity: recentActivity,
            onTarget: onTarget,
            targetLOD: target,
            appliedLOD: applied,
            deltaToTarget: delta,
            lastSentAt: governorBridge.lastSentAt,
            lastEvidenceAt: evidenceDate,
            evidenceLine: evidenceLine,
            reasons: orderedReasons,
            hasSimData: simActive,
            lastSessionTargetLOD: lastSessionTargetLOD,
            lastSessionAppliedLOD: lastSessionAppliedLOD,
            lastSessionAt: lastSessionAt
        )
    }

    private func parseAppliedLOD(from payload: String) -> Double? {
        let trimmed = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.uppercased().hasPrefix("ACK SET_LOD") else { return nil }
        return trimmed.split(separator: " ").last.flatMap { Double($0) }
    }

    private func maybeCompleteRegulatorTestIfNeeded(now: Date) {
        guard let test = pendingRegulatorTest, now >= test.endsAt else { return }

        let liveRestoreTarget = governorConfig.enabled
            ? (governorCurrentTierTargetLODInternal ?? governorSmoothedLODInternal ?? test.fallbackRestoreLOD)
            : test.fallbackRestoreLOD
        let clampedRestore = governorConfig.clampLOD(liveRestoreTarget)

        let restoreResult = governorBridge.sendTestLOD(
            lod: clampedRestore,
            host: governorConfig.commandHost,
            port: governorConfig.commandPort,
            now: now
        )

        pendingRegulatorTest = nil

        if restoreResult.sent {
            logRegulatorAction("Test complete. Restored LOD to \(String(format: "%.2f", clampedRestore)).", at: now)
            logTierEvent("Test restore -> \(String(format: "%.2f", clampedRestore))", at: now)
        } else {
            logRegulatorAction("Test restore failed: \(restoreResult.error ?? "Unknown error").", at: now)
        }
    }

    private func logRegulatorAction(_ message: String, at date: Date = Date()) {
        Task { @MainActor in
            var lines = self.regulatorRecentActions
            lines.append(RegulatorActionLog(timestamp: date, message: message))
            if lines.count > 40 {
                lines.removeFirst(lines.count - 40)
            }
            self.regulatorRecentActions = lines
        }
    }

    private func logTierEvent(_ message: String, at date: Date = Date()) {
        Task { @MainActor in
            var events = self.regulatorTierEvents
            events.append(RegulatorActionLog(timestamp: date, message: message))
            if events.count > 80 {
                events.removeFirst(events.count - 80)
            }
            self.regulatorTierEvents = events
        }
    }

    @MainActor
    func proposedRegulatorTestLOD(increase: Bool, step: Double) -> Double {
        let base = governorBridge.lastAckAppliedLOD
            ?? regulatorFileBridgeStatus?.currentLOD
            ?? governorCurrentTierTargetLODInternal
            ?? governorCurrentTargetLOD
            ?? governorSmoothedTargetLOD
            ?? 1.0

        let normalizedStep = max(step, 0)
        let raw = increase ? base + normalizedStep : base - normalizedStep
        return governorConfig.clampLOD(raw)
    }

    @MainActor
    func runRegulatorRelativeTimedTest(increase: Bool, step: Double, modeLabel: String, durationSeconds: TimeInterval = 10.0) -> ActionOutcome {
        let testLOD = proposedRegulatorTestLOD(increase: increase, step: step)
        return runRegulatorTimedTest(lodValue: testLOD, modeLabel: modeLabel, durationSeconds: durationSeconds)
    }

    @MainActor
    func runRegulatorTimedTest(lodValue: Double, modeLabel: String, durationSeconds: TimeInterval = 10.0) -> ActionOutcome {
        if pendingRegulatorTest != nil {
            return ActionOutcome(success: false, message: "A regulator test is already running.")
        }

        let clampedLOD = governorConfig.clampLOD(lodValue)
        let host = governorConfig.commandHost
        let port = governorConfig.commandPort
        let now = Date()
        let fallbackRestoreLOD = governorConfig.enabled ? (governorCurrentTierTargetLODInternal ?? governorSmoothedLODInternal ?? governorCurrentTargetLOD ?? 1.0) : 1.0

        let result = queue.sync {
            governorBridge.sendTestLOD(lod: clampedLOD, host: host, port: port, now: now)
        }

        governorLastSentLOD = clampedLOD
        governorCommandStatus = result.statusText
        governorAckState = result.ackState
        governorLastCommandText = governorBridge.lastCommand
        governorLastCommandDate = governorBridge.lastCommandAt
        governorLastACKText = governorBridge.lastAckMessage
        governorLastACKDate = governorBridge.lastAckAt

        guard result.sent else {
            let detail = result.error ?? "Unknown send failure."
            logRegulatorAction("Test start failed: \(detail)", at: now)
            return ActionOutcome(success: false, message: "Test command failed: \(detail)")
        }

        pendingRegulatorTest = RegulatorTestSession(
            startedAt: now,
            endsAt: now.addingTimeInterval(max(durationSeconds, 1.0)),
            fallbackRestoreLOD: fallbackRestoreLOD,
            modeLabel: modeLabel
        )

        let displayLOD = String(format: "%.2f", clampedLOD)
        let restoreDisplay = String(format: "%.2f", governorConfig.clampLOD(fallbackRestoreLOD))
        logRegulatorAction("Test started (\(modeLabel)): LOD \(displayLOD) for \(Int(durationSeconds))s. Auto-restore live target (fallback \(restoreDisplay)).", at: now)
        logTierEvent("Test \(modeLabel) -> \(displayLOD) for \(Int(durationSeconds))s", at: now)

        regulatorTestActive = true
        regulatorTestCountdownSeconds = Int(durationSeconds)

        return ActionOutcome(success: true, message: "Test running for \(Int(durationSeconds))s: \(modeLabel), LOD \(displayLOD).")
    }

    @MainActor
    func sendGovernorTestCommand(lodValue: Double) -> ActionOutcome {
        let clampedLOD = governorConfig.clampLOD(lodValue)
        let host = governorConfig.commandHost
        let port = governorConfig.commandPort
        let now = Date()

        let result = queue.sync {
            governorBridge.sendTestLOD(lod: clampedLOD, host: host, port: port, now: now)
        }

        governorLastSentLOD = clampedLOD
        governorCommandStatus = result.statusText
        governorAckState = result.ackState
        governorLastCommandText = governorBridge.lastCommand
        governorLastCommandDate = governorBridge.lastCommandAt
        governorLastACKText = governorBridge.lastAckMessage
        governorLastACKDate = governorBridge.lastAckAt

        if result.sent {
            logRegulatorAction("Manual test command sent: SET_LOD \(String(format: "%.2f", clampedLOD)).", at: now)
            return ActionOutcome(success: true, message: "Manual test command sent: SET_LOD \(String(format: "%.2f", clampedLOD)) to \(host):\(port).")
        }

        let detail = result.error ?? "Unknown send failure."
        logRegulatorAction("Manual test failed: \(detail)", at: now)
        return ActionOutcome(success: false, message: "Test command failed: \(detail)")
    }

    @MainActor
    func sendGovernorPing() -> ActionOutcome {
        let host = governorConfig.commandHost
        let port = governorConfig.commandPort
        let now = Date()

        let result = queue.sync {
            governorBridge.sendPing(host: host, port: port, now: now)
        }

        governorCommandStatus = result.statusText
        governorAckState = result.ackState
        governorLastCommandText = governorBridge.lastCommand
        governorLastCommandDate = governorBridge.lastCommandAt
        governorLastACKText = governorBridge.lastAckMessage
        governorLastACKDate = governorBridge.lastAckAt

        if result.sent {
            if result.ackState == .ackOK {
                return ActionOutcome(success: true, message: "PING succeeded. Received \(result.ackMessage ?? "ACK").")
            }

            if governorBridge.usingFileFallback {
                return ActionOutcome(success: true, message: "PING sent via file bridge. ACK is not expected in file mode.")
            }

            return ActionOutcome(success: false, message: "PING sent but no ACK/PONG received.")
        }

        return ActionOutcome(success: false, message: result.error ?? "PING failed.")
    }

    @MainActor
    func openRegulatorBridgeFolderInFinder() -> ActionOutcome {
        let folderURL = queue.sync { governorBridge.ensureBridgeFolderExists() }
        let opened = NSWorkspace.shared.open(folderURL)

        if opened {
            return ActionOutcome(success: true, message: "Opened bridge folder: \(folderURL.path)")
        }

        return ActionOutcome(success: false, message: "Unable to open bridge folder: \(folderURL.path)")
    }

    private func isXPlaneProcessRunning(processes: [ProcessSample]?) -> Bool {
        if let processes,
           processes.contains(where: { $0.name.localizedCaseInsensitiveContains("X-Plane") }) {
            return true
        }

        return NSWorkspace.shared.runningApplications.contains { app in
            let name = app.localizedName ?? ""
            return name.localizedCaseInsensitiveContains("X-Plane")
        }
    }

    private func readCPU() -> (user: Double, system: Double) {
        guard let ticks = SystemMetricsReader.readHostCPUTicks() else {
            return (smoothedUserCPU, smoothedSystemCPU)
        }

        defer {
            previousCPUTicks = ticks
        }

        guard let previous = previousCPUTicks else {
            return (smoothedUserCPU, smoothedSystemCPU)
        }

        let userDelta = Double(ticks.cpu_ticks.0 - previous.cpu_ticks.0)
        let systemDelta = Double(ticks.cpu_ticks.1 - previous.cpu_ticks.1)
        let idleDelta = Double(ticks.cpu_ticks.2 - previous.cpu_ticks.2)
        let niceDelta = Double(ticks.cpu_ticks.3 - previous.cpu_ticks.3)

        let total = max(userDelta + systemDelta + idleDelta + niceDelta, 1)
        let instantUser = (userDelta / total) * 100.0
        let instantSystem = ((systemDelta + niceDelta) / total) * 100.0

        smoothedUserCPU = smoothingAlpha * instantUser + (1.0 - smoothingAlpha) * smoothedUserCPU
        smoothedSystemCPU = smoothingAlpha * instantSystem + (1.0 - smoothingAlpha) * smoothedSystemCPU

        return (smoothedUserCPU, smoothedSystemCPU)
    }

    private func inferMemoryPressure(memorySnapshot: MemorySnapshot?, swapUsedBytes: UInt64) -> MemoryPressureLevel {
        guard let memorySnapshot else {
            return .yellow
        }

        let physicalBytes = Double(ProcessInfo.processInfo.physicalMemory)
        let freeRatio = Double(memorySnapshot.freeBytes) / max(physicalBytes, 1)
        let swapGB = Double(swapUsedBytes) / 1_073_741_824.0

        if freeRatio < 0.05 || swapGB > 2.0 {
            return .red
        }
        if freeRatio < 0.12 || swapGB > 0.75 {
            return .yellow
        }
        return .green
    }

    private func inferMemoryTrend() -> MemoryPressureTrend {
        let relevant = historyBuffer.suffix(12)
        guard relevant.count >= 6 else { return .stable }

        let scores = relevant.map { Double($0.memoryPressure.score) }
        let midpoint = scores.count / 2
        let olderAvg = scores[..<midpoint].reduce(0, +) / Double(max(midpoint, 1))
        let newerAvg = scores[midpoint...].reduce(0, +) / Double(max(scores.count - midpoint, 1))

        if newerAvg - olderAvg > 0.25 {
            return .rising
        }
        if olderAvg - newerAvg > 0.25 {
            return .falling
        }
        return .stable
    }

    private func computeSwapDelta(windowSeconds: TimeInterval, now: Date) -> Int64 {
        guard let reference = historyBuffer.last(where: { now.timeIntervalSince($0.timestamp) >= windowSeconds }) else {
            return 0
        }
        guard let current = historyBuffer.last else {
            return 0
        }
        return Int64(current.swapUsedBytes) - Int64(reference.swapUsedBytes)
    }

    private func computeDiskRates(current: DiskIOSnapshot?, now: Date) -> (readMBps: Double, writeMBps: Double) {
        guard let current,
              let previous = previousDiskIO,
              let previousTime = previousDiskSampleDate else {
            previousDiskIO = current
            previousDiskSampleDate = now
            return (0, 0)
        }

        let elapsed = max(now.timeIntervalSince(previousTime), 0.001)
        let readDelta = current.bytesRead >= previous.bytesRead ? current.bytesRead - previous.bytesRead : 0
        let writeDelta = current.bytesWritten >= previous.bytesWritten ? current.bytesWritten - previous.bytesWritten : 0

        previousDiskIO = current
        previousDiskSampleDate = now

        return (
            readMBps: Double(readDelta) / elapsed / 1_048_576.0,
            writeMBps: Double(writeDelta) / elapsed / 1_048_576.0
        )
    }

    private func pressureIndexScore(
        cpuTotal: Double,
        memoryPressure: MemoryPressureLevel,
        swapDelta5Min: Int64,
        diskReadMBps: Double,
        diskWriteMBps: Double,
        thermalState: ProcessInfo.ThermalState
    ) -> Double {
        let memoryScore: Double
        switch memoryPressure {
        case .green:
            memoryScore = 0.15
        case .yellow:
            memoryScore = 0.55
        case .red:
            memoryScore = 0.9
        }

        let swapScore = min(max(Double(abs(swapDelta5Min)) / Double(512 * 1_024 * 1_024), 0), 1)
        let diskScore = min((diskReadMBps + diskWriteMBps) / 220.0, 1)
        let cpuScore = min(cpuTotal / 100.0, 1)

        let thermalScore: Double
        switch thermalState {
        case .nominal:
            thermalScore = 0.1
        case .fair:
            thermalScore = 0.35
        case .serious:
            thermalScore = 0.75
        case .critical:
            thermalScore = 1.0
        @unknown default:
            thermalScore = 0.5
        }

        let weighted = (memoryScore * 0.35) + (swapScore * 0.2) + (diskScore * 0.15) + (cpuScore * 0.2) + (thermalScore * 0.1)
        return min(max(weighted, 0), 1)
    }

    private func trimHistory(reference: Date) {
        let cutoff = reference.addingTimeInterval(-1800)
        if let firstValidIndex = historyBuffer.firstIndex(where: { $0.timestamp >= cutoff }) {
            if firstValidIndex > 0 {
                historyBuffer.removeFirst(firstValidIndex)
            }
        } else {
            historyBuffer.removeAll(keepingCapacity: true)
        }

        if let firstSampleIndex = metricSampleBuffer.firstIndex(where: { $0.timestamp >= cutoff }) {
            if firstSampleIndex > 0 {
                metricSampleBuffer.removeFirst(firstSampleIndex)
            }
        } else {
            metricSampleBuffer.removeAll(keepingCapacity: true)
        }
    }

    private func appendDemoMetricSample(now: Date) {
        let phase = Double(sampleCount % 240) / 240.0
        let cpu = 35.0 + (sin(phase * .pi * 2.0) * 18.0)
        let diskBase = 8.0 + (cos(phase * .pi * 4.0) * 5.0)
        let swapDelta = Int64((sin(phase * .pi * 3.0) + 1.0) * 80_000_000)

        let pressure: MemoryPressureLevel
        if phase > 0.68 && phase < 0.82 {
            pressure = .red
        } else if phase > 0.4 {
            pressure = .yellow
        } else {
            pressure = .green
        }

        let demoSample = MetricSample(
            timestamp: now,
            cpuTotal: max(min(cpu, 95), 10),
            memPressure: pressure,
            swapUsed: UInt64(1_000_000_000 + max(swapDelta, 0)),
            swapDelta: swapDelta,
            diskRead: max(diskBase, 0.2),
            diskWrite: max(diskBase * 0.7, 0.2),
            thermalRawValue: pressure == .red ? ProcessInfo.ThermalState.serious.rawValue : ProcessInfo.ThermalState.fair.rawValue,
            pressureIndex: pressure == .red ? 0.9 : (pressure == .yellow ? 0.62 : 0.28),
            topProcessImpacts: [
                ProcessImpact(pid: 991, name: "Mock Browser", cpu: 22.0, residentBytes: 1_800_000_000, impactScore: 22 * 1.7 + 1.8 * 9),
                ProcessImpact(pid: 992, name: "Mock Recorder", cpu: 15.0, residentBytes: 900_000_000, impactScore: 15 * 1.7 + 0.9 * 9)
            ]
        )

        metricSampleBuffer.append(demoSample)

        if sampleCount % 12 == 0 {
            let mock = StutterEvent(
                timestamp: now,
                reason: "Mock burst",
                rankedCulprits: ["Synthetic swap burst", "Synthetic disk spike", "Synthetic CPU pressure"],
                memoryPressure: demoSample.memPressure,
                swapUsedBytes: demoSample.swapUsed,
                compressedMemoryBytes: 1_024 * 1_024 * 1_024,
                diskReadMBps: demoSample.diskRead,
                diskWriteMBps: demoSample.diskWrite,
                thermalStateRaw: thermalStateDescription(ProcessInfo.ThermalState(rawValue: demoSample.thermalRawValue) ?? .fair),
                telemetryPacketsPerSecond: 8,
                telemetryFreshnessSeconds: 0.2,
                topCPUProcesses: [
                    ProcessSample(pid: 991, name: "Mock Browser", bundleIdentifier: nil, cpuPercent: 22, memoryBytes: 1_800_000_000, sampledAt: now)
                ],
                topMemoryProcesses: [
                    ProcessSample(pid: 992, name: "Mock Recorder", bundleIdentifier: nil, cpuPercent: 15, memoryBytes: 900_000_000, sampledAt: now)
                ],
                severity: 0.72,
                classification: .swapThrash,
                confidence: 0.81,
                evidencePoints: ["demoMode=true", "syntheticSwapBurst=true", "syntheticDiskSpike=true"],
                windowRef: "demo-\(Int(now.timeIntervalSince1970))"
            )
            stutterBuffer.append(mock)
            if stutterBuffer.count > 120 {
                stutterBuffer.removeFirst(stutterBuffer.count - 120)
            }
        }
    }

    @MainActor
    func injectMockStutterEvent() {
        demoMockModeEnabled = true
        appendDemoMetricSample(now: Date())
        stutterEvents = stutterBuffer
        metricSamples = metricSampleBuffer
        stutterCauseSummaries = recentStutterCauseRanking(lastMinutes: 10)
    }

    private func buildWarnings(
        memoryPressure: MemoryPressureLevel,
        thermalState: ProcessInfo.ThermalState,
        swapRapidIncrease: Bool,
        ioPressureLikely: Bool,
        freeDiskBytes: UInt64,
        topCPUProcesses: [ProcessSample],
        simActive: Bool,
        udpStatus: XPlaneUDPStatus
    ) -> [String] {
        var items: [String] = []

        if memoryPressure == .red {
            items.append("Memory pressure is HIGH (red). Expect stutters unless memory load is reduced.")
        }

        if thermalState == .serious || thermalState == .critical {
            items.append("Thermal state is \(thermalStateDescription(thermalState)). Reduce graphics load or frame cap.")
        }

        if swapRapidIncrease {
            items.append("Swap usage is climbing rapidly. Paging is likely causing hitching.")
        }

        if ioPressureLikely {
            items.append("I/O pressure likely (high disk throughput + rising swap + red memory pressure).")
        }

        if udpStatus.state == .listening && udpStatus.totalPackets == 0 {
            items.append("No UDP packets received. Confirm Data Output IP/port match.")
        }

        if udpStatus.state == .misconfig {
            items.append(udpStatus.detail ?? "UDP packets look misconfigured.")
        }

        let lowDiskThreshold: UInt64 = 20 * 1_073_741_824
        if freeDiskBytes > 0 && freeDiskBytes < lowDiskThreshold {
            items.append("Low disk free space (\(ByteCountFormatter.string(fromByteCount: Int64(freeDiskBytes), countStyle: .file))).")
        }

        if let hog = topCPUProcesses.first(where: { process in
            process.cpuPercent > 50 &&
            !process.name.localizedCaseInsensitiveContains("X-Plane") &&
            !process.name.localizedCaseInsensitiveContains("Speed")
        }) {
            items.append("Background CPU hog: \(hog.name) at \(String(format: "%.1f", hog.cpuPercent))%.")
        }

        if simActive && items.isEmpty {
            items.append("Sim is active and no immediate pressure signals are detected.")
        }

        return items
    }

    private func buildCulprits(
        memoryPressure: MemoryPressureLevel,
        thermalState: ProcessInfo.ThermalState,
        swapRapidIncrease: Bool,
        ioPressureLikely: Bool,
        freeDiskBytes: UInt64,
        topCPUProcesses: [ProcessSample],
        simTelemetry: SimTelemetrySnapshot?
    ) -> [String] {
        var ranked: [String] = []

        if memoryPressure == .red && swapRapidIncrease {
            ranked.append("Memory pressure red + fast swap growth is likely the top stutter source.")
        }

        if thermalState == .serious || thermalState == .critical {
            ranked.append("Thermal throttling risk is high (\(thermalStateDescription(thermalState))).")
        }

        if ioPressureLikely {
            ranked.append("Storage I/O pressure is likely contributing to frame-time spikes.")
        }

        if let hog = topCPUProcesses.first(where: { $0.cpuPercent > 45 && !$0.name.localizedCaseInsensitiveContains("X-Plane") }) {
            ranked.append("\(hog.name) is consuming \(String(format: "%.1f", hog.cpuPercent))% CPU in the background.")
        }

        let lowDiskThreshold: UInt64 = 20 * 1_073_741_824
        if freeDiskBytes > 0 && freeDiskBytes < lowDiskThreshold {
            ranked.append("Low free disk space can worsen paging and asset streaming latency.")
        }

        if let fps = simTelemetry?.fps, fps < 30 {
            ranked.append("Sim FPS is currently low (\(String(format: "%.1f", fps))).")
        }

        if ranked.isEmpty {
            ranked.append("No dominant bottleneck detected from current telemetry.")
        }

        return Array(ranked.prefix(3))
    }

    private func detectStutterEvent(
        now: Date,
        cpuTotalPercent: Double,
        memoryPressure: MemoryPressureLevel,
        compressedBytes: UInt64,
        swapUsedBytes: UInt64,
        diskReadMBps: Double,
        diskWriteMBps: Double,
        thermalState: ProcessInfo.ThermalState,
        telemetry: SimTelemetrySnapshot?,
        udpStatus: XPlaneUDPStatus,
        rankedCulprits: [String],
        topCPU: [ProcessSample],
        topMemory: [ProcessSample]
    ) -> StutterEvent? {
        var triggerReasons: [String] = []
        var evidencePoints: [String] = []

        if let frameTime = telemetry?.frameTimeMS,
           frameTime >= stutterHeuristics.frameTimeSpikeMS {
            triggerReasons.append("Frame-time spike")
            evidencePoints.append(String(format: "frameTimeMS=%.2f", frameTime))
        }

        if let fps = telemetry?.fps,
           let previousFPS,
           fps <= max(15, previousFPS - stutterHeuristics.fpsDropThreshold) {
            triggerReasons.append("FPS drop")
            evidencePoints.append(String(format: "fps=%.2f prev=%.2f", fps, previousFPS))
        }

        if let previousCPU = previousCPUTotalPercent,
           cpuTotalPercent - previousCPU >= stutterHeuristics.cpuSpikePercent {
            triggerReasons.append("CPU spike")
            evidencePoints.append(String(format: "cpuDelta=%.2f", cpuTotalPercent - previousCPU))
        }

        if diskReadMBps + diskWriteMBps >= stutterHeuristics.diskSpikeMBps {
            triggerReasons.append("Disk I/O spike")
            evidencePoints.append(String(format: "diskMBps=%.2f", diskReadMBps + diskWriteMBps))
        }

        let swapJump = computeSwapDelta(windowSeconds: 90, now: now)
        if swapJump >= Int64(stutterHeuristics.swapJumpBytes) {
            triggerReasons.append("Swap jump")
            evidencePoints.append("swapJump=\(swapJump)")
        }

        if previousThermalState.rawValue < thermalState.rawValue,
           thermalState == .serious || thermalState == .critical {
            triggerReasons.append("Thermal escalation")
            evidencePoints.append("thermal=\(thermalStateDescription(thermalState))")
        }

        if memoryPressure == .red {
            triggerReasons.append("Memory pressure red")
            evidencePoints.append("memPressure=red")
        }

        previousCPUTotalPercent = cpuTotalPercent
        previousFrameTimeMS = telemetry?.frameTimeMS
        previousFPS = telemetry?.fps
        previousThermalState = thermalState

        guard !triggerReasons.isEmpty else {
            return nil
        }

        let freshness: Double
        if let last = udpStatus.lastValidPacketDate {
            freshness = max(now.timeIntervalSince(last), 0)
        } else {
            freshness = .infinity
        }

        let hasSimGpuFrameTime = telemetry?.gpuFrameTimeMS != nil

        var classification: StutterCause
        if swapJump >= Int64(stutterHeuristics.swapJumpBytes) || memoryPressure == .red {
            classification = .swapThrash
        } else if diskReadMBps + diskWriteMBps >= stutterHeuristics.diskSpikeMBps {
            classification = .diskStall
        } else if thermalState == .serious || thermalState == .critical {
            classification = .thermalThrottle
        } else if cpuTotalPercent >= 85 {
            classification = .cpuSaturation
        } else if telemetry?.fps ?? 60 < 28 {
            classification = hasSimGpuFrameTime ? .gpuBoundHeuristic : .unknown
            if !hasSimGpuFrameTime {
                evidencePoints.append("gpuTelemetry=unavailable")
            }
        } else {
            classification = .unknown
        }

        let severity = min(max(
            (Double(triggerReasons.count) / 6.0) +
            (memoryPressure == .red ? 0.2 : 0) +
            ((thermalState == .serious || thermalState == .critical) ? 0.2 : 0),
            0
        ), 1)
        var confidence = min(max(0.35 + (Double(evidencePoints.count) * 0.12), 0), 1)
        if classification == .unknown, evidencePoints.contains("gpuTelemetry=unavailable") {
            confidence = min(confidence, 0.45)
        }

        return StutterEvent(
            timestamp: now,
            reason: triggerReasons.joined(separator: ", "),
            rankedCulprits: rankedCulprits,
            memoryPressure: memoryPressure,
            swapUsedBytes: swapUsedBytes,
            compressedMemoryBytes: compressedBytes,
            diskReadMBps: diskReadMBps,
            diskWriteMBps: diskWriteMBps,
            thermalStateRaw: thermalStateDescription(thermalState),
            telemetryPacketsPerSecond: udpStatus.packetsPerSecond,
            telemetryFreshnessSeconds: freshness,
            topCPUProcesses: topCPU,
            topMemoryProcesses: topMemory,
            severity: severity,
            classification: classification,
            confidence: confidence,
            evidencePoints: evidencePoints,
            windowRef: "\(Int(now.timeIntervalSince1970))"
        )
    }

    @MainActor
    func memoryReliefSuggestions(maxCount: Int = 3) -> [ProcessSample] {
        let shouldSuggest = snapshot.memoryPressure == .yellow || snapshot.memoryPressure == .red || snapshot.swapDelta5MinBytes > Int64(128 * 1_024 * 1_024)
        guard shouldSuggest else { return [] }

        return Array(
            topMemoryProcesses
                .filter { !$0.name.localizedCaseInsensitiveContains("X-Plane") && !$0.name.localizedCaseInsensitiveContains("CruiseControl") }
                .prefix(max(maxCount, 1))
        )
    }

    @MainActor
    func historyPoints(for duration: HistoryDurationOption) -> [MetricHistoryPoint] {
        let cutoff = Date().addingTimeInterval(-duration.seconds)
        return history.filter { $0.timestamp >= cutoff }
    }

    @MainActor
    func metricSamplesInWindow(lastMinutes minutes: Int) -> [MetricSample] {
        let clamped = max(minutes, 1)
        let cutoff = Date().addingTimeInterval(-Double(clamped) * 60.0)
        return metricSamples.filter { $0.timestamp >= cutoff }
    }

    @MainActor
    func recentStutterCauseRanking(lastMinutes minutes: Int = 10) -> [StutterCauseSummary] {
        let cutoff = Date().addingTimeInterval(-Double(max(minutes, 1)) * 60.0)
        let relevant = stutterEvents.filter { $0.timestamp >= cutoff }
        guard !relevant.isEmpty else { return [] }

        let grouped = Dictionary(grouping: relevant, by: { $0.classification })
        return grouped
            .map { cause, events in
                StutterCauseSummary(
                    cause: cause,
                    count: events.count,
                    averageConfidence: events.reduce(0) { $0 + $1.confidence } / Double(max(events.count, 1))
                )
            }
            .sorted {
                if $0.count == $1.count {
                    return $0.averageConfidence > $1.averageConfidence
                }
                return $0.count > $1.count
            }
    }

    @MainActor
    func recordActionReceipt(
        kind: ActionKind,
        params: [String: String],
        outcome: ActionOutcome,
        before: MetricSample?,
        after: MetricSample?
    ) {
        let receipt = ActionReceipt(
            timestamp: Date(),
            profile: workloadProfile,
            kind: kind,
            params: params,
            before: before,
            after: after,
            outcome: outcome.success,
            message: outcome.message
        )

        actionReceiptBuffer.append(receipt)
        if actionReceiptBuffer.count > 120 {
            actionReceiptBuffer.removeFirst(actionReceiptBuffer.count - 120)
        }
        actionReceipts = actionReceiptBuffer
    }

    static func thermalStateDescription(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal:
            return "Nominal"
        case .fair:
            return "Fair"
        case .serious:
            return "Serious"
        case .critical:
            return "Critical"
        @unknown default:
            return "Unknown"
        }
    }

    private func thermalStateDescription(_ state: ProcessInfo.ThermalState) -> String {
        Self.thermalStateDescription(state)
    }
}
