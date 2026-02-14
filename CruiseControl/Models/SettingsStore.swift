import Foundation
import AppKit
import Combine

enum SimModeProfileType: String, Codable, CaseIterable, Identifiable {
    case balanced
    case aggressive
    case streaming

    var id: String { rawValue }

    var displayName: String {
        rawValue.capitalized
    }
}

enum SimProfileListType {
    case allowlist
    case blocklist
    case doNotTouch
}

struct SimModeProfileConfig: Codable {
    var allowlist: [String]
    var blocklist: [String]
    var doNotTouch: [String]
    var autoEnableWhenXPlaneLaunches: Bool
}

struct SimModeActionReport {
    let title: String
    let detailLines: [String]
}

struct ActionOutcome {
    let success: Bool
    let message: String
}

@MainActor
final class SettingsStore: ObservableObject {
    @Published var quitSelectedApps: Bool {
        didSet { savePreferences() }
    }

    @Published var showICloudGuidance: Bool {
        didSet { savePreferences() }
    }

    @Published var showLowPowerGuidance: Bool {
        didSet { savePreferences() }
    }

    @Published var showFocusGuidance: Bool {
        didSet { savePreferences() }
    }

    @Published var sendWarningNotifications: Bool {
        didSet { savePreferences() }
    }

    @Published var samplingInterval: SamplingIntervalOption {
        didSet { savePreferences() }
    }

    @Published var smoothingAlpha: Double {
        didSet { savePreferences() }
    }

    @Published var xPlaneUDPListeningEnabled: Bool {
        didSet { savePreferences() }
    }

    @Published var xPlaneUDPPort: Int {
        didSet { savePreferences() }
    }

    @Published var selectedProfile: SimModeProfileType {
        didSet { savePreferences() }
    }

    @Published var governorModeEnabled: Bool {
        didSet { savePreferences() }
    }

    @Published var governorGroundMaxAGLFeet: Double {
        didSet { savePreferences() }
    }

    @Published var governorCruiseMinAGLFeet: Double {
        didSet { savePreferences() }
    }

    @Published var governorTargetLODGround: Double {
        didSet { savePreferences() }
    }

    @Published var governorTargetLODClimbDescent: Double {
        didSet { savePreferences() }
    }

    @Published var governorTargetLODCruise: Double {
        didSet { savePreferences() }
    }

    @Published var governorLODMinClamp: Double {
        didSet { savePreferences() }
    }

    @Published var governorLODMaxClamp: Double {
        didSet { savePreferences() }
    }

    @Published var governorMinimumTierHoldSeconds: Double {
        didSet { savePreferences() }
    }

    @Published var governorSmoothingDurationSeconds: Double {
        didSet { savePreferences() }
    }

    @Published var governorMinimumCommandIntervalSeconds: Double {
        didSet { savePreferences() }
    }

    @Published var governorMinimumCommandDelta: Double {
        didSet { savePreferences() }
    }

    @Published var governorCommandHost: String {
        didSet { savePreferences() }
    }

    @Published var governorCommandPort: Int {
        didSet { savePreferences() }
    }

    @Published var governorUseMSLFallbackWhenAGLUnavailable: Bool {
        didSet { savePreferences() }
    }

    @Published private(set) var selectedBackgroundBundleIDs: Set<String> {
        didSet { savePreferences() }
    }

    @Published private(set) var isSimModeEnabled: Bool {
        didSet { savePreferences() }
    }

    private var profileConfigs: [SimModeProfileType: SimModeProfileConfig] {
        didSet { savePreferences() }
    }

    private var terminatedBundlePaths: [String] {
        didSet { savePreferences() }
    }

    private let defaults: UserDefaults

