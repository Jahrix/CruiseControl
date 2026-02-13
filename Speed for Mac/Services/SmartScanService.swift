import Foundation
import AppKit

final class SmartScanService {
    struct ScanOptions {
        var includePrivacy: Bool
        var selectedLargeFileRoots: [URL]
        var topLargeFilesCount: Int
    }

    private let fileManager = FileManager.default

    func runSmartScan(options: ScanOptions, topCPUProcesses: [ProcessSample]) -> SmartScanSummary {
        let start = Date()

        var items: [SmartScanItem] = []
        items.append(contentsOf: scanSystemJunk())
        items.append(contentsOf: scanTrashBins())
        items.append(contentsOf: scanLargeFiles(roots: options.selectedLargeFileRoots, topCount: options.topLargeFilesCount))
        items.append(contentsOf: scanOptimization(topCPUProcesses: topCPUProcesses))

        if options.includePrivacy {
            items.append(contentsOf: scanPrivacyCaches())
        }

        return SmartScanSummary(generatedAt: Date(), duration: Date().timeIntervalSince(start), items: items)
    }

    func quarantine(
        items: [SmartScanItem],
        advancedModeEnabled: Bool
    ) -> ActionOutcome {
        guard !items.isEmpty else {
            return ActionOutcome(success: false, message: "No scan items selected for quarantine.")
        }

        let allowedRoots = defaultAllowlistedRoots()
        let root = quarantineRootURL()
        let stamp = isoTimestamp(Date())
        let destinationRoot = root.appendingPathComponent(stamp, isDirectory: true)

        do {
            try fileManager.createDirectory(at: destinationRoot, withIntermediateDirectories: true)
        } catch {
            return ActionOutcome(success: false, message: "Failed to create quarantine folder: \(error.localizedDescription)")
        }

        var entries: [QuarantineManifestEntry] = []
        var movedCount = 0

        for item in items {
            let sourceURL = URL(fileURLWithPath: item.path)
            if !fileManager.fileExists(atPath: sourceURL.path) {
                continue
            }

            let isAllowed = allowedRoots.contains(where: { sourceURL.path.hasPrefix($0.path) })
            if !isAllowed && !advancedModeEnabled {
                continue
            }

            let relative = sourceURL.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let destinationURL = destinationRoot.appendingPathComponent(relative)

            do {
                try fileManager.createDirectory(at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fileManager.moveItem(at: sourceURL, to: destinationURL)
                movedCount += 1

                entries.append(
                    QuarantineManifestEntry(
                        originalPath: sourceURL.path,
                        quarantinedPath: destinationURL.path,
                        sizeBytes: item.sizeBytes,
                        timestamp: Date()
                    )
                )
            } catch {
                continue
            }
        }

        if entries.isEmpty {
            return ActionOutcome(success: false, message: "No files were quarantined. Ensure paths exist and are within safe locations, or enable Advanced Mode.")
        }

        let manifest = QuarantineManifest(createdAt: Date(), entries: entries)
        let manifestURL = destinationRoot.appendingPathComponent("manifest.json")

        do {
            let data = try JSONEncoder().encode(manifest)
            try data.write(to: manifestURL, options: .atomic)
        } catch {
            return ActionOutcome(success: false, message: "Files moved but manifest write failed: \(error.localizedDescription)")
        }

        return ActionOutcome(success: true, message: "Quarantined \(movedCount) item(s) to \(destinationRoot.path).")
    }

    func restoreLatestQuarantine() -> ActionOutcome {
        guard let latestManifestURL = latestManifestURL() else {
            return ActionOutcome(success: false, message: "No quarantine manifest found.")
        }

        do {
            let data = try Data(contentsOf: latestManifestURL)
            let manifest = try JSONDecoder().decode(QuarantineManifest.self, from: data)

            var restored = 0
            for entry in manifest.entries {
                let source = URL(fileURLWithPath: entry.quarantinedPath)
                let destination = URL(fileURLWithPath: entry.originalPath)
                guard fileManager.fileExists(atPath: source.path) else { continue }

                do {
                    try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try fileManager.moveItem(at: source, to: destination)
                    restored += 1
                } catch {
                    continue
                }
            }

            return ActionOutcome(success: true, message: "Restored \(restored) item(s) from quarantine.")
        } catch {
            return ActionOutcome(success: false, message: "Restore failed: \(error.localizedDescription)")
        }
    }

    func permanentlyDeleteLatestQuarantine() -> ActionOutcome {
        guard let folder = latestQuarantineFolderURL() else {
            return ActionOutcome(success: false, message: "No quarantine folder found.")
        }

        do {
            try fileManager.removeItem(at: folder)
            return ActionOutcome(success: true, message: "Permanently deleted quarantine folder \(folder.lastPathComponent).")
        } catch {
            return ActionOutcome(success: false, message: "Failed to delete quarantine folder: \(error.localizedDescription)")
        }
    }

    func revealInFinder(path: String) {
        let url = URL(fileURLWithPath: path)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func openTrashInFinder() {
        let trashURL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".Trash")
        NSWorkspace.shared.open(trashURL)
    }

    private func scanSystemJunk() -> [SmartScanItem] {
        let roots = [
            URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Caches"),
            URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Logs"),
            appCacheRoot()
        ]

        var items: [SmartScanItem] = []
        for root in roots {
            guard fileManager.fileExists(atPath: root.path),
                  let children = try? fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else {
                continue
            }

            for child in children {
                let size = directoryOrFileSize(url: child)
                guard size > 0 else { continue }
                items.append(
                    SmartScanItem(
                        module: .systemJunk,
                        path: child.path,
                        sizeBytes: size,
                        note: "User cache/log candidate",
                        safeByDefault: true
                    )
                )
            }
        }

        return items.sorted { $0.sizeBytes > $1.sizeBytes }
    }

    private func scanTrashBins() -> [SmartScanItem] {
        let trash = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".Trash")
        guard fileManager.fileExists(atPath: trash.path),
              let children = try? fileManager.contentsOfDirectory(at: trash, includingPropertiesForKeys: nil) else {
            return []
        }

        return children.compactMap { item in
            let size = directoryOrFileSize(url: item)
            guard size > 0 else { return nil }
            return SmartScanItem(
                module: .trashBins,
                path: item.path,
                sizeBytes: size,
                note: "User trash item",
                safeByDefault: true
            )
        }
        .sorted { $0.sizeBytes > $1.sizeBytes }
    }

