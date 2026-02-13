import Foundation
import AppKit
import CryptoKit
import Darwin

final class SmartScanService {
    struct ScanOptions {
        var includePrivacy: Bool
        var includeSavedApplicationState: Bool
        var selectedLargeFileRoots: [URL]
        var topLargeFilesCount: Int

        static let `default` = ScanOptions(
            includePrivacy: false,
            includeSavedApplicationState: true,
            selectedLargeFileRoots: [],
            topLargeFilesCount: 25
        )
    }

    private let fileManager = FileManager.default

    func runSmartScan(options: ScanOptions, topCPUProcesses: [ProcessSample]) -> SmartScanSummary {
        let start = Date()

        var moduleResults: [SmartScanModuleResult] = []
        moduleResults.append(runModule(.systemJunk, options: options, topCPUProcesses: topCPUProcesses))
        moduleResults.append(runModule(.trashBins, options: options, topCPUProcesses: topCPUProcesses))
        moduleResults.append(runModule(.largeFiles, options: options, topCPUProcesses: topCPUProcesses))
        moduleResults.append(runModule(.optimization, options: options, topCPUProcesses: topCPUProcesses))
        if options.includePrivacy {
            moduleResults.append(runModule(.privacy, options: options, topCPUProcesses: topCPUProcesses))
        }

        let items = moduleResults.flatMap(\.items)

        return SmartScanSummary(
            generatedAt: Date(),
            duration: Date().timeIntervalSince(start),
            moduleResults: moduleResults,
            items: items
        )
    }

    func runSmartScanAsync(
        options: ScanOptions,
        topCPUProcesses: [ProcessSample],
        progress: @escaping @Sendable (SmartScanRunState) -> Void
    ) async -> SmartScanSummary {
        let start = Date()
        var moduleList: [SmartScanModule] = [.systemJunk, .trashBins, .largeFiles, .optimization]
        if options.includePrivacy {
            moduleList.append(.privacy)
        }

        var runState = SmartScanRunState.idle
        runState.isRunning = true
        runState.cancellable = true
        runState.startedAt = start
        moduleList.forEach { runState.moduleProgress[$0] = 0 }
        progress(runState)

        var moduleResults: [SmartScanModuleResult] = []

        await withTaskGroup(of: SmartScanModuleResult.self) { group in
            for module in moduleList {
                group.addTask(priority: .utility) {
                    Self.scanModule(module: module, options: options, topCPUProcesses: topCPUProcesses)
                }
            }

            for await result in group {
                moduleResults.append(result)
                runState.completedModules.insert(result.module)
                runState.moduleProgress[result.module] = 1
                runState.overallProgress = Double(runState.completedModules.count) / Double(max(moduleList.count, 1))
                progress(runState)
            }
        }

        if Task.isCancelled {
            runState.isRunning = false
            runState.cancellable = false
            runState.finishedAt = Date()
            progress(runState)

            return SmartScanSummary(
                generatedAt: Date(),
                duration: Date().timeIntervalSince(start),
                moduleResults: moduleResults,
                items: moduleResults.flatMap(\.items)
            )
        }

        runState.isRunning = false
        runState.cancellable = false
        runState.overallProgress = 1
        runState.finishedAt = Date()
        progress(runState)

        let sorted = moduleResults.sorted { $0.module.rawValue < $1.module.rawValue }
        return SmartScanSummary(
            generatedAt: Date(),
            duration: Date().timeIntervalSince(start),
            moduleResults: sorted,
            items: sorted.flatMap(\.items)
        )
    }

    func scanCleanerModuleAsync(includeSavedApplicationState: Bool = true) async -> [SmartScanItem] {
        let options = ScanOptions(
            includePrivacy: false,
            includeSavedApplicationState: includeSavedApplicationState,
            selectedLargeFileRoots: [],
            topLargeFilesCount: 25
        )
        return Self.scanSystemJunk(options: options)
    }

    func scanTrashModuleAsync() async -> [SmartScanItem] {
        Self.scanTrashBins()
    }

    func scanLargeFilesModuleAsync(roots: [URL], topCount: Int) async -> [SmartScanItem] {
        Self.scanLargeFiles(roots: roots, topCount: topCount)
    }

