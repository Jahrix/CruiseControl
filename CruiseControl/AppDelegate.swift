import Foundation
import AppKit
import Combine
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

    private let warningCategoryIdentifier = "PROJECT_SPEED_WARNING"

    func applicationDidFinishLaunching(_ notification: Notification) {
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

        sampler.$isSimActive
            .receive(on: RunLoop.main)
            .sink { [weak self] simActive in
                guard let self else { return }
                defer { previousSimActive = simActive }

                guard simActive, !previousSimActive else { return }
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
        applyRuntimeConfigs()
        sampler.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        pendingRuntimeConfigApplyTask?.cancel()
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
            let outcome = await AppMaintenanceService.checkForUpdatesAndInstall(currentVersion: current, preferSparkle: true)

            // Sparkle presents its own update UI once triggered.
            if outcome.message.contains("Sparkle update check triggered") {
                return
            }

            let alert = NSAlert()
            alert.messageText = "CruiseControl Update Check"
            alert.informativeText = outcome.message
            if outcome.releaseURL != nil {
                alert.addButton(withTitle: "Open Releases")
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
        sampler.configureGovernor(config: effectiveConfig)
        sampler.configureStutterHeuristics(featureStore.stutterHeuristics)
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