    private enum Keys {
        static let quitSelectedApps = "simMode.quitSelectedApps"
        static let showICloudGuidance = "simMode.showICloudGuidance"
        static let showLowPowerGuidance = "simMode.showLowPowerGuidance"
        static let showFocusGuidance = "simMode.showFocusGuidance"
        static let sendWarningNotifications = "warnings.sendNotification"
        static let samplingInterval = "sampling.interval"
        static let smoothingAlpha = "sampling.smoothingAlpha"
        static let xPlaneUDPListeningEnabled = "xplane.udpListeningEnabled"
        static let xPlaneUDPPort = "xplane.udpPort"
        static let selectedProfile = "simMode.selectedProfile"
        static let selectedBackgroundBundleIDs = "simMode.selectedBackgroundBundleIDs"
        static let isSimModeEnabled = "simMode.isEnabled"
        static let terminatedBundlePaths = "simMode.terminatedBundlePaths"
        static let profileConfigsData = "simMode.profileConfigsData"

        static let governorModeEnabled = "governor.enabled"
        static let governorGroundMaxAGLFeet = "governor.groundMaxAGLFeet"
        static let governorCruiseMinAGLFeet = "governor.cruiseMinAGLFeet"
        static let governorTargetLODGround = "governor.targetLOD.ground"
        static let governorTargetLODClimbDescent = "governor.targetLOD.climbDescent"
        static let governorTargetLODCruise = "governor.targetLOD.cruise"
        static let governorLODMinClamp = "governor.lod.minClamp"
        static let governorLODMaxClamp = "governor.lod.maxClamp"
        static let governorMinimumTierHoldSeconds = "governor.tier.minimumHoldSeconds"
        static let governorSmoothingDurationSeconds = "governor.smoothing.durationSeconds"
        static let governorMinimumCommandIntervalSeconds = "governor.command.minimumIntervalSeconds"
        static let governorMinimumCommandDelta = "governor.command.minimumDelta"
        static let governorCommandHost = "governor.command.host"
        static let governorCommandPort = "governor.command.port"
        static let governorUseMSLFallbackWhenAGLUnavailable = "governor.altitude.useMSLFallback"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.quitSelectedApps = defaults.object(forKey: Keys.quitSelectedApps) as? Bool ?? true
        self.showICloudGuidance = defaults.object(forKey: Keys.showICloudGuidance) as? Bool ?? true
        self.showLowPowerGuidance = defaults.object(forKey: Keys.showLowPowerGuidance) as? Bool ?? true
        self.showFocusGuidance = defaults.object(forKey: Keys.showFocusGuidance) as? Bool ?? true
        self.sendWarningNotifications = defaults.object(forKey: Keys.sendWarningNotifications) as? Bool ?? false

        if let raw = defaults.string(forKey: Keys.samplingInterval),
           let parsed = SamplingIntervalOption(rawValue: raw) {
            self.samplingInterval = parsed
        } else {
            self.samplingInterval = .oneSecond
        }

        let storedAlpha = defaults.object(forKey: Keys.smoothingAlpha) as? Double ?? 0.35
        self.smoothingAlpha = min(max(storedAlpha, 0.05), 0.95)

        self.xPlaneUDPListeningEnabled = defaults.object(forKey: Keys.xPlaneUDPListeningEnabled) as? Bool ?? true

        let storedUDPPort = defaults.object(forKey: Keys.xPlaneUDPPort) as? Int ?? 49_005
        self.xPlaneUDPPort = min(max(storedUDPPort, 1_024), 65_535)

        if let raw = defaults.string(forKey: Keys.selectedProfile),
           let parsed = SimModeProfileType(rawValue: raw) {
            self.selectedProfile = parsed
        } else {
            self.selectedProfile = .balanced
        }

        let selectedIDs = defaults.array(forKey: Keys.selectedBackgroundBundleIDs) as? [String] ?? []
        self.selectedBackgroundBundleIDs = Set(selectedIDs)

        self.isSimModeEnabled = defaults.object(forKey: Keys.isSimModeEnabled) as? Bool ?? false
        self.terminatedBundlePaths = defaults.array(forKey: Keys.terminatedBundlePaths) as? [String] ?? []

