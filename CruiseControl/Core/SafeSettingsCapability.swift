import Foundation

/// The only allowlisted setting that the installed companion bridge can expose today.
/// Additional settings must be added here before they can be considered for a write.
enum SafeSettingID: String, Codable, CaseIterable, Hashable {
    case lodBias
}

enum XPlaneSimulatorVersion: String, Codable, CaseIterable {
    case xp11 = "XP11"
    case xp12 = "XP12"
    case unknown
}

enum SafeSettingValue: Equatable, Codable {
    case number(Double)
    case choice(String)

    private enum CodingKeys: String, CodingKey { case kind, number, choice }
    private enum Kind: String, Codable { case number, choice }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .number:
            self = .number(try container.decode(Double.self, forKey: .number))
        case .choice:
            self = .choice(try container.decode(String.self, forKey: .choice))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .number(value):
            try container.encode(Kind.number, forKey: .kind)
            try container.encode(value, forKey: .number)
        case let .choice(value):
            try container.encode(Kind.choice, forKey: .kind)
            try container.encode(value, forKey: .choice)
        }
    }
}

enum SafeSettingAllowedValues: Equatable {
    case numericRange(ClosedRange<Double>)
    case choices(Set<String>)

    func contains(_ value: SafeSettingValue) -> Bool {
        switch (self, value) {
        case let (.numericRange(range), .number(number)):
            return number.isFinite && range.contains(number)
        case let (.choices(choices), .choice(choice)):
            return choices.contains(choice)
        default:
            return false
        }
    }
}

enum SafeSettingWriteMechanism: Equatable {
    case bridgeCommand(String)
    case preferenceFile
    case unsupported
}

enum SafeSettingReadability: String, Codable {
    case readable
    case unavailable
}

enum SafeSettingWritability: String, Codable {
    case writable
    case runtimeVerificationRequired
    case readOnly
    case unsupported
}

enum SafeSettingChangeTiming: String, Codable {
    case live
    case restartRequired
}

enum SafeSettingRollback: String, Codable {
    case restorePreviousValue
    case restorePreferenceBackup
    case unavailable
}

struct SafeSettingsRuntime: Equatable {
    var simulatorVersion: XPlaneSimulatorVersion
    var currentValues: [SafeSettingID: SafeSettingValue]
    /// Values in this set are supplied only after the bridge has verified the
    /// corresponding dataref or command can be written in this X-Plane session.
    var writableSettings: Set<SafeSettingID>

    static let unavailable = SafeSettingsRuntime(
        simulatorVersion: .unknown,
        currentValues: [:],
        writableSettings: []
    )
}

struct SafeSettingsCapability: Equatable {
    let id: SafeSettingID
    let supportedSimulatorVersions: Set<XPlaneSimulatorVersion>
    let currentValue: SafeSettingValue?
    let readability: SafeSettingReadability
    let writability: SafeSettingWritability
    let allowedValues: SafeSettingAllowedValues
    let writeMechanism: SafeSettingWriteMechanism
    let changeTiming: SafeSettingChangeTiming
    let rollback: SafeSettingRollback

    func supports(_ simulatorVersion: XPlaneSimulatorVersion) -> Bool {
        supportedSimulatorVersions.contains(simulatorVersion)
    }
}

/// A strict, typed registry. There is deliberately no fallback for a raw
/// dataref name or preference key: unregistered settings cannot be written.
enum SafeSettingsCapabilityRegistry {
    static func capability(
        for id: SafeSettingID,
        runtime: SafeSettingsRuntime
    ) -> SafeSettingsCapability {
        let currentValue = runtime.currentValues[id]
        let writability: SafeSettingWritability
        if runtime.writableSettings.contains(id) {
            writability = .writable
        } else if currentValue != nil {
            writability = .runtimeVerificationRequired
        } else {
            writability = .readOnly
        }

        switch id {
        case .lodBias:
            return SafeSettingsCapability(
                id: .lodBias,
                supportedSimulatorVersions: [.xp11, .xp12],
                currentValue: currentValue,
                readability: currentValue == nil ? .unavailable : .readable,
                writability: writability,
                allowedValues: .numericRange(0.20...3.00),
                writeMechanism: .bridgeCommand("SET_LOD"),
                changeTiming: .live,
                rollback: .restorePreviousValue
            )
        }
    }
}

