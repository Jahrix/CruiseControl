import Foundation
import Combine

@MainActor
final class V112FeatureStore: ObservableObject {
    @Published var historyDuration: HistoryDurationOption {
        didSet { save() }
    }

    @Published var manualAirportICAO: String {
        didSet { save() }
    }

    @Published var airportProfiles: [AirportGovernorProfile] {
        didSet { save() }
    }

    @Published var advancedModeEnabled: Bool {
        didSet { save() }
    }

    @Published var advancedModeExtraConfirmation: Bool {
        didSet { save() }
    }

    @Published var purgeAttemptEnabled: Bool {
        didSet { save() }
    }

    @Published var stutterHeuristics: StutterHeuristicConfig {
        didSet { save() }
    }

    @Published var optimizationProcessAllowlist: [String] {
        didSet { save() }
    }

    @Published var largeFilesTopN: Int {
        didSet {
            largeFilesTopN = min(max(largeFilesTopN, 10), 200)
            save()
        }
    }

    @Published var largeFilesDefaultScopes: [String] {
        didSet { save() }
    }

     var pauseBackgroundScansDuringSim: Bool {
        didSet { save() }
    }

    private let defaults: UserDefaults

    private enum Keys {
        static let historyDuration = "v112.history.duration"
        static let manualAirportICAO = "v112.airport.manualICAO"
        static let airportProfiles = "v112.airport.profiles"
        static let advancedModeEnabled = "v112.cleaner.advancedMode"
        static let advancedModeExtraConfirmation = "v114.cleaner.advancedModeExtraConfirmation"
        static let purgeAttemptEnabled = "v112.cleaner.purgeAttempt"
        static let stutterHeuristics = "v112.stutter.heuristics"
        static let optimizationProcessAllowlist = "v114.optimization.allowlist"
        static let largeFilesTopN = "v114.largeFiles.topN"
        static let largeFilesDefaultScopes = "v114.largeFiles.defaultScopes"
        static let pauseBackgroundScansDuringSim = "v114.scans.pauseWhenSimActive"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        if let raw = defaults.string(forKey: Keys.historyDuration),
           let parsed = HistoryDurationOption(rawValue: raw) {
            self.historyDuration = parsed
        } else {
            self.historyDuration = .tenMinutes
        }

        self.manualAirportICAO = defaults.string(forKey: Keys.manualAirportICAO) ?? ""

        if let data = defaults.data(forKey: Keys.airportProfiles),
           let parsed = try? JSONDecoder().decode([AirportGovernorProfile].self, from: data),
           !parsed.isEmpty {
            self.airportProfiles = parsed
        } else {
            self.airportProfiles = AirportGovernorProfile.examples
        }

        self.advancedModeEnabled = defaults.object(forKey: Keys.advancedModeEnabled) as? Bool ?? false
        self.advancedModeExtraConfirmation = defaults.object(forKey: Keys.advancedModeExtraConfirmation) as? Bool ?? true
        self.purgeAttemptEnabled = defaults.object(forKey: Keys.purgeAttemptEnabled) as? Bool ?? false

        if let data = defaults.data(forKey: Keys.stutterHeuristics),
           let parsed = try? JSONDecoder().decode(StutterHeuristicConfig.self, from: data) {
            self.stutterHeuristics = parsed
        } else {
            self.stutterHeuristics = .default
        }

        self.optimizationProcessAllowlist = defaults.array(forKey: Keys.optimizationProcessAllowlist) as? [String] ?? []

        let storedTopN = defaults.object(forKey: Keys.largeFilesTopN) as? Int ?? 25
        self.largeFilesTopN = min(max(storedTopN, 10), 200)

        self.largeFilesDefaultScopes = defaults.array(forKey: Keys.largeFilesDefaultScopes) as? [String] ?? []
        self.pauseBackgroundScansDuringSim = defaults.object(forKey: Keys.pauseBackgroundScansDuringSim) as? Bool ?? true
    }

    func upsertAirportProfile(_ profile: AirportGovernorProfile) {
        let normalized = AirportGovernorProfile.normalizeICAO(profile.icao)
        guard !normalized.isEmpty else { return }

        if let index = airportProfiles.firstIndex(where: { AirportGovernorProfile.normalizeICAO($0.icao) == normalized }) {
            airportProfiles[index] = profile
        } else {
            airportProfiles.append(profile)
        }

        airportProfiles.sort { $0.icao < $1.icao }
    }