        if let data = defaults.data(forKey: Keys.profileConfigsData),
           let decoded = try? JSONDecoder().decode([SimModeProfileType: SimModeProfileConfig].self, from: data) {
            self.profileConfigs = decoded
        } else {
            self.profileConfigs = SettingsStore.defaultProfileConfigs
        }

        self.governorModeEnabled = defaults.object(forKey: Keys.governorModeEnabled) as? Bool ?? GovernorPolicyConfig.default.enabled
        self.governorGroundMaxAGLFeet = defaults.object(forKey: Keys.governorGroundMaxAGLFeet) as? Double ?? GovernorPolicyConfig.default.groundMaxAGLFeet
        self.governorCruiseMinAGLFeet = defaults.object(forKey: Keys.governorCruiseMinAGLFeet) as? Double ?? GovernorPolicyConfig.default.cruiseMinAGLFeet
        self.governorTargetLODGround = defaults.object(forKey: Keys.governorTargetLODGround) as? Double ?? GovernorPolicyConfig.default.targetLODGround
        self.governorTargetLODClimbDescent = defaults.object(forKey: Keys.governorTargetLODClimbDescent) as? Double ?? GovernorPolicyConfig.default.targetLODClimbDescent
        self.governorTargetLODCruise = defaults.object(forKey: Keys.governorTargetLODCruise) as? Double ?? GovernorPolicyConfig.default.targetLODCruise
        self.governorLODMinClamp = defaults.object(forKey: Keys.governorLODMinClamp) as? Double ?? GovernorPolicyConfig.default.clampMinLOD
        self.governorLODMaxClamp = defaults.object(forKey: Keys.governorLODMaxClamp) as? Double ?? GovernorPolicyConfig.default.clampMaxLOD
        self.governorMinimumTierHoldSeconds = defaults.object(forKey: Keys.governorMinimumTierHoldSeconds) as? Double ?? GovernorPolicyConfig.default.minimumTierHoldSeconds
        self.governorSmoothingDurationSeconds = defaults.object(forKey: Keys.governorSmoothingDurationSeconds) as? Double ?? GovernorPolicyConfig.default.smoothingDurationSeconds
        self.governorMinimumCommandIntervalSeconds = defaults.object(forKey: Keys.governorMinimumCommandIntervalSeconds) as? Double ?? GovernorPolicyConfig.default.minimumCommandIntervalSeconds
        self.governorMinimumCommandDelta = defaults.object(forKey: Keys.governorMinimumCommandDelta) as? Double ?? GovernorPolicyConfig.default.minimumCommandDelta
        self.governorCommandHost = defaults.string(forKey: Keys.governorCommandHost) ?? GovernorPolicyConfig.default.commandHost

        let storedCommandPort = defaults.object(forKey: Keys.governorCommandPort) as? Int ?? GovernorPolicyConfig.default.commandPort
        self.governorCommandPort = min(max(storedCommandPort, 1_024), 65_535)
        self.governorUseMSLFallbackWhenAGLUnavailable = defaults.object(forKey: Keys.governorUseMSLFallbackWhenAGLUnavailable) as? Bool ?? GovernorPolicyConfig.default.useMSLFallbackWhenAGLUnavailable
    }

    var governorConfig: GovernorPolicyConfig {
        let groundMax = max(governorGroundMaxAGLFeet, 100)
        let cruiseMin = max(governorCruiseMinAGLFeet, groundMax + 100)
        let minClamp = min(governorLODMinClamp, governorLODMaxClamp)
        let maxClamp = max(governorLODMinClamp, governorLODMaxClamp)

        return GovernorPolicyConfig(
            enabled: governorModeEnabled,
            groundMaxAGLFeet: groundMax,
            cruiseMinAGLFeet: cruiseMin,
            targetLODGround: governorTargetLODGround,
            targetLODClimbDescent: governorTargetLODClimbDescent,
            targetLODCruise: governorTargetLODCruise,
            clampMinLOD: minClamp,
            clampMaxLOD: maxClamp,
            minimumTierHoldSeconds: max(governorMinimumTierHoldSeconds, 0),
            smoothingDurationSeconds: max(governorSmoothingDurationSeconds, 0.1),
            minimumCommandIntervalSeconds: max(governorMinimumCommandIntervalSeconds, 0.1),
            minimumCommandDelta: max(governorMinimumCommandDelta, 0.005),
            commandHost: governorCommandHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "127.0.0.1" : governorCommandHost,
            commandPort: min(max(governorCommandPort, 1_024), 65_535),
            useMSLFallbackWhenAGLUnavailable: governorUseMSLFallbackWhenAGLUnavailable
        )
    }

