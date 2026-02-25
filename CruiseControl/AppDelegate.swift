import Foundation
import AppKit
import Combine
import SwiftUI
import UserNotifications
#if canImport(Sparkle)
import Sparkle
#endif

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    let settingsStore = SettingsStore()
    let featureStore = V112FeatureStore()
    lazy var sampler = PerformanceSampler()

    #if canImport(Sparkle)
    var sparkleUpdaterController: SPUStandardUpdaterController?
    #endif

    private var cancellables: Set<AnyCancellable> = []
    private var previousSimActive: Bool = false
    private var previousAlertFlags = AlertFlags(memoryPressureRed: false, thermalCritical: false, swapRisingFast: false)
    private var pendingRuntimeConfigApplyTask: Task<Void, Never>?
    private var didSuggestSimProfile = false
    private var overlayPanel: NSPanel?

    private let warningCategoryIdentifier = "PROJECT_SPEED_WARNING"
    private let defaults = UserDefaults.standard

    private enum LifecycleKeys {
        static let cleanShutdown = "app.lifecycle.cleanShutdown"
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let wasCleanShutdown = defaults.object(forKey: LifecycleKeys.cleanShutdown) as? Bool ?? false
        let modifierRequestedSafeMode = NSEvent.modifierFlags.contains(.option)
        defaults.set(false, forKey: LifecycleKeys.cleanShutdown)

        NSApp.setActivationPolicy(.regular)
        configureNotifications()
        configureSparkleIfAvailable()

        #if DEBUG
        GovernorPolicyEngineSelfTests.run()
        #endif

        settingsStore.$samplingInterval
            .combineLatest(settingsStore.$smoothingAlpha)
            .receive(on: RunLoop.main)
            .sink { [weak self] interval, alpha in
                self?.sampler.configureSampling(interval: interval.seconds, alpha: alpha)
            }
            .store(in: &cancellables)

        settingsStore.$xPlaneUDPListeningEnabled
            .combineLatest(settingsStore.$xPlaneUDPPort)
            .receive(on: RunLoop.main)
            .sink { [weak self] enabled, port in
                self?.sampler.configureXPlaneUDP(enabled: enabled, port: port)
            }
            .store(in: &cancellables)

        Publishers.Merge(
            settingsStore.objectWillChange.map { _ in () },
            featureStore.objectWillChange.map { _ in () }
        )
        .sink { [weak self] _ in
            self?.scheduleRuntimeConfigApply()
        }
        .store(in: &cancellables)

        sampler.$snapshot
            .map { $0.xplaneTelemetry?.nearestAirportICAO ?? "" }
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.scheduleRuntimeConfigApply()
            }
            .store(in: &cancellables)

        featureStore.$overlayEnabled
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] enabled in
                self?.updateOverlayVisibility(enabled: enabled)
            }
            .store(in: &cancellables)

        featureStore.$supportModeEnabled
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { enabled in
                NSLog("CruiseControl Support Mode \(enabled ? "enabled" : "disabled").")
            }
            .store(in: &cancellables)

        sampler.$isSimActive
            .receive(on: RunLoop.main)
            .sink { [weak self] simActive in
                guard let self else { return }
                defer { previousSimActive = simActive }

                if !simActive {
                    didSuggestSimProfile = false
                    return
                }

                if featureStore.workloadProfile != .simMode,
                   !didSuggestSimProfile {
                    didSuggestSimProfile = true
                    if settingsStore.sendWarningNotifications {
                        enqueueWarningNotification(
                            title: "CruiseControl: Sim Mode Available",
                            body: "X-Plane is active. Consider switching workload profile to Sim Mode for faster sampling."
                        )
                    }
                }

                guard !previousSimActive else { return }
                guard settingsStore.shouldAutoEnableForSelectedProfile(), !settingsStore.isSimModeEnabled else { return }

                _ = settingsStore.enableSimMode(trigger: "Auto (X-Plane detected)")
            }
            .store(in: &cancellables)

        sampler.$alertFlags
            .receive(on: RunLoop.main)
            .sink { [weak self] flags in
                self?.handleAlertTransitions(flags)
            }
            .store(in: &cancellables)

        sampler.configureSampling(interval: settingsStore.samplingInterval.seconds, alpha: settingsStore.smoothingAlpha)
        sampler.configureXPlaneUDP(enabled: settingsStore.xPlaneUDPListeningEnabled, port: settingsStore.xPlaneUDPPort)

        if !wasCleanShutdown || modifierRequestedSafeMode || featureStore.safeModeEnabled {
            featureStore.activateSafeMode()
        }

        applyRuntimeConfigs()
        sampler.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        pendingRuntimeConfigApplyTask?.cancel()
        defaults.set(true, forKey: LifecycleKeys.cleanShutdown)
        sampler.stop()
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        switch response.actionIdentifier {
        case "OPEN_PROJECT_SPEED":
            focusMainWindow()
        case "OPEN_ACTIVITY_MONITOR":
            openActivityMonitor()
        default:
            focusMainWindow()
        }
    }

    func checkForUpdatesFromMenu() {
        Task {
            let current = AppMaintenanceService.currentVersionString()
            let outcome = await AppMaintenanceService.checkForUpdates(currentVersion: current, preferSparkle: false)

            // Sparkle presents its own update UI once triggered.
            if outcome.message.contains("Sparkle update check triggered") {
                return
            }

            let alert = NSAlert()
            alert.messageText = "CruiseControl Update Check"
            alert.alertStyle = .informational
            alert.informativeText = "Current \(AppMaintenanceService.currentVersionString())\n\(outcome.message)"
            if outcome.releaseURL != nil {
                alert.addButton(withTitle: "Open latest release")
                alert.addButton(withTitle: "OK")
            } else {
                alert.addButton(withTitle: "OK")
            }

            let response = alert.runModal()
            if response == .alertFirstButtonReturn, let url = outcome.releaseURL {
                NSWorkspace.shared.open(url)
            }
        }
    }

    private func applyRuntimeConfigs() {
        let baseConfig = settingsStore.governorConfig
        let telemetryICAO = sampler.snapshot.xplaneTelemetry?.nearestAirportICAO
        let effectiveConfig = featureStore.effectiveGovernorConfig(base: baseConfig, telemetryICAO: telemetryICAO)
        let effectiveProfile: ProfileKind = featureStore.safeModeEnabled ? .generalPerformance : featureStore.workloadProfile
        let demoMockModeEnabled = featureStore.safeModeEnabled ? false : featureStore.demoMockModeEnabled

        sampler.configureGovernor(config: effectiveConfig)
        sampler.configureStutterHeuristics(featureStore.stutterHeuristics)
        sampler.configureWorkloadProfile(effectiveProfile)
        sampler.configureRetention(window: featureStore.historyDuration)
        sampler.configureCPUBudgetMode(enabled: featureStore.cpuBudgetModeEnabled)
        sampler.configureDemoMockMode(enabled: demoMockModeEnabled)
    }

    private func updateOverlayVisibility(enabled: Bool) {
        if enabled {
            if overlayPanel == nil {
                let overlayView = XPlaneMiniOverlayView(sampler: sampler)
                let hosting = NSHostingController(rootView: overlayView)
                let panel = NSPanel(
                    contentRect: NSRect(x: 40, y: 40, width: 270, height: 145),
                    styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],
                    backing: .buffered,
                    defer: false
                )
                panel.level = .floating
                panel.titleVisibility = .hidden
                panel.titlebarAppearsTransparent = true
                panel.isMovableByWindowBackground = true
                panel.isFloatingPanel = true
                panel.hidesOnDeactivate = false
                panel.becomesKeyOnlyIfNeeded = true
                panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
                panel.standardWindowButton(.closeButton)?.isHidden = true
                panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
                panel.standardWindowButton(.zoomButton)?.isHidden = true
                panel.isReleasedWhenClosed = false
                panel.contentViewController = hosting
                overlayPanel = panel
            }

            overlayPanel?.orderFront(nil)
        } else {
            overlayPanel?.orderOut(nil)
        }
    }

    private func scheduleRuntimeConfigApply(delayMilliseconds: UInt64 = 500) {
        pendingRuntimeConfigApplyTask?.cancel()
        pendingRuntimeConfigApplyTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: delayMilliseconds * 1_000_000)
            } catch {
                return
            }

            guard !Task.isCancelled else { return }
            await MainActor.run {
                self?.applyRuntimeConfigs()
            }
        }
    }

    private func configureSparkleIfAvailable() {
        #if canImport(Sparkle)
        guard let feedURL = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String,
              !feedURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let _ = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String else {
            return
        }

        sparkleUpdaterController = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        #endif
    }

    private func focusMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        if NSApp.windows.isEmpty {
            NSApp.sendAction(#selector(NSApplication.newWindowForTab(_:)), to: nil, from: nil)
        }
        NSApp.windows.forEach { window in
            window.makeKeyAndOrderFront(nil)
        }
    }

    private func configureNotifications() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self

        let openAppAction = UNNotificationAction(identifier: "OPEN_PROJECT_SPEED", title: "Open CruiseControl", options: [.foreground])
        let openActivityAction = UNNotificationAction(identifier: "OPEN_ACTIVITY_MONITOR", title: "Open Activity Monitor", options: [])
        let category = UNNotificationCategory(
            identifier: warningCategoryIdentifier,
            actions: [openAppAction, openActivityAction],
            intentIdentifiers: []
        )
        center.setNotificationCategories([category])

        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error {
                NSLog("CruiseControl notification permission error: \(error.localizedDescription)")
            }
            if !granted {
                NSLog("CruiseControl notifications were not granted by the user.")
            }
        }
    }

    private func handleAlertTransitions(_ flags: AlertFlags) {
        guard settingsStore.sendWarningNotifications else {
            previousAlertFlags = flags
            return
        }

        if flags.memoryPressureRed && !previousAlertFlags.memoryPressureRed {
            enqueueWarningNotification(
                title: "CruiseControl: Memory Pressure High",
                body: "Memory pressure turned red. Review top memory users in CruiseControl."
            )
        }

        if flags.thermalCritical && !previousAlertFlags.thermalCritical {
            enqueueWarningNotification(
                title: "CruiseControl: Thermal Warning",
                body: "Thermal state is serious/critical. Reduce graphics settings or frame cap."
            )
        }

        if flags.swapRisingFast && !previousAlertFlags.swapRisingFast {
            enqueueWarningNotification(
                title: "CruiseControl: Swap Rising Fast",
                body: "Swap growth is high. Paging may be causing frame-time spikes."
            )
        }

        previousAlertFlags = flags
    }

    private func enqueueWarningNotification(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.categoryIdentifier = warningCategoryIdentifier

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )

        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                NSLog("CruiseControl failed to schedule notification: \(error.localizedDescription)")
            }
        }
    }

    private func openActivityMonitor() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-a", "Activity Monitor"]

        do {
            try process.run()
        } catch {
            NSLog("CruiseControl failed to open Activity Monitor: \(error.localizedDescription)")
        }
    }
}

