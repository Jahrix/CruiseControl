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
    let latestTag: String?
    let latestVersion: String?
    let latestBuild: String?
    let releaseURL: URL?
    let downloadedAssetURL: URL?
    let latestAssetName: String?
    let isUpdateAvailable: Bool
    let isOffline: Bool
    let canInstallAutomatically: Bool
    let shouldOfferOpenDownloadedAsset: Bool
    let shouldOfferApplicationsFolder: Bool
    let gatekeeperCommand: String?

    init(
        success: Bool,
        message: String,
        currentVersion: String? = nil,
        currentBuild: String? = nil,
        latestTag: String? = nil,
        latestVersion: String?,
        latestBuild: String? = nil,
        releaseURL: URL?,
        downloadedAssetURL: URL? = nil,
        latestAssetName: String? = nil,
        isUpdateAvailable: Bool = false,
        isOffline: Bool = false,
        canInstallAutomatically: Bool = false,
        shouldOfferOpenDownloadedAsset: Bool = false,
        shouldOfferApplicationsFolder: Bool = false,
        gatekeeperCommand: String? = nil
    ) {
        self.success = success
        self.message = message
        self.currentVersion = currentVersion ?? bundleVersionString()
        self.currentBuild = currentBuild ?? bundleBuildString()
        self.latestTag = latestTag
        self.latestVersion = latestVersion
        self.latestBuild = latestBuild
        self.releaseURL = releaseURL
        self.downloadedAssetURL = downloadedAssetURL
        self.latestAssetName = latestAssetName
        self.isUpdateAvailable = isUpdateAvailable
        self.isOffline = isOffline
        self.canInstallAutomatically = canInstallAutomatically
        self.shouldOfferOpenDownloadedAsset = shouldOfferOpenDownloadedAsset
        self.shouldOfferApplicationsFolder = shouldOfferApplicationsFolder
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
}

private struct GitHubReleaseInfo {
    let latestTag: String
    let latestVersion: String
    let latestBuild: String?
    let currentVersion: String
    let currentBuild: String
    let releaseURL: URL?
    let dmgAssetURL: URL?
    let dmgAssetName: String?
    let isPrerelease: Bool
}

private struct GitHubReleaseFetch {
    let info: GitHubReleaseInfo?
    let outcome: UpdateCheckOutcome?
}

