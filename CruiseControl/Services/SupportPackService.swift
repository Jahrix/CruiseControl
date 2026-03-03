import Foundation
import CryptoKit

struct SupportPackSelection {
    var includeXPlaneLog: Bool
    var selectedURL: URL?
}

struct SupportPackReview {
    let rootFolderName: String
    let includedFiles: [FileEntry]
    let omissions: [Omission]
    let totalBytes: UInt64
    let exclusionRules: [String]

    struct FileEntry: Identifiable {
        let relativePath: String
        let sizeBytes: UInt64
        let note: String?

        var id: String { relativePath }
    }

    struct Omission: Identifiable, Codable {
        let rule: String
        let reason: String
        let sourcePath: String?

        var id: String { [rule, reason, sourcePath ?? ""].joined(separator: "|") }
    }
}

struct SupportPackSystemPayload: Codable {
    let generatedAt: Date
    let appVersion: String
    let appBuild: String
    let gitCommitHash: String?
    let macOSVersion: String
    let cpuModel: String
    let macModelIdentifier: String
    let physicalMemoryBytes: UInt64
    let freeDiskBytes: UInt64
}

struct SupportPackUpdateStatusPayload: Codable {
    let capturedAt: Date
    let currentVersion: String
    let currentBuild: String
    let checkedRepo: String
    let latestReleaseTag: String?
    let updateAvailable: Bool
    let statusMessage: String
}

struct SupportPackPerfSummaryPayload: Codable {
    let generatedAt: Date
    let telemetryState: String
    let simActive: Bool
    let memoryPressure: String
    let memoryPressureTrend: String
    let thermalState: String
    let swapUsedBytes: UInt64
    let swapDelta5MinBytes: Int64
    let compressedMemoryBytes: UInt64
    let diskReadMBps: Double
    let diskWriteMBps: Double
    let freeDiskBytes: UInt64
    let ioPressureLikely: Bool
    let stutterEpisodesLast10m: Int
    let rawStutterEventsLast10m: Int
    let topStutterCause: String
    let warningCount: Int
    let warnings: [String]
    let culprits: [String]
    let lastSessionSummary: LastSessionSummary?

    struct LastSessionSummary: Codable {
        let capturedAt: Date
        let sessionDurationText: String
        let totalPackets: UInt64
        let lastTarget: Double?
        let lastApplied: Double?
        let lastAckAt: Date?
        let reasons: [String]
    }
}

struct SupportPackRequest {
    let createdAt: Date
    let system: SupportPackSystemPayload
    let settingsSnapshot: [String: String]
    let updateStatus: SupportPackUpdateStatusPayload
    let perfSummary: SupportPackPerfSummaryPayload
    let appLogsText: String
    let selection: SupportPackSelection
}

enum SupportPackService {
    nonisolated static let maxFileBytes: UInt64 = 10 * 1024 * 1024
    nonisolated static let maxTotalPayloadBytes: UInt64 = 25 * 1024 * 1024
    nonisolated private static let maxAppLogsBytes: Int = 512 * 1024
    nonisolated private static let maxAppLogsFallbackBytes: Int = 128 * 1024
    nonisolated private static let maxXPlaneLogBytes: Int = 2 * 1024 * 1024
    nonisolated private static let maxXPlaneLogFallbackBytes: Int = 256 * 1024
    nonisolated private static let blockedDirectoryNames: Set<String> = [".git", ".svn", ".hg"]
    nonisolated private static let blockedPathComponents: Set<String> = ["deriveddata", ".build", "build", "dist", "node_modules", "carthage", "pods"]
    nonisolated private static let blockedFilenameTokens = [
        "token", "secret", "password", "credentials", "key", "private", "id_rsa", "oauth", "bearer", "api_key", "auth"
    ]

    nonisolated static let exclusionRuleDescriptions: [String] = [
        "Never include version control folders (.git, .svn, .hg).",
        "Never include build outputs or caches (DerivedData, .build, build, dist, node_modules, Carthage, Pods).",
        "Never include Xcode or SwiftPM caches from Library/Caches or Library/Developer/Xcode.",
        "Never include sensitive directories such as Keychains, Mail, Messages, .ssh, or .gnupg.",
        "Never include filenames containing token, secret, password, credentials, key, private, id_rsa, oauth, bearer, api_key, or auth.",
        "Never follow symlinks.",
        "Never include files larger than 10 MB unless explicitly allowlisted, and keep total payload under 25 MB."
    ]

