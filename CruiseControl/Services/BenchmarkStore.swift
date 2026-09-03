import Foundation
import Combine

@MainActor
final class BenchmarkStore: ObservableObject {
    @Published private(set) var pairs: [BenchmarkPair] = []
    @Published private(set) var lastError: String?

    private let fileManager: FileManager
    private let fileURL: URL

    init(fileManager: FileManager = .default, fileURL: URL? = nil) {
        self.fileManager = fileManager
        self.fileURL = fileURL ?? Self.defaultFileURL(fileManager: fileManager)
        load()
    }

    func append(_ pair: BenchmarkPair) {
        pairs.removeAll { $0.id == pair.id }
        pairs.insert(pair, at: 0)
        pairs.sort { $0.createdAt > $1.createdAt }
        save()
    }

    func delete(_ pair: BenchmarkPair) {
        pairs.removeAll { $0.id == pair.id }
        save()
    }

    private func load() {
        guard fileManager.fileExists(atPath: fileURL.path) else { return }
        do { pairs = try BenchmarkHistoryPersistence.decode(Data(contentsOf: fileURL)).pairs }
        catch { lastError = "Saved benchmark history could not be read." }
    }

    private func save() {
        do {
            try fileManager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try BenchmarkHistoryPersistence.encode(.init(pairs: pairs)).write(to: fileURL, options: .atomic)
            lastError = nil
        } catch {
            lastError = "Benchmark history could not be saved: \(error.localizedDescription)"
        }
    }

    private static func defaultFileURL(fileManager: FileManager) -> URL {
        let folder = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        return folder.appendingPathComponent("CruiseControl", isDirectory: true).appendingPathComponent("benchmark-history-v1.json")
    }
}