enum AppMaintenanceService {
    private static var githubOwner: String {
        if let value = Bundle.main.object(forInfoDictionaryKey: "CCGitHubOwner") as? String,
           !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return value
        }
        return "Jahrix"
    }

    private static var githubRepo: String {
        if let value = Bundle.main.object(forInfoDictionaryKey: "CCGitHubRepo") as? String,
           !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return value
        }
        return "CruiseControl"
    }

    private static var githubReleasesPageURL: URL? {
        URL(string: "https://github.com/\(githubOwner)/\(githubRepo)/releases")
    }

    private static var githubLatestReleaseAPIURL: URL? {
        URL(string: "https://api.github.com/repos/\(githubOwner)/\(githubRepo)/releases/latest")
    }

    private static var githubRecentReleasesAPIURL: URL? {
        URL(string: "https://api.github.com/repos/\(githubOwner)/\(githubRepo)/releases?per_page=1")
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
        guard let url = githubReleasesPageURL else { return }
        NSWorkspace.shared.open(url)
    }

    static func openDownloadedAssetInFinder(_ url: URL) -> ActionOutcome {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return ActionOutcome(success: false, message: "Downloaded DMG not found. Check for updates again.")
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
        return ActionOutcome(success: true, message: "Revealed downloaded DMG in Finder.")
    }

    static func gatekeeperFixCommand() -> String {
        "xattr -dr com.apple.quarantine /Applications/CruiseControl.app"
    }

    static func checkForUpdates(currentVersion: String, preferSparkle: Bool = true) async -> UpdateCheckOutcome {
        if preferSparkle {
            let sparkleOutcome = SparkleUpdateBridge.checkForUpdatesIfAvailable()
            if sparkleOutcome.success {
                return sparkleOutcome
            }
            if sparkleOutcome.message.contains("Sparkle not configured") == false {
                return sparkleOutcome
            }
        }

        return await checkGitHubReleases(currentVersion: currentVersion)
    }

    static func checkForUpdatesAndInstall(currentVersion: String, preferSparkle: Bool = true) async -> UpdateCheckOutcome {
        await checkForUpdatesAndInstall(currentVersion: currentVersion, preferSparkle: preferSparkle, progress: nil)
    }

    static func checkForUpdatesAndInstall(
        currentVersion: String,
        preferSparkle: Bool = true,
        progress: (@MainActor @Sendable (String) -> Void)?
    ) async -> UpdateCheckOutcome {
        if preferSparkle {
            let sparkleOutcome = SparkleUpdateBridge.checkForUpdatesIfAvailable()
            if sparkleOutcome.success {
                return sparkleOutcome
            }
        }

        let fetched = await fetchGitHubReleaseInfo(currentVersion: currentVersion)
        guard let release = fetched.info else {
            return fetched.outcome ?? UpdateCheckOutcome(success: false, message: "Update check failed.", latestVersion: nil, releaseURL: nil)
        }

        guard compareReleaseVersion(
            latestVersion: release.latestVersion,
            latestBuild: release.latestBuild,
            currentVersion: release.currentVersion,
            currentBuild: release.currentBuild
        ) == .orderedDescending else {
            return upToDateOutcome(for: release)
        }

        guard let dmgAssetURL = release.dmgAssetURL else {
            return UpdateCheckOutcome(
                success: false,
                message: statusMessage(
                    "Update \(release.latestVersion) is available, but no CruiseControl DMG asset was published. Open the release page and download manually.",
                    currentVersion: release.currentVersion,
                    currentBuild: release.currentBuild,
                    latestTag: release.latestTag
                ),
                currentVersion: release.currentVersion,
                currentBuild: release.currentBuild,
                latestTag: release.latestTag,
                latestVersion: release.latestVersion,
                latestBuild: release.latestBuild,
                releaseURL: release.releaseURL,
                latestAssetName: release.dmgAssetName,
                isUpdateAvailable: true,
                shouldOfferApplicationsFolder: true,
                gatekeeperCommand: gatekeeperFixCommand()
            )
        }

        do {
            if let progress {
                await MainActor.run {
                    progress("Current: \(currentVersionBuildString())\nDownloading CruiseControl \(release.latestVersion)…")
                }
            }
            let downloadedDMG = try await downloadDMGAsset(
                from: dmgAssetURL,
                tag: release.latestVersion,
                assetName: release.dmgAssetName ?? dmgAssetURL.lastPathComponent
            )
            if let progress {
                await MainActor.run {
                    progress("Current: \(currentVersionBuildString())\nInstalling to /Applications…")
                }
            }
            let installMessage = try await installDownloadedDMG(
                at: downloadedDMG,
                version: release.latestVersion
            )
            return UpdateCheckOutcome(
                success: true,
                message: statusMessage(installMessage),
                currentVersion: release.currentVersion,
                currentBuild: release.currentBuild,
                latestTag: release.latestTag,
                latestVersion: release.latestVersion,
                latestBuild: release.latestBuild,
                releaseURL: release.releaseURL,
                downloadedAssetURL: downloadedDMG,
                latestAssetName: release.dmgAssetName,
                isUpdateAvailable: true,
                canInstallAutomatically: true,
                shouldOfferOpenDownloadedAsset: true,
                gatekeeperCommand: gatekeeperFixCommand()
            )
        } catch {
            let downloadedDMG = lastDownloadedDMGURL(tag: release.latestVersion)
            let message: String
            let needsApplicationsHelp: Bool
            if isApplicationsPermissionError(error) {
                message = statusMessage("CruiseControl needs permission to write to /Applications. Drag and drop install may be required.")
                needsApplicationsHelp = true
            } else {
                message = statusMessage(
                    "Update download/install failed: \(error.localizedDescription)",
                    currentVersion: release.currentVersion,
                    currentBuild: release.currentBuild,
                    latestTag: release.latestTag
                )
                needsApplicationsHelp = false
            }

            return UpdateCheckOutcome(
                success: false,
                message: message,
                currentVersion: release.currentVersion,
                currentBuild: release.currentBuild,
                latestTag: release.latestTag,
                latestVersion: release.latestVersion,
                latestBuild: release.latestBuild,
                releaseURL: release.releaseURL,
                downloadedAssetURL: downloadedDMG,
                latestAssetName: release.dmgAssetName,
                isUpdateAvailable: true,
                canInstallAutomatically: true,
                shouldOfferOpenDownloadedAsset: downloadedDMG != nil,
                shouldOfferApplicationsFolder: needsApplicationsHelp,
                gatekeeperCommand: gatekeeperFixCommand()
            )
        }
    }

    static func currentVersionString() -> String {
        bundleVersionString()
    }

    static func currentBuildString() -> String {
        bundleBuildString()
    }

    static func currentVersionBuildString() -> String {
        "\(currentVersionString()) (\(currentBuildString()))"
    }

    private static func checkGitHubReleases(currentVersion: String) async -> UpdateCheckOutcome {
        let fetched = await fetchGitHubReleaseInfo(currentVersion: currentVersion)
        guard let release = fetched.info else {
            return fetched.outcome ?? UpdateCheckOutcome(success: false, message: statusMessage("Update check failed."), latestVersion: nil, releaseURL: nil)
        }

        if compareReleaseVersion(
            latestVersion: release.latestVersion,
            latestBuild: release.latestBuild,
            currentVersion: release.currentVersion,
            currentBuild: release.currentBuild
        ) == .orderedDescending {
            return UpdateCheckOutcome(
                success: true,
                message: statusMessage(
                    "Update available.",
                    currentVersion: release.currentVersion,
                    currentBuild: release.currentBuild,
                    latestTag: release.latestTag
                ),
                currentVersion: release.currentVersion,
                currentBuild: release.currentBuild,
                latestTag: release.latestTag,
                latestVersion: release.latestVersion,
                latestBuild: release.latestBuild,
                releaseURL: release.releaseURL,
                latestAssetName: release.dmgAssetName,
                isUpdateAvailable: true,
                canInstallAutomatically: release.dmgAssetURL != nil,
                gatekeeperCommand: gatekeeperFixCommand()
            )
        }

        return upToDateOutcome(for: release)
    }

    private static func fetchGitHubReleaseInfo(currentVersion: String) async -> GitHubReleaseFetch {
        guard let url = githubLatestReleaseAPIURL else {
            return GitHubReleaseFetch(info: nil, outcome: UpdateCheckOutcome(success: false, message: statusMessage("Invalid releases URL configuration."), latestVersion: nil, releaseURL: githubReleasesPageURL))
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        request.setValue("CruiseControl/\(currentVersion)", forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return GitHubReleaseFetch(info: nil, outcome: UpdateCheckOutcome(success: false, message: statusMessage("Update check failed: invalid server response."), latestVersion: nil, releaseURL: githubReleasesPageURL))
            }

            if !(200...299).contains(http.statusCode) {
                let statusCode = http.statusCode
                if statusCode == 404 {
                    // GitHub /releases/latest ignores prereleases. Fall back to newest release (including prereleases).
                    let fallback = await fetchNewestReleaseIncludingPrereleases(currentVersion: currentVersion)
                    if fallback.info != nil {
                        return fallback
                    }

                    return GitHubReleaseFetch(
                        info: nil,
                        outcome: UpdateCheckOutcome(
                            success: false,
                            message: statusMessage(
                                "No GitHub Releases found yet. Publish a GitHub Release for tag \(suggestedReleaseTag(for: currentVersion)) (for example v1.1.3-rc1) to enable updates.",
                                currentVersion: currentVersion,
                                currentBuild: currentBuildString()
                            ),
                            currentVersion: currentVersion,
                            currentBuild: currentBuildString(),
                            latestVersion: nil,
                            releaseURL: githubReleasesPageURL
                        )
                    )
                }

                if statusCode == 403,
                   let remaining = http.value(forHTTPHeaderField: "X-RateLimit-Remaining"),
                   remaining == "0" {
                    return GitHubReleaseFetch(
                        info: nil,
                        outcome: UpdateCheckOutcome(
                            success: false,
                            message: statusMessage("Update check is temporarily rate-limited by GitHub. Try again later."),
                            latestVersion: nil,
                            releaseURL: githubReleasesPageURL
                        )
                    )
                }

                return GitHubReleaseFetch(
                    info: nil,
                    outcome: UpdateCheckOutcome(
                        success: false,
                        message: statusMessage("Update check failed: HTTP \(statusCode)."),
                        latestVersion: nil,
                        releaseURL: githubReleasesPageURL
                    )
                )
            }

            struct ReleasePayload: Decodable {
                let tag_name: String
                let html_url: String
                let assets: [Asset]
            }

            struct Asset: Decodable {
                let name: String
                let browser_download_url: String
            }

            let payload = try JSONDecoder().decode(ReleasePayload.self, from: data)
            let latest = normalizedVersion(payload.tag_name)
            let current = normalizedVersion(currentVersion)
            let releaseURL = URL(string: payload.html_url) ?? githubReleasesPageURL

            let preferredDMG = payload.assets.first {
                let lower = $0.name.lowercased()
                return lower.hasSuffix(".dmg") && lower.contains("cruisecontrol")
            } ?? payload.assets.first {
                $0.name.lowercased().hasSuffix(".dmg")
            }

            return GitHubReleaseFetch(
                info: GitHubReleaseInfo(
                    latestTag: payload.tag_name.trimmingCharacters(in: .whitespacesAndNewlines),
                    latestVersion: latest,
                    latestBuild: extractBuildNumber(fromAssetName: preferredDMG?.name),
                    currentVersion: current,
                    currentBuild: currentBuildString(),
                    releaseURL: releaseURL,
                    dmgAssetURL: preferredDMG.flatMap { URL(string: $0.browser_download_url) },
                    dmgAssetName: preferredDMG?.name,
                    isPrerelease: false
                ),
                outcome: nil
            )
        } catch {
            if isOfflineError(error) {
                return GitHubReleaseFetch(
                    info: nil,
                    outcome: UpdateCheckOutcome(
                        success: true,
                        message: statusMessage("You appear offline. Connect and try again."),
                        latestVersion: nil,
                        releaseURL: githubReleasesPageURL,
                        isUpdateAvailable: false,
                        isOffline: true
                    )
                )
            }
            return GitHubReleaseFetch(info: nil, outcome: UpdateCheckOutcome(success: false, message: statusMessage("Update check failed: \(error.localizedDescription)"), latestVersion: nil, releaseURL: githubReleasesPageURL))
        }
    }

    private static func fetchNewestReleaseIncludingPrereleases(currentVersion: String) async -> GitHubReleaseFetch {
        guard let url = githubRecentReleasesAPIURL else {
            return GitHubReleaseFetch(info: nil, outcome: nil)
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        request.setValue("CruiseControl/\(currentVersion)", forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                return GitHubReleaseFetch(info: nil, outcome: nil)
            }

            struct ReleasePayload: Decodable {
                let tag_name: String
                let html_url: String
                let prerelease: Bool
                let assets: [Asset]
            }

            struct Asset: Decodable {
                let name: String
                let browser_download_url: String
            }

            let payloads = try JSONDecoder().decode([ReleasePayload].self, from: data)
            guard let payload = payloads.first else {
                return GitHubReleaseFetch(info: nil, outcome: nil)
            }

            let latest = normalizedVersion(payload.tag_name)
            let current = normalizedVersion(currentVersion)
            let releaseURL = URL(string: payload.html_url) ?? githubReleasesPageURL

            let preferredDMG = payload.assets.first {
                let lower = $0.name.lowercased()
                return lower.hasSuffix(".dmg") && lower.contains("cruisecontrol")
            } ?? payload.assets.first {
                $0.name.lowercased().hasSuffix(".dmg")
            }

            return GitHubReleaseFetch(
                info: GitHubReleaseInfo(
                    latestTag: payload.tag_name.trimmingCharacters(in: .whitespacesAndNewlines),
                    latestVersion: latest,
                    latestBuild: extractBuildNumber(fromAssetName: preferredDMG?.name),
                    currentVersion: current,
                    currentBuild: currentBuildString(),
                    releaseURL: releaseURL,
                    dmgAssetURL: preferredDMG.flatMap { URL(string: $0.browser_download_url) },
                    dmgAssetName: preferredDMG?.name,
                    isPrerelease: payload.prerelease
                ),
                outcome: nil
            )
        } catch {
            return GitHubReleaseFetch(info: nil, outcome: nil)
        }
    }

    private static func normalizedVersion(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "v", with: "", options: [.caseInsensitive, .anchored])
    }

    private static func isOfflineError(_ error: Error) -> Bool {
        guard let urlError = error as? URLError else {
            return false
        }

        switch urlError.code {
        case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
            return true
        default:
            return false
        }
    }

    private static func downloadDMGAsset(from assetURL: URL, tag: String, assetName: String) async throws -> URL {
        var request = URLRequest(url: assetURL)
        request.timeoutInterval = 120
        request.setValue("CruiseControl-Updater", forHTTPHeaderField: "User-Agent")

        let (downloadedTempURL, response) = try await URLSession.shared.download(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw NSError(domain: "CruiseControlUpdater", code: 1, userInfo: [NSLocalizedDescriptionKey: "Download failed (HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1))."])
        }

        let fileManager = FileManager.default
        guard let cacheRoot = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("CruiseControl/Updates", isDirectory: true)
            .appendingPathComponent(sanitizePathComponent(tag), isDirectory: true) else {
            throw NSError(domain: "CruiseControlUpdater", code: 2, userInfo: [NSLocalizedDescriptionKey: "Could not access the CruiseControl update cache."])
        }

        try fileManager.createDirectory(at: cacheRoot, withIntermediateDirectories: true)

        let destination = cacheRoot.appendingPathComponent("CruiseControl.dmg")
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.moveItem(at: downloadedTempURL, to: destination)

        let attributes = try fileManager.attributesOfItem(atPath: destination.path)
        let fileSize = attributes[.size] as? NSNumber
        if (fileSize?.int64Value ?? 0) <= 0 {
            throw NSError(domain: "CruiseControlUpdater", code: 3, userInfo: [NSLocalizedDescriptionKey: "Downloaded DMG is empty."])
        }

        if assetName.lowercased().hasSuffix(".dmg") == false {
            throw NSError(domain: "CruiseControlUpdater", code: 4, userInfo: [NSLocalizedDescriptionKey: "Downloaded update is not a DMG."])
        }

        return destination
    }

    private static func installDownloadedDMG(at dmgURL: URL, version: String) async throws -> String {
        let fileManager = FileManager.default
        let mountPoint = fileManager.temporaryDirectory
            .appendingPathComponent("CruiseControl-DMG-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: mountPoint, withIntermediateDirectories: true)
        try runProcess(
            "/usr/bin/hdiutil",
            arguments: ["attach", "-nobrowse", "-readonly", dmgURL.path, "-mountpoint", mountPoint.path]
        )
        defer {
            try? runProcess("/usr/bin/hdiutil", arguments: ["detach", mountPoint.path, "-force"])
            try? fileManager.removeItem(at: mountPoint)
        }

        guard let mountedAppURL = findAppBundle(in: mountPoint) else {
            throw NSError(domain: "CruiseControlUpdater", code: 5, userInfo: [NSLocalizedDescriptionKey: "Mounted DMG did not contain CruiseControl.app."])
        }

        let destination = URL(fileURLWithPath: "/Applications/CruiseControl.app", isDirectory: true)
        try replaceAppInApplications(at: destination, with: mountedAppURL)
        try await relaunchInstalledApp(at: destination)
        return "Updated to \(formattedVersionBuild(version: version, build: extractBuildNumber(fromAssetName: dmgURL.lastPathComponent))) and relaunching."
    }

    private static func replaceAppInApplications(at destination: URL, with source: URL) throws {
        let fileManager = FileManager.default
        let timestamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let backup = destination.deletingLastPathComponent()
            .appendingPathComponent("CruiseControl.app.backup-\(timestamp)")
        var movedExistingApp = false

        if fileManager.fileExists(atPath: destination.path) {
            do {
                try fileManager.moveItem(at: destination, to: backup)
                movedExistingApp = true
            } catch {
                throw mapApplicationsError(error)
            }
        }

        do {
            try fileManager.copyItem(at: source, to: destination)
        } catch {
            if movedExistingApp, fileManager.fileExists(atPath: backup.path) {
                try? fileManager.moveItem(at: backup, to: destination)
            }
            throw mapApplicationsError(error)
        }
    }

    @MainActor
    private static func relaunchInstalledApp(at appURL: URL) async throws {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.createsNewApplicationInstance = true

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { _, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            }
        }

        NSApp.terminate(nil)
    }

    private static func mapApplicationsError(_ error: Error) -> Error {
        if isApplicationsPermissionError(error) {
            return NSError(
                domain: "CruiseControlUpdater",
                code: 6,
                userInfo: [NSLocalizedDescriptionKey: "CruiseControl needs permission to write to /Applications. Drag and drop install may be required."]
            )
        }
        return error
    }

    private static func isApplicationsPermissionError(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain {
            return [
                NSFileWriteNoPermissionError,
                NSFileWriteUnknownError,
                NSFileWriteVolumeReadOnlyError,
                NSFileWriteFileExistsError
            ].contains(nsError.code)
        }
        if nsError.domain == NSPOSIXErrorDomain {
            return nsError.code == Int(EACCES) || nsError.code == Int(EPERM)
        }
        return false
    }

    private static func findAppBundle(in root: URL) -> URL? {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        for case let url as URL in enumerator {
            if url.pathExtension.caseInsensitiveCompare("app") == .orderedSame {
                return url
            }
        }
        return nil
    }

    private static func runProcess(_ launchPath: String, arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments

        let stderrPipe = Pipe()
        process.standardError = stderrPipe

        try process.run()
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            let stderr = String(data: stderrData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Unknown error"
            throw NSError(domain: "CruiseControlUpdater", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: stderr])
        }
    }

    private static func compareVersions(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let l = lhs.split(separator: ".").map {
            Int(String($0.prefix { $0.isNumber })) ?? 0
        }
        let r = rhs.split(separator: ".").map {
            Int(String($0.prefix { $0.isNumber })) ?? 0
        }
        let count = max(l.count, r.count)

        for index in 0..<count {
            let left = index < l.count ? l[index] : 0
            let right = index < r.count ? r[index] : 0
            if left > right { return .orderedDescending }
            if left < right { return .orderedAscending }
        }
        return .orderedSame
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

    private static func suggestedReleaseTag(for currentVersion: String) -> String {
        "v\(normalizedVersion(currentVersion))-rc1"
    }

    private static func lastDownloadedDMGURL(tag: String) -> URL? {
        guard let cacheRoot = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("CruiseControl/Updates", isDirectory: true)
            .appendingPathComponent(sanitizePathComponent(tag), isDirectory: true) else {
            return nil
        }
        let dmgURL = cacheRoot.appendingPathComponent("CruiseControl.dmg")
        return FileManager.default.fileExists(atPath: dmgURL.path) ? dmgURL : nil
    }

    private static func statusMessage(
        _ base: String,
        currentVersion: String? = nil,
        currentBuild: String? = nil,
        latestTag: String? = nil
    ) -> String {
        var lines = ["Current: \((currentVersion ?? currentVersionString())) (Build \((currentBuild ?? currentBuildString())))"]
        if let latestTag, latestTag.isEmpty == false {
            lines.append("Latest release tag: \(latestTag)")
        }
        lines.append(base)
        return lines.joined(separator: "\n")
    }

    private static func upToDateOutcome(for release: GitHubReleaseInfo) -> UpdateCheckOutcome {
        UpdateCheckOutcome(
            success: true,
            message: statusMessage(
                "You are up to date.",
                currentVersion: release.currentVersion,
                currentBuild: release.currentBuild,
                latestTag: release.latestTag
            ),
            currentVersion: release.currentVersion,
            currentBuild: release.currentBuild,
            latestTag: release.latestTag,
            latestVersion: release.latestVersion,
            latestBuild: release.latestBuild,
            releaseURL: release.releaseURL,
            latestAssetName: release.dmgAssetName,
            isUpdateAvailable: false
        )
    }
}
