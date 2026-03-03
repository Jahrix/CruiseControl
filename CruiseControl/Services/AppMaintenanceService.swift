import Foundation
import AppKit

private func bundleVersionString() -> String {
    if let marketing = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
       !marketing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        return marketing
    }
    return "Unknown"
}

private func bundleBuildString() -> String {
    if let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
       !build.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        return build
    }
    return "Unknown"
}

struct UpdateCheckOutcome {
    let success: Bool
    let message: String
    let currentVersion: String
    let currentBuild: String
    let checkedRepo: String
    let checkedEndpoint: String
    let latestTag: String?
    let latestVersion: String?
    let latestBuild: String?
    let releaseURL: URL?
    let latestAssetURL: URL?
    let downloadedAssetURL: URL?
    let latestAssetName: String?
    let isUpdateAvailable: Bool
    let isOffline: Bool
    let canDownloadAsset: Bool
    let shouldOfferOpenDownloadedAsset: Bool
    let gatekeeperCommand: String?

    init(
        success: Bool,
        message: String,
        currentVersion: String? = nil,
        currentBuild: String? = nil,
        checkedRepo: String = GitHubReleaseClient.repoLabel,
        checkedEndpoint: String = GitHubReleaseClient.releasesEndpoint.absoluteString,
        latestTag: String? = nil,
        latestVersion: String? = nil,
        latestBuild: String? = nil,
        releaseURL: URL? = GitHubReleaseClient.releasesPageURL,
        latestAssetURL: URL? = nil,
        downloadedAssetURL: URL? = nil,
        latestAssetName: String? = nil,
        isUpdateAvailable: Bool = false,
        isOffline: Bool = false,
        canDownloadAsset: Bool = false,
        shouldOfferOpenDownloadedAsset: Bool = false,
        gatekeeperCommand: String? = nil
    ) {
        self.success = success
        self.message = message
        self.currentVersion = currentVersion ?? bundleVersionString()
        self.currentBuild = currentBuild ?? bundleBuildString()
        self.checkedRepo = checkedRepo
        self.checkedEndpoint = checkedEndpoint
        self.latestTag = latestTag
        self.latestVersion = latestVersion
        self.latestBuild = latestBuild
        self.releaseURL = releaseURL
        self.latestAssetURL = latestAssetURL
        self.downloadedAssetURL = downloadedAssetURL
        self.latestAssetName = latestAssetName
        self.isUpdateAvailable = isUpdateAvailable
        self.isOffline = isOffline
        self.canDownloadAsset = canDownloadAsset
        self.shouldOfferOpenDownloadedAsset = shouldOfferOpenDownloadedAsset
        self.gatekeeperCommand = gatekeeperCommand
    }

    var currentVersionBuildString: String {
        "\(currentVersion) (Build \(currentBuild))"
    }

    var latestVersionBuildString: String? {
        if let latestTag, latestTag.isEmpty == false {
            if let latestBuild, latestBuild.isEmpty == false {
                return "\(latestTag) (Build \(latestBuild))"
            }
            return latestTag
        }
        guard let latestVersion else {
            return nil
        }
        if let latestBuild, latestBuild.isEmpty == false {
            return "\(latestVersion) (Build \(latestBuild))"
        }
        return latestVersion
    }

    var downloadButtonTitle: String {
        guard let latestAssetName else {
            return "Download Latest Release"
        }
        let lower = latestAssetName.lowercased()
        if lower.hasSuffix(".dmg") {
            return "Download Latest DMG"
        }
        if lower.hasSuffix(".zip") {
            return "Download Latest ZIP"
        }
        return "Download Latest Release"
    }
}

private final class ReleaseAssetDownloadDelegate: NSObject, URLSessionDownloadDelegate {
    private let progressHandler: (@MainActor @Sendable (Double) -> Void)?
    private var continuation: CheckedContinuation<(URL, URLResponse), Error>?
    private var temporaryFileURL: URL?
    private var hasCompleted = false

