import Foundation
import AppKit
import Combine
import UserNotifications

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    let settingsStore = SettingsStore()
    lazy var sampler = PerformanceSampler()

    private var cancellables: Set<AnyCancellable> = []
    private var previousSimActive: Bool = false
    private var previousAlertFlags = AlertFlags(memoryPressureRed: false, thermalCritical: false, swapRisingFast: false)

    private let warningCategoryIdentifier = "PROJECT_SPEED_WARNING"

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        configureNotifications()

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

        settingsStore.objectWillChange
            .debounce(for: .milliseconds(120), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                sampler.configureGovernor(config: settingsStore.governorConfig)
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
        sampler.configureGovernor(config: settingsStore.governorConfig)
        sampler.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
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

        let openAppAction = UNNotificationAction(identifier: "OPEN_PROJECT_SPEED", title: "Open Project Speed", options: [.foreground])
        let openActivityAction = UNNotificationAction(identifier: "OPEN_ACTIVITY_MONITOR", title: "Open Activity Monitor", options: [])
        let category = UNNotificationCategory(
            identifier: warningCategoryIdentifier,
            actions: [openAppAction, openActivityAction],
            intentIdentifiers: []
        )
        center.setNotificationCategories([category])

        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error {
                NSLog("ProjectSpeed notification permission error: \(error.localizedDescription)")
            }
            if !granted {
                NSLog("ProjectSpeed notifications were not granted by the user.")
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
                title: "Project Speed: Memory Pressure High",
                body: "Memory pressure turned red. Review top memory users in Project Speed."
            )
        }

        if flags.thermalCritical && !previousAlertFlags.thermalCritical {
            enqueueWarningNotification(
                title: "Project Speed: Thermal Warning",
                body: "Thermal state is serious/critical. Reduce graphics settings or frame cap."
            )
        }

        if flags.swapRisingFast && !previousAlertFlags.swapRisingFast {
            enqueueWarningNotification(
                title: "Project Speed: Swap Rising Fast",
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
                NSLog("ProjectSpeed failed to schedule notification: \(error.localizedDescription)")
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
            NSLog("ProjectSpeed failed to open Activity Monitor: \(error.localizedDescription)")
        }
    }
}
