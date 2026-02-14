import SwiftUI
import AppKit
import Combine

enum DashboardSection: String, CaseIterable, Identifiable {
    case overview
    case smartScan
    case cleaner
    case largeFiles
    case optimization
    case quarantine
    case processes
    case simMode
    case history
    case diagnostics
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: return "Overview"
        case .smartScan: return "Smart Scan"
        case .cleaner: return "Cleaner"
        case .largeFiles: return "Large Files"
        case .optimization: return "Optimization"
        case .quarantine: return "Quarantine"
        case .processes: return "Top Processes"
        case .simMode: return "Sim Mode"
        case .history: return "History"
        case .diagnostics: return "Diagnostics"
        case .settings: return "Preferences"
        }
    }

    var icon: String {
        switch self {
        case .overview: return "speedometer"
        case .smartScan: return "sparkles"
        case .cleaner: return "trash.slash"
        case .largeFiles: return "externaldrive.fill.badge.plus"
        case .optimization: return "waveform.path.ecg.rectangle"
        case .quarantine: return "archivebox"
        case .processes: return "list.bullet.rectangle.portrait"
        case .simMode: return "airplane"
        case .history: return "clock.arrow.circlepath"
        case .diagnostics: return "waveform.path.ecg"
        case .settings: return "gearshape"
        }
    }
}

struct RunningAppChoice: Identifiable {
    let id: String
    let name: String
}

struct MenuContentView: View {
    @EnvironmentObject private var sampler: PerformanceSampler
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var featureStore: V112FeatureStore

    @State private var selectedSection: DashboardSection? = .overview

    @State private var showSimModeChecklist: Bool = false
    @State private var availableApps: [RunningAppChoice] = []
    @State private var lastActionReport: SimModeActionReport?
    @State private var processActionResult: String?
    @State private var diagnosticsExportResult: String?
    @State private var forceQuitCandidate: ProcessSample?

    @State private var allowlistText: String = ""
    @State private var blocklistText: String = ""
    @State private var doNotTouchText: String = ""

    @State private var udpPortText: String = "49005"
    @State private var governorPortText: String = "49006"
    @State private var governorHostText: String = "127.0.0.1"
    @State private var governorTestLODText: String = "1.00"
    @State private var regulatorTestStepUp: Double = 0.60
    @State private var regulatorTestStepDown: Double = 0.80
    @State private var regulatorTestDurationSeconds: Double = 10.0

    @State private var showUDPSetupGuide: Bool = true
    @State private var now: Date = Date()

    @State private var selectedReliefPIDs: Set<Int32> = []
    @State private var confirmCloseSelectedApps = false

    @State private var selectedAirportProfileICAO: String = ""
    @State private var airportProfileName: String = ""
    @State private var airportGroundMax: Double = 1500
    @State private var airportCruiseMin: Double = 10000
    @State private var airportTargetGround: Double = 1.4
    @State private var airportTargetTransition: Double = 1.1
    @State private var airportTargetCruise: Double = 0.95
    @State private var airportClampMin: Double = 0.20
    @State private var airportClampMax: Double = 3.00
    @State private var airportImportJSONText: String = ""

    @State private var smartScanIncludePrivacy = false
    @State private var smartScanRoots: [URL] = []
    @State private var smartScanSummary: SmartScanSummary?
    @State private var smartScanRunState: SmartScanRunState = .idle
    @State private var selectedSmartScanItemIDs: Set<UUID> = []
    @State private var confirmQuarantineSelection = false
    @State private var confirmDeleteSelection = false
    @State private var confirmDeleteLatestQuarantine = false
    @State private var confirmEmptyTrash = false
    @State private var smartScanTask: Task<Void, Never>?

    @State private var cleanerItems: [SmartScanItem] = []
    @State private var selectedCleanerItemIDs: Set<UUID> = []
    @State private var cleanerLoading = false

    @State private var largeFileItems: [SmartScanItem] = []
    @State private var selectedLargeFileItemIDs: Set<UUID> = []
    @State private var largeFilesLoading = false

    @State private var optimizationItems: [SmartScanItem] = []
    @State private var selectedOptimizationItemIDs: Set<UUID> = []

    @State private var quarantineBatches: [QuarantineBatchSummary] = []
    @State private var selectedQuarantineBatchID: String = ""

    @State private var updateCheckStatus: String?
    private let smartScanService = SmartScanService()
    private let clockTimer = Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()