    init(progressHandler: (@MainActor @Sendable (Double) -> Void)?) {
        self.progressHandler = progressHandler
    }

    func begin(with task: URLSessionDownloadTask) async throws -> (URL, URLResponse) {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            task.resume()
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else {
            return
        }
        let fraction = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        if let progressHandler {
            Task { @MainActor in
                progressHandler(fraction)
            }
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        temporaryFileURL = location
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            finish(.failure(error))
            return
        }

        guard let temporaryFileURL, let response = task.response else {
            finish(.failure(NSError(
                domain: "CruiseControlUpdater",
                code: 900,
                userInfo: [NSLocalizedDescriptionKey: "Download completed without a file."]
            )))
            return
        }

        finish(.success((temporaryFileURL, response)))
    }

    private func finish(_ result: Result<(URL, URLResponse), Error>) {
        guard hasCompleted == false else {
            return
        }
        hasCompleted = true

        switch result {
        case .success(let value):
            continuation?.resume(returning: value)
        case .failure(let error):
            continuation?.resume(throwing: error)
        }
        continuation = nil
    }
}

enum AppMaintenanceService {
    static var updateSourceLabel: String {
        GitHubReleaseClient.repoLabel
    }

    static var updateEndpointLabel: String {
        GitHubReleaseClient.releasesEndpoint.absoluteString
    }

    static func showAppInFinder() -> ActionOutcome {
        let url = Bundle.main.bundleURL
        NSWorkspace.shared.activateFileViewerSelecting([url])
        return ActionOutcome(success: true, message: "Revealed app in Finder.")
    }

    static func openApplicationsFolder() -> ActionOutcome {
        let applicationsURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        NSWorkspace.shared.open(applicationsURL)
        return ActionOutcome(success: true, message: "Opened /Applications.")
    }

    @MainActor
    static func installToApplications() -> ActionOutcome {
        let source = Bundle.main.bundleURL

        let panel = NSOpenPanel()
        panel.title = "Install CruiseControl"
        panel.message = "Select an install folder. /Applications is recommended."
        panel.prompt = "Install"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)

        guard panel.runModal() == .OK, let destinationFolder = panel.url else {
            return ActionOutcome(success: false, message: "Install cancelled.")
        }

        let access = destinationFolder.startAccessingSecurityScopedResource()
        defer {
            if access { destinationFolder.stopAccessingSecurityScopedResource() }
        }

        let destination = destinationFolder.appendingPathComponent(source.lastPathComponent)

        do {
            if source.path == destination.path {
                return ActionOutcome(success: true, message: "CruiseControl is already running from \(destinationFolder.path).")
            }

            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }

            try FileManager.default.copyItem(at: source, to: destination)
            return ActionOutcome(success: true, message: "Installed app to \(destination.path).")
        } catch {
            return ActionOutcome(
                success: false,
                message: "Install failed: \(error.localizedDescription). Choose a writable folder or retry /Applications and approve admin prompt."
            )
        }
    }

    static func openReleasesPage() {
        NSWorkspace.shared.open(GitHubReleaseClient.releasesPageURL)
    }

    static func openDownloadedAssetInFinder(_ url: URL) -> ActionOutcome {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return ActionOutcome(success: false, message: "Downloaded release asset not found. Download it again.")
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
        return ActionOutcome(success: true, message: "Revealed downloaded release asset in Finder.")
    }

    static func gatekeeperFixCommand() -> String {
        #"xattr -dr com.apple.quarantine "/Applications/CruiseControl.app""#
    }

    static func currentVersionString() -> String {
        bundleVersionString()
    }

    static func currentBuildString() -> String {
        bundleBuildString()
    }

    static func currentVersionBuildString() -> String {
        "\(currentVersionString()) (Build \(currentBuildString()))"
    }

    nonisolated static func checkedGitHubRepository() -> String {
        GitHubReleaseClient.repoLabel
    }

    static func checkForUpdates(
        currentVersion: String,
        preferSparkle: Bool = true,
        includePrereleases: Bool = false
    ) async -> UpdateCheckOutcome {
        if preferSparkle {
            let sparkleOutcome = SparkleUpdateBridge.checkForUpdatesIfAvailable()
            if sparkleOutcome.success {
                return sparkleOutcome
            }
            if sparkleOutcome.message.contains("Sparkle not configured") == false {
                return sparkleOutcome
            }
        }

        let result = await GitHubReleaseClient.fetchLatestRelease(
            currentVersion: currentVersion,
            includePrereleases: includePrereleases
        )
        return outcome(from: result, currentVersion: currentVersion)
    }

    static func downloadLatestReleaseAsset(
        currentVersion: String,
        includePrereleases: Bool = false,
        progress: (@MainActor @Sendable (String) -> Void)? = nil
    ) async -> UpdateCheckOutcome {
        let result = await GitHubReleaseClient.fetchLatestRelease(
            currentVersion: currentVersion,
            includePrereleases: includePrereleases
        )
        let initialOutcome = outcome(from: result, currentVersion: currentVersion)

        guard case let .success(selection) = result else {
            return initialOutcome
        }

        guard compareReleaseVersion(
            latestVersion: selection.normalizedVersion,
            latestBuild: extractBuildNumber(fromAssetName: selection.preferredAsset?.name),
            currentVersion: normalizedVersion(currentVersion),
            currentBuild: currentBuildString()
        ) == .orderedDescending else {
            return initialOutcome
        }

        guard let asset = selection.preferredAsset else {
            return UpdateCheckOutcome(
                success: false,
                message: statusMessage(
                    "No downloadable asset found on the release.",
                    currentVersion: currentVersionString(),
                    currentBuild: currentBuildString(),
                    latestTag: selection.release.tagName
                ),
                currentVersion: currentVersionString(),
                currentBuild: currentBuildString(),
                latestTag: selection.release.tagName,
                latestVersion: selection.normalizedVersion,
                latestBuild: extractBuildNumber(fromAssetName: nil),
                releaseURL: selection.release.htmlURL,
                latestAssetURL: nil,
                latestAssetName: nil,
                isUpdateAvailable: true,
                canDownloadAsset: false,
                gatekeeperCommand: gatekeeperFixCommand()
            )
        }

        do {
            if let progress {
                await MainActor.run {
                    progress(statusMessage(
                        "Downloading \(asset.name)… 0%",
                        currentVersion: currentVersionString(),
                        currentBuild: currentBuildString(),
                        latestTag: selection.release.tagName
                    ))
                }
            }

            let savedURL = try await downloadReleaseAsset(asset: asset, releaseTag: selection.release.tagName) { fraction in
                let percent = Int((fraction * 100).rounded())
                progress?(statusMessage(
                    "Downloading \(asset.name)… \(percent)%",
                    currentVersion: currentVersionString(),
                    currentBuild: currentBuildString(),
                    latestTag: selection.release.tagName
                ))
            }

            let savedPath = savedURL.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
            return UpdateCheckOutcome(
                success: true,
                message: statusMessage(
                    "Downloaded \(asset.name) to \(savedPath). Drag CruiseControl.app to /Applications from the downloaded DMG or ZIP.",
                    currentVersion: currentVersionString(),
                    currentBuild: currentBuildString(),
                    latestTag: selection.release.tagName
                ),
                currentVersion: currentVersionString(),
                currentBuild: currentBuildString(),
                latestTag: selection.release.tagName,
                latestVersion: selection.normalizedVersion,
                latestBuild: extractBuildNumber(fromAssetName: asset.name),
                releaseURL: selection.release.htmlURL,
                latestAssetURL: asset.browserDownloadURL,
                downloadedAssetURL: savedURL,
                latestAssetName: asset.name,
                isUpdateAvailable: true,
                canDownloadAsset: true,
                shouldOfferOpenDownloadedAsset: true,
                gatekeeperCommand: gatekeeperFixCommand()
            )
        } catch {
            return UpdateCheckOutcome(
                success: false,
                message: statusMessage(
                    "Download failed: \(error.localizedDescription)",
                    currentVersion: currentVersionString(),
                    currentBuild: currentBuildString(),
                    latestTag: selection.release.tagName
                ),
                currentVersion: currentVersionString(),
                currentBuild: currentBuildString(),
                latestTag: selection.release.tagName,
                latestVersion: selection.normalizedVersion,
                latestBuild: extractBuildNumber(fromAssetName: asset.name),
                releaseURL: selection.release.htmlURL,
                latestAssetURL: asset.browserDownloadURL,
                latestAssetName: asset.name,
                isUpdateAvailable: true,
                canDownloadAsset: true,
                gatekeeperCommand: gatekeeperFixCommand()
            )
        }
    }

    private static func outcome(from result: GitHubReleaseLookupResult, currentVersion: String) -> UpdateCheckOutcome {
        switch result {
        case let .success(selection):
            let latestBuild = extractBuildNumber(fromAssetName: selection.preferredAsset?.name)
            let comparison = compareReleaseVersion(
                latestVersion: selection.normalizedVersion,
                latestBuild: latestBuild,
                currentVersion: normalizedVersion(currentVersion),
                currentBuild: currentBuildString()
            )

            if comparison == .orderedDescending {
                let body: String
                if selection.preferredAsset == nil {
                    body = "Update available: \(formattedVersionBuild(version: selection.normalizedVersion, build: latestBuild)). No downloadable asset found on the release."
                } else {
                    body = "Update available: \(formattedVersionBuild(version: selection.normalizedVersion, build: latestBuild))."
                }

                return UpdateCheckOutcome(
                    success: true,
                    message: statusMessage(
                        body,
                        currentVersion: currentVersionString(),
                        currentBuild: currentBuildString(),
                        latestTag: selection.release.tagName
                    ),
                    currentVersion: currentVersionString(),
                    currentBuild: currentBuildString(),
                    latestTag: selection.release.tagName,
                    latestVersion: selection.normalizedVersion,
                    latestBuild: latestBuild,
                    releaseURL: selection.release.htmlURL,
                    latestAssetURL: selection.preferredAsset?.browserDownloadURL,
                    latestAssetName: selection.preferredAsset?.name,
                    isUpdateAvailable: true,
                    canDownloadAsset: selection.preferredAsset != nil,
                    gatekeeperCommand: gatekeeperFixCommand()
                )
            }

            return UpdateCheckOutcome(
                success: true,
                message: statusMessage(
                    "You're up to date.",
                    currentVersion: currentVersionString(),
                    currentBuild: currentBuildString(),
                    latestTag: selection.release.tagName
                ),
                currentVersion: currentVersionString(),
                currentBuild: currentBuildString(),
                latestTag: selection.release.tagName,
                latestVersion: selection.normalizedVersion,
                latestBuild: latestBuild,
                releaseURL: selection.release.htmlURL,
                latestAssetURL: selection.preferredAsset?.browserDownloadURL,
                latestAssetName: selection.preferredAsset?.name,
                isUpdateAvailable: false
            )

        case let .offline(repoLabel, endpoint, errorDescription):
            return UpdateCheckOutcome(
                success: false,
                message: statusMessage("You appear offline. Connect and try again. (\(errorDescription))"),
                checkedRepo: repoLabel,
                checkedEndpoint: endpoint.absoluteString,
                latestVersion: nil,
                isOffline: true,
                gatekeeperCommand: gatekeeperFixCommand()
            )

        case let .notFound(repoLabel, endpoint):
            return UpdateCheckOutcome(
                success: false,
                message: statusMessage("The repo or release API is not accessible (HTTP 404). Verify the owner/repo name or access permissions."),
                checkedRepo: repoLabel,
                checkedEndpoint: endpoint.absoluteString,
                latestVersion: nil,
                gatekeeperCommand: gatekeeperFixCommand()
            )

        case let .unauthorized(repoLabel, endpoint):
            return UpdateCheckOutcome(
                success: false,
                message: statusMessage("GitHub rejected the request (HTTP 401 unauthorized). Check repository access."),
                checkedRepo: repoLabel,
                checkedEndpoint: endpoint.absoluteString,
                latestVersion: nil,
                gatekeeperCommand: gatekeeperFixCommand()
            )

        case let .rateLimited(repoLabel, endpoint, resetAt):
            let detail: String
            if let resetAt {
                detail = "GitHub API rate limit reached. Try again after \(Self.rateLimitFormatter.string(from: resetAt))."
            } else {
                detail = "GitHub API rate limit reached. Try again later."
            }
            return UpdateCheckOutcome(
                success: false,
                message: statusMessage(detail),
                checkedRepo: repoLabel,
                checkedEndpoint: endpoint.absoluteString,
                latestVersion: nil,
                gatekeeperCommand: gatekeeperFixCommand()
            )

        case let .forbidden(repoLabel, endpoint, detail):
            return UpdateCheckOutcome(
                success: false,
                message: statusMessage("GitHub refused access (HTTP 403 forbidden). \(detail)"),
                checkedRepo: repoLabel,
                checkedEndpoint: endpoint.absoluteString,
                latestVersion: nil,
                gatekeeperCommand: gatekeeperFixCommand()
            )

        case let .empty(repoLabel, endpoint):
            return UpdateCheckOutcome(
                success: false,
                message: statusMessage("No releases are published yet. Updates will work after the first GitHub Release is created."),
                checkedRepo: repoLabel,
                checkedEndpoint: endpoint.absoluteString,
                latestVersion: nil,
                gatekeeperCommand: gatekeeperFixCommand()
            )

        case let .apiError(repoLabel, endpoint, statusCode, detail):
            let suffix = detail.map { " \($0)" } ?? ""
            return UpdateCheckOutcome(
                success: false,
                message: statusMessage("GitHub API error (HTTP \(statusCode)).\(suffix)"),
                checkedRepo: repoLabel,
                checkedEndpoint: endpoint.absoluteString,
                latestVersion: nil,
                gatekeeperCommand: gatekeeperFixCommand()
            )

        case let .invalidResponse(repoLabel, endpoint, detail):
            return UpdateCheckOutcome(
                success: false,
                message: statusMessage("GitHub returned an unexpected response. \(detail)"),
                checkedRepo: repoLabel,
                checkedEndpoint: endpoint.absoluteString,
                latestVersion: nil,
                gatekeeperCommand: gatekeeperFixCommand()
            )
        }
    }

    private static func downloadReleaseAsset(
        asset: GitHubReleaseAsset,
        releaseTag: String,
        progress: (@MainActor @Sendable (Double) -> Void)?
    ) async throws -> URL {
        var request = URLRequest(url: asset.browserDownloadURL)
        request.timeoutInterval = 180
        request.setValue("CruiseControl/\(currentVersionString())", forHTTPHeaderField: "User-Agent")

        let delegate = ReleaseAssetDownloadDelegate(progressHandler: progress)
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        let task = session.downloadTask(with: request)
        let (temporaryFileURL, response) = try await delegate.begin(with: task)
        session.finishTasksAndInvalidate()

        guard let http = response as? HTTPURLResponse else {
            throw NSError(domain: "CruiseControlUpdater", code: 901, userInfo: [
                NSLocalizedDescriptionKey: "Download failed: invalid server response."
            ])
        }

        log("download status=\(http.statusCode) asset=\(asset.name)")

        guard (200...299).contains(http.statusCode) else {
            throw NSError(domain: "CruiseControlUpdater", code: http.statusCode, userInfo: [
                NSLocalizedDescriptionKey: "Download failed (HTTP \(http.statusCode))."
            ])
        }

        let destination = try uniqueDownloadDestination(tag: releaseTag, assetName: asset.name)
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: temporaryFileURL, to: destination)

        let attributes = try FileManager.default.attributesOfItem(atPath: destination.path)
        let fileSize = attributes[.size] as? NSNumber
        if (fileSize?.int64Value ?? 0) <= 0 {
            throw NSError(domain: "CruiseControlUpdater", code: 902, userInfo: [
                NSLocalizedDescriptionKey: "Downloaded file is empty."
            ])
        }

        log("savedPath=\(destination.path)")
        return destination
    }

    private static func uniqueDownloadDestination(tag: String, assetName: String) throws -> URL {
        let downloadsDirectory: URL
        if let url = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first {
            downloadsDirectory = url
        } else {
            downloadsDirectory = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
                .appendingPathComponent("Downloads", isDirectory: true)
        }

        try FileManager.default.createDirectory(at: downloadsDirectory, withIntermediateDirectories: true)

        let lowerAssetName = assetName.lowercased()
        let ext = lowerAssetName.hasSuffix(".zip") ? "zip" : "dmg"
        let safeTag = sanitizePathComponent(tag)
        let baseName = "CruiseControl-\(safeTag)"
        var candidate = downloadsDirectory.appendingPathComponent("\(baseName).\(ext)")
        var index = 1

        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = downloadsDirectory.appendingPathComponent("\(baseName)-\(index).\(ext)")
            index += 1
        }

        return candidate
    }

    private static func compareReleaseVersion(
        latestVersion: String,
        latestBuild: String?,
        currentVersion: String,
        currentBuild: String
    ) -> ComparisonResult {
        let versionResult = compareVersions(latestVersion, currentVersion)
        if versionResult != .orderedSame {
            return versionResult
        }
        guard let latestBuild else {
            return .orderedSame
        }
        return compareVersions(latestBuild, currentBuild)
    }

    private static func compareVersions(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let l = lhs.split(separator: ".").map { Int(String($0.prefix { $0.isNumber })) ?? 0 }
        let r = rhs.split(separator: ".").map { Int(String($0.prefix { $0.isNumber })) ?? 0 }
        let count = max(l.count, r.count)

        for index in 0..<count {
            let left = index < l.count ? l[index] : 0
            let right = index < r.count ? r[index] : 0
            if left > right { return .orderedDescending }
            if left < right { return .orderedAscending }
        }
        return .orderedSame
    }

    private static func normalizedVersion(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "v", with: "", options: [.caseInsensitive, .anchored])
    }

    private static func formattedVersionBuild(version: String, build: String?) -> String {
        if let build, build.isEmpty == false {
            return "\(version) (Build \(build))"
        }
        return version
    }

    private static func extractBuildNumber(fromAssetName assetName: String?) -> String? {
        guard let assetName else {
            return nil
        }
        let base = URL(fileURLWithPath: assetName).deletingPathExtension().lastPathComponent
        let components = base.split(separator: "-")
        guard let candidate = components.last, candidate.allSatisfy(\.isNumber) else {
            return nil
        }
        return String(candidate)
    }

    private static func sanitizePathComponent(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
    }

    private static func statusMessage(
        _ base: String,
        currentVersion: String? = nil,
        currentBuild: String? = nil,
        latestTag: String? = nil
    ) -> String {
        var lines = [
            "Checking updates from \(GitHubReleaseClient.repoLabel)",
            "Endpoint: \(GitHubReleaseClient.releasesEndpoint.absoluteString)",
            "Current: \((currentVersion ?? currentVersionString())) (Build \((currentBuild ?? currentBuildString())))"
        ]
        if let latestTag, latestTag.isEmpty == false {
            lines.append("Latest release tag: \(latestTag)")
        }
        lines.append(base)
        return lines.joined(separator: "\n")
    }

    private static func log(_ message: String) {
        print("[CruiseControl Update] \(message)")
    }

    private static let rateLimitFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()
}