    private func scanLargeFiles(roots: [URL], topCount: Int) -> [SmartScanItem] {
        guard !roots.isEmpty else { return [] }

        var files: [SmartScanItem] = []

        for root in roots {
            guard fileManager.fileExists(atPath: root.path) else { continue }

            let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
                options: [.skipsPackageDescendants, .skipsHiddenFiles]
            )

            while let fileURL = enumerator?.nextObject() as? URL {
                guard let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                      values.isRegularFile == true,
                      let size = values.fileSize,
                      size > 10 * 1_024 * 1_024 else {
                    continue
                }

                files.append(
                    SmartScanItem(
                        module: .largeFiles,
                        path: fileURL.path,
                        sizeBytes: UInt64(size),
                        note: "Large file",
                        safeByDefault: false
                    )
                )
            }
        }

        return files
            .sorted { $0.sizeBytes > $1.sizeBytes }
            .prefix(max(topCount, 1))
            .map { $0 }
    }

    private func scanOptimization(topCPUProcesses: [ProcessSample]) -> [SmartScanItem] {
        topCPUProcesses
            .filter { $0.cpuPercent > 18 && !$0.name.localizedCaseInsensitiveContains("X-Plane") }
            .map { process in
                SmartScanItem(
                    module: .optimization,
                    path: "pid:\(process.pid) \(process.name)",
                    sizeBytes: 0,
                    note: "CPU hog \(String(format: "%.1f", process.cpuPercent))%",
                    safeByDefault: false
                )
            }
    }

    private func scanPrivacyCaches() -> [SmartScanItem] {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        let candidates = [
            home.appendingPathComponent("Library/Caches/com.apple.Safari"),
            home.appendingPathComponent("Library/Application Support/Google/Chrome/Default/Cache"),
            home.appendingPathComponent("Library/Application Support/Firefox/Profiles")
        ]

        return candidates.compactMap { url in
            guard fileManager.fileExists(atPath: url.path) else { return nil }
            let size = directoryOrFileSize(url: url)
            guard size > 0 else { return nil }
            return SmartScanItem(
                module: .privacy,
                path: url.path,
                sizeBytes: size,
                note: "User browser data",
                safeByDefault: false
            )
        }
        .sorted { $0.sizeBytes > $1.sizeBytes }
    }

    private func directoryOrFileSize(url: URL) -> UInt64 {
        if let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
           values.isRegularFile == true {
            return UInt64(max(values.fileSize ?? 0, 0))
        }

        let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsPackageDescendants]
        )

        var total: UInt64 = 0
        while let fileURL = enumerator?.nextObject() as? URL {
            guard let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true else {
                continue
            }
            total += UInt64(max(values.fileSize ?? 0, 0))
        }
        return total
    }

    private func appCacheRoot() -> URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Project Speed/Cache", isDirectory: true)
    }

    private func quarantineRootURL() -> URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Project Speed/Quarantine", isDirectory: true)
    }

    private func defaultAllowlistedRoots() -> [URL] {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        return [
            home.appendingPathComponent("Library/Caches"),
            home.appendingPathComponent("Library/Logs"),
            home.appendingPathComponent(".Trash"),
            appCacheRoot()
        ]
    }

    private func latestManifestURL() -> URL? {
        guard let folder = latestQuarantineFolderURL() else { return nil }
        let manifest = folder.appendingPathComponent("manifest.json")
        return fileManager.fileExists(atPath: manifest.path) ? manifest : nil
    }

    private func latestQuarantineFolderURL() -> URL? {
        let root = quarantineRootURL()
        guard fileManager.fileExists(atPath: root.path),
              let folders = try? fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: [.creationDateKey], options: [.skipsHiddenFiles]) else {
            return nil
        }

        return folders.sorted {
            let left = (try? $0.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            let right = (try? $1.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            return left > right
        }.first
    }

    private func isoTimestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }
}
