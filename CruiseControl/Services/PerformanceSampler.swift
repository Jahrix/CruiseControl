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
    @Published private(set) var telemetryLiveState: TelemetryLiveState = .offline
    @Published private(set) var lastSessionSnapshot: SessionSnapshot?
    @Published private(set) var regulatorTierEvents: [RegulatorActionLog] = []
    @Published private(set) var regulatorRecentActions: [RegulatorActionLog] = []
    @Published private(set) var regulatorTestActive: Bool = false
    @Published private(set) var regulatorTestCountdownSeconds: Int = 0
    @Published private(set) var stutterEvents: [StutterEvent] = []
    @Published private(set) var stutterEpisodes: [StutterEpisode] = []
    @Published private(set) var metricSamples: [MetricSample] = []
    @Published private(set) var actionReceipts: [ActionReceipt] = []
    @Published private(set) var workloadProfile: ProfileKind = .generalPerformance
    @Published private(set) var stutterCauseSummaries: [StutterCauseSummary] = []
    @Published private(set) var sessionReport: SessionReport?
    @Published private(set) var configuredRetentionSeconds: TimeInterval = HistoryDurationOption.tenMinutes.seconds
    @Published private(set) var cpuBudgetModeEnabled: Bool = false
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

    private var requestedSamplingIntervalSeconds: TimeInterval = 1.0
    private var samplingIntervalSeconds: TimeInterval = 1.0
    private var smoothingAlpha: Double = 0.35
    private var profileMode: ProfileKind = .generalPerformance
    private var dataRetentionSeconds: TimeInterval = HistoryDurationOption.tenMinutes.seconds
    private var cpuBudgetModeEnabledInternal: Bool = false
    private var latestSampleDate: Date?
    private var latestPublishedAlertFlags = AlertFlags(memoryPressureRed: false, thermalCritical: false, swapRisingFast: false)
    private var latestPublishedLiveState: TelemetryLiveState = .offline
    private var lastBuiltSessionReport: SessionReport?
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
    private var previousTelemetryState: TelemetryLiveState = .offline

    private struct ActiveTelemetrySession {
        var sessionStartAt: Date
        var packetBaseline: UInt64
        var lastLiveSnapshot: SessionSnapshot?
        var ackOkCount: Int
        var ackTimeoutCount: Int
        var previousAckWasHealthy: Bool?
    }

    private var currentTelemetrySession: ActiveTelemetrySession?
    private var lastSessionSnapshotState: SessionSnapshot?

    private var stutterHeuristics: StutterHeuristicConfig = .default
    private var stutterBuffer: [StutterEvent] = []
    private var finalizedStutterEpisodes: [StutterEpisode] = []
    private var stutterEpisodeBuffer: [StutterEpisode] = []
    private var stutterLastEmissionAt: [StutterCause: Date] = [:]
    private let stutterEpisodeContinuationSeconds: TimeInterval = 8.0
    private let minimumStutterEpisodeDurationSeconds: TimeInterval = 0.3
    private let stutterCooldownsByCause: [StutterCause: TimeInterval] = [
        .swapThrash: 5.0,
        .diskStall: 2.0,
        .cpuSaturation: 1.5,
        .thermalThrottle: 4.0,
        .gpuBoundHeuristic: 1.5,
        .unknown: 1.0
    ]
    private var previousFrameTimeMS: Double?
    private var previousFPS: Double?
    private var previousCPUTotalPercent: Double?
    private var previousThermalState: ProcessInfo.ThermalState = .nominal

    private struct StutterEpisodeAccumulator {
        var id: UUID
        var cause: StutterCause
        var startAt: Date
        var endAt: Date
        var count: Int
        var peakSeverity: Double
        var confidenceSum: Double
        var evidenceCounts: [String: Int]

        mutating func absorb(event: StutterEvent, at time: Date) {
            endAt = time
            count += 1
            peakSeverity = max(peakSeverity, event.severity)
            confidenceSum += event.confidence
            for evidence in event.evidencePoints where !evidence.isEmpty {
                evidenceCounts[evidence, default: 0] += 1
            }
        }

        func materialized() -> StutterEpisode {
            let summary = evidenceCounts
                .sorted {
                    if $0.value == $1.value {
                        return $0.key < $1.key
                    }
                    return $0.value > $1.value
                }
                .prefix(3)
                .map(\.key)
            return StutterEpisode(
                id: id,
                cause: cause,
                startAt: startAt,
                endAt: endAt,
                count: count,
                peakSeverity: peakSeverity,
                avgConfidence: confidenceSum / Double(max(count, 1)),
                evidenceSummary: summary
            )
        }
    }

    private var stutterEpisodeAccumulators: [StutterCause: StutterEpisodeAccumulator] = [:]

    func configureSampling(interval: TimeInterval, alpha: Double) {
        let clampedInterval = max(0.25, min(interval, 2.0))
        let clampedAlpha = min(max(alpha, 0.05), 0.95)

        requestedSamplingIntervalSeconds = clampedInterval
        samplingIntervalSeconds = effectiveSamplingInterval(
            requestedInterval: clampedInterval,
            profile: profileMode,
            cpuBudgetMode: cpuBudgetModeEnabledInternal
        )
        smoothingAlpha = clampedAlpha

        Task { @MainActor in
            configuredIntervalSeconds = samplingIntervalSeconds
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

    func configureRetention(window: HistoryDurationOption) {
        let seconds = window.seconds
        dataRetentionSeconds = seconds

        Task { @MainActor in
            configuredRetentionSeconds = seconds
        }

        queue.async { [weak self] in
            self?.trimHistory(reference: Date())
        }
    }

    func configureCPUBudgetMode(enabled: Bool) {
        cpuBudgetModeEnabledInternal = enabled
        samplingIntervalSeconds = effectiveSamplingInterval(
            requestedInterval: requestedSamplingIntervalSeconds,
            profile: profileMode,
            cpuBudgetMode: enabled
        )

        Task { @MainActor in
            cpuBudgetModeEnabled = enabled
            configuredIntervalSeconds = samplingIntervalSeconds
        }

        guard timer != nil else { return }
        restartTimer()
    }

    func configureWorkloadProfile(_ profile: ProfileKind) {
        profileMode = profile
        Task { @MainActor in
            workloadProfile = profile
        }

        samplingIntervalSeconds = effectiveSamplingInterval(
            requestedInterval: requestedSamplingIntervalSeconds,
            profile: profile,
            cpuBudgetMode: cpuBudgetModeEnabledInternal
        )

        Task { @MainActor in
            configuredIntervalSeconds = samplingIntervalSeconds
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
        let latestFromSampler = queue.sync { self.latestSampleDate }
        guard let lastUpdated = latestFromSampler ?? snapshot.lastUpdated else { return true }
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
    func clearSessionSnapshot() {
        clearCurrentSession()
    }

    @MainActor
    func clearCurrentSession() {
        lastSessionSnapshot = nil
        sessionReport = nil
        queue.async { [weak self] in
            self?.currentTelemetrySession = nil
            self?.lastSessionSnapshotState = nil
            self?.previousTelemetryState = .offline
            self?.lastBuiltSessionReport = nil
        }
    }

    @MainActor
    func clearHistory() {
        history = []
        metricSamples = []
        stutterEvents = []
        stutterEpisodes = []
        stutterCauseSummaries = []
        actionReceipts = []
        sessionReport = nil
        queue.async { [weak self] in
            guard let self else { return }
            self.historyBuffer.removeAll(keepingCapacity: true)
            self.metricSampleBuffer.removeAll(keepingCapacity: true)
            self.actionReceiptBuffer.removeAll(keepingCapacity: true)
            self.stutterBuffer.removeAll(keepingCapacity: true)
            self.finalizedStutterEpisodes.removeAll(keepingCapacity: true)
            self.stutterEpisodeBuffer.removeAll(keepingCapacity: true)
            self.stutterEpisodeAccumulators.removeAll()
            self.stutterLastEmissionAt.removeAll()
            self.lastBuiltSessionReport = nil
        }
    }

    @MainActor
    func stutterEpisodesInWindow(lastMinutes minutes: Int) -> [StutterEpisode] {
        let cutoff = Date().addingTimeInterval(-Double(max(minutes, 1)) * 60.0)
        return stutterEpisodes.filter { $0.endAt >= cutoff }
    }

    @MainActor
    func rawStutterEventsInWindow(lastMinutes minutes: Int) -> [StutterEvent] {
        let cutoff = Date().addingTimeInterval(-Double(max(minutes, 1)) * 60.0)
        return stutterEvents.filter { $0.timestamp >= cutoff }
    }

    @MainActor
    func exportDiagnostics(settingsSnapshot: [String: String] = [:]) -> DiagnosticsExportOutcome {
        struct ExportReport: Codable {
            let generatedAt: Date
            let profile: String
            let simActive: Bool
            let snapshot: SnapshotBody
            let proof: ProofBody
            let liveState: LiveStateBody
            let lastSessionSnapshot: SessionSnapshot?
            let warnings: [String]
            let culprits: [String]
            let topCPUProcesses: [ProcessSample]
            let topMemoryProcesses: [ProcessSample]
            let recentHistory: [MetricHistoryPoint]
            let recentSamples: [MetricSample]
            let stutterEvents: [StutterEvent]
            let stutterEpisodes: [StutterEpisode]
            let stutterCauseSummaries: [StutterCauseSummary]
            let actionReceipts: [ActionReceipt]
            let sessionReport: SessionReport?
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

            struct LiveStateBody: Codable {
                let telemetryState: String
                let telemetryFreshnessSeconds: Double?
                let hasSimData: Bool
                let proof: ProofBody
            }
        }

        let now = Date()
        let proof = computeProofState(now: now)
        let proofBody = ExportReport.ProofBody(
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
        )
        let freshness = snapshot.udpStatus.lastValidPacketDate.map {
            max(now.timeIntervalSince($0), 0)
        }
        let report = ExportReport(
            generatedAt: now,
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
            proof: proofBody,
            liveState: .init(
                telemetryState: telemetryLiveState.rawValue,
                telemetryFreshnessSeconds: freshness,
                hasSimData: proof.hasSimData,
                proof: proofBody
            ),
            lastSessionSnapshot: lastSessionSnapshot,
            warnings: warnings,
            culprits: culprits,
            topCPUProcesses: topCPUProcesses,
            topMemoryProcesses: topMemoryProcesses,
            recentHistory: history,
            recentSamples: metricSamples,
            stutterEvents: stutterEvents,
            stutterEpisodes: stutterEpisodes,
            stutterCauseSummaries: stutterCauseSummaries,
            actionReceipts: actionReceipts,
            sessionReport: sessionReport,
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

    @MainActor
    func exportSessionReport() -> DiagnosticsExportOutcome {
        guard let sessionReport else {
            return DiagnosticsExportOutcome(success: false, fileURL: nil, message: "No session report available yet.")
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        do {
            let data = try encoder.encode(sessionReport)

            let formatter = DateFormatter()
            formatter.dateFormat = "yyyyMMdd-HHmmss"
            let suggestedName = "CruiseControl-session-report-\(formatter.string(from: Date())).json"

            let panel = NSSavePanel()
            panel.title = "Export Session Report"
            panel.message = "Choose where to save the session report."
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
                return DiagnosticsExportOutcome(success: false, fileURL: nil, message: "Session report export cancelled.")
            }

            let directoryURL = fileURL.deletingLastPathComponent()
            let access = directoryURL.startAccessingSecurityScopedResource()
            defer {
                if access { directoryURL.stopAccessingSecurityScopedResource() }
            }

            try data.write(to: fileURL, options: .atomic)
            return DiagnosticsExportOutcome(success: true, fileURL: fileURL, message: "Session report exported to \(fileURL.path).")
        } catch {
            return DiagnosticsExportOutcome(success: false, fileURL: nil, message: "Failed to export session report: \(error.localizedDescription)")
        }
    }

    private func restartTimer() {
        timer?.cancel()

        let timer = DispatchSource.makeTimerSource(queue: queue)
        let leewayMs = Int(max(samplingIntervalSeconds * 0.25 * 1_000.0, cpuBudgetModeEnabledInternal ? 220.0 : 140.0))
        timer.schedule(deadline: .now(), repeating: samplingIntervalSeconds, leeway: .milliseconds(leewayMs))
        timer.setEventHandler { [weak self] in
            self?.sample()
        }
        self.timer = timer
        timer.resume()
    }

    private func effectiveSamplingInterval(
        requestedInterval: TimeInterval,
        profile: ProfileKind,
        cpuBudgetMode: Bool
    ) -> TimeInterval {
        let boundedByProfile = min(
            max(requestedInterval, profile.minimumSamplingInterval),
            profile.maximumSamplingInterval
        )

        guard cpuBudgetMode else {
            return boundedByProfile
        }

        let budgetFloor = profile == .simMode ? 0.75 : 1.25
        return min(max(boundedByProfile, budgetFloor), profile.maximumSamplingInterval)
    }

    private func shouldPublishToUI(
        sampleIndex: UInt64,
        didScanProcesses: Bool,
        didEmitStutter: Bool,
        didAlertChange: Bool,
        liveState: TelemetryLiveState
    ) -> Bool {
        let cadenceModulo: UInt64
        if profileMode == .simMode {
            cadenceModulo = cpuBudgetModeEnabledInternal ? 3 : 2
        } else {
            cadenceModulo = 1
        }

        if sampleIndex <= 2 {
            return true
        }

        if didScanProcesses || didEmitStutter || didAlertChange {
            return true
        }

        if liveState != latestPublishedLiveState {
            return true
        }

        return sampleIndex % cadenceModulo == 0
    }

    private func sample() {
        sampleCount += 1
        let now = Date()
        latestSampleDate = now

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
        let processScanEverySeconds: TimeInterval
        if cpuBudgetModeEnabledInternal {
            processScanEverySeconds = profileMode == .simMode ? 2.5 : 4.0
        } else {
            processScanEverySeconds = profileMode == .simMode ? 1.2 : 2.0
        }
        let processScanModulo = max(Int((processScanEverySeconds / max(samplingIntervalSeconds, 0.2)).rounded(.awayFromZero)), 1)
        if sampleCount % UInt64(processScanModulo) == 0 {
            scannedProcesses = processScanner.sampleProcesses()
        }

        let processDetected = isXPlaneProcessRunning(processes: scannedProcesses)
        let simActive = processDetected || udpStatus.state == .active
        let liveState = telemetryState(for: udpStatus, simActive: simActive, now: now)


        let swapDelta5Min = computeSwapDelta(windowSeconds: 300, now: now)
        let swapRapidIncrease = computeSwapDelta(windowSeconds: 90, now: now) > Int64(256 * 1_024 * 1_024)
        let pressureTrend = inferMemoryTrend()

        let ioPressureLikely =
            (diskRate.readMBps + diskRate.writeMBps) > 120.0 &&
            swapRapidIncrease &&
            memoryPressure == .red

        maybeCompleteRegulatorTestIfNeeded(now: now)
        let governorResult = evaluateGovernor(telemetry: telemetry, udpStatus: udpStatus, simActive: simActive, now: now)
        let shouldReadFileBridgeStatus = governorConfig.enabled || simActive || pendingRegulatorTest != nil
        let fileBridgeStatus = shouldReadFileBridgeStatus ? governorBridge.readFileBridgeStatus() : nil
        let controlState = deriveRegulatorControlState(now: now, fileBridgeStatus: fileBridgeStatus)
        maybeLogBridgeEvents(now: now, fileBridgeStatus: fileBridgeStatus)
        let proofState = buildRegulatorProofState(
            now: now,
            simActive: simActive,
            controlState: controlState,
            fileBridgeStatus: fileBridgeStatus,
            governorResult: governorResult
        )
        updateTelemetrySession(
            now: now,
            liveState: liveState,
            udpStatus: udpStatus,
            proofState: proofState,
            controlState: controlState,
            ackState: governorResult.ackState,
            lastAckAt: governorResult.lastACKDate
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
        let impactLimit = cpuBudgetModeEnabledInternal ? 3 : 5
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
                .prefix(impactLimit)
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

        var emittedStutterEvent = false
        if simActive || demoMockModeEnabled {
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
                emittedStutterEvent = recordStutterDetection(stutterEvent, at: now)
            }
        }

        refreshStutterEpisodeBuffer(reference: now)
        let causeSummaries = buildStutterCauseRanking(referenceDate: now, episodes: stutterEpisodeBuffer, windowMinutes: 10)
        let shouldRefreshSessionReport = !cpuBudgetModeEnabledInternal || emittedStutterEvent || sampleCount.isMultiple(of: 2)
        if shouldRefreshSessionReport {
            lastBuiltSessionReport = buildSessionReport(
                referenceDate: now,
                metricSamples: metricSampleBuffer,
                stutterEpisodes: stutterEpisodeBuffer,
                stutterEvents: stutterBuffer,
                actionReceipts: actionReceiptBuffer,
                warnings: warningItems,
                culprits: culpritItems,
                sessionSnapshot: lastSessionSnapshotState,
                activeSession: currentTelemetrySession
            )
        }

        let nextAlertFlags = AlertFlags(
            memoryPressureRed: memoryPressure == .red,
            thermalCritical: thermal == .serious || thermal == .critical,
            swapRisingFast: swapRapidIncrease
        )
        let shouldPublishNow = shouldPublishToUI(
            sampleIndex: sampleCount,
            didScanProcesses: scannedProcesses != nil,
            didEmitStutter: emittedStutterEvent,
            didAlertChange: nextAlertFlags != latestPublishedAlertFlags,
            liveState: liveState
        )

        if shouldPublishNow {
            latestPublishedAlertFlags = nextAlertFlags
            latestPublishedLiveState = liveState

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
                stutterCauseSummaries = causeSummaries
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
                telemetryLiveState = liveState
                lastSessionSnapshot = lastSessionSnapshotState
                stutterEvents = stutterBuffer
                stutterEpisodes = stutterEpisodeBuffer
                sessionReport = lastBuiltSessionReport

                alertFlags = nextAlertFlags
            }
        }

        previousSwapUsedBytes = swapUsedBytes
    }

    private func telemetryState(for udpStatus: XPlaneUDPStatus, simActive: Bool, now: Date) -> TelemetryLiveState {
        if udpStatus.state == .idle {
            return .offline
        }

        if let lastValid = udpStatus.lastValidPacketDate {
            let age = max(now.timeIntervalSince(lastValid), 0)
            if age <= 2.0 {
                return .live
            }
            if age > 10.0 {
                return .stale
            }
            return .listening
        }

        if simActive || udpStatus.state == .listening || udpStatus.state == .active || udpStatus.state == .misconfig {
            return .listening
        }

        return .offline
    }

    private func updateTelemetrySession(
        now: Date,
        liveState: TelemetryLiveState,
        udpStatus: XPlaneUDPStatus,
        proofState: RegulatorProofState,
        controlState: RegulatorControlState,
        ackState: GovernorAckState,
        lastAckAt: Date?
    ) {
        if liveState == .live, currentTelemetrySession == nil {
            if previousTelemetryState == .offline {
                lastSessionSnapshotState = nil
            }
            currentTelemetrySession = ActiveTelemetrySession(
                sessionStartAt: udpStatus.lastValidPacketDate ?? now,
                packetBaseline: udpStatus.totalPackets,
                lastLiveSnapshot: nil,
                ackOkCount: 0,
                ackTimeoutCount: 0,
                previousAckWasHealthy: nil
            )
        }

        if liveState == .live, var activeSession = currentTelemetrySession {
            let ackHealthy = ackState == .ackOK
            if activeSession.previousAckWasHealthy == nil, ackHealthy {
                activeSession.ackOkCount += 1
            } else if activeSession.previousAckWasHealthy == false, ackHealthy {
                activeSession.ackOkCount += 1
            } else if activeSession.previousAckWasHealthy == true, ackState == .noAck {
                activeSession.ackTimeoutCount += 1
            }
            activeSession.previousAckWasHealthy = ackHealthy
            activeSession.lastLiveSnapshot = buildSessionSnapshot(
                now: now,
                sessionStartAt: activeSession.sessionStartAt,
                packetBaseline: activeSession.packetBaseline,
                udpStatus: udpStatus,
                proofState: proofState,
                controlState: controlState,
                lastAckAt: lastAckAt,
                ackOkCount: activeSession.ackOkCount,
                ackTimeoutCount: activeSession.ackTimeoutCount
            )
            currentTelemetrySession = activeSession
        }

        let transitionFromLive = previousTelemetryState == .live
        let shouldFreeze = transitionFromLive && (liveState == .stale || liveState == .offline)
        if shouldFreeze, let session = currentTelemetrySession, var frozen = session.lastLiveSnapshot {
            frozen.sessionEndAt = now
            lastSessionSnapshotState = frozen
            currentTelemetrySession = nil
        }

        previousTelemetryState = liveState
    }

    private func buildSessionSnapshot(
        now: Date,
        sessionStartAt: Date,
        packetBaseline: UInt64,
        udpStatus: XPlaneUDPStatus,
        proofState: RegulatorProofState,
        controlState: RegulatorControlState,
        lastAckAt: Date?,
        ackOkCount: Int,
        ackTimeoutCount: Int
    ) -> SessionSnapshot {
        let packetDelta = udpStatus.totalPackets >= packetBaseline
            ? udpStatus.totalPackets - packetBaseline
            : udpStatus.totalPackets
        let elapsed = max(now.timeIntervalSince(sessionStartAt), 0)
        let avgPackets = elapsed > 0.25 ? Double(packetDelta) / elapsed : nil

        return SessionSnapshot(
            capturedAt: now,
            sessionStartAt: sessionStartAt,
            sessionEndAt: nil,
            telemetrySummary: .init(
                totalPackets: packetDelta,
                avgPacketsPerSec: avgPackets,
                lastValidPacketAt: udpStatus.lastValidPacketDate
            ),
            regulatorSummary: .init(
                lastTarget: proofState.targetLOD,
                lastApplied: proofState.appliedLOD,
                lastDelta: proofState.deltaToTarget,
                lastAckAt: lastAckAt ?? proofState.lastEvidenceAt,
                evidenceSource: regulatorEvidenceSource(from: controlState),
                bridgeMode: proofState.bridgeModeLabel,
                appliedOK: proofState.lodApplied,
                activityRecent: proofState.recentActivity,
                reasons: proofState.reasons
            ),
            governorAckOkCount: ackOkCount,
            ackTimeoutCount: ackTimeoutCount
        )
    }

    private func regulatorEvidenceSource(from controlState: RegulatorControlState) -> RegulatorEvidenceSource {
        switch controlState {
        case .udpAckOK:
            return .udpAck
        case .fileBridge:
            return .fileStatus
        case .udpNoAck, .disconnected:
            return .unknown
        }
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
        computeSwapDeltaSignal(windowSeconds: windowSeconds, now: now).delta
    }

    private func computeSwapDeltaSignal(windowSeconds: TimeInterval, now: Date) -> (delta: Int64, available: Bool) {
        guard let reference = historyBuffer.last(where: { now.timeIntervalSince($0.timestamp) >= windowSeconds }) else {
            return (0, false)
        }
        guard let current = historyBuffer.last else {
            return (0, false)
        }
        return (Int64(current.swapUsedBytes) - Int64(reference.swapUsedBytes), true)
    }

    private func isSwapUsedIncreasingAcrossSamples(minIncreases: Int, sampleWindow: Int, minimumStepBytes: UInt64 = 4 * 1_024 * 1_024) -> Bool {
        let points = Array(historyBuffer.suffix(max(sampleWindow, minIncreases + 1)))
        guard points.count >= minIncreases + 1 else { return false }

        var increases = 0
        for index in 1..<points.count {
            let previous = points[index - 1].swapUsedBytes
            let current = points[index].swapUsedBytes
            if current > previous && (current - previous) >= minimumStepBytes {
                increases += 1
            }
        }
        return increases >= minIncreases
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
        let cutoff = reference.addingTimeInterval(-dataRetentionSeconds)
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

        if let firstStutterIndex = stutterBuffer.firstIndex(where: { $0.timestamp >= cutoff }) {
            if firstStutterIndex > 0 {
                stutterBuffer.removeFirst(firstStutterIndex)
            }
        } else {
            stutterBuffer.removeAll(keepingCapacity: true)
        }

        if let firstEpisodeIndex = finalizedStutterEpisodes.firstIndex(where: { $0.endAt >= cutoff }) {
            if firstEpisodeIndex > 0 {
                finalizedStutterEpisodes.removeFirst(firstEpisodeIndex)
            }
        } else {
            finalizedStutterEpisodes.removeAll(keepingCapacity: true)
        }

        stutterEpisodeAccumulators = stutterEpisodeAccumulators.filter { _, accumulator in
            accumulator.endAt >= cutoff
        }
        stutterLastEmissionAt = stutterLastEmissionAt.filter { _, timestamp in
            timestamp >= cutoff
        }

        let historyCap = ringBufferLimit(multiplier: 1.1, minimum: 300)
        let sampleCap = ringBufferLimit(multiplier: 1.4, minimum: 420)
        let actionCap = max(Int(dataRetentionSeconds / 30.0), 120)

        if historyBuffer.count > historyCap {
            historyBuffer.removeFirst(historyBuffer.count - historyCap)
        }
        if metricSampleBuffer.count > sampleCap {
            metricSampleBuffer.removeFirst(metricSampleBuffer.count - sampleCap)
        }
        if actionReceiptBuffer.count > actionCap {
            actionReceiptBuffer.removeFirst(actionReceiptBuffer.count - actionCap)
        }
    }

    private func ringBufferLimit(multiplier: Double, minimum: Int) -> Int {
        let expectedSamples = Int((dataRetentionSeconds / max(samplingIntervalSeconds, 0.25)).rounded(.up))
        let scaled = Int((Double(expectedSamples) * multiplier).rounded(.up))
        return max(scaled, minimum)
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
            recordStutterDetection(mock, at: now)
            refreshStutterEpisodeBuffer(reference: now)
        }
    }

    @MainActor
    func injectMockStutterEvent() {
        demoMockModeEnabled = true
        appendDemoMetricSample(now: Date())
        stutterEvents = stutterBuffer
        stutterEpisodes = stutterEpisodeBuffer
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
        let diskTotalMBps = diskReadMBps + diskWriteMBps
        let diskSpike = diskTotalMBps >= stutterHeuristics.diskSpikeMBps
        let compressedHighThreshold: UInt64 = 2 * 1_024 * 1_024 * 1_024

        let frameTimeSpikeSignal: Bool
        if let frameTime = telemetry?.frameTimeMS,
           frameTime >= stutterHeuristics.frameTimeSpikeMS {
            frameTimeSpikeSignal = true
            triggerReasons.append("Frame-time spike")
            evidencePoints.append(String(format: "frameTimeMS=%.2f", frameTime))
        } else {
            frameTimeSpikeSignal = false
        }

        let fpsDropSignal: Bool
        if let fps = telemetry?.fps,
           let previousFPS,
           fps <= max(15, previousFPS - stutterHeuristics.fpsDropThreshold) {
            fpsDropSignal = true
            triggerReasons.append("FPS drop")
            evidencePoints.append(String(format: "fps=%.2f prev=%.2f", fps, previousFPS))
        } else {
            fpsDropSignal = false
        }

        let cpuSpikeSignal: Bool
        if let previousCPU = previousCPUTotalPercent,
           cpuTotalPercent - previousCPU >= stutterHeuristics.cpuSpikePercent {
            cpuSpikeSignal = true
            triggerReasons.append("CPU spike")
            evidencePoints.append(String(format: "cpuDelta=%.2f", cpuTotalPercent - previousCPU))
        } else {
            cpuSpikeSignal = false
        }

        if diskSpike {
            triggerReasons.append("Disk I/O spike")
            evidencePoints.append(String(format: "diskMBps=%.2f", diskTotalMBps))
        }

        let swapDelta90s = computeSwapDeltaSignal(windowSeconds: 90, now: now)
        let swapJump = swapDelta90s.delta
        let swapJumpSignal = swapJump >= Int64(stutterHeuristics.swapJumpBytes)
        if swapJump >= Int64(stutterHeuristics.swapJumpBytes) {
            triggerReasons.append("Swap jump")
            evidencePoints.append("swapJump=\(swapJump)")
        }

        let swapDeltaPerMinute = computeSwapDeltaSignal(windowSeconds: 60, now: now)
        let swapPerMinuteThreshold = Int64(Double(stutterHeuristics.swapJumpBytes) * (60.0 / 90.0))
        let swapRisingFast = swapDeltaPerMinute.available && swapDeltaPerMinute.delta >= swapPerMinuteThreshold
        let swapUsedRising = isSwapUsedIncreasingAcrossSamples(minIncreases: 2, sampleWindow: 4)
        let diskSpikeWithPressure = diskSpike && (memoryPressure == .yellow || memoryPressure == .red)
        let pressureOrCompressedHigh = memoryPressure == .yellow || memoryPressure == .red || compressedBytes >= compressedHighThreshold

        if swapDeltaPerMinute.available {
            evidencePoints.append("swapDeltaPerMin=\(swapDeltaPerMinute.delta)")
        } else {
            evidencePoints.append("swapDeltaPerMin=unavailable")
        }
        if swapUsedRising {
            evidencePoints.append("swapUsedTrend=rising")
        }
        if compressedBytes >= compressedHighThreshold {
            evidencePoints.append("compressedHigh=true")
        }
        if memoryPressure == .yellow || memoryPressure == .red {
            evidencePoints.append("memPressure=\(memoryPressure.rawValue)")
        }

        let thermalEscalationSignal: Bool
        if previousThermalState.rawValue < thermalState.rawValue,
           thermalState == .serious || thermalState == .critical {
            thermalEscalationSignal = true
            triggerReasons.append("Thermal escalation")
            evidencePoints.append("thermal=\(thermalStateDescription(thermalState))")
        } else {
            thermalEscalationSignal = false
        }

        let pressureRedSignal = memoryPressure == .red && (swapRisingFast || swapUsedRising || diskSpikeWithPressure || compressedBytes >= compressedHighThreshold)
        if pressureRedSignal {
            triggerReasons.append("Memory pressure red")
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

        let hasRecentPackets = freshness.isFinite && freshness <= 10.0
        let hasFrameTimeMetric = telemetry?.frameTimeMS != nil
        let hasFPSMetric = telemetry?.fps != nil
        let hasSwapRateMetric = swapDeltaPerMinute.available
        let metricAvailability: StutterMetricAvailability
        if !hasRecentPackets && !hasSwapRateMetric {
            metricAvailability = .unavailable
        } else if !(hasRecentPackets && hasFrameTimeMetric && hasFPSMetric && hasSwapRateMetric) {
            metricAvailability = .partial
        } else {
            metricAvailability = .full
        }

        let hasSimGpuFrameTime = telemetry?.gpuFrameTimeMS != nil
        let swapSignalCount = [swapRisingFast, swapUsedRising, diskSpikeWithPressure].filter { $0 }.count

        var classification: StutterCause
        if pressureOrCompressedHigh && swapSignalCount > 0 {
            classification = .swapThrash
        } else if diskSpike {
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

        let multiSignalCount = [
            frameTimeSpikeSignal,
            fpsDropSignal,
            cpuSpikeSignal,
            diskSpike,
            swapJumpSignal || swapRisingFast || swapUsedRising,
            thermalEscalationSignal,
            pressureRedSignal
        ]
        .filter { $0 }
        .count

        let severity = min(max(
            (Double(multiSignalCount) / 6.0) +
            (memoryPressure == .red ? 0.2 : 0) +
            ((thermalState == .serious || thermalState == .critical) ? 0.2 : 0),
            0
        ), 1)
        var confidence = min(max(0.28 + (Double(multiSignalCount) * 0.14) + (severity * 0.25), 0), 0.97)
        if classification == .swapThrash {
            if swapSignalCount >= 2 && pressureOrCompressedHigh {
                confidence = min(confidence + 0.12, 0.95)
            } else {
                confidence = min(confidence, 0.62)
            }
        }

        if multiSignalCount < 2 {
            confidence = min(confidence, 0.72)
            evidencePoints.append("multiSignal=single")
        } else {
            evidencePoints.append("multiSignal=\(multiSignalCount)")
        }

        switch metricAvailability {
        case .full:
            evidencePoints.append("metrics=full")
        case .partial:
            confidence = min(confidence, 0.68)
            evidencePoints.append("metrics=partial")
        case .unavailable:
            confidence = min(confidence, 0.45)
            evidencePoints.append("metrics=unavailable")
        }

        if classification == .unknown {
            confidence = min(confidence, metricAvailability == .unavailable ? 0.35 : 0.58)
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
            metricAvailability: metricAvailability,
            evidencePoints: evidencePoints,
            windowRef: "\(Int(now.timeIntervalSince1970))"
        )
    }

    @discardableResult
    private func recordStutterDetection(_ event: StutterEvent, at now: Date) -> Bool {
        upsertStutterEpisode(with: event, at: now)

        let cooldown = cooldownSeconds(for: event.classification)
        if let lastEmission = stutterLastEmissionAt[event.classification],
           now.timeIntervalSince(lastEmission) < cooldown {
            return false
        }

        stutterBuffer.append(event)
        stutterLastEmissionAt[event.classification] = now
        return true
    }

    private func upsertStutterEpisode(with event: StutterEvent, at now: Date) {
        if var accumulator = stutterEpisodeAccumulators[event.classification] {
            let gap = now.timeIntervalSince(accumulator.endAt)
            if gap <= stutterEpisodeContinuationSeconds {
                accumulator.absorb(event: event, at: now)
                stutterEpisodeAccumulators[event.classification] = accumulator
            } else {
                if let materialized = materializeEpisodeIfRelevant(accumulator) {
                    finalizedStutterEpisodes.append(materialized)
                }
                stutterEpisodeAccumulators[event.classification] = StutterEpisodeAccumulator(
                    id: UUID(),
                    cause: event.classification,
                    startAt: now,
                    endAt: now,
                    count: 1,
                    peakSeverity: event.severity,
                    confidenceSum: event.confidence,
                    evidenceCounts: evidenceFrequencyMap(from: event.evidencePoints)
                )
            }
        } else {
            stutterEpisodeAccumulators[event.classification] = StutterEpisodeAccumulator(
                id: UUID(),
                cause: event.classification,
                startAt: now,
                endAt: now,
                count: 1,
                peakSeverity: event.severity,
                confidenceSum: event.confidence,
                evidenceCounts: evidenceFrequencyMap(from: event.evidencePoints)
            )
        }
    }

    private func materializeEpisodeIfRelevant(_ accumulator: StutterEpisodeAccumulator) -> StutterEpisode? {
        let episode = accumulator.materialized()
        let duration = max(episode.endAt.timeIntervalSince(episode.startAt), 0)
        guard duration >= minimumStutterEpisodeDurationSeconds else {
            return nil
        }
        return episode
    }

    private func refreshStutterEpisodeBuffer(reference: Date) {
        let staleCauses = stutterEpisodeAccumulators.compactMap { cause, accumulator in
            if reference.timeIntervalSince(accumulator.endAt) > stutterEpisodeContinuationSeconds {
                return cause
            }
            return nil
        }
        for cause in staleCauses {
            if let accumulator = stutterEpisodeAccumulators.removeValue(forKey: cause) {
                if let materialized = materializeEpisodeIfRelevant(accumulator) {
                    finalizedStutterEpisodes.append(materialized)
                }
            }
        }

        let activeEpisodes = stutterEpisodeAccumulators.values.compactMap { materializeEpisodeIfRelevant($0) }
        stutterEpisodeBuffer = (finalizedStutterEpisodes + activeEpisodes)
            .sorted { $0.endAt < $1.endAt }
    }

    private func evidenceFrequencyMap(from points: [String]) -> [String: Int] {
        var counts: [String: Int] = [:]
        for point in points where !point.isEmpty {
            counts[point, default: 0] += 1
        }
        return counts
    }

    private func cooldownSeconds(for cause: StutterCause) -> TimeInterval {
        stutterCooldownsByCause[cause] ?? 0
    }

    private struct SessionReportWindow {
        let start: Date
        let end: Date
    }

    private func buildSessionReport(
        referenceDate: Date,
        metricSamples: [MetricSample],
        stutterEpisodes: [StutterEpisode],
        stutterEvents: [StutterEvent],
        actionReceipts: [ActionReceipt],
        warnings: [String],
        culprits: [String],
        sessionSnapshot: SessionSnapshot?,
        activeSession: ActiveTelemetrySession?
    ) -> SessionReport? {
        guard let window = resolveSessionReportWindow(
            referenceDate: referenceDate,
            metricSamples: metricSamples,
            stutterEpisodes: stutterEpisodes,
            actionReceipts: actionReceipts,
            sessionSnapshot: sessionSnapshot,
            activeSession: activeSession
        ) else {
            return nil
        }

        let sessionSamples = metricSamples.filter { $0.timestamp >= window.start && $0.timestamp <= window.end }
        let sessionEpisodes = stutterEpisodes.filter { $0.endAt >= window.start && $0.startAt <= window.end }
        let sessionEvents = stutterEvents.filter { $0.timestamp >= window.start && $0.timestamp <= window.end }
        let sessionActions = actionReceipts.filter { $0.timestamp >= window.start && $0.timestamp <= window.end }

        let avgPressureIndex: Double
        if sessionSamples.isEmpty {
            avgPressureIndex = metricSamples.last?.pressureIndex ?? 0
        } else {
            avgPressureIndex = sessionSamples.reduce(0) { $0 + $1.pressureIndex } / Double(sessionSamples.count)
        }
        let maxPressureIndex = sessionSamples.map(\.pressureIndex).max() ?? avgPressureIndex

        let topCauses = topCauseBreakdown(from: sessionEpisodes)
        let actionsTakenSummary = actionSummary(from: sessionActions)
        let advisorSummary = advisorSummary(
            warnings: warnings,
            culprits: culprits,
            sessionSnapshot: sessionSnapshot
        )
        let recommendations = recommendationBullets(
            topCauses: topCauses,
            actionSummary: actionsTakenSummary,
            advisorSummary: advisorSummary,
            avgPressureIndex: avgPressureIndex,
            maxPressureIndex: maxPressureIndex
        )

        let durationSeconds = Int(max(window.end.timeIntervalSince(window.start), 0))
        return SessionReport(
            sessionStartAt: window.start,
            sessionEndAt: window.end,
            durationSeconds: durationSeconds,
            avgPressureIndex: avgPressureIndex,
            maxPressureIndex: maxPressureIndex,
            stutterEpisodesCount: sessionEpisodes.count,
            topCauses: topCauses,
            worstWindow: worstWindow(from: sessionEpisodes, events: sessionEvents),
            actionsTakenSummary: actionsTakenSummary,
            advisorTriggersSummary: advisorSummary,
            keyRecommendations: recommendations
        )
    }

    private func resolveSessionReportWindow(
        referenceDate: Date,
        metricSamples: [MetricSample],
        stutterEpisodes: [StutterEpisode],
        actionReceipts: [ActionReceipt],
        sessionSnapshot: SessionSnapshot?,
        activeSession: ActiveTelemetrySession?
    ) -> SessionReportWindow? {
        if let activeSession {
            let end = referenceDate >= activeSession.sessionStartAt ? referenceDate : activeSession.sessionStartAt
            return SessionReportWindow(start: activeSession.sessionStartAt, end: end)
        }

        if let sessionSnapshot {
            let start = sessionSnapshot.sessionStartAt ?? sessionSnapshot.capturedAt
            let endCandidate = sessionSnapshot.sessionEndAt ?? sessionSnapshot.capturedAt
            let end = endCandidate >= start ? endCandidate : start
            return SessionReportWindow(start: start, end: end)
        }

        let sampleTimes = metricSamples.map(\.timestamp)
        let episodeTimes = stutterEpisodes.flatMap { [$0.startAt, $0.endAt] }
        let actionTimes = actionReceipts.map(\.timestamp)
        let timestamps = sampleTimes + episodeTimes + actionTimes
        guard let start = timestamps.min(), let endCandidate = timestamps.max() else {
            return nil
        }
        let end = endCandidate >= start ? endCandidate : start
        return SessionReportWindow(start: start, end: end)
    }

    private func topCauseBreakdown(from episodes: [StutterEpisode]) -> [SessionReport.TopCause] {
        let grouped = Dictionary(grouping: episodes, by: { $0.cause })
        return grouped
            .map { cause, groupedEpisodes in
                SessionReport.TopCause(cause: cause.displayName, count: groupedEpisodes.count)
            }
            .sorted {
                if $0.count == $1.count {
                    return $0.cause < $1.cause
                }
                return $0.count > $1.count
            }
            .prefix(3)
            .map { $0 }
    }

    private func worstWindow(from episodes: [StutterEpisode], events: [StutterEvent]) -> SessionReport.WorstWindow? {
        guard let worstEpisode = episodes.max(by: { lhs, rhs in
            if lhs.peakSeverity == rhs.peakSeverity {
                if lhs.count == rhs.count {
                    return lhs.endAt < rhs.endAt
                }
                return lhs.count < rhs.count
            }
            return lhs.peakSeverity < rhs.peakSeverity
        }) else {
            return nil
        }

        let reason = events
            .filter { $0.timestamp >= worstEpisode.startAt && $0.timestamp <= worstEpisode.endAt }
            .max(by: { $0.severity < $1.severity })?
            .rankedCulprits
            .first
            ?? worstEpisode.evidenceSummary.first
            ?? worstEpisode.cause.displayName

        return SessionReport.WorstWindow(
            startAt: worstEpisode.startAt,
            endAt: worstEpisode.endAt,
            reason: reason
        )
    }

    private func actionSummary(from actions: [ActionReceipt]) -> SessionReport.ActionsTakenSummary {
        let grouped = Dictionary(grouping: actions, by: { actionDisplayName(for: $0.kind) })
        let topActions = grouped
            .map { action, group in
                SessionReport.ActionsTakenSummary.ActionBreakdown(action: action, count: group.count)
            }
            .sorted {
                if $0.count == $1.count {
                    return $0.action < $1.action
                }
                return $0.count > $1.count
            }
            .prefix(3)
            .map { $0 }

        return SessionReport.ActionsTakenSummary(
            count: actions.count,
            topActions: topActions
        )
    }

    private func actionDisplayName(for kind: ActionKind) -> String {
        switch kind {
        case .quitApp:
            return "Quit App"
        case .forceQuitApp:
            return "Force Quit App"
        case .pauseBackgroundScans:
            return "Background Scans Toggle"
        case .openBridgeFolder:
            return "Open Bridge Folder"
        case .exportDiagnostics:
            return "Export Diagnostics"
        case .cleanerAction:
            return "Cleaner Action"
        }
    }

    private func advisorSummary(
        warnings: [String],
        culprits: [String],
        sessionSnapshot: SessionSnapshot?
    ) -> SessionReport.AdvisorTriggersSummary? {
        var unique: [String] = []
        var seen: Set<String> = []

        for item in warnings + culprits + (sessionSnapshot?.regulatorSummary.reasons ?? []) {
            let trimmed = item.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if seen.insert(trimmed).inserted {
                unique.append(trimmed)
            }
        }

        guard !unique.isEmpty else {
            return nil
        }

        return SessionReport.AdvisorTriggersSummary(
            count: unique.count,
            topTriggers: Array(unique.prefix(3))
        )
    }

    private func recommendationBullets(
        topCauses: [SessionReport.TopCause],
        actionSummary: SessionReport.ActionsTakenSummary,
        advisorSummary: SessionReport.AdvisorTriggersSummary?,
        avgPressureIndex: Double,
        maxPressureIndex: Double
    ) -> [String] {
        var items: [String] = []
        func append(_ text: String) {
            if !items.contains(text) {
                items.append(text)
            }
        }

        if let topCause = topCauses.first?.cause {
            switch topCause {
            case StutterCause.swapThrash.displayName:
                append("Prioritize memory relief first: lower texture load and close high-memory background apps.")
            case StutterCause.diskStall.displayName:
                append("Reduce disk churn during flight: pause heavy background I/O and keep free space healthy.")
            case StutterCause.cpuSaturation.displayName:
                append("Lower CPU-heavy scene options and cap background CPU consumers before launch.")
            case StutterCause.thermalThrottle.displayName:
                append("Allow thermal recovery and reduce sustained graphics load to stabilize frame-time.")
            case StutterCause.gpuBoundHeuristic.displayName:
                append("Dial back GPU-bound settings (clouds, AA, resolution scaling) for steadier frame pacing.")
            default:
                append("Review the highest-severity stutter window and retest after one targeted change.")
            }
        }

        if avgPressureIndex >= 0.65 || maxPressureIndex >= 0.82 {
            append("Pressure index stayed elevated; apply one mitigation at a time and verify in Frame-Time Lab.")
        }

        if actionSummary.count == 0 {
            append("No corrective actions were logged in this session. Capture at least one mitigation in the next run.")
        } else if let topAction = actionSummary.topActions.first {
            append("Most frequent mitigation was \(topAction.action); keep testing to confirm sustained improvement.")
        }

        if let topTrigger = advisorSummary?.topTriggers.first {
            append("Advisor trigger to revisit: \(topTrigger)")
        }

        if items.isEmpty {
            append("No dominant bottleneck was detected. Monitor the heatmap for recurring hotspots.")
        }

        return Array(items.prefix(3))
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
        buildStutterCauseRanking(
            referenceDate: Date(),
            episodes: stutterEpisodes,
            windowMinutes: max(minutes, 1)
        )
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
        sessionReport = buildSessionReport(
            referenceDate: Date(),
            metricSamples: metricSamples,
            stutterEpisodes: stutterEpisodes,
            stutterEvents: stutterEvents,
            actionReceipts: actionReceipts,
            warnings: warnings,
            culprits: culprits,
            sessionSnapshot: lastSessionSnapshot,
            activeSession: nil
        )
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

    private func buildStutterCauseRanking(
        referenceDate: Date,
        episodes: [StutterEpisode],
        windowMinutes: Int
    ) -> [StutterCauseSummary] {
        let cutoff = referenceDate.addingTimeInterval(-Double(max(windowMinutes, 1)) * 60.0)
        let relevant = episodes.filter { $0.endAt >= cutoff }
        guard !relevant.isEmpty else { return [] }

        var totalsByCause: [StutterCause: (count: Int, confidenceSum: Double)] = [:]
        for episode in relevant {
            let weightedConfidence = episode.avgConfidence * Double(max(episode.count, 1))
            var current = totalsByCause[episode.cause] ?? (0, 0)
            current.count += episode.count
            current.confidenceSum += weightedConfidence
            totalsByCause[episode.cause] = current
        }

        return totalsByCause
            .map { cause, payload in
                StutterCauseSummary(
                    cause: cause,
                    count: payload.count,
                    averageConfidence: payload.confidenceSum / Double(max(payload.count, 1))
                )
            }
            .sorted {
                if $0.count == $1.count {
                    return $0.averageConfidence > $1.averageConfidence
                }
                return $0.count > $1.count
            }
    }
}