    func deleteAirportProfile(icao: String) {
        let normalized = AirportGovernorProfile.normalizeICAO(icao)
        airportProfiles.removeAll { AirportGovernorProfile.normalizeICAO($0.icao) == normalized }
    }

    func profile(forICAO icao: String?) -> AirportGovernorProfile? {
        let normalized = AirportGovernorProfile.normalizeICAO(icao ?? manualAirportICAO)
        guard !normalized.isEmpty else { return nil }
        return airportProfiles.first { AirportGovernorProfile.normalizeICAO($0.icao) == normalized }
    }

    func exportAirportProfiles() -> ActionOutcome {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        do {
            let data = try encoder.encode(airportProfiles)
            let destination = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            let fileURL = destination.appendingPathComponent("CruiseControl-airport-profiles.json")
            try data.write(to: fileURL, options: .atomic)
            return ActionOutcome(success: true, message: "Exported airport profiles to \(fileURL.path).")
        } catch {
            return ActionOutcome(success: false, message: "Failed to export airport profiles: \(error.localizedDescription)")
        }
    }

    func importAirportProfiles(from jsonText: String) -> ActionOutcome {
        let trimmed = jsonText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return ActionOutcome(success: false, message: "Paste profile JSON before importing.")
        }

        do {
            let decoded = try JSONDecoder().decode([AirportGovernorProfile].self, from: Data(trimmed.utf8))
            if decoded.isEmpty {
                return ActionOutcome(success: false, message: "No airport profiles found in JSON.")
            }
            airportProfiles = decoded.sorted { $0.icao < $1.icao }
            return ActionOutcome(success: true, message: "Imported \(decoded.count) airport profile(s).")
        } catch {
            return ActionOutcome(success: false, message: "Invalid airport profile JSON: \(error.localizedDescription)")
        }
    }

    func effectiveGovernorConfig(base: GovernorPolicyConfig, telemetryICAO: String?) -> GovernorPolicyConfig {
        guard let profile = profile(forICAO: telemetryICAO) else {
            return base
        }

        var config = base
        config.groundMaxAGLFeet = profile.groundMaxAGLFeet
        config.cruiseMinAGLFeet = profile.cruiseMinAGLFeet
        config.targetLODGround = profile.targetLODGround
        config.targetLODClimbDescent = profile.targetLODTransition
        config.targetLODCruise = profile.targetLODCruise
        config.clampMinLOD = profile.clampMinLOD
        config.clampMaxLOD = profile.clampMaxLOD
        return config
    }

    func isProcessAllowlisted(_ processName: String) -> Bool {
        optimizationProcessAllowlist.contains { $0.caseInsensitiveCompare(processName) == .orderedSame }
    }

    func addProcessToAllowlist(_ processName: String) {
        guard !isProcessAllowlisted(processName) else { return }
        optimizationProcessAllowlist.append(processName)
        optimizationProcessAllowlist.sort { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    func removeProcessFromAllowlist(_ processName: String) {
        optimizationProcessAllowlist.removeAll { $0.caseInsensitiveCompare(processName) == .orderedSame }
    }

    private func save() {
        defaults.set(historyDuration.rawValue, forKey: Keys.historyDuration)
        defaults.set(manualAirportICAO, forKey: Keys.manualAirportICAO)
        defaults.set(advancedModeEnabled, forKey: Keys.advancedModeEnabled)
        defaults.set(advancedModeExtraConfirmation, forKey: Keys.advancedModeExtraConfirmation)
        defaults.set(purgeAttemptEnabled, forKey: Keys.purgeAttemptEnabled)
        defaults.set(optimizationProcessAllowlist, forKey: Keys.optimizationProcessAllowlist)
        defaults.set(largeFilesTopN, forKey: Keys.largeFilesTopN)
        defaults.set(largeFilesDefaultScopes, forKey: Keys.largeFilesDefaultScopes)
        defaults.set(pauseBackgroundScansDuringSim, forKey: Keys.pauseBackgroundScansDuringSim)

        if let profilesData = try? JSONEncoder().encode(airportProfiles) {
            defaults.set(profilesData, forKey: Keys.airportProfiles)
        }
        if let stutterData = try? JSONEncoder().encode(stutterHeuristics) {
            defaults.set(stutterData, forKey: Keys.stutterHeuristics)
        }
    }
}
