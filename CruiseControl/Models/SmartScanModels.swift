import Foundation

enum SmartScanModule: String, Codable, CaseIterable, Identifiable {
    case systemJunk = "System Junk"
    case trashBins = "Trash Bins"
    case largeFiles = "Large Files"
    case optimization = "Optimization"
    case privacy = "Privacy"

    var id: String { rawValue }
}

struct SmartScanItem: Identifiable, Codable, Hashable {
    let id: UUID
    let module: SmartScanModule
    let path: String
    let sizeBytes: UInt64
    let note: String
    let safeByDefault: Bool

    init(module: SmartScanModule, path: String, sizeBytes: UInt64, note: String = "", safeByDefault: Bool = true) {
        self.id = UUID()
        self.module = module
        self.path = path
        self.sizeBytes = sizeBytes
        self.note = note
        self.safeByDefault = safeByDefault
    }
}

struct SmartScanModuleResult: Identifiable, Codable {
    let module: SmartScanModule
    let items: [SmartScanItem]
    let bytes: UInt64
    let duration: TimeInterval
    let error: String?

    var id: SmartScanModule { module }
}

struct SmartScanSummary {
    let generatedAt: Date
    let duration: TimeInterval
    let moduleResults: [SmartScanModuleResult]
    let items: [SmartScanItem]

    var totalBytes: UInt64 {
        items.reduce(0) { $0 + $1.sizeBytes }
    }
}

struct SmartScanRunState {
    var isRunning: Bool
    var overallProgress: Double
    var moduleProgress: [SmartScanModule: Double]
    var startedAt: Date?
    var finishedAt: Date?
    var cancellable: Bool
    var completedModules: Set<SmartScanModule>

    static let idle = SmartScanRunState(
        isRunning: false,
        overallProgress: 0,
        moduleProgress: [:],
        startedAt: nil,
        finishedAt: nil,
        cancellable: false,
        completedModules: []
    )
}

struct QuarantineBatchSummary: Identifiable, Hashable {
    let batchID: String
    let folderPath: String
    let createdAt: Date
    let entryCount: Int
    let totalBytes: UInt64

    var id: String { batchID }
}

struct QuarantineManifestEntry: Codable, Hashable {
    let originalPath: String
    let quarantinedPath: String
    let sizeBytes: UInt64
    let timestamp: Date
    let sha256: String?
}

struct QuarantineManifest: Codable {
    let batchId: String
    let createdAt: Date
    let totalBytes: UInt64
    let entries: [QuarantineManifestEntry]
}