    private let neonMint = Color(red: 0.30, green: 0.95, blue: 0.68)
    private let neonBlue = Color(red: 0.42, green: 0.72, blue: 1.00)
    private let neonViolet = Color(red: 0.61, green: 0.52, blue: 1.00)
    private let neonOrange = Color(red: 1.00, green: 0.52, blue: 0.18)
    private let cardInk = Color(red: 0.05, green: 0.08, blue: 0.16)
    private let decimalFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 2
        formatter.minimumFractionDigits = 0
        return formatter
    }()

    var body: some View {
        ZStack {
            CruiseBackgroundView()
                .ignoresSafeArea()
                .allowsHitTesting(false)

            NavigationSplitView {
                sidebar
            } detail: {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        heroBanner

                        detailContent

                        if let processActionResult {
                            feedbackCard(title: "Action Result", text: processActionResult)
                        }

                        if let diagnosticsExportResult {
                            feedbackCard(title: "Diagnostics", text: diagnosticsExportResult)
                        }

                        if let updateCheckStatus {
                            feedbackCard(title: "Update Check", text: updateCheckStatus)
                        }

                        if let lastActionReport {
                            dashboardCard(title: lastActionReport.title) {
                                VStack(alignment: .leading, spacing: 4) {
                                    ForEach(lastActionReport.detailLines, id: \.self) { line in
                                        Text("- \(line)")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                    .padding(24)
                    .padding(.bottom, 24)
                }
                .scrollIndicators(.hidden)
                .background(Color.clear)
            }
            .navigationSplitViewStyle(.balanced)
            .tint(neonBlue)
        }
        .onAppear {
            sampler.start()
            refreshRunningApps()
            refreshProfileLists()
            udpPortText = String(settings.xPlaneUDPPort)
            governorPortText = String(settings.governorCommandPort)
            governorHostText = settings.governorCommandHost
            syncAirportProfileEditorSelection()
            airportImportJSONText = ""
            applyDefaultLargeFileScopesIfNeeded()
            refreshQuarantineBatches()
        }
        .onReceive(clockTimer) { newDate in
            now = newDate
        }
        .onChange(of: settings.selectedProfile) {
            refreshProfileLists()
        }
        .onChange(of: selectedAirportProfileICAO) {
            loadAirportProfileEditor()
        }
        .onChange(of: featureStore.airportProfiles) {
            syncAirportProfileEditorSelection()
        }
        .onDisappear {
            smartScanTask?.cancel()
        }
        .alert("Force Quit Process", isPresented: forceQuitBinding) {
            Button("Cancel", role: .cancel) {
                forceQuitCandidate = nil
            }
            Button("Force Quit", role: .destructive) {
                guard let process = forceQuitCandidate else { return }
                runProcessAction(process: process, force: true)
                forceQuitCandidate = nil
            }
        } message: {
            Text(forceQuitMessage)
        }
        .confirmationDialog("Close selected apps?", isPresented: $confirmCloseSelectedApps, titleVisibility: .visible) {
            Button("Close Selected", role: .destructive) {
                closeSelectedReliefApps()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This sends graceful terminate to selected apps. Unsaved data may be lost if apps ignore state restoration.")
        }
        .confirmationDialog("Quarantine selected files?", isPresented: $confirmQuarantineSelection, titleVisibility: .visible) {
            Button("Quarantine", role: .destructive) {
                quarantineSelectedScanItems()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Files are moved to CruiseControl quarantine with manifest metadata for restore.")
        }
        .confirmationDialog("Delete selected files permanently?", isPresented: $confirmDeleteSelection, titleVisibility: .visible) {
            Button("Delete Selected", role: .destructive) {
                deleteSelectedScanItems()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Delete is permanent. Use Quarantine first for safer rollback.")
        }
        .confirmationDialog("Permanently delete latest quarantine?", isPresented: $confirmDeleteLatestQuarantine, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                let outcome = smartScanService.permanentlyDeleteLatestQuarantine()
                processActionResult = outcome.message
                refreshQuarantineBatches()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This cannot be undone.")
        }
        .confirmationDialog("Empty Trash?", isPresented: $confirmEmptyTrash, titleVisibility: .visible) {
            Button("Empty Trash", role: .destructive) {
                processActionResult = smartScanService.emptyTrash().message
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes files currently in your user Trash.")
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Circle()
                        .fill(neonViolet.opacity(0.35))
                        .frame(width: 34, height: 34)
                        .overlay(
                            Image(systemName: "gauge.high")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundStyle(neonBlue)
                        )

                    VStack(alignment: .leading, spacing: 2) {
                        Text("CruiseControl")
                            .font(.system(size: 26, weight: .black, design: .rounded))
                            .foregroundStyle(.white)
                        Text("FLIGHT PERFORMANCE LAB")
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.52))
                    }
                }

                HStack(spacing: 8) {
                    Circle()
                        .fill(sampler.isSimActive ? neonMint : .orange)
                        .frame(width: 8, height: 8)
                    Text(sampler.isSimActive ? "SIM ACTIVE" : "STANDBY")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(sampler.isSimActive ? neonMint : .orange)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.black.opacity(0.22), in: Capsule())
                .overlay(Capsule().stroke((sampler.isSimActive ? neonMint : .orange).opacity(0.55), lineWidth: 1))
            }
            .padding(.top, 8)

            VStack(spacing: 6) {
                ForEach(DashboardSection.allCases) { section in
                    let isActive = (selectedSection ?? .overview) == section

                    Button {
                        selectedSection = section
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: section.icon)
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(isActive ? neonBlue : .white.opacity(0.6))
                                .frame(width: 18)

                            Text(section.title)
                                .font(.system(size: 13, weight: .semibold, design: .rounded))
                                .foregroundStyle(isActive ? .white : .white.opacity(0.72))

                            Spacer()

                            if isActive {
                                Circle()
                                    .fill(neonMint)
                                    .frame(width: 6, height: 6)
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 9)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(isActive ? Color(red: 0.10, green: 0.18, blue: 0.31).opacity(0.92) : Color.clear)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .stroke(isActive ? neonBlue.opacity(0.45) : Color.white.opacity(0.06), lineWidth: 1)
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }

            Spacer(minLength: 8)

            VStack(alignment: .leading, spacing: 8) {
                quickMetric(title: "CPU", value: percentString(sampler.snapshot.cpuTotalPercent))
                quickMetric(title: "Pressure", value: "\(sampler.snapshot.memoryPressure.displayName) \(sampler.snapshot.memoryPressureTrend.icon)")
                quickMetric(title: "UDP", value: sampler.snapshot.udpStatus.state.displayName)
                quickMetric(title: "Regulator", value: settings.governorModeEnabled ? "ON" : "OFF")
            }
            .padding(12)
            .background(Color.black.opacity(0.28), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(neonBlue.opacity(0.28), lineWidth: 1)
            )
        }
        .padding(18)
        .frame(minWidth: 268, maxWidth: 286)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(cardInk.opacity(0.78))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(neonBlue.opacity(0.24), lineWidth: 1)
        )
    }

    @ViewBuilder
    private var detailContent: some View {
        switch selectedSection ?? .overview {
        case .overview:
            overviewSection
        case .smartScan:
            smartScanSection
        case .cleaner:
            cleanerSection
        case .largeFiles:
            largeFilesSection
        case .optimization:
            optimizationSection
        case .quarantine:
            quarantineSection
        case .processes:
            processesSection
        case .simMode:
            simModeSection
        case .history:
            historySection
        case .diagnostics:
            diagnosticsSection
        case .settings:
            preferencesSection
        }
    }

    private var heroBanner: some View {
        HStack(alignment: .top, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Circle()
                        .fill(sampler.isSimActive ? neonMint : .orange)
                        .frame(width: 8, height: 8)
                    Text(sampler.snapshot.udpStatus.state == .active ? "LIVE TELEMETRY" : "WAITING FOR STREAM")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundStyle(sampler.snapshot.udpStatus.state == .active ? neonMint : .orange)
                }

                Text("CruiseControl")
                    .font(.system(size: 40, weight: .black, design: .rounded))
                    .foregroundStyle(.white)
                Text("by Jahrix")
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.68))

                Text("Real-time simulator performance monitoring, regulator controls, and diagnostics tuned for long-haul sessions.")
                    .font(.system(size: 18, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.68))
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()

            VStack(alignment: .leading, spacing: 10) {
                Text("NETWORK STATUS")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.55))
                Text(sampler.snapshot.udpStatus.state == .active ? "All Systems Operational" : "Telemetry Not Locked")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundStyle(sampler.snapshot.udpStatus.state == .active ? neonMint : .orange)

                Text("Packets/sec: \(String(format: "%.1f", sampler.snapshot.udpStatus.packetsPerSecond))")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.72))
                Text("Endpoint: \(sampler.snapshot.udpStatus.listenHost):\(String(sampler.snapshot.udpStatus.listenPort))")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.72))
            }
            .padding(18)
            .frame(maxWidth: 420, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(red: 0.09, green: 0.16, blue: 0.28).opacity(0.9),
                                Color(red: 0.19, green: 0.14, blue: 0.36).opacity(0.8)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(neonBlue.opacity(0.35), lineWidth: 1)
            )
        }
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color.black.opacity(0.24))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(neonMint.opacity(0.2), lineWidth: 1)
        )
    }

    private var overviewSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            dashboardCard(title: "Session Overview") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text(sampler.isSimActive ? "X-Plane detected" : "Waiting for simulator")
                            .font(.title3)
                            .fontWeight(.semibold)
                        Spacer()
                        udpStateBadge(sampler.snapshot.udpStatus.state)
                    }

                    Text("Listening on \(sampler.snapshot.udpStatus.listenHost):\(String(sampler.snapshot.udpStatus.listenPort))")
                        .font(.subheadline)
                    Text("Last packet received: \(lastPacketText)")
                        .font(.subheadline)
                    Text("Packets/sec: \(String(format: "%.1f", sampler.snapshot.udpStatus.packetsPerSecond))")
                        .font(.subheadline)
                    Text("X-Plane detected: \(sampler.isSimActive ? "Yes" : "No")")
                        .font(.subheadline)

                    if let telemetry = sampler.snapshot.xplaneTelemetry {
                        HStack(spacing: 12) {
                            if let fps = telemetry.fps {
                                metricPill(label: "Sim FPS", value: String(format: "%.1f", fps))
                            }
                            if let frameTime = telemetry.frameTimeMS {
                                metricPill(label: "Frame Time", value: String(format: "%.2f ms", frameTime))
                            }
                            if let agl = telemetry.altitudeAGLFeet {
                                metricPill(label: "AGL", value: String(format: "%.0f ft", agl))
                            } else if let msl = telemetry.altitudeMSLFeet {
                                metricPill(label: "MSL", value: String(format: "%.0f ft", msl))
                            }
                            metricPill(label: "Bound", value: simBoundHeuristic())
                        }
                    }

                    Text(sampler.snapshot.governorStatusLine)
                        .font(.subheadline)
                        .foregroundStyle(settings.governorModeEnabled ? .green : .secondary)

                    if let detail = sampler.snapshot.udpStatus.detail {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(sampler.snapshot.udpStatus.state == .misconfig ? .orange : .secondary)
                    }
                }
            }


            dashboardCard(title: "Connection Wizard") {
                VStack(alignment: .leading, spacing: 8) {
                    wizardStep(title: "1) X-Plane running", good: sampler.isSimActive, detail: sampler.isSimActive ? "Detected" : "Not detected")
                    wizardStep(
                        title: "2) Telemetry",
                        good: sampler.snapshot.udpStatus.state == .active || sampler.snapshot.udpStatus.state == .listening,
                        detail: "\(sampler.snapshot.udpStatus.state.displayName) | \(telemetryFreshnessText) | \(String(format: "%.1f", sampler.snapshot.udpStatus.packetsPerSecond)) pkt/s"
                    )
                    wizardStep(
                        title: "3) Control Bridge",
                        good: regulatorBridgeConnected,
                        detail: regulatorControlWizardDetail
                    )
                    wizardStep(
                        title: "4) ACK",
                        good: regulatorAckWizardHealthy,
                        detail: regulatorAckWizardDetail
                    )

                    HStack {
                        Button("Copy 127.0.0.1:\(String(settings.xPlaneUDPPort))") {
                            copyToClipboard("127.0.0.1:\(String(settings.xPlaneUDPPort))")
                            processActionResult = "Copied telemetry endpoint."
                        }
                        .buttonStyle(.bordered)

                        Button("Copy Lua listen port") {
                            copyToClipboard(String(settings.governorCommandPort))
                            processActionResult = "Copied Lua listen port."
                        }
                        .buttonStyle(.bordered)

                        Button("Test PING") {
                            let outcome = sampler.sendGovernorPing()
                            processActionResult = outcome.message
                        }
                        .buttonStyle(.borderedProminent)

                        Button("Open Bridge Folder in Finder") {
                            let outcome = sampler.openRegulatorBridgeFolderInFinder()
                            processActionResult = outcome.message
                        }
                        .buttonStyle(.bordered)
                    }

                    Text("Install Lua script in X-Plane 11/12/Resources/plugins/FlyWithLua/Scripts/")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            dashboardCard(title: "Regulator Proof") {
                let proof = sampler.computeProofState(now: now)
                let fpsTestValue = sampler.proposedRegulatorTestLOD(increase: true, step: regulatorTestStepUp)
                let visualTestValue = sampler.proposedRegulatorTestLOD(increase: false, step: regulatorTestStepDown)
                let testDuration = max(Int(regulatorTestDurationSeconds.rounded()), 1)

                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("LOD APPLIED: \(proof.lodApplied ? "YES" : "NO")")
                            .font(.headline)
                            .foregroundStyle(proof.lodApplied ? .green : .orange)
                        Spacer()
                        let targetStateText = proof.deltaToTarget.map {
                            proof.onTarget ? "On target" : "Off target (Δ \(String(format: "%.3f", $0)))"
                        } ?? "No target delta"
                        Text(targetStateText)
                            .font(.caption)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background((proof.onTarget ? Color.green : Color.orange).opacity(0.15), in: Capsule())
                    }

                    HStack {
                        Text("RECENT ACTIVITY: \(proof.recentActivity ? "YES" : "NO")")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(proof.recentActivity ? .green : .secondary)
                        Spacer()
                        Text("Bridge: \(proof.bridgeModeLabel)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if !proof.recentActivity {
                        Text("Stable target; no recent writes needed.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Text("Last send: \(proof.lastSentAt.map(relativeAgeText(from:)) ?? "Never")")
                        .font(.subheadline)
                    Text("Last evidence: \(proof.lastEvidenceAt.map(relativeAgeText(from:)) ?? "None")")
                        .font(.subheadline)
                    Text("Target: \(proof.targetLOD.map { String(format: "%.2f", $0) } ?? "-") | Applied: \(proof.appliedLOD.map { String(format: "%.2f", $0) } ?? "-") | Δ: \(proof.deltaToTarget.map { String(format: "%.3f", $0) } ?? "-")")
                        .font(.subheadline)

                    if let evidence = proof.evidenceLine, !evidence.isEmpty {
                        Text("Evidence: \(evidence)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Evidence: No confirmation available")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if !proof.hasSimData {
                        Text("No sim data. Last session target/applied: \(proof.lastSessionTargetLOD.map { String(format: "%.2f", $0) } ?? "-") / \(proof.lastSessionAppliedLOD.map { String(format: "%.2f", $0) } ?? "-") at \(proof.lastSessionAt.map(relativeAgeText(from:)) ?? "unknown")")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Why not changing?")
                            .font(.headline)
                        if proof.reasons.isEmpty {
                            Text("No blockers detected.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(Array(proof.reasons.prefix(5)), id: \.self) { reason in
                                Text("- \(reason)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    HStack {
                        Text("Test step FPS +")
                        TextField("0.60", value: $regulatorTestStepUp, formatter: decimalFormatter)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 70)
                        Text("Visual -")
                        TextField("0.80", value: $regulatorTestStepDown, formatter: decimalFormatter)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 70)
                        Text("Duration")
                        TextField("10", value: $regulatorTestDurationSeconds, formatter: decimalFormatter)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 60)
                        Text("s")
                    }
                    .font(.caption)

                    HStack {
                        Button("Open Bridge Folder in Finder") {
                            let outcome = sampler.openRegulatorBridgeFolderInFinder()
                            processActionResult = outcome.message
                        }
                        .buttonStyle(.bordered)

                        Button("Test: Shorter draw distance (More FPS)") {
                            let outcome = sampler.runRegulatorRelativeTimedTest(
                                increase: true,
                                step: max(regulatorTestStepUp, 0),
                                modeLabel: "More FPS (shorter draw distance)",
                                durationSeconds: TimeInterval(testDuration)
                            )
                            processActionResult = outcome.message
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(sampler.regulatorTestActive)

                        Button("Test: Longer draw distance (More visuals)") {
                            let outcome = sampler.runRegulatorRelativeTimedTest(
                                increase: false,
                                step: max(regulatorTestStepDown, 0),
                                modeLabel: "More visuals (longer draw distance)",
                                durationSeconds: TimeInterval(testDuration)
                            )
                            processActionResult = outcome.message
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(sampler.regulatorTestActive)
                    }

                    Text("Will apply \(String(format: "%.2f", fpsTestValue)) for \(testDuration)s (FPS) or \(String(format: "%.2f", visualTestValue)) for \(testDuration)s (visuals).")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if sampler.regulatorTestActive {
                        Text("Test running... \(sampler.regulatorTestCountdownSeconds)s")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }

                    if !sampler.regulatorTierEvents.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Tier events")
                                .font(.headline)
                            ForEach(Array(sampler.regulatorTierEvents.suffix(10).reversed())) { action in
                                Text("\(timeOnly(action.timestamp))  -  \(action.message)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }

            dashboardCard(title: "X-Plane UDP Setup") {
                DisclosureGroup(isExpanded: $showUDPSetupGuide) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("1) X-Plane > Settings > Data Output")
                        Text("2) Check Send network data output")
                        Text("3) Set IP to 127.0.0.1")
                        Text("4) Set Port to \(String(settings.xPlaneUDPPort))")
                        Text("5) Enable Data Set 0 (frame-rate) and Data Set 20 (position/altitude)")

                        HStack {
                            Text("Setup line: 127.0.0.1:\(String(settings.xPlaneUDPPort))")
                                .font(.caption)
                            Spacer()
                            Button("Copy setup line") {
                                let line = "127.0.0.1:\(String(settings.xPlaneUDPPort))"
                                copyToClipboard(line)
                                diagnosticsExportResult = "Copied \(line)"
                            }
                            .buttonStyle(.bordered)
                        }
                        .padding(.top, 6)
                    }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                } label: {
                    Text("How to enable X-Plane UDP output")
                        .font(.headline)
                }
            }

            let columns = [
                GridItem(.flexible(minimum: 150)),
                GridItem(.flexible(minimum: 150)),
                GridItem(.flexible(minimum: 150))
            ]

            LazyVGrid(columns: columns, spacing: 12) {
                statTile("CPU Total", percentString(sampler.snapshot.cpuTotalPercent), color: .blue)
                statTile("Memory", "\(sampler.snapshot.memoryPressure.displayName) \(sampler.snapshot.memoryPressureTrend.icon)", color: color(for: sampler.snapshot.memoryPressure))
                statTile("Swap delta 5m", deltaByteString(sampler.snapshot.swapDelta5MinBytes), color: .orange)
                statTile("Disk Read", String(format: "%.1f MB/s", sampler.snapshot.diskReadMBps), color: .teal)
                statTile("Disk Write", String(format: "%.1f MB/s", sampler.snapshot.diskWriteMBps), color: .teal)
                statTile("Thermal", PerformanceSampler.thermalStateDescription(sampler.snapshot.thermalState), color: (sampler.snapshot.thermalState == .serious || sampler.snapshot.thermalState == .critical) ? .red : .green)
            }

            dashboardCard(title: "Memory Pressure Relief") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Pressure: \(sampler.snapshot.memoryPressure.displayName) \(sampler.snapshot.memoryPressureTrend.icon)")
                    Text("Swap: \(byteCountString(sampler.snapshot.swapUsedBytes))  -  delta5m: \(deltaByteString(sampler.snapshot.swapDelta5MinBytes))")
                    Text("Compressed: \(byteCountString(sampler.snapshot.compressedMemoryBytes))")
                        .foregroundStyle(.secondary)

                    let suggestions = sampler
                        .memoryReliefSuggestions(maxCount: 6)
                        .filter { !featureStore.isProcessAllowlisted($0.name) }
                        .prefix(3)
                    if suggestions.isEmpty {
                        Text("No immediate memory-relief suggestions.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Relief suggestions")
                            .font(.headline)
                        ForEach(suggestions) { process in
                            Toggle(
                                "\(process.name) (\(byteCountString(process.memoryBytes)))",
                                isOn: reliefSelectionBinding(pid: process.pid)
                            )
                            .toggleStyle(.checkbox)
                        }

                        HStack {
                            Button("Close selected apps") {
                                confirmCloseSelectedApps = true
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(selectedReliefPIDs.isEmpty)

                            Button("Run limited purge attempt") {
                                runLimitedPurgeAttempt()
                            }
                            .buttonStyle(.bordered)
                        }

                        Toggle("Pause CruiseControl background scans while sim is active", isOn: $featureStore.pauseBackgroundScansDuringSim)

                        HStack {
                            Button("Run Cleaner recommendations") {
                                selectedSection = .cleaner
                                scanCleanerModule()
                            }
                            .buttonStyle(.bordered)

                            Button("Large Files: Downloads") {
                                setLargeFileQuickScope(.downloadsDirectory)
                                selectedSection = .largeFiles
                                scanLargeFilesModule()
                            }
                            .buttonStyle(.bordered)
                        }

                        Text("Limited purge only clears CruiseControl local caches and pauses internal work briefly. It does not purge protected system caches.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            dashboardCard(title: "Warnings") {
                if sampler.warnings.isEmpty {
                    Text("No immediate pressure warnings.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(sampler.warnings, id: \.self) { warning in
                            Text(warning)
                                .font(.subheadline)
                                .foregroundStyle(colorForWarning(warning))
                        }
                    }
                }
            }

            dashboardCard(title: "What's Hurting Performance") {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(sampler.culprits.enumerated()), id: \.offset) { item in
                        Text("\(item.offset + 1). \(item.element)")
                            .font(.subheadline)
                    }
                }
            }
        }
    }

    private var processesSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            dashboardCard(title: "Top CPU Processes") {
                processList(processes: sampler.topCPUProcesses)
            }

            dashboardCard(title: "Top Memory Processes") {
                processList(processes: sampler.topMemoryProcesses)
            }
        }
    }

    private func processList(processes: [ProcessSample]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if processes.isEmpty {
                Text("No process sample yet.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(processes) { process in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("\(process.name) (PID \(process.pid))")
                                .font(.headline)
                            Spacer()
                            Text(timeOnly(process.sampledAt))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Text("CPU \(percentString(process.cpuPercent))  -  RAM \(byteCountString(process.memoryBytes))")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)

                        HStack(spacing: 10) {
                            Button("Show in Activity Monitor") {
                                let outcome = settings.openInActivityMonitor(process: process)
                                processActionResult = outcome.message
                            }
                            .buttonStyle(.bordered)

                            Button("Quit") {
                                runProcessAction(process: process, force: false)
                            }
                            .buttonStyle(.bordered)

                            Button("Force Quit") {
                                forceQuitCandidate = process
                            }
                            .buttonStyle(.bordered)
                            .tint(.red)
                        }
                    }
                    .padding(10)
                    .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
            }
        }
    }

    private var simModeSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            dashboardCard(title: "LOD Regulator") {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle("Enable LOD Regulator", isOn: $settings.governorModeEnabled)

                    HStack(spacing: 12) {
                        metricPill(label: "AGL", value: sampler.governorActiveAGLFeet.map { String(format: "%.0f ft", $0) } ?? "AGL unavailable")
                        metricPill(label: "Tier", value: sampler.governorCurrentTier?.rawValue ?? "Paused")
                        metricPill(label: "Target", value: sampler.governorCurrentTargetLOD.map { String(format: "%.2f", $0) } ?? "-")
                        metricPill(label: "Ramp", value: sampler.governorSmoothedTargetLOD.map { String(format: "%.2f", $0) } ?? "-")
                        metricPill(label: "Last Sent", value: sampler.governorLastSentLOD.map { String(format: "%.2f", $0) } ?? "-")
                    }


                    Text("Control state: \(regulatorControlStateBadge)")
                        .font(.subheadline)
                        .foregroundStyle(regulatorBridgeConnected ? .green : .orange)
                    if case .udpAckOK(_, let payload) = sampler.regulatorControlState {
                        Text("Last ACK: \(payload)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else if case .fileBridge = sampler.regulatorControlState {
                        Text("ACK not used in file bridge mode.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text("Command status: \(sampler.governorCommandStatus)")
                        .font(.subheadline)
                        .foregroundStyle(regulatorBridgeConnected ? .green : .orange)
                    if let pauseReason = sampler.governorPauseReason {
                        Text(pauseReason)
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }

                    Text("Altitude thresholds (feet AGL)")
                        .font(.headline)
                    Toggle("Use MSL if AGL unavailable", isOn: $settings.governorUseMSLFallbackWhenAGLUnavailable)
                    sliderRow(label: "GROUND upper (ft)", value: $settings.governorGroundMaxAGLFeet, range: 500...5000, step: 100)
                    sliderRow(label: "CRUISE lower (ft)", value: $settings.governorCruiseMinAGLFeet, range: 6000...45000, step: 250)

                    Text("Per-tier LOD targets")
                        .font(.headline)
                    Text("LOD bias: higher = shorter draw distance (more FPS), lower = longer draw distance (more visuals).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    sliderRow(label: "GROUND target (higher = more FPS)", value: $settings.governorTargetLODGround, range: 0.20...3.00, step: 0.05)
                    sliderRow(label: "TRANSITION target (higher = more FPS)", value: $settings.governorTargetLODClimbDescent, range: 0.20...3.00, step: 0.05)
                    sliderRow(label: "CRUISE target (higher = more FPS)", value: $settings.governorTargetLODCruise, range: 0.20...3.00, step: 0.05)

                    Text("Safety clamps")
                        .font(.headline)
                    sliderRow(label: "Min LOD bias (visual floor)", value: $settings.governorLODMinClamp, range: 0.20...2.00, step: 0.05)
                    sliderRow(label: "Max LOD bias (FPS ceiling)", value: $settings.governorLODMaxClamp, range: 0.50...3.00, step: 0.05)

                    Text("Regulator behavior")
                        .font(.headline)
                    sliderRow(label: "Min time in tier (s)", value: $settings.governorMinimumTierHoldSeconds, range: 0...30, step: 1)
                    sliderRow(label: "Ramp duration (s)", value: $settings.governorSmoothingDurationSeconds, range: 0.5...12, step: 0.5)
                    sliderRow(label: "Command interval (s)", value: $settings.governorMinimumCommandIntervalSeconds, range: 0.1...3.0, step: 0.1)
                    sliderRow(label: "Min send delta", value: $settings.governorMinimumCommandDelta, range: 0.01...0.30, step: 0.01)
                    Text("Regulator config changes are debounced: command updates apply after 0.5s without further slider movement.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    HStack {
                        Text("Bridge Host")
                        TextField("127.0.0.1", text: $governorHostText)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 130)
                        Text("Port")
                        TextField("49006", text: $governorPortText)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 90)
                        Button("Apply") {
                            applyGovernorBridgeEndpoint()
                        }
                        .buttonStyle(.bordered)

                        Button("Test PING") {
                            let outcome = sampler.sendGovernorPing()
                            processActionResult = outcome.message
                        }
                        .buttonStyle(.bordered)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        let fpsTestValue = sampler.proposedRegulatorTestLOD(increase: true, step: max(regulatorTestStepUp, 0))
                        let visualTestValue = sampler.proposedRegulatorTestLOD(increase: false, step: max(regulatorTestStepDown, 0))
                        let testDuration = max(Int(regulatorTestDurationSeconds.rounded()), 1)

                        HStack {
                            Button("Test: Shorter draw distance (More FPS)") {
                                let outcome = sampler.runRegulatorRelativeTimedTest(
                                    increase: true,
                                    step: max(regulatorTestStepUp, 0),
                                    modeLabel: "More FPS (shorter draw distance)",
                                    durationSeconds: TimeInterval(testDuration)
                                )
                                processActionResult = outcome.message
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(sampler.regulatorTestActive)

                            Button("Test: Longer draw distance (More visuals)") {
                                let outcome = sampler.runRegulatorRelativeTimedTest(
                                    increase: false,
                                    step: max(regulatorTestStepDown, 0),
                                    modeLabel: "More visuals (longer draw distance)",
                                    durationSeconds: TimeInterval(testDuration)
                                )
                                processActionResult = outcome.message
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(sampler.regulatorTestActive)
                        }

                        Text("Will apply \(String(format: "%.2f", fpsTestValue)) for \(testDuration)s (FPS) or \(String(format: "%.2f", visualTestValue)) for \(testDuration)s (visuals).")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        HStack {
                            Text("Manual test LOD")
                            TextField("1.00", text: $governorTestLODText)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 90)
                            Button("Send once") {
                                guard let lod = Double(governorTestLODText) else {
                                    processActionResult = "Invalid LOD test value. Use a number like 0.95 or 1.25."
                                    return
                                }
                                let outcome = sampler.sendGovernorTestCommand(lodValue: lod)
                                processActionResult = outcome.message
                            }
                            .buttonStyle(.bordered)
                            .disabled(sampler.regulatorTestActive)
                        }

                        if sampler.regulatorTestActive {
                            Text("Test running... \(sampler.regulatorTestCountdownSeconds)s")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }

                    Text(sampler.snapshot.governorStatusLine)
                        .font(.subheadline)
                        .foregroundStyle(settings.governorModeEnabled ? .green : .secondary)
                }
            }

            dashboardCard(title: "Per-Airport Regulator Profiles") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Active ICAO source: \(resolvedActiveICAO)")
                        .font(.subheadline)
                    HStack {
                        Text("Manual ICAO")
                        TextField("e.g. KATL", text: $featureStore.manualAirportICAO)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 120)
                    }

                    if !featureStore.airportProfiles.isEmpty {
                        Picker("Profile", selection: $selectedAirportProfileICAO) {
                            ForEach(featureStore.airportProfiles) { profile in
                                Text("\(profile.icao) - \(profile.name)").tag(profile.icao)
                            }
                        }
                    }

                    HStack {
                        TextField("ICAO", text: $selectedAirportProfileICAO)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 100)
                        TextField("Profile name", text: $airportProfileName)
                            .textFieldStyle(.roundedBorder)
                            .frame(minWidth: 180)
                    }

                    sliderRow(label: "GROUND upper (ft)", value: $airportGroundMax, range: 500...5000, step: 100)
                    sliderRow(label: "CRUISE lower (ft)", value: $airportCruiseMin, range: 6000...45000, step: 250)
                    sliderRow(label: "GROUND LOD", value: $airportTargetGround, range: 0.20...3.00, step: 0.05)
                    sliderRow(label: "TRANSITION LOD", value: $airportTargetTransition, range: 0.20...3.00, step: 0.05)
                    sliderRow(label: "CRUISE LOD", value: $airportTargetCruise, range: 0.20...3.00, step: 0.05)
                    sliderRow(label: "Min clamp", value: $airportClampMin, range: 0.20...2.00, step: 0.05)
                    sliderRow(label: "Max clamp", value: $airportClampMax, range: 0.50...3.00, step: 0.05)

                    HStack {
                        Button("Save / Update Profile") {
                            saveAirportProfileFromEditor()
                        }
                        .buttonStyle(.borderedProminent)

                        Button("Delete") {
                            let normalized = AirportGovernorProfile.normalizeICAO(selectedAirportProfileICAO)
                            featureStore.deleteAirportProfile(icao: normalized)
                            processActionResult = "Deleted airport profile \(normalized)."
                        }
                        .buttonStyle(.bordered)
                    }

                    HStack {
                        Button("Export Profiles JSON") {
                            let outcome = featureStore.exportAirportProfiles()
                            processActionResult = outcome.message
                        }
                        .buttonStyle(.bordered)

                        Button("Import Profiles JSON") {
                            let outcome = featureStore.importAirportProfiles(from: airportImportJSONText)
                            processActionResult = outcome.message
                        }
                        .buttonStyle(.bordered)
                    }

                    TextEditor(text: $airportImportJSONText)
                        .font(.system(size: 11, weight: .regular, design: .monospaced))
                        .frame(minHeight: 120)
                        .scrollContentBackground(.hidden)
                        .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
            }

            dashboardCard(title: "Setup FlyWithLua Companion") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Install to: X-Plane 11/12/Resources/plugins/FlyWithLua/Scripts/")
                    Text("Companion regulator bridge listens on \(settings.governorCommandHost):\(String(settings.governorCommandPort)) and applies sim/private/controls/reno/LOD_bias_rat.")
                    Text("ACK protocol: PING/PONG, ACK ENABLE, ACK DISABLE, ACK SET_LOD <value>, ERR <message>.")
                    Text("If LuaSocket is missing, CruiseControl writes fallback commands to ~/Library/Application Support/CruiseControl/lod_target.txt and lod_mode.txt.")
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }

            dashboardCard(title: "Sim Mode Profiles") {
                VStack(alignment: .leading, spacing: 12) {
                    Picker("Profile", selection: $settings.selectedProfile) {
                        ForEach(SimModeProfileType.allCases) { profile in
                            Text(profile.displayName).tag(profile)
                        }
                    }
                    .pickerStyle(.segmented)

                    Toggle("Auto-enable when X-Plane launches", isOn: Binding(
                        get: { settings.shouldAutoEnableForSelectedProfile() },
                        set: { settings.updateAutoEnableForSelectedProfile($0) }
                    ))

                    TextField("Allowlist bundle IDs", text: $allowlistText)
                        .textFieldStyle(.roundedBorder)
                    TextField("Blocklist bundle IDs", text: $blocklistText)
                        .textFieldStyle(.roundedBorder)
                    TextField("Do-not-touch bundle IDs", text: $doNotTouchText)
                        .textFieldStyle(.roundedBorder)

                    HStack {
                        Button("Save Profile Lists") {
                            saveProfileLists()
                        }
                        .buttonStyle(.bordered)

                        Button("Refresh Running Apps") {
                            refreshRunningApps()
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }

            dashboardCard(title: "Sim Mode Actions") {
                VStack(alignment: .leading, spacing: 10) {
                    if settings.isSimModeEnabled {
                        Text("Sim Mode currently enabled")
                            .foregroundStyle(.green)
                        Button("Revert Sim Mode") {
                            lastActionReport = settings.revertSimMode()
                        }
                        .buttonStyle(.borderedProminent)
                    } else {
                        Button("Enable Sim Mode") {
                            refreshRunningApps()
                            showSimModeChecklist.toggle()
                        }
                        .buttonStyle(.borderedProminent)
                    }

                    if showSimModeChecklist {
                        simModeChecklist
                    }
                }
            }
        }
    }

    private func sliderRow(label: String, value: Binding<Double>, range: ClosedRange<Double>, step: Double) -> some View {
        HStack {
            Text(label)
                .frame(width: 170, alignment: .leading)
            Slider(value: value, in: range, step: step)
            Text(String(format: step < 1 ? "%.2f" : "%.0f", value.wrappedValue))
                .frame(width: 58, alignment: .trailing)
        }
    }

    private var simModeChecklist: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Quit selected background apps", isOn: $settings.quitSelectedApps)

            if settings.quitSelectedApps {
                if availableApps.isEmpty {
                    Text("No regular background apps detected.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(availableApps) { app in
                        Toggle(app.name, isOn: bindingForAppSelection(bundleID: app.id))
                            .font(.caption)
                    }
                }
            }

            Toggle("Show iCloud Drive guidance", isOn: $settings.showICloudGuidance)
            Toggle("Show Low Power Mode guidance", isOn: $settings.showLowPowerGuidance)
            Toggle("Show Focus guidance", isOn: $settings.showFocusGuidance)

            HStack {
                Button("Apply") {
                    saveProfileLists()
                    lastActionReport = settings.enableSimMode(trigger: "Manual")
                    showSimModeChecklist = false
                }
                .buttonStyle(.borderedProminent)

                Button("Cancel") {
                    showSimModeChecklist = false
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(12)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var historySection: some View {
        VStack(alignment: .leading, spacing: 16) {
            dashboardCard(title: "Mini History") {
                VStack(alignment: .leading, spacing: 10) {
                    Picker("Duration", selection: $featureStore.historyDuration) {
                        ForEach(HistoryDurationOption.allCases) { option in
                            Text(option.rawValue).tag(option)
                        }
                    }
                    .pickerStyle(.segmented)

                    let points = sampler.historyPoints(for: featureStore.historyDuration)

                    historyChartRow(
                        title: "CPU %",
                        values: points.map { $0.cpuTotalPercent },
                        color: .blue
                    )

                    historyChartRow(
                        title: "Swap Used",
                        values: points.map { Double($0.swapUsedBytes) / 1_073_741_824.0 },
                        color: .orange,
                        suffix: "GB"
                    )

                    historyChartRow(
                        title: "Disk Read",
                        values: points.map { $0.diskReadMBps },
                        color: .teal,
                        suffix: "MB/s"
                    )

                    historyChartRow(
                        title: "Disk Write",
                        values: points.map { $0.diskWriteMBps },
                        color: .cyan,
                        suffix: "MB/s"
                    )

                    historyChartRow(
                        title: "Regulator ACK",
                        values: points.map { $0.governorAckState.score },
                        color: .green
                    )
                }
            }

            dashboardCard(title: "Recent Samples") {
                let points = Array(sampler.historyPoints(for: featureStore.historyDuration).suffix(50).reversed())
                if points.isEmpty {
                    Text("No history yet.")
                        .foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(points) { point in
                            Text("\(timeOnly(point.timestamp))  -  CPU \(percentString(point.cpuTotalPercent))  -  Swap \(byteCountString(point.swapUsedBytes))  -  \(point.memoryPressure.displayName)")
                                .font(.caption)
                        }
                    }
                }
            }
        }
    }

    private func historyChartRow(title: String, values: [Double], color: Color, suffix: String = "") -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                    .font(.subheadline)
                Spacer()
                if let last = values.last {
                    Text(suffix.isEmpty ? String(format: "%.2f", last) : String(format: "%.2f %@", last, suffix))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            SparklineView(values: values, color: color)
                .frame(height: 36)
        }
    }

    private var diagnosticsSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            dashboardCard(title: "Diagnostics Export") {
                VStack(alignment: .leading, spacing: 10) {
                    Button("Export Diagnostics") {
                        let outcome = sampler.exportDiagnostics()
                        diagnosticsExportResult = outcome.message
                    }
                    .buttonStyle(.borderedProminent)

                    Text("Snapshot includes metrics, warnings, top processes, recent history, stutter events, UDP state, and regulator control status.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            dashboardCard(title: "Stutter Detective") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Heuristics")
                        .font(.headline)
                    sliderRow(label: "Frame-time spike (ms)", value: Binding(
                        get: { featureStore.stutterHeuristics.frameTimeSpikeMS },
                        set: { featureStore.stutterHeuristics.frameTimeSpikeMS = $0 }
                    ), range: 20...100, step: 1)
                    sliderRow(label: "FPS drop threshold", value: Binding(
                        get: { featureStore.stutterHeuristics.fpsDropThreshold },
                        set: { featureStore.stutterHeuristics.fpsDropThreshold = $0 }
                    ), range: 5...40, step: 1)
                    sliderRow(label: "CPU spike %", value: Binding(
                        get: { featureStore.stutterHeuristics.cpuSpikePercent },
                        set: { featureStore.stutterHeuristics.cpuSpikePercent = $0 }
                    ), range: 5...60, step: 1)
                    sliderRow(label: "Disk spike MB/s", value: Binding(
                        get: { featureStore.stutterHeuristics.diskSpikeMBps },
                        set: { featureStore.stutterHeuristics.diskSpikeMBps = $0 }
                    ), range: 40...400, step: 5)

                    if sampler.stutterEvents.isEmpty {
                        Text("No stutter events detected yet.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(Array(sampler.stutterEvents.suffix(8).reversed())) { event in
                            VStack(alignment: .leading, spacing: 3) {
                                Text("\(timeOnly(event.timestamp))  -  \(event.reason)")
                                    .font(.subheadline)
                                Text("Top culprits: \(event.rankedCulprits.joined(separator: " > "))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
            }
        }
    }


    private var smartScanSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            dashboardCard(title: "Smart Scan") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Runs System Junk, Trash, Large Files, and Optimization scans in parallel.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    Toggle("Include privacy data scan (user profile only)", isOn: $smartScanIncludePrivacy)
                    Toggle("Advanced mode (allow quarantine outside safe defaults)", isOn: $featureStore.advancedModeEnabled)
                    Toggle("Extra confirmation for advanced-mode destructive actions", isOn: $featureStore.advancedModeExtraConfirmation)

                    HStack {
                        Button("Pick Large Files Folder") {
                            pickLargeFileFolder()
                        }
                        .buttonStyle(.bordered)

                        Button(smartScanRunState.isRunning ? "Scanning..." : "Scan") {
                            runSmartScan()
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(smartScanRunState.isRunning)

                        if smartScanRunState.isRunning {
                            Button("Cancel") {
                                smartScanTask?.cancel()
                            }
                            .buttonStyle(.bordered)
                        }
                    }

                    if !smartScanRoots.isEmpty {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(smartScanRoots, id: \.path) { root in
                                Text("Large file scope: \(root.path)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    } else {
                        Text("Large Files scope required: pick one or more folders.")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }

                    ProgressView(value: smartScanRunState.overallProgress)
                    Text("Overall progress: \(Int((smartScanRunState.overallProgress * 100).rounded()))%")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    ForEach(SmartScanModule.allCases) { module in
                        if let progress = smartScanRunState.moduleProgress[module] {
                            HStack {
                                Text(module.rawValue)
                                    .font(.caption)
                                Spacer()
                                Text("\(Int((progress * 100).rounded()))%")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    if let summary = smartScanSummary {
                        Text("Found \(summary.items.count) items, total \(byteCountString(summary.totalBytes)).")
                            .font(.subheadline)

                        ForEach(Array(summary.moduleResults.enumerated()), id: \.offset) { _, module in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text(module.module.rawValue)
                                        .font(.headline)
                                    Spacer()
                                    Text(byteCountString(module.bytes))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }

                                Text(module.error ?? "\(module.items.count) item(s)")
                                    .font(.caption)
                                    .foregroundStyle(module.error == nil ? Color.secondary : Color.orange)

                                HStack {
                                    Button("Review Items") {
                                        deepLinkToModule(module.module)
                                    }
                                    .buttonStyle(.bordered)
                                }
                            }
                            .padding(.vertical, 4)
                        }

                        HStack {
                            Button("Run Clean") {
                                selectedSmartScanItemIDs = Set(summary.items.filter { $0.safeByDefault }.map(\.id))
                                confirmQuarantineSelection = true
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(summary.items.isEmpty)

                            Button("Review Quarantine") {
                                refreshQuarantineBatches()
                                selectedSection = .quarantine
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                }
            }
        }
    }

    private var cleanerSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            dashboardCard(title: "Cleaner") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Safe targets only: ~/Library/Caches, ~/Library/Logs, ~/Library/Application Support/CruiseControl, optional Saved Application State.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text("Caches may regenerate. Cleaning helps reduce pressure but is not a permanent speed hack.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    HStack {
                        Button(cleanerLoading ? "Scanning..." : "Scan Cleaner") {
                            scanCleanerModule()
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(cleanerLoading)

                        Button("Quarantine Selected") {
                            confirmQuarantineSelection = true
                        }
                        .buttonStyle(.bordered)
                        .disabled(selectedCleanerItems.isEmpty)

                        Button("Delete Selected") {
                            confirmDeleteSelection = true
                        }
                        .buttonStyle(.bordered)
                        .tint(.red)
                        .disabled(selectedCleanerItems.isEmpty)
                    }

                    if cleanerItems.isEmpty {
                        Text("No cleaner items loaded yet.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(cleanerItems.prefix(60)) { item in
                            VStack(alignment: .leading, spacing: 4) {
                                Toggle(item.path, isOn: cleanerSelectionBinding(itemID: item.id))
                                    .toggleStyle(.checkbox)
                                Text("\(item.note) • \(byteCountString(item.sizeBytes))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                HStack {
                                    Button("Reveal in Finder") {
                                        smartScanService.revealInFinder(path: item.path)
                                    }
                                    .buttonStyle(.bordered)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
            }

            dashboardCard(title: "Trash Bins") {
                VStack(alignment: .leading, spacing: 10) {
                    let summary = smartScanService.trashSummary()
                    Text("Items: \(summary.count) • Size: \(byteCountString(summary.sizeBytes))")

                    HStack {
                        Button("Open Trash in Finder") {
                            smartScanService.openTrashInFinder()
                        }
                        .buttonStyle(.bordered)

                        Button("Empty Trash") {
                            confirmEmptyTrash = true
                        }
                        .buttonStyle(.bordered)
                        .tint(.red)
                    }
                }
            }
        }
    }

    private var largeFilesSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            dashboardCard(title: "Large Files") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Scope required: choose folders first. CruiseControl does not scan entire disk by default.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    HStack {
                        Button("Documents") { setLargeFileQuickScope(.documentDirectory) }
                            .buttonStyle(.bordered)
                        Button("Downloads") { setLargeFileQuickScope(.downloadsDirectory) }
                            .buttonStyle(.bordered)
                        Button("Desktop") { setLargeFileQuickScope(.desktopDirectory) }
                            .buttonStyle(.bordered)
                        Button("Pick Folder") { pickLargeFileFolder() }
                            .buttonStyle(.bordered)
                    }

                    HStack {
                        Button(largeFilesLoading ? "Scanning..." : "Scan Large Files") {
                            scanLargeFilesModule()
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(largeFilesLoading || smartScanRoots.isEmpty)

                        Button("Quarantine Selected") {
                            confirmQuarantineSelection = true
                        }
                        .buttonStyle(.bordered)
                        .disabled(selectedLargeFileItems.isEmpty)

                        Button("Delete Selected") {
                            confirmDeleteSelection = true
                        }
                        .buttonStyle(.bordered)
                        .tint(.red)
                        .disabled(selectedLargeFileItems.isEmpty)
                    }

                    if smartScanRoots.isEmpty {
                        Text("No scope selected yet.")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    } else {
                        ForEach(smartScanRoots, id: \.path) { root in
                            Text(root.path)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    ForEach(largeFileItems.prefix(featureStore.largeFilesTopN)) { item in
                        VStack(alignment: .leading, spacing: 4) {
                            Toggle(item.path, isOn: largeFilesSelectionBinding(itemID: item.id))
                                .toggleStyle(.checkbox)
                            Text("\(byteCountString(item.sizeBytes)) • \(item.note)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Button("Reveal in Finder") {
                                smartScanService.revealInFinder(path: item.path)
                            }
                            .buttonStyle(.bordered)
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
        }
    }

    private var optimizationSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            dashboardCard(title: "Optimization") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("CPU: \(percentString(sampler.snapshot.cpuTotalPercent)) • Memory: \(sampler.snapshot.memoryPressure.displayName) • Swap \(deltaByteString(sampler.snapshot.swapDelta5MinBytes))")
                        .font(.subheadline)

                    let impact = impactProcesses()
                    if impact.isEmpty {
                        Text("No significant background impact process detected.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(impact) { process in
                            VStack(alignment: .leading, spacing: 6) {
                                Text("\(process.name) (PID \(process.pid))")
                                    .font(.headline)
                                Text("CPU \(percentString(process.cpuPercent)) • RAM \(byteCountString(process.memoryBytes))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)

                                HStack {
                                    Button("Quit") {
                                        runProcessAction(process: process, force: false)
                                    }
                                    .buttonStyle(.bordered)

                                    Button("Force Quit") {
                                        forceQuitCandidate = process
                                    }
                                    .buttonStyle(.bordered)
                                    .tint(.red)

                                    Button("Allowlist") {
                                        featureStore.addProcessToAllowlist(process.name)
                                        processActionResult = "Added \(process.name) to Optimization allowlist."
                                    }
                                    .buttonStyle(.bordered)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
            }

            dashboardCard(title: "Allowlist") {
                VStack(alignment: .leading, spacing: 8) {
                    if featureStore.optimizationProcessAllowlist.isEmpty {
                        Text("No allowlisted processes yet.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(featureStore.optimizationProcessAllowlist, id: \.self) { item in
                            HStack {
                                Text(item)
                                Spacer()
                                Button("Remove") {
                                    featureStore.removeProcessFromAllowlist(item)
                                }
                                .buttonStyle(.bordered)
                            }
                        }
                    }

                    Button("Open Login Items Settings") {
                        openLoginItemsSettings()
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
    }

    private var quarantineSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            dashboardCard(title: "Quarantine") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Button("Refresh") {
                            refreshQuarantineBatches()
                        }
                        .buttonStyle(.bordered)

                        Button("Restore Latest") {
                            processActionResult = smartScanService.restoreLatestQuarantine().message
                            refreshQuarantineBatches()
                        }
                        .buttonStyle(.bordered)

                        Button("Delete Latest") {
                            confirmDeleteLatestQuarantine = true
                        }
                        .buttonStyle(.bordered)
                        .tint(.red)
                    }

                    if quarantineBatches.isEmpty {
                        Text("No quarantine batches found.")
                            .foregroundStyle(.secondary)
                    } else {
                        Picker("Batch", selection: $selectedQuarantineBatchID) {
                            ForEach(quarantineBatches) { batch in
                                Text("\(batch.batchID) • \(byteCountString(batch.totalBytes))").tag(batch.batchID)
                            }
                        }

                        if let selected = quarantineBatches.first(where: { $0.batchID == selectedQuarantineBatchID }) {
                            Text("Created: \(selected.createdAt.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text("Entries: \(selected.entryCount) • Total: \(byteCountString(selected.totalBytes))")
                                .font(.subheadline)

                            HStack {
                                Button("Restore Batch") {
                                    processActionResult = smartScanService.restoreQuarantineBatch(batchID: selected.batchID).message
                                    refreshQuarantineBatches()
                                }
                                .buttonStyle(.bordered)

                                Button("Delete Batch") {
                                    processActionResult = smartScanService.permanentlyDeleteQuarantineBatch(batchID: selected.batchID).message
                                    refreshQuarantineBatches()
                                }
                                .buttonStyle(.bordered)
                                .tint(.red)
                            }
                        }
                    }

                    Text("Total quarantined size: \(byteCountString(quarantineBatches.reduce(0) { $0 + $1.totalBytes }))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
    private var preferencesSection: some View {
        dashboardCard(title: "Preferences") {
            VStack(alignment: .leading, spacing: 10) {
                Picker("Update Interval", selection: $settings.samplingInterval) {
                    ForEach(SamplingIntervalOption.allCases) { option in
                        Text(option.rawValue).tag(option)
                    }
                }
                .pickerStyle(.segmented)

                HStack {
                    Text("Smoothing Alpha")
                    Slider(value: $settings.smoothingAlpha, in: 0.1...0.9, step: 0.05)
                    Text(String(format: "%.2f", settings.smoothingAlpha))
                        .frame(width: 42)
                }

                Toggle("Listen for X-Plane UDP", isOn: $settings.xPlaneUDPListeningEnabled)
                Toggle("Send warning notifications", isOn: $settings.sendWarningNotifications)
                Toggle("Enable optional limited purge attempt UI", isOn: $featureStore.purgeAttemptEnabled)
                Stepper("Large Files top results: \(featureStore.largeFilesTopN)", value: $featureStore.largeFilesTopN, in: 10...200, step: 5)

                HStack {
                    Text("X-Plane UDP Port")
                    TextField("49005", text: $udpPortText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 100)
                    Button("Apply") {
                        applyUDPPort()
                    }
                    .buttonStyle(.bordered)
                }

                HStack {
                    Button("Show App in Finder") {
                        let outcome = AppMaintenanceService.showAppInFinder()
                        processActionResult = outcome.message
                    }
                    .buttonStyle(.bordered)

                    Button("Open Applications Folder") {
                        let outcome = AppMaintenanceService.openApplicationsFolder()
                        processActionResult = outcome.message
                    }
                    .buttonStyle(.bordered)

                    Button("Install to /Applications") {
                        let outcome = AppMaintenanceService.installToApplications()
                        processActionResult = outcome.message
                    }
                    .buttonStyle(.borderedProminent)

                    Button("Check for Updates...") {
                        Task {
                            let current = AppMaintenanceService.currentVersionString()
                            let outcome = await AppMaintenanceService.checkForUpdatesAndInstall(currentVersion: current)
                            await MainActor.run {
                                updateCheckStatus = outcome.message
                            }
                        }
                    }
                    .buttonStyle(.bordered)

                    Button("Open Releases") {
                        AppMaintenanceService.openReleasesPage()
                    }
                    .buttonStyle(.bordered)
                }

                Text("UDP state: \(sampler.snapshot.udpStatus.state.displayName)")
                Text("Last updated: \(lastUpdatedText)")
                    .foregroundStyle(isStale ? .orange : .secondary)

                Text("CruiseControl performs monitoring and user-approved actions only. It does not control scheduler internals, GPU clocks, kernel paths, or private macOS internals.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func dashboardCard<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.title3)
                .fontWeight(.semibold)
                .foregroundStyle(.white)
            content()
                .foregroundStyle(.white.opacity(0.92))
        }
        .padding(16)
        .background(.ultraThinMaterial.opacity(0.7), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.white.opacity(0.12), lineWidth: 1)
        )
    }

    private func feedbackCard(title: String, text: String) -> some View {
        dashboardCard(title: title) {
            Text(text)
                .font(.subheadline)
        }
    }

    private func wizardStep(title: String, good: Bool, detail: String) -> some View {
        HStack(spacing: 10) {
            Circle()
                .fill(good ? neonMint : neonOrange)
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 2)
    }

    private func metricPill(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label.uppercased())
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.48))
            Text(value)
                .font(.system(size: 17, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.black.opacity(0.3))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(neonViolet.opacity(0.24), lineWidth: 1)
        )
    }

    private func statTile(_ label: String, _ value: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label.uppercased())
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.46))
            Text(value)
                .font(.system(size: 28, weight: .heavy, design: .rounded))
                .foregroundStyle(color)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.black.opacity(0.32))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(color.opacity(0.35), lineWidth: 1)
        )
    }

    private func quickMetric(title: String, value: String) -> some View {
        HStack {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.5))
            Spacer()
            Text(value)
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
        }
    }

    private func udpStateBadge(_ state: XPlaneUDPConnectionState) -> some View {
        let color: Color
        switch state {
        case .idle:
            color = .gray
        case .listening:
            color = neonOrange
        case .active:
            color = neonMint
        case .misconfig:
            color = .red
        }

        return Text(state.displayName.uppercased())
            .font(.system(size: 10, weight: .black, design: .monospaced))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(color.opacity(0.14), in: Capsule())
            .overlay(Capsule().stroke(color.opacity(0.5), lineWidth: 1))
            .foregroundStyle(color)
    }

    private var lastPacketText: String {
        guard let lastPacket = sampler.snapshot.udpStatus.lastPacketDate else {
            return "Never"
        }
        let secondsAgo = Int(now.timeIntervalSince(lastPacket))
        if secondsAgo < 1 {
            return "Just now"
        }
        return "\(secondsAgo)s ago"
    }

    private var telemetryFreshnessText: String {
        guard let lastPacket = sampler.snapshot.udpStatus.lastPacketDate else {
            return "No packets yet"
        }
        return "Last packet \(relativeAgeText(from: lastPacket))"
    }

    private var regulatorBridgeConnected: Bool {
        switch sampler.regulatorControlState {
        case .udpAckOK, .fileBridge:
            return true
        case .udpNoAck, .disconnected:
            return false
        }
    }

    private var regulatorControlWizardDetail: String {
        switch sampler.regulatorControlState {
        case .disconnected:
            return "None"
        case .udpNoAck:
            return "UDP \(settings.governorCommandHost):\(String(settings.governorCommandPort)) (waiting)"
        case .udpAckOK:
            return "UDP \(settings.governorCommandHost):\(String(settings.governorCommandPort))"
        case .fileBridge(let lastUpdate):
            return "File fallback | update \(relativeAgeText(from: lastUpdate))"
        }
    }

    private var regulatorAckWizardHealthy: Bool {
        switch sampler.regulatorControlState {
        case .udpAckOK, .fileBridge:
            return true
        case .udpNoAck, .disconnected:
            return false
        }
    }

    private var regulatorAckWizardDetail: String {
        switch sampler.regulatorControlState {
        case .udpAckOK(let lastAck, let payload):
            return "OK | \(relativeAgeText(from: lastAck)) | \(payload)"
        case .fileBridge(let lastUpdate):
            return "Not configured (expected in file mode) | update \(relativeAgeText(from: lastUpdate))"
        case .udpNoAck:
            return "Waiting for ACK"
        case .disconnected:
            return "Not configured"
        }
    }

    private var regulatorControlStateBadge: String {
        switch sampler.regulatorControlState {
        case .disconnected:
            return "DISCONNECTED"
        case .udpNoAck:
            return "UDP NO ACK"
        case .udpAckOK:
            return "UDP ACK OK"
        case .fileBridge:
            return "FILE BRIDGE"
        }
    }

    private var regulatorAckProofLine: String {
        switch sampler.regulatorControlState {
        case .udpAckOK(let lastAck, let payload):
            return "ACK OK | \(relativeAgeText(from: lastAck)) | \(payload)"
        case .fileBridge(let lastUpdate):
            return "No ACK (file bridge) | Connected | update \(relativeAgeText(from: lastUpdate))"
        case .udpNoAck:
            return "No ACK yet (UDP)"
        case .disconnected:
            return "Bridge not connected"
        }
    }

    private var appliedLODEvidenceLine: String? {
        switch sampler.regulatorControlState {
        case .udpAckOK(_, let payload):
            if let applied = parseAppliedLOD(from: payload) {
                return "UDP ACK applied \(String(format: "%.2f", applied))"
            }
            return payload
        case .fileBridge(let lastUpdate):
            guard let status = sampler.regulatorFileBridgeStatus else {
                return "No ACK (file bridge). Waiting for lod_status.txt updates."
            }

            var parts: [String] = ["File bridge"]
            if let current = status.currentLOD {
                parts.append("current \(String(format: "%.2f", current))")
            }
            if let target = status.targetLOD {
                parts.append("target \(String(format: "%.2f", target))")
            }
            if let tier = status.tier, !tier.isEmpty {
                parts.append("tier \(tier)")
            }
            parts.append("update \(relativeAgeText(from: status.lastUpdateDate ?? lastUpdate))")
            return parts.joined(separator: " | ")
        case .udpNoAck, .disconnected:
            return nil
        }
    }

    private var lastCommandAgeText: String {
        guard let lastCommandDate = sampler.governorLastCommandDate else {
            return "time unknown"
        }
        return relativeAgeText(from: lastCommandDate)
    }

    private func parseAppliedLOD(from payload: String?) -> Double? {
        guard let payload else { return nil }
        let trimmed = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.uppercased().hasPrefix("ACK SET_LOD") else { return nil }
        return trimmed.split(separator: " ").last.flatMap { Double($0) }
    }

    private func relativeAgeText(from date: Date) -> String {
        let secondsAgo = Int(max(now.timeIntervalSince(date), 0))
        if secondsAgo < 1 {
            return "Just now"
        }
        return "\(secondsAgo)s ago"
    }
    private var isStale: Bool {
        sampler.isSamplingStale(at: now)
    }

    private var lastUpdatedText: String {
        guard let lastUpdated = sampler.snapshot.lastUpdated else {
            return "Waiting for first sample"
        }

        let ago = now.timeIntervalSince(lastUpdated)
        if ago < 1 {
            return "Just now"
        }
        return "\(Int(ago))s ago\(isStale ? " (stale)" : "")"
    }

    private var forceQuitBinding: Binding<Bool> {
        Binding(
            get: { forceQuitCandidate != nil },
            set: { newValue in
                if !newValue {
                    forceQuitCandidate = nil
                }
            }
        )
    }

    private var forceQuitMessage: String {
        guard let process = forceQuitCandidate else {
            return ""
        }
        return "Force quit \(process.name) (PID \(process.pid))? Unsaved data can be lost."
    }

    private var resolvedActiveICAO: String {
        if let telemetryICAO = sampler.snapshot.xplaneTelemetry?.nearestAirportICAO,
           !telemetryICAO.isEmpty {
            return telemetryICAO
        }

        let manual = AirportGovernorProfile.normalizeICAO(featureStore.manualAirportICAO)
        return manual.isEmpty ? "N/A" : "\(manual) (manual)"
    }

    private var selectedSmartScanItems: [SmartScanItem] {
        guard let summary = smartScanSummary else { return [] }
        let idSet = selectedSmartScanItemIDs
        return summary.items.filter { idSet.contains($0.id) }
    }

    private var selectedCleanerItems: [SmartScanItem] {
        cleanerItems.filter { selectedCleanerItemIDs.contains($0.id) }
    }

    private var selectedLargeFileItems: [SmartScanItem] {
        largeFileItems.filter { selectedLargeFileItemIDs.contains($0.id) }
    }

    private var selectedOptimizationItems: [SmartScanItem] {
        optimizationItems.filter { selectedOptimizationItemIDs.contains($0.id) }
    }

    private var selectedScanItemsForAction: [SmartScanItem] {
        switch selectedSection ?? .overview {
        case .cleaner:
            return selectedCleanerItems
        case .largeFiles:
            return selectedLargeFileItems
        case .optimization:
            return selectedOptimizationItems
        default:
            return selectedSmartScanItems
        }
    }

    private func runProcessAction(process: ProcessSample, force: Bool) {
        let outcome = settings.terminateProcess(pid: process.pid, force: force)
        processActionResult = outcome.message
        if outcome.success {
            refreshRunningApps()
        }
    }

    private func percentString(_ value: Double) -> String {
        String(format: "%.1f%%", value)
    }

    private func byteCountString(_ value: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .memory)
    }

    private func deltaByteString(_ value: Int64) -> String {
        let sign = value >= 0 ? "+" : "-"
        return "\(sign)\(byteCountString(UInt64(abs(value))))"
    }

    private func color(for level: MemoryPressureLevel) -> Color {
        switch level {
        case .green:
            return .green
        case .yellow:
            return .orange
        case .red:
            return .red
        }
    }

    private func colorForWarning(_ warning: String) -> Color {
        let lowered = warning.lowercased()
        if lowered.contains("high") || lowered.contains("critical") || lowered.contains("red") {
            return .red
        }
        if lowered.contains("stale") || lowered.contains("pressure") || lowered.contains("swap") || lowered.contains("udp") {
            return .orange
        }
        return .secondary
    }

    private func timeOnly(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .medium
        return formatter.string(from: date)
    }

    private func refreshRunningApps() {
        let ownBundleID = Bundle.main.bundleIdentifier

        availableApps = NSWorkspace.shared.runningApplications
            .filter { app in
                app.activationPolicy == .regular &&
                !app.isTerminated &&
                app.bundleIdentifier != ownBundleID &&
                !(app.localizedName ?? "").localizedCaseInsensitiveContains("X-Plane") &&
                !(app.localizedName ?? "").localizedCaseInsensitiveContains("CruiseControl") &&
                app.bundleIdentifier != nil
            }
            .compactMap { app in
                guard let id = app.bundleIdentifier else { return nil }
                let name = app.localizedName ?? id
                return RunningAppChoice(id: id, name: name)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func bindingForAppSelection(bundleID: String) -> Binding<Bool> {
        Binding(
            get: { settings.selectedBackgroundBundleIDs.contains(bundleID) },
            set: { selected in
                settings.updateSelection(bundleID: bundleID, selected: selected)
            }
        )
    }

    private func refreshProfileLists() {
        allowlistText = settings.listString(for: .allowlist, profile: settings.selectedProfile)
        blocklistText = settings.listString(for: .blocklist, profile: settings.selectedProfile)
        doNotTouchText = settings.listString(for: .doNotTouch, profile: settings.selectedProfile)
    }

    private func saveProfileLists() {
        settings.updateList(allowlistText, listType: .allowlist, profile: settings.selectedProfile)
        settings.updateList(blocklistText, listType: .blocklist, profile: settings.selectedProfile)
        settings.updateList(doNotTouchText, listType: .doNotTouch, profile: settings.selectedProfile)
        processActionResult = "Saved profile lists for \(settings.selectedProfile.displayName)."
    }

    private func applyUDPPort() {
        guard let port = Int(udpPortText), (1024...65535).contains(port) else {
            diagnosticsExportResult = "Invalid UDP port. Use 1024-65535."
            return
        }

        settings.xPlaneUDPPort = port
        let host = sampler.snapshot.udpStatus.listenHost
        diagnosticsExportResult = "Listening on \(host):\(String(port))."
    }

    private func applyGovernorBridgeEndpoint() {
        guard let port = Int(governorPortText), (1024...65535).contains(port) else {
            processActionResult = "Regulator command port must be between 1024 and 65535."
            return
        }

        let host = governorHostText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else {
            processActionResult = "Regulator host cannot be empty."
            return
        }

        settings.governorCommandHost = host
        settings.governorCommandPort = port
        processActionResult = "Regulator bridge set to \(host):\(String(port))."
    }

    private func simBoundHeuristic() -> String {
        if sampler.snapshot.thermalState == .serious || sampler.snapshot.thermalState == .critical {
            return "Thermal"
        }
        if sampler.snapshot.memoryPressure == .red || sampler.snapshot.swapDelta5MinBytes > Int64(256 * 1_024 * 1_024) {
            return "Memory"
        }
        if sampler.snapshot.cpuTotalPercent > 80 {
            return "CPU"
        }
        return "Balanced"
    }

    private func reliefSelectionBinding(pid: Int32) -> Binding<Bool> {
        Binding(
            get: { selectedReliefPIDs.contains(pid) },
            set: { isSelected in
                if isSelected {
                    selectedReliefPIDs.insert(pid)
                } else {
                    selectedReliefPIDs.remove(pid)
                }
            }
        )
    }

    private func closeSelectedReliefApps() {
        let targets = sampler.topMemoryProcesses.filter {
            selectedReliefPIDs.contains($0.pid) && !featureStore.isProcessAllowlisted($0.name)
        }
        guard !targets.isEmpty else {
            processActionResult = "No selected memory-relief targets."
            return
        }

        var lines: [String] = []
        for target in targets {
            let outcome = settings.terminateProcess(pid: target.pid, force: false)
            lines.append("\(target.name): \(outcome.message)")
        }

        selectedReliefPIDs.removeAll()
        refreshRunningApps()
        processActionResult = lines.joined(separator: "\n")
    }

    private func runLimitedPurgeAttempt() {
        guard featureStore.purgeAttemptEnabled else {
            processActionResult = "Enable optional purge attempt in Preferences first."
            return
        }

        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let cacheRoot = base.appendingPathComponent("CruiseControl/Cache", isDirectory: true)

        do {
            if fm.fileExists(atPath: cacheRoot.path) {
                let children = try fm.contentsOfDirectory(at: cacheRoot, includingPropertiesForKeys: nil)
                for child in children {
                    try? fm.removeItem(at: child)
                }
            }
            processActionResult = "Limited purge completed: cleared CruiseControl local cache only."
        } catch {
            processActionResult = "Limited purge attempt failed: \(error.localizedDescription)"
        }
    }

    private func syncAirportProfileEditorSelection() {
        if featureStore.airportProfiles.isEmpty {
            selectedAirportProfileICAO = ""
            airportProfileName = ""
            return
        }

        if selectedAirportProfileICAO.isEmpty || !featureStore.airportProfiles.contains(where: { $0.icao == selectedAirportProfileICAO }) {
            selectedAirportProfileICAO = featureStore.airportProfiles[0].icao
        }

        loadAirportProfileEditor()
    }

    private func loadAirportProfileEditor() {
        let normalized = AirportGovernorProfile.normalizeICAO(selectedAirportProfileICAO)
        guard let profile = featureStore.airportProfiles.first(where: { $0.icao == normalized }) else {
            return
        }

        selectedAirportProfileICAO = profile.icao
        airportProfileName = profile.name
        airportGroundMax = profile.groundMaxAGLFeet
        airportCruiseMin = profile.cruiseMinAGLFeet
        airportTargetGround = profile.targetLODGround
        airportTargetTransition = profile.targetLODTransition
        airportTargetCruise = profile.targetLODCruise
        airportClampMin = profile.clampMinLOD
        airportClampMax = profile.clampMaxLOD
    }

    private func saveAirportProfileFromEditor() {
        let normalized = AirportGovernorProfile.normalizeICAO(selectedAirportProfileICAO)
        guard normalized.count >= 3 else {
            processActionResult = "ICAO must be at least 3 characters."
            return
        }

        let profile = AirportGovernorProfile(
            icao: normalized,
            name: airportProfileName.isEmpty ? "Custom" : airportProfileName,
            groundMaxAGLFeet: max(500, airportGroundMax),
            cruiseMinAGLFeet: max(airportCruiseMin, airportGroundMax + 200),
            targetLODGround: airportTargetGround,
            targetLODTransition: airportTargetTransition,
            targetLODCruise: airportTargetCruise,
            clampMinLOD: min(airportClampMin, airportClampMax),
            clampMaxLOD: max(airportClampMin, airportClampMax)
        )

        featureStore.upsertAirportProfile(profile)
        selectedAirportProfileICAO = normalized
        processActionResult = "Saved airport profile \(normalized)."
    }

    private func pickLargeFileFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Select"

        if panel.runModal() == .OK {
            smartScanRoots = panel.urls
            featureStore.largeFilesDefaultScopes = panel.urls.map(\.path)
        }
    }

    private func setLargeFileQuickScope(_ directory: FileManager.SearchPathDirectory) {
        if let url = FileManager.default.urls(for: directory, in: .userDomainMask).first {
            smartScanRoots = [url]
            featureStore.largeFilesDefaultScopes = [url.path]
        }
    }

    private func applyDefaultLargeFileScopesIfNeeded() {
        guard smartScanRoots.isEmpty else { return }
        let urls = featureStore.largeFilesDefaultScopes.map { URL(fileURLWithPath: $0) }
        let existing = urls.filter { FileManager.default.fileExists(atPath: $0.path) }
        if !existing.isEmpty {
            smartScanRoots = existing
        }
    }

    private func runSmartScan() {
        guard !smartScanRunState.isRunning else { return }

        guard !smartScanRoots.isEmpty else {
            processActionResult = "Select at least one Large Files scope before running Smart Scan."
            return
        }

        smartScanTask?.cancel()
        processActionResult = "Smart Scan in progress..."

        let options = SmartScanService.ScanOptions(
            includePrivacy: smartScanIncludePrivacy,
            includeSavedApplicationState: true,
            selectedLargeFileRoots: smartScanRoots,
            topLargeFilesCount: featureStore.largeFilesTopN
        )

        let topCPU = sampler.topCPUProcesses
        smartScanTask = Task {
            let summary = await smartScanService.runSmartScanAsync(options: options, topCPUProcesses: topCPU) { state in
                Task { @MainActor in
                    smartScanRunState = state
                }
            }

            await MainActor.run {
                smartScanSummary = summary
                selectedSmartScanItemIDs.removeAll()
                smartScanRunState.isRunning = false
                processActionResult = "Smart Scan complete: \(summary.items.count) items found, total \(byteCountString(summary.totalBytes))."
            }

            await scanOptimizationModule()
            if !(featureStore.pauseBackgroundScansDuringSim && sampler.isSimActive) {
                scanCleanerModule()
                scanLargeFilesModule()
            }
            await MainActor.run {
                refreshQuarantineBatches()
            }
        }
    }

    private func scanCleanerModule() {
        guard !cleanerLoading else { return }
        cleanerLoading = true

        Task {
            let items = await smartScanService.scanCleanerModuleAsync(includeSavedApplicationState: true)
            await MainActor.run {
                cleanerItems = items
                selectedCleanerItemIDs.removeAll()
                cleanerLoading = false
                processActionResult = "Cleaner scan complete: \(items.count) item(s)."
            }
        }
    }

    private func scanLargeFilesModule() {
        guard !largeFilesLoading else { return }
        guard !smartScanRoots.isEmpty else {
            processActionResult = "Choose at least one folder scope for Large Files scan."
            return
        }

        largeFilesLoading = true

        Task {
            let items = await smartScanService.scanLargeFilesModuleAsync(roots: smartScanRoots, topCount: featureStore.largeFilesTopN)
            await MainActor.run {
                largeFileItems = items
                selectedLargeFileItemIDs.removeAll()
                largeFilesLoading = false
                processActionResult = "Large Files scan complete: \(items.count) item(s)."
            }
        }
    }

    private func scanOptimizationModule() async {
        let items = await smartScanService.scanOptimizationModuleAsync(topCPUProcesses: sampler.topCPUProcesses)
        await MainActor.run {
            optimizationItems = items
            selectedOptimizationItemIDs.removeAll()
        }
    }

    private func deepLinkToModule(_ module: SmartScanModule) {
        switch module {
        case .systemJunk, .trashBins:
            selectedSection = .cleaner
            scanCleanerModule()
        case .largeFiles:
            selectedSection = .largeFiles
            scanLargeFilesModule()
        case .optimization:
            selectedSection = .optimization
            Task { await scanOptimizationModule() }
        case .privacy:
            selectedSection = .cleaner
            scanCleanerModule()
        }
    }

    private func smartScanSelectionBinding(itemID: UUID) -> Binding<Bool> {
        Binding(
            get: { selectedSmartScanItemIDs.contains(itemID) },
            set: { selected in
                if selected {
                    selectedSmartScanItemIDs.insert(itemID)
                } else {
                    selectedSmartScanItemIDs.remove(itemID)
                }
            }
        )
    }

    private func cleanerSelectionBinding(itemID: UUID) -> Binding<Bool> {
        Binding(
            get: { selectedCleanerItemIDs.contains(itemID) },
            set: { selected in
                if selected {
                    selectedCleanerItemIDs.insert(itemID)
                } else {
                    selectedCleanerItemIDs.remove(itemID)
                }
            }
        )
    }

    private func largeFilesSelectionBinding(itemID: UUID) -> Binding<Bool> {
        Binding(
            get: { selectedLargeFileItemIDs.contains(itemID) },
            set: { selected in
                if selected {
                    selectedLargeFileItemIDs.insert(itemID)
                } else {
                    selectedLargeFileItemIDs.remove(itemID)
                }
            }
        )
    }

    private func impactProcesses() -> [ProcessSample] {
        let allowlisted = Set(featureStore.optimizationProcessAllowlist.map { $0.lowercased() })
        let combined = Dictionary(grouping: sampler.topCPUProcesses + sampler.topMemoryProcesses, by: { $0.pid })
            .compactMap { _, group -> ProcessSample? in
                guard let first = group.first else { return nil }
                let highestCPU = group.map(\.cpuPercent).max() ?? first.cpuPercent
                let highestMemory = group.map(\.memoryBytes).max() ?? first.memoryBytes
                return ProcessSample(
                    pid: first.pid,
                    name: first.name,
                    bundleIdentifier: first.bundleIdentifier,
                    cpuPercent: highestCPU,
                    memoryBytes: highestMemory,
                    sampledAt: first.sampledAt
                )
            }
            .filter {
                !$0.name.localizedCaseInsensitiveContains("X-Plane") &&
                !$0.name.localizedCaseInsensitiveContains("CruiseControl") &&
                !allowlisted.contains($0.name.lowercased())
            }
            .sorted {
                let leftScore = ($0.cpuPercent * 1.8) + (Double($0.memoryBytes) / 1_073_741_824.0 * 8.0)
                let rightScore = ($1.cpuPercent * 1.8) + (Double($1.memoryBytes) / 1_073_741_824.0 * 8.0)
                return leftScore > rightScore
            }

        return Array(combined.prefix(8))
    }

    private func refreshQuarantineBatches() {
        quarantineBatches = smartScanService.listQuarantineBatches()
        if selectedQuarantineBatchID.isEmpty || !quarantineBatches.contains(where: { $0.batchID == selectedQuarantineBatchID }) {
            selectedQuarantineBatchID = quarantineBatches.first?.batchID ?? ""
        }
    }

    private func quarantineSelectedScanItems() {
        let selected = selectedScanItemsForAction
        let outcome = smartScanService.quarantine(
            items: selected,
            advancedModeEnabled: featureStore.advancedModeEnabled
        )
        processActionResult = outcome.message
        refreshQuarantineBatches()
    }

    private func deleteSelectedScanItems() {
        if featureStore.advancedModeEnabled && featureStore.advancedModeExtraConfirmation {
            processActionResult = "Advanced Mode destructive action confirmed."
        }

        let selected = selectedScanItemsForAction
        let outcome = smartScanService.deletePermanently(
            items: selected,
            advancedModeEnabled: featureStore.advancedModeEnabled
        )
        processActionResult = outcome.message

        if selectedSection == .cleaner {
            cleanerItems.removeAll { selectedCleanerItemIDs.contains($0.id) }
            selectedCleanerItemIDs.removeAll()
        } else if selectedSection == .largeFiles {
            largeFileItems.removeAll { selectedLargeFileItemIDs.contains($0.id) }
            selectedLargeFileItemIDs.removeAll()
        } else {
            smartScanSummary = SmartScanSummary(
                generatedAt: smartScanSummary?.generatedAt ?? Date(),
                duration: smartScanSummary?.duration ?? 0,
                moduleResults: smartScanSummary?.moduleResults ?? [],
                items: (smartScanSummary?.items ?? []).filter { !selectedSmartScanItemIDs.contains($0.id) }
            )
            selectedSmartScanItemIDs.removeAll()
        }

        refreshQuarantineBatches()
    }

    private func openLoginItemsSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") {
            if NSWorkspace.shared.open(url) {
                processActionResult = "Opened Login Items settings."
                return
            }
        }
        processActionResult = "Open System Settings > General > Login Items to review startup/background apps."
    }
    private func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

private struct CruiseBackgroundView: View {
    var body: some View {
        GeometryReader { geo in
            ZStack {
                LinearGradient(
                    colors: [
                        Color(red: 0.02, green: 0.04, blue: 0.09),
                        Color(red: 0.03, green: 0.06, blue: 0.12),
                        Color(red: 0.02, green: 0.03, blue: 0.07)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )

                Canvas { context, size in
                    let spacing: CGFloat = 20
                    let amplitude: CGFloat = 3
                    let frequency: CGFloat = 0.022

                    var y: CGFloat = -spacing
                    while y < size.height + spacing {
                        var path = Path()
                        path.move(to: CGPoint(x: 0, y: y))

                        var x: CGFloat = 0
                        while x <= size.width {
                            let wave = sin((x * frequency) + (y * 0.05)) * amplitude
                            path.addLine(to: CGPoint(x: x, y: y + wave))
                            x += 8
                        }

                        context.stroke(path, with: .color(Color.white.opacity(0.08)), lineWidth: 0.7)
                        y += spacing
                    }
                }

                Circle()
                    .fill(Color(red: 0.43, green: 0.35, blue: 1.0).opacity(0.24))
                    .blur(radius: 45)
                    .frame(width: 220, height: 220)
                    .position(x: geo.size.width * 0.12, y: 90)

                Circle()
                    .fill(Color(red: 0.24, green: 0.95, blue: 0.72).opacity(0.20))
                    .blur(radius: 50)
                    .frame(width: 260, height: 260)
                    .position(x: geo.size.width * 0.78, y: geo.size.height * 0.18)
            }
            .ignoresSafeArea()
        }
    }
}

private struct SparklineView: View {
    let values: [Double]
    let color: Color

    var body: some View {
        GeometryReader { geo in
            let normalized = normalizedPoints(width: geo.size.width, height: geo.size.height)

            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.white.opacity(0.04))

                Path { path in
                    guard normalized.count > 1 else { return }
                    path.move(to: normalized[0])
                    for point in normalized.dropFirst() {
                        path.addLine(to: point)
                    }
                }
                .stroke(color, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            }
        }
    }

    private func normalizedPoints(width: CGFloat, height: CGFloat) -> [CGPoint] {
        guard values.count > 1 else { return [] }

        let minValue = values.min() ?? 0
        let maxValue = values.max() ?? 1
        let span = max(maxValue - minValue, 0.0001)

        return values.enumerated().map { index, value in
            let x = CGFloat(index) / CGFloat(max(values.count - 1, 1)) * max(width, 1)
            let yRatio = (value - minValue) / span
            let y = max(height, 1) - CGFloat(yRatio) * max(height, 1)
            return CGPoint(x: x, y: y)
        }
    }
}