private struct XPlaneMiniOverlayView: View {
    @ObservedObject var sampler: PerformanceSampler

    private var pressureTint: Color {
        switch sampler.snapshot.memoryPressure {
        case .green:
            return .green
        case .yellow:
            return .orange
        case .red:
            return .red
        }
    }

    private var swapTrendText: String {
        let delta = sampler.snapshot.swapDelta5MinBytes
        let sign = delta >= 0 ? "+" : "-"
        let bytes = UInt64(abs(delta))
        let value = ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .memory)
        return "\(sign)\(value) / 5m"
    }

    private var stutterEpisodes10m: Int {
        let cutoff = Date().addingTimeInterval(-600)
        return sampler.stutterEpisodes.filter { $0.endAt >= cutoff }.count
    }

    private var regulatorLine: String {
        let proof = sampler.computeProofState()
        let applied = proof.appliedLOD.map { String(format: "%.2f", $0) } ?? "—"
        let tier = sampler.governorCurrentTier?.rawValue ?? "Paused"
        return "Applied \(applied) • \(tier)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("CruiseControl Overlay")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            HStack {
                Text("Pressure")
                Spacer()
                Text(sampler.snapshot.memoryPressure.displayName)
                    .foregroundStyle(pressureTint)
            }
            HStack {
                Text("Swap trend")
                Spacer()
                Text(swapTrendText)
            }
            HStack {
                Text("Stutter episodes (10m)")
                Spacer()
                Text("\(stutterEpisodes10m)")
            }
            HStack {
                Text("Regulator")
                Spacer()
                Text(regulatorLine)
            }
        }
        .font(.system(size: 11, weight: .medium, design: .rounded))
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.black.opacity(0.78))
    }
}
