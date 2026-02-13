import SwiftUI
import AppKit
import Combine

enum DashboardSection: String, CaseIterable, Identifiable {
    case overview
    case processes
    case simMode
    case history
    case diagnostics
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview:
            return "Overview"
        case .processes:
            return "Top Processes"
        case .simMode:
            return "Sim Mode"
        case .history:
            return "History"
        case .diagnostics:
            return "Diagnostics"
        case .settings:
            return "Preferences"
        }
    }

    var icon: String {
        switch self {
        case .overview:
            return "speedometer"
        case .processes:
            return "list.bullet.rectangle.portrait"
        case .simMode:
            return "airplane"
        case .history:
            return "clock.arrow.circlepath"
        case .diagnostics:
            return "waveform.path.ecg"
        case .settings:
            return "gearshape"
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

    @State private var showUDPSetupGuide: Bool = true
    @State private var now: Date = Date()

    private let clockTimer = Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.06, green: 0.08, blue: 0.16), Color(red: 0.10, green: 0.15, blue: 0.27)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            NavigationSplitView {
                sidebar
            } detail: {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        detailContent

                        if let processActionResult {
                            feedbackCard(title: "Action Result", text: processActionResult)
                        }

                        if let diagnosticsExportResult {
                            feedbackCard(title: "Diagnostics", text: diagnosticsExportResult)
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
                }
                .background(Color.clear)
            }
            .navigationSplitViewStyle(.balanced)
            .tint(Color(red: 0.30, green: 0.76, blue: 1.0))
        }
        .onAppear {
            sampler.start()
            refreshRunningApps()
            refreshProfileLists()
            udpPortText = String(settings.xPlaneUDPPort)
            governorPortText = String(settings.governorCommandPort)
            governorHostText = settings.governorCommandHost
        }
        .onReceive(clockTimer) { newDate in
            now = newDate
        }
        .onChange(of: settings.selectedProfile) { _ in
            refreshProfileLists()
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
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Project Speed")
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)

                Text(sampler.isSimActive ? "Sim Active" : "System Monitoring")
                    .font(.subheadline)
                    .foregroundStyle(sampler.isSimActive ? .green : .white.opacity(0.7))
            }
            .padding(.top, 8)

            List(DashboardSection.allCases, selection: $selectedSection) { section in
                Label(section.title, systemImage: section.icon)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .padding(.vertical, 4)
                    .tag(section)
            }
            .scrollContentBackground(.hidden)
            .listStyle(.sidebar)

            VStack(alignment: .leading, spacing: 8) {
                quickMetric(title: "CPU", value: percentString(sampler.snapshot.cpuTotalPercent))
                quickMetric(title: "Pressure", value: "\(sampler.snapshot.memoryPressure.displayName) \(sampler.snapshot.memoryPressureTrend.icon)")
                quickMetric(title: "UDP", value: sampler.snapshot.udpStatus.state.displayName)
                quickMetric(title: "Governor", value: settings.governorModeEnabled ? "ON" : "OFF")
            }
            .padding(12)
            .background(.ultraThinMaterial.opacity(0.65), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .padding(18)
        .frame(minWidth: 260)
    }

    @ViewBuilder
    private var detailContent: some View {
        switch selectedSection ?? .overview {
        case .overview:
            overviewSection
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

            dashboardCard(title: "X-Plane UDP Setup") {
                DisclosureGroup(isExpanded: $showUDPSetupGuide) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("1) X-Plane > Settings > Data Output")
                        Text("2) Check Send network data output")
                        Text("3) Set IP to 127.0.0.1")
                        Text("4) Set Port to \(String(settings.xPlaneUDPPort))")
                        Text("5) Enable frame-rate and position datasets")

                        HStack {
                            Text("Setup line: 127.0.0.1:\(String(settings.xPlaneUDPPort))")
                                .font(.caption)
                            Spacer()
                            Button("Copy setup line") {
                                let line = "127.0.0.1:\(String(settings.xPlaneUDPPort))"
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(line, forType: .string)
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
                statTile("Swap Δ 5m", deltaByteString(sampler.snapshot.swapDelta5MinBytes), color: .orange)
                statTile("Disk Read", String(format: "%.1f MB/s", sampler.snapshot.diskReadMBps), color: .teal)
                statTile("Disk Write", String(format: "%.1f MB/s", sampler.snapshot.diskWriteMBps), color: .teal)
                statTile("Thermal", PerformanceSampler.thermalStateDescription(sampler.snapshot.thermalState), color: (sampler.snapshot.thermalState == .serious || sampler.snapshot.thermalState == .critical) ? .red : .green)
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

                        Text("CPU \(percentString(process.cpuPercent)) · RAM \(byteCountString(process.memoryBytes))")
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
            dashboardCard(title: "LOD Governor") {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle("Enable LOD Governor", isOn: $settings.governorModeEnabled)

                    HStack(spacing: 12) {
                        metricPill(label: "AGL", value: sampler.governorActiveAGLFeet.map { String(format: "%.0f ft", $0) } ?? "AGL unavailable")
                        metricPill(label: "Tier", value: sampler.governorCurrentTier?.rawValue ?? "Paused")
                        metricPill(label: "Target", value: sampler.governorCurrentTargetLOD.map { String(format: "%.2f", $0) } ?? "-")
                        metricPill(label: "Ramp", value: sampler.governorSmoothedTargetLOD.map { String(format: "%.2f", $0) } ?? "-")
                        metricPill(label: "Last Sent", value: sampler.governorLastSentLOD.map { String(format: "%.2f", $0) } ?? "-")
                    }

                    Text("Command status: \(sampler.governorCommandStatus)")
                        .font(.subheadline)
                        .foregroundStyle(sampler.governorCommandStatus == "Connected" ? .green : .orange)

                    if let pauseReason = sampler.governorPauseReason {
                        Text(pauseReason)
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }

                    Text("Altitude thresholds (feet AGL)")
                        .font(.headline)
                    sliderRow(
                        label: "GROUND upper (ft)",
                        value: $settings.governorGroundMaxAGLFeet,
                        range: 500...5000,
                        step: 100
                    )
                    sliderRow(
                        label: "CRUISE lower (ft)",
                        value: $settings.governorCruiseMinAGLFeet,
                        range: 6000...45000,
                        step: 250
                    )

                    Text("Per-tier LOD targets")
                        .font(.headline)
                    sliderRow(label: "GROUND target", value: $settings.governorTargetLODGround, range: 0.20...3.00, step: 0.05)
                    sliderRow(label: "TRANSITION target", value: $settings.governorTargetLODClimbDescent, range: 0.20...3.00, step: 0.05)
                    sliderRow(label: "CRUISE target", value: $settings.governorTargetLODCruise, range: 0.20...3.00, step: 0.05)

                    Text("Safety clamps")
                        .font(.headline)
                    sliderRow(label: "Min LOD", value: $settings.governorLODMinClamp, range: 0.20...2.00, step: 0.05)
                    sliderRow(label: "Max LOD", value: $settings.governorLODMaxClamp, range: 0.50...3.00, step: 0.05)

                    Text("Governor behavior")
                        .font(.headline)
                    sliderRow(label: "Min time in tier (s)", value: $settings.governorMinimumTierHoldSeconds, range: 0...30, step: 1)
                    sliderRow(label: "Ramp duration (s)", value: $settings.governorSmoothingDurationSeconds, range: 0.5...12, step: 0.5)
                    sliderRow(label: "Command interval (s)", value: $settings.governorMinimumCommandIntervalSeconds, range: 0.1...3.0, step: 0.1)
                    sliderRow(label: "Min send delta", value: $settings.governorMinimumCommandDelta, range: 0.01...0.30, step: 0.01)

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
                    }

                    HStack {
                        Text("Test LOD")
                        TextField("1.00", text: $governorTestLODText)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 90)
                        Button("Test send") {
                            guard let lod = Double(governorTestLODText) else {
                                processActionResult = "Invalid LOD test value. Use a number like 0.95 or 1.25."
                                return
                            }
                            let outcome = sampler.sendGovernorTestCommand(lodValue: lod)
                            processActionResult = outcome.message
                        }
                        .buttonStyle(.borderedProminent)
                    }

                    Text(sampler.snapshot.governorStatusLine)
                        .font(.subheadline)
                        .foregroundStyle(settings.governorModeEnabled ? .green : .secondary)
                }
            }

            dashboardCard(title: "Setup FlyWithLua Companion") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Install to: X-Plane 12/Resources/plugins/FlyWithLua/Scripts/ProjectSpeed_Governor.lua")
                    Text("Companion listens on \(settings.governorCommandHost):\(String(settings.governorCommandPort)) and applies sim/private/controls/reno/LOD_bias_rat.")
                    Text("In FlyWithLua log, confirm: [ProjectSpeed_Governor] Listening on ...")
                    Text("Troubleshooting: if LuaSocket is missing, Project Speed writes fallback commands to /tmp/ProjectSpeed_lod_target.txt.")
                    Text("If not connected, verify UDP host/port and check FlyWithLua log for fallback mode.")
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
        dashboardCard(title: "History (Last 15 Minutes)") {
            let recent = Array(sampler.history.suffix(120).reversed())
            if recent.isEmpty {
                Text("No history yet.")
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(recent) { point in
                        Text("\(timeOnly(point.timestamp)) · CPU \(percentString(point.cpuTotalPercent)) · Swap \(byteCountString(point.swapUsedBytes)) · \(point.memoryPressure.displayName)")
                            .font(.caption)
                    }
                }
            }
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

                    Text("Snapshot includes metrics, warnings, top processes, recent history, UDP state, and governor policy status.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            dashboardCard(title: "FlyWithLua Governor Bridge") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Install Scripts/ProjectSpeed_Governor.lua in your X-Plane FlyWithLua Scripts folder.")
                    Text("The mac app sends UDP commands to \(settings.governorCommandHost):\(settings.governorCommandPort).")
                    Text("The script applies LOD bias with bounds checks and restores original value when disabled.")
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
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

                Text("UDP state: \(sampler.snapshot.udpStatus.state.displayName)")
                Text("Last updated: \(lastUpdatedText)")
                    .foregroundStyle(isStale ? .orange : .secondary)

                Text("Project Speed performs monitoring and user-approved actions only. It does not control scheduler internals, GPU clocks, or protected kernel paths.")
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

    private func metricPill(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.subheadline)
                .fontWeight(.semibold)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func statTile(_ label: String, _ value: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.headline)
                .foregroundStyle(color)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func quickMetric(title: String, value: String) -> some View {
        HStack {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.white)
        }
    }

    private func udpStateBadge(_ state: XPlaneUDPConnectionState) -> some View {
        let color: Color
        switch state {
        case .idle:
            color = .gray
        case .listening:
            color = .orange
        case .active:
            color = .green
        case .misconfig:
            color = .red
        }

        return Text(state.displayName)
            .font(.caption)
            .fontWeight(.bold)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(color.opacity(0.2), in: Capsule())
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
                !(app.localizedName ?? "").localizedCaseInsensitiveContains("Project Speed") &&
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
            processActionResult = "Governor command port must be between 1024 and 65535."
            return
        }

        let host = governorHostText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else {
            processActionResult = "Governor host cannot be empty."
            return
        }

        settings.governorCommandHost = host
        settings.governorCommandPort = port
        processActionResult = "Governor bridge set to \(host):\(String(port))."
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
}