struct SafeSettingsWriteRequest: Equatable {
    let settingID: SafeSettingID
    let value: SafeSettingValue
}

enum SafeSettingsWriteOutcome: String, Codable {
    case applied
    case rejectedUnsupportedSimulator
    case rejectedNotWritable
    case rejectedInvalidValue
    case failed
}

struct SafeSettingsReceipt: Identifiable, Equatable {
    let id: UUID
    let attemptedAt: Date
    let settingID: SafeSettingID
    let requestedValue: SafeSettingValue
    let previousValue: SafeSettingValue?
    let outcome: SafeSettingsWriteOutcome
    let rollback: SafeSettingRollback
    let message: String
}

protocol SafeSettingsWriter {
    func write(_ value: SafeSettingValue, for capability: SafeSettingsCapability) throws
}

/// The sole execution gate for future supported X-Plane setting changes.
/// It contains no transport or file-writing implementation; callers must
/// supply a verified writer, making it safe to exercise with test doubles.
struct SafeSettingsWriteGateway {
    func execute(
        _ request: SafeSettingsWriteRequest,
        runtime: SafeSettingsRuntime,
        writer: SafeSettingsWriter,
        now: Date = Date()
    ) -> SafeSettingsReceipt {
        let capability = SafeSettingsCapabilityRegistry.capability(for: request.settingID, runtime: runtime)
        let previousValue = capability.currentValue

        guard capability.supports(runtime.simulatorVersion) else {
            return receipt(request, previousValue: previousValue, outcome: .rejectedUnsupportedSimulator, rollback: capability.rollback, message: "(request.settingID.rawValue) is not supported by the connected simulator.", now: now)
        }
        guard capability.writability == .writable else {
            return receipt(request, previousValue: previousValue, outcome: .rejectedNotWritable, rollback: capability.rollback, message: "(request.settingID.rawValue) has not passed runtime writability verification.", now: now)
        }
        guard capability.allowedValues.contains(request.value) else {
            return receipt(request, previousValue: previousValue, outcome: .rejectedInvalidValue, rollback: capability.rollback, message: "The requested value is outside the allowlisted range.", now: now)
        }

        do {
            try writer.write(request.value, for: capability)
            return receipt(request, previousValue: previousValue, outcome: .applied, rollback: capability.rollback, message: "Applied through the verified (request.settingID.rawValue) capability.", now: now)
        } catch {
            return receipt(request, previousValue: previousValue, outcome: .failed, rollback: capability.rollback, message: error.localizedDescription, now: now)
        }
    }

    private func receipt(
        _ request: SafeSettingsWriteRequest,
        previousValue: SafeSettingValue?,
        outcome: SafeSettingsWriteOutcome,
        rollback: SafeSettingRollback,
        message: String,
        now: Date
    ) -> SafeSettingsReceipt {
        SafeSettingsReceipt(
            id: UUID(),
            attemptedAt: now,
            settingID: request.settingID,
            requestedValue: request.value,
            previousValue: previousValue,
            outcome: outcome,
            rollback: rollback,
            message: message
        )
    }
}

/// File-backed capabilities must create a backup before an edit and can use
/// the returned URL to restore the original bytes. No current capability uses
/// preference-file writes, but this makes that requirement explicit.
struct SafeSettingsPreferenceBackupStore {
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func backup(fileURL: URL, into directoryURL: URL) throws -> URL {
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let backupURL = directoryURL.appendingPathComponent("\(fileURL.lastPathComponent).\(UUID().uuidString).backup")
        try fileManager.copyItem(at: fileURL, to: backupURL)
        return backupURL
    }

    func restore(backupURL: URL, to fileURL: URL) throws {
        let replacementURL = fileURL.deletingLastPathComponent().appendingPathComponent(".\(fileURL.lastPathComponent).restore-\(UUID().uuidString)")
        try fileManager.copyItem(at: backupURL, to: replacementURL)
        _ = try fileManager.replaceItemAt(fileURL, withItemAt: replacementURL)
    }
}