    func updateSelection(bundleID: String, selected: Bool) {
        if selected {
            selectedBackgroundBundleIDs.insert(bundleID)
        } else {
            selectedBackgroundBundleIDs.remove(bundleID)
        }
    }

    func profileConfig(for profile: SimModeProfileType) -> SimModeProfileConfig {
        profileConfigs[profile] ?? SettingsStore.defaultProfileConfig(for: profile)
    }

    func updateAutoEnableForSelectedProfile(_ enabled: Bool) {
        var config = profileConfig(for: selectedProfile)
        config.autoEnableWhenXPlaneLaunches = enabled
        profileConfigs[selectedProfile] = config
    }

    func listString(for listType: SimProfileListType, profile: SimModeProfileType) -> String {
        let config = profileConfig(for: profile)
        let items: [String]

        switch listType {
        case .allowlist:
            items = config.allowlist
        case .blocklist:
            items = config.blocklist
        case .doNotTouch:
            items = config.doNotTouch
        }

        return items.joined(separator: ", ")
    }

    func updateList(_ rawValue: String, listType: SimProfileListType, profile: SimModeProfileType) {
        var config = profileConfig(for: profile)
        let parsed = parseBundleIDList(rawValue)

        switch listType {
        case .allowlist:
            config.allowlist = parsed
        case .blocklist:
            config.blocklist = parsed
        case .doNotTouch:
            config.doNotTouch = parsed
        }

        profileConfigs[profile] = config
    }

    func shouldAutoEnableForSelectedProfile() -> Bool {
        profileConfig(for: selectedProfile).autoEnableWhenXPlaneLaunches
    }

    func enableSimMode(trigger: String = "Manual") -> SimModeActionReport {
        let config = profileConfig(for: selectedProfile)
        var detailLines: [String] = ["Profile: \(selectedProfile.displayName) (\(trigger))."]
        var terminatedNow: [String] = []

        let protectedIDs = Set(config.allowlist + config.doNotTouch)

        if quitSelectedApps {
            let terminationCandidates = Set(selectedBackgroundBundleIDs).union(config.blocklist)
            if terminationCandidates.isEmpty {
                detailLines.append("No background apps selected by profile/selection.")
            }

            for bundleID in terminationCandidates.sorted() {
                if protectedIDs.contains(bundleID) {
                    detailLines.append("\(bundleID): skipped (allowlist/do-not-touch).")
                    continue
                }

                let bundlePath = runningApplicationBundlePath(bundleID: bundleID)
                let result = terminateApplication(bundleID: bundleID, force: false)
                detailLines.append("\(bundleID): \(result.message)")

                if result.success, let bundlePath {
                    terminatedNow.append(bundlePath)
                }
            }
        } else {
            detailLines.append("App termination actions are disabled.")
        }

        if showICloudGuidance {
            detailLines.append("iCloud Drive prompts cannot be programmatically disabled by this app; follow guidance in Settings.")
        }
        if showLowPowerGuidance {
            detailLines.append("Low Power Mode must be changed by the user in System Settings.")
        }
        if showFocusGuidance {
            detailLines.append("Focus/notification suppression must be user-configured in System Settings.")
        }

        terminatedBundlePaths = Array(Set(terminatedNow)).sorted()
        isSimModeEnabled = true

        return SimModeActionReport(title: "Sim Mode enabled", detailLines: detailLines)
    }

