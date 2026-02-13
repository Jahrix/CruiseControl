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

struct SmartScanSummary {
    let generatedAt: Date
    let duration: TimeInterval
    let items: [SmartScanItem]

    var totalBytes: UInt64 {
        items.reduce(0) { $0 + $1.sizeBytes }
    }
}

struct QuarantineManifestEntry: Codable, Hashable {
    let originalPath: String
    let quarantinedPath: String
    let sizeBytes: UInt64
    let timestamp: Date
}

struct QuarantineManifest: Codable {
    let createdAt: Date
    let entries: [QuarantineManifestEntry]
}