    func scanOptimizationModuleAsync(topCPUProcesses: [ProcessSample]) async -> [SmartScanItem] {
        Self.scanOptimization(topCPUProcesses: topCPUProcesses)
    }
    func trashSummary() -> (count: Int, sizeBytes: UInt64) {
        let trashFolders = Self.discoveredTrashDirectories(fileManager: fileManager)
        var totalCount = 0
        var totalSize: UInt64 = 0

        for folder in trashFolders {
            guard fileManager.fileExists(atPath: folder.path),
                  let children = try? fileManager.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else {
                continue
            }

            totalCount += children.count
            for item in children {
                totalSize += directoryOrFileSize(url: item)
            }
        }

        return (totalCount, totalSize)
    }

    func emptyTrash() -> ActionOutcome {
        let before = trashSummary()
        if before.count == 0 {
            return ActionOutcome(success: true, message: "Trash is already empty.")
        }

        let scriptResult = runFinderEmptyTrashScript()
        if scriptResult.success {
            let after = trashSummary()
            return ActionOutcome(success: true, message: after.count == 0 ? "Trash emptied." : "Trash command sent to Finder.")
        }

        let fallback = emptyTrashByRemovingFiles()
        if fallback.deletedCount > 0 {
            let partial = fallback.failedCount > 0 ? " (\(fallback.failedCount) could not be removed)" : ""
            return ActionOutcome(success: true, message: "Trash emptied via fallback: removed \(fallback.deletedCount) item(s)\(partial).")
        }

        return ActionOutcome(
            success: false,
            message: "Could not empty Trash automatically. \(scriptResult.message). Open Trash in Finder and empty it manually."
        )
    }