    func revertSimMode() -> SimModeActionReport {
        var detailLines: [String] = []

        for path in terminatedBundlePaths {
            let url = URL(fileURLWithPath: path)
            let configuration = NSWorkspace.OpenConfiguration()
            NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, error in
                if let error {
                    NSLog("CruiseControl: Failed to relaunch app at path \(path): \(error.localizedDescription)")
                }
            }
            detailLines.append("Requested relaunch: \(url.lastPathComponent)")
        }

        if detailLines.isEmpty {
            detailLines.append("No previously terminated apps were tracked.")
        }

        terminatedBundlePaths = []
        isSimModeEnabled = false

        return SimModeActionReport(title: "Sim Mode reverted", detailLines: detailLines)
    }

    func openInActivityMonitor(process: ProcessSample) -> ActionOutcome {
        let openProcess = Process()
        openProcess.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        openProcess.arguments = ["-a", "Activity Monitor"]

        do {
            try openProcess.run()
            openProcess.waitUntilExit()
            if openProcess.terminationStatus == 0 {
                return ActionOutcome(success: true, message: "Opened Activity Monitor. Search PID \(process.pid).")
            }
            return ActionOutcome(success: false, message: "Could not open Activity Monitor (exit code \(openProcess.terminationStatus)).")
        } catch {
            return ActionOutcome(success: false, message: "Could not launch Activity Monitor: \(error.localizedDescription)")
        }
    }

    func terminateProcess(pid: Int32, force: Bool) -> ActionOutcome {
        guard let app = NSRunningApplication(processIdentifier: pid_t(pid)) else {
            return ActionOutcome(success: false, message: "Process \(pid) is no longer running or is not controllable via NSRunningApplication.")
        }

        if let bundleID = app.bundleIdentifier {
            let protectedIDs = Set(profileConfig(for: selectedProfile).allowlist + profileConfig(for: selectedProfile).doNotTouch)
            if protectedIDs.contains(bundleID) {
                return ActionOutcome(success: false, message: "\(bundleID) is marked allowlist/do-not-touch in the current profile.")
            }
        }

        let success = force ? app.forceTerminate() : app.terminate()
        let appName = app.localizedName ?? app.bundleIdentifier ?? "pid \(pid)"

        if success {
            return ActionOutcome(success: true, message: force ? "Force quit requested for \(appName)." : "Quit requested for \(appName).")
        }

        if force {
            return ActionOutcome(success: false, message: "Force quit failed for \(appName). macOS may block this target or required permissions are missing.")
        }

        return ActionOutcome(success: false, message: "Quit failed for \(appName). The app may have refused termination or requires user confirmation.")
    }

    private func runningApplicationBundlePath(bundleID: String) -> String? {
        NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleID })?.bundleURL?.path
    }

    private func terminateApplication(bundleID: String, force: Bool) -> ActionOutcome {
        guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleID }) else {
            return ActionOutcome(success: false, message: "Not currently running.")
        }

        let appName = app.localizedName ?? bundleID
        let success = force ? app.forceTerminate() : app.terminate()
        if success {
            return ActionOutcome(success: true, message: "\(appName): Termination requested.")
        }

        if force {
            return ActionOutcome(success: false, message: "Force quit failed (permission denied or system-protected process).")
        }

        return ActionOutcome(success: false, message: "Could not terminate. App may refuse quit, prompt for save, or be permission-restricted.")
    }

    private func parseBundleIDList(_ rawValue: String) -> [String] {
        rawValue
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .sorted()
    }

    private func savePreferences() {
        defaults.set(quitSelectedApps, forKey: Keys.quitSelectedApps)
        defaults.set(showICloudGuidance, forKey: Keys.showICloudGuidance)
        defaults.set(showLowPowerGuidance, forKey: Keys.showLowPowerGuidance)
        defaults.set(showFocusGuidance, forKey: Keys.showFocusGuidance)
        defaults.set(sendWarningNotifications, forKey: Keys.sendWarningNotifications)
        defaults.set(samplingInterval.rawValue, forKey: Keys.samplingInterval)
        defaults.set(smoothingAlpha, forKey: Keys.smoothingAlpha)
        defaults.set(xPlaneUDPListeningEnabled, forKey: Keys.xPlaneUDPListeningEnabled)
        defaults.set(min(max(xPlaneUDPPort, 1_024), 65_535), forKey: Keys.xPlaneUDPPort)
        defaults.set(selectedProfile.rawValue, forKey: Keys.selectedProfile)
        defaults.set(Array(selectedBackgroundBundleIDs).sorted(), forKey: Keys.selectedBackgroundBundleIDs)
        defaults.set(isSimModeEnabled, forKey: Keys.isSimModeEnabled)
        defaults.set(terminatedBundlePaths, forKey: Keys.terminatedBundlePaths)

        defaults.set(governorModeEnabled, forKey: Keys.governorModeEnabled)
        defaults.set(governorGroundMaxAGLFeet, forKey: Keys.governorGroundMaxAGLFeet)
        defaults.set(governorCruiseMinAGLFeet, forKey: Keys.governorCruiseMinAGLFeet)
        defaults.set(governorTargetLODGround, forKey: Keys.governorTargetLODGround)
        defaults.set(governorTargetLODClimbDescent, forKey: Keys.governorTargetLODClimbDescent)
        defaults.set(governorTargetLODCruise, forKey: Keys.governorTargetLODCruise)
        defaults.set(governorLODMinClamp, forKey: Keys.governorLODMinClamp)
        defaults.set(governorLODMaxClamp, forKey: Keys.governorLODMaxClamp)
        defaults.set(governorMinimumTierHoldSeconds, forKey: Keys.governorMinimumTierHoldSeconds)
        defaults.set(governorSmoothingDurationSeconds, forKey: Keys.governorSmoothingDurationSeconds)
        defaults.set(governorMinimumCommandIntervalSeconds, forKey: Keys.governorMinimumCommandIntervalSeconds)
        defaults.set(governorMinimumCommandDelta, forKey: Keys.governorMinimumCommandDelta)
        defaults.set(governorCommandHost, forKey: Keys.governorCommandHost)
        defaults.set(min(max(governorCommandPort, 1_024), 65_535), forKey: Keys.governorCommandPort)
        defaults.set(governorUseMSLFallbackWhenAGLUnavailable, forKey: Keys.governorUseMSLFallbackWhenAGLUnavailable)

        if let encoded = try? JSONEncoder().encode(profileConfigs) {
            defaults.set(encoded, forKey: Keys.profileConfigsData)
        }
    }

    private static func defaultProfileConfig(for profile: SimModeProfileType) -> SimModeProfileConfig {
        switch profile {
        case .balanced:
            return SimModeProfileConfig(
                allowlist: [],
                blocklist: [],
                doNotTouch: ["com.apple.finder"],
                autoEnableWhenXPlaneLaunches: false
            )
        case .aggressive:
            return SimModeProfileConfig(
                allowlist: [],
                blocklist: ["com.google.Chrome", "com.apple.Safari"],
                doNotTouch: ["com.apple.finder"],
                autoEnableWhenXPlaneLaunches: false
            )
        case .streaming:
            return SimModeProfileConfig(
                allowlist: ["com.obsproject.obs-studio"],
                blocklist: [],
                doNotTouch: ["com.apple.finder", "com.obsproject.obs-studio"],
                autoEnableWhenXPlaneLaunches: false
            )
        }
    }

    private static let defaultProfileConfigs: [SimModeProfileType: SimModeProfileConfig] = {
        var result: [SimModeProfileType: SimModeProfileConfig] = [:]
        SimModeProfileType.allCases.forEach { result[$0] = defaultProfileConfig(for: $0) }
        return result
    }()
}
