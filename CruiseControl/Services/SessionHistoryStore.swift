import Foundation
import Combine

@MainActor
final class SessionHistoryStore: ObservableObject {
    @Published private(set) var records: [FlightSessionRecord]
    @Published private(set) var lastError: String?

    private let fileManager: FileManager
    private let fileURL: URL

    init(fileManager: FileManager = .default, fileURL: URL? = nil) {
        self.fileManager = fileManager
        self.fileURL = fileURL ?? Self.defaultFileURL(fileManager: fileManager)
        self.records = []
        self.lastError = nil
        load()
    }

    func append(_ record: FlightSessionRecord) {
        guard record.durationSeconds >= 3, record.stability.sampleCount >= 2 else { return }
        records.removeAll { $0.id == record.id }
        records.insert(record, at: 0)
        records.sort { $0.endedAt > $1.endedAt }
        save()
    }

    func delete(_ record: FlightSessionRecord) {
        records.removeAll { $0.id == record.id }
        save()
    }

    func exportData() throws -> Data {
        try SessionHistoryPersistence.encode(SessionHistoryDocument(records: records))
    }

    private func load() {
        guard fileManager.fileExists(atPath: fileURL.path) else { return }
        do {
            records = try SessionHistoryPersistence.decode(Data(contentsOf: fileURL)).records
        } catch {
            lastError = "Saved session history could not be read. New sessions will continue to be recorded."
        }
    }

    private func save() {
        do {
            try fileManager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try exportData().write(to: fileURL, options: .atomic)
            lastError = nil
        } catch {
            lastError = "Session history could not be saved: \(error.localizedDescription)"
        }
    }

    private static func defaultFileURL(fileManager: FileManager) -> URL {
        let folder = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        return folder
            .appendingPathComponent("CruiseControl", isDirectory: true)
            .appendingPathComponent("session-history-v1.json")
    }
}
