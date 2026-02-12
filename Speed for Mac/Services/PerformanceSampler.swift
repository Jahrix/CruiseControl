import Foundation
import AppKit
import Combine

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

    private let processScanner = ProcessScanner()
    private let queue = DispatchQueue(label: "ProjectSpeed.PerformanceSampler", qos: .utility)
    private let xPlaneReceiver = XPlaneUDPReceiver()
    private let governorBridge = GovernorCommandBridge()

    private var timer: DispatchSourceTimer?
    private var sampleCount: UInt64 = 0
    private var previousCPUTicks: host_cpu_load_info_data_t?
    private var previousSwapUsedBytes: UInt64 = 0
    private var previousDiskIO: DiskIOSnapshot?
    private var previousDiskSampleDate: Date?

    private var historyBuffer: [MetricHistoryPoint] = []

    private var smoothedUserCPU: Double = 0
    private var smoothedSystemCPU: Double = 0

    private var samplingIntervalSeconds: TimeInterval = 1.0
    private var smoothingAlpha: Double = 0.35

    private var udpListeningEnabled: Bool = true
    private var xPlaneUDPPort: Int = 49_005

    private var governorConfig: GovernorPolicyConfig = .default
    private var governorPreviouslyEnabled = false

    private var governorLockedTier: GovernorTier?
    private var governorLockedTierSince: Date?
    private var governorSmoothedLODInternal: Double?
    private var governorLastUpdateAt: Date?

    func configureSampling(interval: TimeInterval, alpha: Double) {
        let clampedInterval = max(0.5, min(interval, 2.0))
        let clampedAlpha = min(max(alpha, 0.05), 0.95)

        samplingIntervalSeconds = clampedInterval
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
    func exportDiagnostics() -> DiagnosticsExportOutcome {
        struct ExportReport: Codable {
            let generatedAt: Date
            let simActive: Bool
            let snapshot: SnapshotBody
            let warnings: [String]
            let culprits: [String]
            let topCPUProcesses: [ProcessSample]
            let topMemoryProcesses: [ProcessSample]
            let recentHistory: [MetricHistoryPoint]
            let governorDecision: GovernorDecision?

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
            }
        }

        let report = ExportReport(
            generatedAt: Date(),
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
                governorStatusLine: snapshot.governorStatusLine
            ),
            warnings: warnings,
            culprits: culprits,
            topCPUProcesses: topCPUProcesses,
            topMemoryProcesses: topMemoryProcesses,
            recentHistory: Array(history.suffix(180)),
            governorDecision: governorDecision
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        do {
            let data = try encoder.encode(report)
            let destination = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyyMMdd-HHmmss"
            let fileURL = destination.appendingPathComponent("ProjectSpeed-diagnostics-\(formatter.string(from: Date())).json")
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

        let historyPoint = MetricHistoryPoint(
            timestamp: now,
            cpuTotalPercent: cpu.user + cpu.system,
            swapUsedBytes: swapUsedBytes,
            memoryPressure: memoryPressure
        )
        historyBuffer.append(historyPoint)
        trimHistory(reference: now)

        let swapDelta5Min = computeSwapDelta(windowSeconds: 300, now: now)
        let swapRapidIncrease = computeSwapDelta(windowSeconds: 90, now: now) > Int64(256 * 1_024 * 1_024)
        let pressureTrend = inferMemoryTrend()

        let ioPressureLikely =
            (diskRate.readMBps + diskRate.writeMBps) > 120.0 &&
            swapRapidIncrease &&
            memoryPressure == .red

        let governorResult = evaluateGovernor(telemetry: telemetry, udpStatus: udpStatus, simActive: simActive, now: now)

        let warningItems = buildWarnings(
            memoryPressure: memoryPressure,
            thermalState: thermal,
            swapRapidIncrease: swapRapidIncrease,
            ioPressureLikely: ioPressureLikely,
            freeDiskBytes: freeDiskBytes,
            topCPUProcesses: scannedProcesses ?? topCPUProcesses,
            simActive: simActive,
            udpStatus: udpStatus
        )

        let culpritItems = buildCulprits(
            memoryPressure: memoryPressure,
            thermalState: thermal,
            swapRapidIncrease: swapRapidIncrease,
            ioPressureLikely: ioPressureLikely,
            freeDiskBytes: freeDiskBytes,
            topCPUProcesses: scannedProcesses ?? topCPUProcesses,
            simTelemetry: telemetry
        )

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

            isSimActive = simActive
            warnings = warningItems
            culprits = culpritItems
            history = historyBuffer
            governorDecision = governorResult.decision
            governorCurrentTier = governorResult.currentTier
            governorCurrentTargetLOD = governorResult.currentTargetLOD
            governorSmoothedTargetLOD = governorResult.smoothedLOD
            governorActiveAGLFeet = governorResult.activeAGLFeet
            governorLastSentLOD = governorResult.lastSentLOD
            governorCommandStatus = governorResult.commandStatus
            governorPauseReason = governorResult.pauseReason

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
        pauseReason: String?
    ) {
        func pausedResult(reason: String) -> (
            decision: GovernorDecision?,
            statusLine: String,
            currentTier: GovernorTier?,
            currentTargetLOD: Double?,
            smoothedLOD: Double?,
            activeAGLFeet: Double?,
            lastSentLOD: Double?,
            commandStatus: String,
            pauseReason: String?
        ) {
            _ = governorBridge.sendDisable(host: governorConfig.commandHost, port: governorConfig.commandPort)
            governorPreviouslyEnabled = false
            resetGovernorRuntimeState()
            let commandStatus = governorBridge.commandStatusText(now: now)
            return (nil, "Governor: \(reason)", nil, nil, nil, nil, governorBridge.lastSentLOD, commandStatus, reason)
        }

        guard governorConfig.enabled else {
            if governorPreviouslyEnabled {
                _ = governorBridge.sendDisable(host: governorConfig.commandHost, port: governorConfig.commandPort)
                governorPreviouslyEnabled = false
            }
            resetGovernorRuntimeState()
            return (nil, "Governor: Disabled", nil, nil, nil, nil, governorBridge.lastSentLOD, governorBridge.commandStatusText(now: now), nil)
        }

        guard simActive else {
            return pausedResult(reason: "No sim data; governor paused")
        }

        guard udpStatus.state == .active else {
            return pausedResult(reason: "No sim data; governor paused")
        }

        guard let telemetry else {
            return pausedResult(reason: "No sim data; governor paused")
        }

        let resolved = GovernorPolicyEngine.resolveAGL(telemetry: telemetry)
        guard let aglFeet = resolved.feet else {
            return pausedResult(reason: "AGL unavailable; governor paused")
        }

        governorPreviouslyEnabled = true

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
            }
        } else if governorLockedTier == nil {
            governorLockedTier = candidateTier
            governorLockedTierSince = now
        }

        let effectiveTier = governorLockedTier ?? candidateTier
        let tierTarget = governorConfig.targetLOD(for: effectiveTier)

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

        let sendResult = governorBridge.send(
            lod: smoothedLOD,
            tier: effectiveTier,
            host: governorConfig.commandHost,
            port: governorConfig.commandPort,
            now: now,
            minimumInterval: governorConfig.minimumCommandIntervalSeconds,
            minimumDelta: governorConfig.minimumCommandDelta
        )

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
            statusLine += " | Bridge error: \(bridgeError)"
        }

        return (
            decision,
            statusLine,
            effectiveTier,
            tierTarget,
            smoothedLOD,
            aglFeet,
            governorBridge.lastSentLOD,
            sendResult.statusText,
            nil
        )
    }

    private func resetGovernorRuntimeState() {
        governorLockedTier = nil
        governorLockedTierSince = nil
        governorSmoothedLODInternal = nil
        governorLastUpdateAt = nil
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

        if result.sent {
            governorLastSentLOD = clampedLOD
            governorCommandStatus = result.statusText
            return ActionOutcome(success: true, message: "Test command sent: SET_LOD \(String(format: "%.2f", clampedLOD)) to \(host):\(port).")
        }

        let detail = result.error ?? "Unknown send failure."
        governorCommandStatus = result.statusText
        return ActionOutcome(success: false, message: "Test command failed: \(detail)")
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

    private func trimHistory(reference: Date) {
        let cutoff = reference.addingTimeInterval(-900)
        if let firstValidIndex = historyBuffer.firstIndex(where: { $0.timestamp >= cutoff }) {
            if firstValidIndex > 0 {
                historyBuffer.removeFirst(firstValidIndex)
            }
        } else {
            historyBuffer.removeAll(keepingCapacity: true)
        }
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