    func quarantine(items: [SmartScanItem], advancedModeEnabled: Bool) -> ActionOutcome {
        guard !items.isEmpty else {
            return ActionOutcome(success: false, message: "No scan items selected for quarantine.")
        }

        let allowedRoots = defaultAllowlistedRoots()
        let root = quarantineRootURL()
        let batchID = isoTimestamp(Date())
        let destinationRoot = root.appendingPathComponent(batchID, isDirectory: true)

        do {
            try fileManager.createDirectory(at: destinationRoot, withIntermediateDirectories: true)
        } catch {
            return ActionOutcome(success: false, message: "Failed to create quarantine folder: \(error.localizedDescription)")
        }

        var entries: [QuarantineManifestEntry] = []
        var movedCount = 0

        for item in items {
            if item.path.hasPrefix("pid:") { continue }

            let sourceURL = URL(fileURLWithPath: item.path).standardizedFileURL
            guard fileManager.fileExists(atPath: sourceURL.path) else { continue }
            guard !isProtectedSystemPath(sourceURL.path) else { continue }

            let isAllowed = isPathWithinAllowlist(sourceURL.path, allowlistedRoots: allowedRoots)
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
                        timestamp: Date(),
                        sha256: quickSHA256(url: destinationURL)
                    )
                )
            } catch {
                continue
            }
        }

        if entries.isEmpty {
            return ActionOutcome(success: false, message: "No files were quarantined. Check selection and safe-path restrictions.")
        }

        let totalBytes = entries.reduce(UInt64(0)) { $0 + $1.sizeBytes }
        let manifest = QuarantineManifest(batchId: batchID, createdAt: Date(), totalBytes: totalBytes, entries: entries)
        let manifestURL = destinationRoot.appendingPathComponent("manifest.json")

        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(manifest)
            try data.write(to: manifestURL, options: .atomic)
        } catch {
            return ActionOutcome(success: false, message: "Files moved but manifest write failed: \(error.localizedDescription)")
        }

        return ActionOutcome(success: true, message: "Quarantined \(movedCount) item(s) to \(destinationRoot.path).")
    }

    func listQuarantineBatches() -> [QuarantineBatchSummary] {
        let root = quarantineRootURL()
        guard fileManager.fileExists(atPath: root.path),
              let folders = try? fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: [.creationDateKey], options: [.skipsHiddenFiles]) else {
            return []
        }

        return folders.compactMap { folder in
            let manifestURL = folder.appendingPathComponent("manifest.json")
            guard let data = try? Data(contentsOf: manifestURL),
                  let manifest = try? JSONDecoder().decode(QuarantineManifest.self, from: data) else {
                return nil
            }

            return QuarantineBatchSummary(
                batchID: manifest.batchId,
                folderPath: folder.path,
                createdAt: manifest.createdAt,
                entryCount: manifest.entries.count,
                totalBytes: manifest.totalBytes
            )
        }
        .sorted { $0.createdAt > $1.createdAt }
    }

    func restoreQuarantineBatch(batchID: String) -> ActionOutcome {
        guard let folder = quarantineFolder(batchID: batchID) else {
            return ActionOutcome(success: false, message: "Quarantine batch not found.")
        }

        let manifestURL = folder.appendingPathComponent("manifest.json")
        do {
            let data = try Data(contentsOf: manifestURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let manifest = try decoder.decode(QuarantineManifest.self, from: data)

            var restored = 0
            for entry in manifest.entries {
                let source = URL(fileURLWithPath: entry.quarantinedPath)
                let destination = URL(fileURLWithPath: entry.originalPath)
                guard fileManager.fileExists(atPath: source.path) else { continue }

                do {
                    try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                    if fileManager.fileExists(atPath: destination.path) {
                        try fileManager.removeItem(at: destination)
                    }
                    try fileManager.moveItem(at: source, to: destination)
                    restored += 1
                } catch {
                    continue
                }
            }

            return ActionOutcome(success: true, message: "Restored \(restored) item(s) from batch \(batchID).")
        } catch {
            return ActionOutcome(success: false, message: "Restore failed: \(error.localizedDescription)")
        }
    }

    func permanentlyDeleteQuarantineBatch(batchID: String) -> ActionOutcome {
        guard let folder = quarantineFolder(batchID: batchID) else {
            return ActionOutcome(success: false, message: "Quarantine batch not found.")
        }

        do {
            try fileManager.removeItem(at: folder)
            return ActionOutcome(success: true, message: "Deleted quarantine batch \(batchID).")
        } catch {
            return ActionOutcome(success: false, message: "Failed to delete quarantine batch: \(error.localizedDescription)")
        }
    }

    func restoreLatestQuarantine() -> ActionOutcome {
        guard let batch = listQuarantineBatches().first else {
            return ActionOutcome(success: false, message: "No quarantine batch found.")
        }
        return restoreQuarantineBatch(batchID: batch.batchID)
    }

    func permanentlyDeleteLatestQuarantine() -> ActionOutcome {
        guard let batch = listQuarantineBatches().first else {
            return ActionOutcome(success: false, message: "No quarantine batch found.")
        }
        return permanentlyDeleteQuarantineBatch(batchID: batch.batchID)
    }

    func deletePermanently(items: [SmartScanItem], advancedModeEnabled: Bool) -> ActionOutcome {
        guard !items.isEmpty else {
            return ActionOutcome(success: false, message: "No items selected for permanent delete.")
        }

        let allowedRoots = defaultAllowlistedRoots()
        var deleted = 0

        for item in items {
            if item.path.hasPrefix("pid:") { continue }
            let path = URL(fileURLWithPath: item.path).standardizedFileURL.path
            guard fileManager.fileExists(atPath: path) else { continue }
            guard !isProtectedSystemPath(path) else { continue }

            let isAllowed = isPathWithinAllowlist(path, allowlistedRoots: allowedRoots)
            if !isAllowed && !advancedModeEnabled {
                continue
            }

            do {
                try fileManager.removeItem(atPath: path)
                deleted += 1
            } catch {
                continue
            }
        }

        return ActionOutcome(success: deleted > 0, message: deleted > 0 ? "Permanently deleted \(deleted) item(s)." : "No items were deleted.")
    }

    func revealInFinder(path: String) {
        let url = URL(fileURLWithPath: path)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func openTrashInFinder() {
        if let trashURL = URL(string: "trash://") {
            NSWorkspace.shared.open(trashURL)
            return
        }

        let fallbackTrash = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".Trash", isDirectory: true)
        NSWorkspace.shared.open(fallbackTrash)
    }

    func openBridgeFolderInFinder() -> ActionOutcome {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let folder = base.appendingPathComponent("CruiseControl", isDirectory: true)

        do {
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
            NSWorkspace.shared.open(folder)
            return ActionOutcome(success: true, message: "Opened bridge folder: \(folder.path)")
        } catch {
            return ActionOutcome(success: false, message: "Could not open bridge folder: \(error.localizedDescription)")
        }
    }

    private func runModule(_ module: SmartScanModule, options: ScanOptions, topCPUProcesses: [ProcessSample]) -> SmartScanModuleResult {
        Self.scanModule(module: module, options: options, topCPUProcesses: topCPUProcesses)
    }

    private static func scanModule(module: SmartScanModule, options: ScanOptions, topCPUProcesses: [ProcessSample]) -> SmartScanModuleResult {
        let start = Date()

        do {
            let items: [SmartScanItem]
            switch module {
            case .systemJunk:
                items = scanSystemJunk(options: options)
            case .trashBins:
                items = scanTrashBins()
            case .largeFiles:
                items = scanLargeFiles(roots: options.selectedLargeFileRoots, topCount: options.topLargeFilesCount)
            case .optimization:
                items = scanOptimization(topCPUProcesses: topCPUProcesses)
            case .privacy:
                items = scanPrivacyCaches()
            }

            return SmartScanModuleResult(
                module: module,
                items: items,
                bytes: items.reduce(0) { $0 + $1.sizeBytes },
                duration: Date().timeIntervalSince(start),
                error: nil
            )
        } catch {
            return SmartScanModuleResult(
                module: module,
                items: [],
                bytes: 0,
                duration: Date().timeIntervalSince(start),
                error: error.localizedDescription
            )
        }
    }

    private static func scanSystemJunk(options: ScanOptions) -> [SmartScanItem] {
        let fm = FileManager.default
        let home = URL(fileURLWithPath: NSHomeDirectory())

        var roots: [URL] = [
            home.appendingPathComponent("Library/Caches"),
            home.appendingPathComponent("Library/Logs"),
            appSupportCruiseControlRoot()
        ]

        if options.includeSavedApplicationState {
            roots.append(home.appendingPathComponent("Library/Saved Application State"))
        }

        var items: [SmartScanItem] = []
        for root in roots {
            guard fm.fileExists(atPath: root.path),
                  let children = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else {
                continue
            }

            for child in children {
                if Task.isCancelled { break }
                let childPath = child.standardizedFileURL.path
                if isProtectedSystemPath(childPath) { continue }
                if !isPathWithinAllowlist(childPath, allowlistedRoots: defaultAllowlistedRoots()) { continue }

                let size = directoryOrFileSize(url: child)
                guard size > 0 else { continue }

                let groupName = topLevelGroupName(root: root, child: child)
                items.append(
                    SmartScanItem(
                        module: .systemJunk,
                        path: child.path,
                        sizeBytes: size,
                        note: "\(groupName) cache/log candidate (regenerates as apps run)",
                        safeByDefault: true
                    )
                )
            }
        }

        return items.sorted { $0.sizeBytes > $1.sizeBytes }
    }

    private static func scanTrashBins() -> [SmartScanItem] {
        let fm = FileManager.default
        var items: [SmartScanItem] = []

        for trash in discoveredTrashDirectories(fileManager: fm) {
            guard fm.fileExists(atPath: trash.path),
                  let children = try? fm.contentsOfDirectory(at: trash, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else {
                continue
            }

            let sourceLabel = trash.path.hasSuffix("/.Trash") ? "Home Trash" : trash.path

            for item in children {
                if Task.isCancelled { break }
                let size = directoryOrFileSize(url: item)
                guard size > 0 else { continue }
                items.append(
                    SmartScanItem(
                        module: .trashBins,
                        path: item.path,
                        sizeBytes: size,
                        note: "Trash item (\(sourceLabel))",
                        safeByDefault: true
                    )
                )
            }
        }

        return items.sorted { $0.sizeBytes > $1.sizeBytes }
    }

    private static func scanLargeFiles(roots: [URL], topCount: Int) -> [SmartScanItem] {
        let fm = FileManager.default
        guard !roots.isEmpty else { return [] }

        var files: [SmartScanItem] = []

        for root in roots {
            if Task.isCancelled { break }
            guard fm.fileExists(atPath: root.path) else { continue }

            let enumerator = fm.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey],
                options: [.skipsPackageDescendants, .skipsHiddenFiles]
            )

            while let fileURL = enumerator?.nextObject() as? URL {
                if Task.isCancelled { break }

                guard let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]),
                      values.isRegularFile == true,
                      let size = values.fileSize,
                      size > 10 * 1_024 * 1_024 else {
                    continue
                }

                let modified = values.contentModificationDate?.formatted(date: .abbreviated, time: .shortened) ?? "unknown date"
                files.append(
                    SmartScanItem(
                        module: .largeFiles,
                        path: fileURL.path,
                        sizeBytes: UInt64(size),
                        note: "Modified \(modified)",
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

    private static func scanOptimization(topCPUProcesses: [ProcessSample]) -> [SmartScanItem] {
        topCPUProcesses
            .filter { $0.cpuPercent > 12 && !$0.name.localizedCaseInsensitiveContains("X-Plane") }
            .map { process in
                SmartScanItem(
                    module: .optimization,
                    path: "pid:\(process.pid) \(process.name)",
                    sizeBytes: process.memoryBytes,
                    note: "Impact: CPU \(String(format: "%.1f", process.cpuPercent))% • RAM \(ByteCountFormatter.string(fromByteCount: Int64(process.memoryBytes), countStyle: .memory))",
                    safeByDefault: false
                )
            }
    }

    private static func scanPrivacyCaches() -> [SmartScanItem] {
        let fm = FileManager.default
        let home = URL(fileURLWithPath: NSHomeDirectory())
        let candidates = [
            home.appendingPathComponent("Library/Caches/com.apple.Safari"),
            home.appendingPathComponent("Library/Application Support/Google/Chrome/Default/Cache"),
            home.appendingPathComponent("Library/Application Support/Firefox/Profiles")
        ]

        return candidates.compactMap { url in
            if Task.isCancelled { return nil }
            guard fm.fileExists(atPath: url.path) else { return nil }
            let size = directoryOrFileSize(url: url)
            guard size > 0 else { return nil }
            return SmartScanItem(
                module: .privacy,
                path: url.path,
                sizeBytes: size,
                note: "User browser cache data",
                safeByDefault: false
            )
        }
        .sorted { $0.sizeBytes > $1.sizeBytes }
    }

    private func quickSHA256(url: URL) -> String? {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true,
              let size = values.fileSize,
              size <= 32 * 1_024 * 1_024 else {
            return nil
        }

        guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) else {
            return nil
        }

        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func topLevelGroupName(root: URL, child: URL) -> String {
        let relative = child.path.replacingOccurrences(of: root.path, with: "").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let first = relative.split(separator: "/").first
        return first.map(String.init) ?? root.lastPathComponent
    }

    private func runFinderEmptyTrashScript() -> (success: Bool, message: String) {
        let script = "tell application \"Finder\"\nactivate\nempty the trash\nend tell"

        let firstError = executeAppleScript(script)
        if firstError == nil {
            return (true, "OK")
        }

        if let code = firstError?[NSAppleScript.errorNumber] as? Int, code == -600 {
            _ = NSWorkspace.shared.launchApplication("Finder")
            Thread.sleep(forTimeInterval: 0.35)
            let retryError = executeAppleScript(script)
            if retryError == nil {
                return (true, "OK")
            }
            return (false, userFriendlyAppleScriptError(retryError))
        }

        return (false, userFriendlyAppleScriptError(firstError))
    }

    private func executeAppleScript(_ source: String) -> NSDictionary? {
        guard let script = NSAppleScript(source: source) else {
            return [NSLocalizedDescriptionKey: "Unable to create AppleScript instance"]
        }

        var scriptError: NSDictionary?
        script.executeAndReturnError(&scriptError)
        return scriptError
    }

    private func userFriendlyAppleScriptError(_ error: NSDictionary?) -> String {
        guard let error else { return "Unknown Finder automation error." }

        let code = (error[NSAppleScript.errorNumber] as? Int) ?? 0
        let brief = (error[NSAppleScript.errorBriefMessage] as? String)
            ?? (error[NSAppleScript.errorMessage] as? String)
            ?? "Unknown error"

        switch code {
        case -600:
            return "Finder is not running (error -600)."
        case -1743:
            return "Permission denied controlling Finder. Allow CruiseControl under Privacy & Security > Automation."
        case -1712:
            return "Finder automation timed out (error -1712)."
        default:
            return "Finder automation failed (error \(code)): \(brief)"
        }
    }

    private func emptyTrashByRemovingFiles() -> (deletedCount: Int, failedCount: Int) {
        var deleted = 0
        var failed = 0

        for folder in Self.discoveredTrashDirectories(fileManager: fileManager) {
            guard fileManager.fileExists(atPath: folder.path),
                  let children = try? fileManager.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else {
                continue
            }

            for child in children {
                do {
                    try fileManager.removeItem(at: child)
                    deleted += 1
                } catch {
                    failed += 1
                }
            }
        }

        return (deleted, failed)
    }

    private static func discoveredTrashDirectories(fileManager: FileManager = .default) -> [URL] {
        var candidates: [URL] = [
            URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".Trash", isDirectory: true)
        ]

        if let userTrash = fileManager.urls(for: .trashDirectory, in: .userDomainMask).first {
            candidates.append(userTrash)
        }

        let uid = String(getuid())
        if let volumeURLs = fileManager.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: [.skipHiddenVolumes]) {
            for volume in volumeURLs {
                candidates.append(volume.appendingPathComponent(".Trashes/\(uid)", isDirectory: true))
            }
        }

        var seen: Set<String> = []
        var unique: [URL] = []
        for url in candidates {
            let path = url.standardizedFileURL.path
            if seen.insert(path).inserted {
                unique.append(url)
            }
        }

        return unique
    }

    private static func appSupportCruiseControlRoot() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("CruiseControl", isDirectory: true)
    }

    private func quarantineRootURL() -> URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("CruiseControl/Quarantine", isDirectory: true)
    }

    private func quarantineFolder(batchID: String) -> URL? {
        let root = quarantineRootURL()
        guard fileManager.fileExists(atPath: root.path) else { return nil }
        let folder = root.appendingPathComponent(batchID, isDirectory: true)
        return fileManager.fileExists(atPath: folder.path) ? folder : nil
    }

    private static func defaultAllowlistedRoots() -> [URL] {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        return [
            home.appendingPathComponent("Library/Caches"),
            home.appendingPathComponent("Library/Logs"),
            home.appendingPathComponent("Library/Saved Application State"),
            home.appendingPathComponent(".Trash"),
            appSupportCruiseControlRoot()
        ]
    }

    private func defaultAllowlistedRoots() -> [URL] {
        Self.defaultAllowlistedRoots()
    }

    private static func isPathWithinAllowlist(_ path: String, allowlistedRoots: [URL]) -> Bool {
        let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
        for root in allowlistedRoots {
            let rootPath = root.standardizedFileURL.path
            if standardized == rootPath || standardized.hasPrefix(rootPath + "/") {
                return true
            }
        }
        return false
    }

    private func isPathWithinAllowlist(_ path: String, allowlistedRoots: [URL]) -> Bool {
        Self.isPathWithinAllowlist(path, allowlistedRoots: allowlistedRoots)
    }

    private static func isProtectedSystemPath(_ path: String) -> Bool {
        let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
        let blockedPrefixes = ["/System", "/Library", "/private/var/vm"]
        return blockedPrefixes.contains { prefix in
            standardized == prefix || standardized.hasPrefix(prefix + "/")
        }
    }

    private func isProtectedSystemPath(_ path: String) -> Bool {
        Self.isProtectedSystemPath(path)
    }

    private static func directoryOrFileSize(url: URL) -> UInt64 {
        let fm = FileManager.default

        if let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
           values.isRegularFile == true {
            return UInt64(max(values.fileSize ?? 0, 0))
        }

        let enumerator = fm.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsPackageDescendants]
        )

        var total: UInt64 = 0
        while let fileURL = enumerator?.nextObject() as? URL {
            if Task.isCancelled { break }
            guard let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true else {
                continue
            }
            total += UInt64(max(values.fileSize ?? 0, 0))
        }
        return total
    }

    private func directoryOrFileSize(url: URL) -> UInt64 {
        Self.directoryOrFileSize(url: url)
    }

    private func isoTimestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }
}