    nonisolated private static let requiredRelativePaths: Set<String> = [
        "system.json",
        "app/settings_redacted.json",
        "app/update_status.json",
        "app/logs_tail.txt"
    ]

    nonisolated static func rootFolderName(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return "SupportPack_\(formatter.string(from: date))"
    }

    nonisolated static func reviewPathLabel(for url: URL) -> String {
        scrubText(url.path)
    }

    static func review(for request: SupportPackRequest) -> SupportPackReview {
        let prepared = buildPreparedPack(for: request)
        return SupportPackReview(
            rootFolderName: prepared.rootFolderName,
            includedFiles: prepared.files.map {
                SupportPackReview.FileEntry(relativePath: $0.relativePath, sizeBytes: UInt64($0.data.count), note: $0.note)
            },
            omissions: prepared.omissions,
            totalBytes: prepared.files.reduce(0) { $0 + UInt64($1.data.count) },
            exclusionRules: exclusionRuleDescriptions
        )
    }

    static func writePack(for request: SupportPackRequest, destinationURL: URL) throws -> URL {
        let failures = validationFailures()
        guard failures.isEmpty else {
            throw NSError(
                domain: "CruiseControl.SupportPack",
                code: 91,
                userInfo: [NSLocalizedDescriptionKey: "Support pack security validation failed: \(failures.joined(separator: "; "))."]
            )
        }

        let prepared = buildPreparedPack(for: request)
        let fileManager = FileManager.default
        let workspaceFolder = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: workspaceFolder, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: workspaceFolder) }

        let packFolder = workspaceFolder.appendingPathComponent(prepared.rootFolderName, isDirectory: true)
        try fileManager.createDirectory(at: packFolder, withIntermediateDirectories: true)

        for file in prepared.files {
            let destination = packFolder.appendingPathComponent(file.relativePath)
            try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try file.data.write(to: destination, options: .atomic)
        }

        let fileEntries = try prepared.files.map { file -> SupportPackManifest.FileEntry in
            let destination = packFolder.appendingPathComponent(file.relativePath)
            let data = try Data(contentsOf: destination)
            return SupportPackManifest.FileEntry(
                relativePath: file.relativePath,
                sizeBytes: UInt64(data.count),
                sha256: sha256Hex(for: data),
                note: file.note
            )
        }
        .sorted { $0.relativePath < $1.relativePath }

        let manifest = SupportPackManifest(
            createdAt: request.createdAt,
            rootFolderName: prepared.rootFolderName,
            maxPayloadBytes: maxTotalPayloadBytes,
            totalPayloadBytes: fileEntries.reduce(0) { $0 + $1.sizeBytes },
            includedFiles: fileEntries,
            omissions: prepared.omissions.sorted { lhs, rhs in
                if lhs.rule == rhs.rule {
                    return (lhs.sourcePath ?? lhs.reason) < (rhs.sourcePath ?? rhs.reason)
                }
                return lhs.rule < rhs.rule
            }
        )

        let manifestURL = packFolder.appendingPathComponent("manifest.json")
        let manifestData = try encodeJSON(manifest)
        try manifestData.write(to: manifestURL, options: .atomic)

        let extensionLowercased = destinationURL.pathExtension.lowercased()
        if extensionLowercased == "zip" {
            try zipSupportPack(folderURL: packFolder, destinationZipURL: destinationURL)
            return destinationURL
        }

        let folderDestination = destinationURL.pathExtension.isEmpty
            ? destinationURL
            : destinationURL.deletingPathExtension()
        if fileManager.fileExists(atPath: folderDestination.path) {
            try fileManager.removeItem(at: folderDestination)
        }
        try fileManager.copyItem(at: packFolder, to: folderDestination)
        return folderDestination
    }

    nonisolated static func validationFailures() -> [String] {
        var failures: [String] = []

        if blockedReason(for: URL(fileURLWithPath: "/tmp/.git/config"), allowlistedFilename: false) == nil {
            failures.append(".git path was not blocked")
        }

        if blockedReason(for: URL(fileURLWithPath: "/Users/Test/Library/Developer/Xcode/DerivedData/Foo"), allowlistedFilename: false) == nil {
            failures.append("DerivedData path was not blocked")
        }

        let scrubbed = scrubText("Open /Users/Test/Documents/Log.txt and \(NSHomeDirectory())/Library/Application Support/CruiseControl")
        if scrubbed.contains("/Users/Test") || scrubbed.contains(NSHomeDirectory()) {
            failures.append("absolute path scrubbing did not redact home paths")
        }

        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let targetFile = tempRoot.appendingPathComponent("Log.txt")
        let symlinkURL = tempRoot.appendingPathComponent("Log-link.txt")
        do {
            try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
            try Data("test".utf8).write(to: targetFile, options: .atomic)
            try FileManager.default.createSymbolicLink(at: symlinkURL, withDestinationURL: targetFile)
            if isSymlink(symlinkURL) == false {
                failures.append("symlink detection failed")
            }
        } catch {
            failures.append("symlink validation setup failed: \(error.localizedDescription)")
        }
        try? FileManager.default.removeItem(at: tempRoot)

        return failures
    }

    private static func buildPreparedPack(for request: SupportPackRequest) -> PreparedPack {
        var omissions: [SupportPackReview.Omission] = []
        var files: [PreparedFile] = []
        let rootFolderName = rootFolderName(for: request.createdAt)

        files.append(PreparedFile(relativePath: "system.json", data: tryOrEmpty { try encodeJSON(request.system) }, priority: 0, note: nil))
        files.append(PreparedFile(relativePath: "app/settings_redacted.json", data: tryOrEmpty { try encodeJSON(settingsPayload(from: request.settingsSnapshot, capturedAt: request.createdAt)) }, priority: 0, note: nil))
        files.append(PreparedFile(relativePath: "app/update_status.json", data: tryOrEmpty { try encodeJSON(redactedUpdateStatusPayload(request.updateStatus)) }, priority: 0, note: nil))
        files.append(PreparedFile(relativePath: "app/perf_summary.json", data: tryOrEmpty { try encodeJSON(redactedPerfSummaryPayload(request.perfSummary)) }, priority: 1, note: nil))

        let logsData = boundedTextData(scrubText(request.appLogsText).isEmpty ? "No app logs captured." : scrubText(request.appLogsText), limitBytes: maxAppLogsBytes)
        files.append(PreparedFile(relativePath: "app/logs_tail.txt", data: logsData, priority: 2, note: "Tail only"))

        if let xplaneFile = prepareXPlaneLogFile(selection: request.selection, omissions: &omissions) {
            files.append(xplaneFile)
        }

        applyPayloadCap(to: &files, omissions: &omissions)
        files.sort { $0.relativePath < $1.relativePath }
        return PreparedPack(rootFolderName: rootFolderName, files: files, omissions: omissions)
    }

    private static func prepareXPlaneLogFile(selection: SupportPackSelection, omissions: inout [SupportPackReview.Omission]) -> PreparedFile? {
        guard selection.includeXPlaneLog else { return nil }
        guard let selectedURL = selection.selectedURL else {
            omissions.append(.init(rule: "selection", reason: "X-Plane Log.txt was enabled but no file or folder was selected.", sourcePath: nil))
            return nil
        }

        guard isSymlink(selectedURL) == false else {
            omissions.append(.init(rule: "symlink", reason: "Skipped selected symlink.", sourcePath: redactedPath(selectedURL)))
            return nil
        }

        let resolvedURL: URL
        if isDirectory(selectedURL) {
            if let reason = blockedReason(for: selectedURL, allowlistedFilename: true) {
                omissions.append(.init(rule: reason, reason: "Selected folder is blocked by support-pack security rules.", sourcePath: redactedPath(selectedURL)))
                return nil
            }
            resolvedURL = selectedURL.appendingPathComponent("Log.txt")
        } else {
            resolvedURL = selectedURL
        }

        guard resolvedURL.lastPathComponent.caseInsensitiveCompare("Log.txt") == .orderedSame else {
            omissions.append(.init(rule: "allowlist", reason: "Only X-Plane Log.txt may be included from a user-selected path.", sourcePath: redactedPath(resolvedURL)))
            return nil
        }

        guard FileManager.default.fileExists(atPath: resolvedURL.path) else {
            omissions.append(.init(rule: "missing", reason: "Selected file or folder did not provide Log.txt.", sourcePath: redactedPath(resolvedURL)))
            return nil
        }

        guard isSymlink(resolvedURL) == false else {
            omissions.append(.init(rule: "symlink", reason: "Skipped Log.txt symlink.", sourcePath: redactedPath(resolvedURL)))
            return nil
        }

        if let reason = blockedReason(for: resolvedURL, allowlistedFilename: true) {
            omissions.append(.init(rule: reason, reason: "Blocked selected Log.txt path by support-pack security rules.", sourcePath: redactedPath(resolvedURL)))
            return nil
        }

        let fileSize = fileSizeBytes(at: resolvedURL)
        if fileSize > maxFileBytes {
            omissions.append(.init(rule: ">10MB", reason: "Selected X-Plane Log.txt exceeded 10 MB and was trimmed to a bounded tail.", sourcePath: redactedPath(resolvedURL)))
        }
        if fileSize > UInt64(maxXPlaneLogBytes) {
            omissions.append(.init(rule: "bounded-tail", reason: "Included only the tail of X-Plane Log.txt to keep the support pack minimal.", sourcePath: redactedPath(resolvedURL)))
        }

        guard let data = try? readTailData(from: resolvedURL, maxBytes: maxXPlaneLogBytes) else {
            omissions.append(.init(rule: "read", reason: "Could not read selected Log.txt.", sourcePath: redactedPath(resolvedURL)))
            return nil
        }

        let scrubbed = scrubText(String(decoding: data, as: UTF8.self))
        let bounded = boundedTextData(scrubbed, limitBytes: maxXPlaneLogBytes)
        let note = fileSize > UInt64(maxXPlaneLogBytes) ? "Tail only" : nil
        return PreparedFile(relativePath: "xplane/Log.txt", data: bounded, priority: 3, note: note)
    }

    private static func applyPayloadCap(to files: inout [PreparedFile], omissions: inout [SupportPackReview.Omission]) {
        func totalBytes() -> UInt64 {
            files.reduce(0) { $0 + UInt64($1.data.count) }
        }

        if totalBytes() <= maxTotalPayloadBytes { return }

        if let index = files.firstIndex(where: { $0.relativePath == "app/logs_tail.txt" && $0.data.count > maxAppLogsFallbackBytes }) {
            files[index].data = boundedTextData(String(decoding: files[index].data, as: UTF8.self), limitBytes: maxAppLogsFallbackBytes)
            files[index].note = "Tail only (reduced for payload cap)"
            omissions.append(.init(rule: "payload-cap", reason: "Reduced app logs tail to stay under the payload cap.", sourcePath: "app/logs_tail.txt"))
        }

        if totalBytes() <= maxTotalPayloadBytes { return }

        if let index = files.firstIndex(where: { $0.relativePath == "xplane/Log.txt" && $0.data.count > maxXPlaneLogFallbackBytes }) {
            files[index].data = boundedTextData(String(decoding: files[index].data, as: UTF8.self), limitBytes: maxXPlaneLogFallbackBytes)
            files[index].note = "Tail only (reduced for payload cap)"
            omissions.append(.init(rule: "payload-cap", reason: "Reduced X-Plane Log.txt to stay under the payload cap.", sourcePath: "xplane/Log.txt"))
        }

        if totalBytes() <= maxTotalPayloadBytes { return }

        while totalBytes() > maxTotalPayloadBytes {
            guard let removeIndex = files.indices
                .filter({ requiredRelativePaths.contains(files[$0].relativePath) == false })
                .sorted(by: { lhs, rhs in
                    if files[lhs].priority == files[rhs].priority {
                        return files[lhs].relativePath > files[rhs].relativePath
                    }
                    return files[lhs].priority > files[rhs].priority
                })
                .first else {
                break
            }

            let removed = files.remove(at: removeIndex)
            omissions.append(.init(rule: "payload-cap", reason: "Dropped \(removed.relativePath) to stay under the payload cap.", sourcePath: removed.relativePath))
        }
    }

    private static func settingsPayload(from snapshot: [String: String], capturedAt: Date) -> SettingsPayload {
        let redacted = Dictionary(uniqueKeysWithValues: snapshot.map { key, value in
            (key, redactSettingValue(key: key, value: value))
        })

        let featureToggles = redacted
            .filter { key, value in
                let loweredKey = key.lowercased()
                return loweredKey.contains("enabled") || value == "true" || value == "false"
            }

        return SettingsPayload(
            capturedAt: capturedAt,
            settings: redacted.sortedByKey(),
            featureToggles: featureToggles.sortedByKey()
        )
    }

    private static func redactedUpdateStatusPayload(_ payload: SupportPackUpdateStatusPayload) -> SupportPackUpdateStatusPayload {
        SupportPackUpdateStatusPayload(
            capturedAt: payload.capturedAt,
            currentVersion: scrubText(payload.currentVersion),
            currentBuild: scrubText(payload.currentBuild),
            checkedRepo: scrubText(payload.checkedRepo),
            latestReleaseTag: payload.latestReleaseTag.map(scrubText),
            updateAvailable: payload.updateAvailable,
            statusMessage: scrubText(payload.statusMessage)
        )
    }

    private static func redactedPerfSummaryPayload(_ payload: SupportPackPerfSummaryPayload) -> SupportPackPerfSummaryPayload {
        SupportPackPerfSummaryPayload(
            generatedAt: payload.generatedAt,
            telemetryState: scrubText(payload.telemetryState),
            simActive: payload.simActive,
            memoryPressure: scrubText(payload.memoryPressure),
            memoryPressureTrend: scrubText(payload.memoryPressureTrend),
            thermalState: scrubText(payload.thermalState),
            swapUsedBytes: payload.swapUsedBytes,
            swapDelta5MinBytes: payload.swapDelta5MinBytes,
            compressedMemoryBytes: payload.compressedMemoryBytes,
            diskReadMBps: payload.diskReadMBps,
            diskWriteMBps: payload.diskWriteMBps,
            freeDiskBytes: payload.freeDiskBytes,
            ioPressureLikely: payload.ioPressureLikely,
            stutterEpisodesLast10m: payload.stutterEpisodesLast10m,
            rawStutterEventsLast10m: payload.rawStutterEventsLast10m,
            topStutterCause: scrubText(payload.topStutterCause),
            warningCount: payload.warningCount,
            warnings: payload.warnings.map(scrubText),
            culprits: payload.culprits.map(scrubText),
            lastSessionSummary: payload.lastSessionSummary.map {
                .init(
                    capturedAt: $0.capturedAt,
                    sessionDurationText: scrubText($0.sessionDurationText),
                    totalPackets: $0.totalPackets,
                    lastTarget: $0.lastTarget,
                    lastApplied: $0.lastApplied,
                    lastAckAt: $0.lastAckAt,
                    reasons: $0.reasons.map(scrubText)
                )
            }
        )
    }

    private static func redactSettingValue(key: String, value: String) -> String {
        let loweredKey = key.lowercased()
        if blockedFilenameTokens.contains(where: loweredKey.contains) {
            return "<redacted>"
        }
        return scrubText(value)
    }

    nonisolated private static func encodeJSON<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(value)
    }

    nonisolated private static func boundedTextData(_ text: String, limitBytes: Int) -> Data {
        let data = Data(text.utf8)
        guard data.count > limitBytes else { return data }
        let suffix = data.suffix(limitBytes)
        let prefix = "[tail-only]\n"
        return Data(prefix.utf8) + suffix
    }

    nonisolated private static func sha256Hex(for data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    nonisolated private static func redactedPath(_ url: URL) -> String {
        scrubText(url.path)
    }

    nonisolated private static func scrubText(_ text: String) -> String {
        let home = NSHomeDirectory()
        var scrubbed = text.replacingOccurrences(of: home, with: "$HOME")

        let patterns = [
            #"/Users/[^/\s]+"#,
            #"/var/folders/[^\s]+"#,
            #"/private/var/folders/[^\s]+"#
        ]

        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(scrubbed.startIndex..., in: scrubbed)
            scrubbed = regex.stringByReplacingMatches(in: scrubbed, options: [], range: range, withTemplate: "$HOME")
        }

        return scrubbed
    }

    nonisolated private static func blockedReason(for url: URL, allowlistedFilename: Bool) -> String? {
        let lowercasedPath = url.standardizedFileURL.path.lowercased()
        let components = url.standardizedFileURL.pathComponents.map { $0.lowercased() }
        let lastName = url.lastPathComponent.lowercased()

        if components.contains(where: { blockedDirectoryNames.contains($0) }) {
            return "blocked-vcs"
        }

        if components.contains(where: { blockedPathComponents.contains($0) }) {
            return "blocked-build-or-cache"
        }

        let sensitiveRoots = sensitiveDirectoryRoots().map { $0.standardizedFileURL.path.lowercased() }
        if sensitiveRoots.contains(where: { lowercasedPath == $0 || lowercasedPath.hasPrefix($0 + "/") }) {
            return "blocked-sensitive-directory"
        }

        if allowlistedFilename == false && blockedFilenameTokens.contains(where: lastName.contains) {
            return "blocked-sensitive-filename"
        }

        return nil
    }

    nonisolated private static func sensitiveDirectoryRoots() -> [URL] {
        let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        return [
            home.appendingPathComponent("Library/Developer/Xcode/DerivedData"),
            home.appendingPathComponent("Library/Caches/org.swift.swiftpm"),
            home.appendingPathComponent("Library/Caches/com.apple.dt.Xcode"),
            home.appendingPathComponent("Library/Keychains"),
            home.appendingPathComponent(".ssh"),
            home.appendingPathComponent(".gnupg"),
            home.appendingPathComponent("Library/Mail"),
            home.appendingPathComponent("Library/Messages")
        ]
    }

    nonisolated private static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
    }

    nonisolated private static func isSymlink(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) ?? false
    }

    nonisolated private static func fileSizeBytes(at url: URL) -> UInt64 {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        return UInt64(values?.fileSize ?? 0)
    }

    nonisolated private static func readTailData(from url: URL, maxBytes: Int) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        let totalSize = try handle.seekToEnd()
        let boundedSize = UInt64(max(maxBytes, 0))
        let startOffset = totalSize > boundedSize ? totalSize - boundedSize : 0
        try handle.seek(toOffset: startOffset)
        return try handle.readToEnd() ?? Data()
    }

    nonisolated private static func tryOrEmpty(_ work: () throws -> Data) -> Data {
        (try? work()) ?? Data("{}".utf8)
    }

    private static func zipSupportPack(folderURL: URL, destinationZipURL: URL) throws {
        if FileManager.default.fileExists(atPath: destinationZipURL.path) {
            try FileManager.default.removeItem(at: destinationZipURL)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", "--sequesterRsrc", "--keepParent", folderURL.path, destinationZipURL.path]
        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw NSError(
                domain: "CruiseControl.SupportPack",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: "zip packaging failed (\(process.terminationStatus))."]
            )
        }
    }

    private struct PreparedPack {
        let rootFolderName: String
        let files: [PreparedFile]
        let omissions: [SupportPackReview.Omission]
    }

    private struct PreparedFile {
        let relativePath: String
        var data: Data
        let priority: Int
        var note: String?
    }

    private struct SettingsPayload: Codable {
        let capturedAt: Date
        let settings: [String: String]
        let featureToggles: [String: String]
    }

    private struct SupportPackManifest: Codable {
        let createdAt: Date
        let rootFolderName: String
        let maxPayloadBytes: UInt64
        let totalPayloadBytes: UInt64
        let includedFiles: [FileEntry]
        let omissions: [SupportPackReview.Omission]

        struct FileEntry: Codable {
            let relativePath: String
            let sizeBytes: UInt64
            let sha256: String
            let note: String?
        }
    }
}

private extension Dictionary where Key == String, Value == String {
    func sortedByKey() -> [String: String] {
        let ordered = self.sorted { $0.key < $1.key }
        return Dictionary(uniqueKeysWithValues: ordered)
    }
}
