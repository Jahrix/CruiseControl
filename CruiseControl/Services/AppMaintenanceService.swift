import Foundation
import AppKit

struct UpdateCheckOutcome {
    let success: Bool
    let message: String
    let latestVersion: String?
    let releaseURL: URL?
}

private struct GitHubReleaseInfo {
    let latestVersion: String
    let currentVersion: String
    let releaseURL: URL?
    let zipAssetURL: URL?
    let zipAssetName: String?
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

        guard compareVersions(release.latestVersion, release.currentVersion) == .orderedDescending else {
            return UpdateCheckOutcome(
                success: true,
                message: "You are up to date (\(release.currentVersion)).",
                latestVersion: release.latestVersion,
                releaseURL: release.releaseURL
            )
        }

        guard let zipAssetURL = release.zipAssetURL else {
            return UpdateCheckOutcome(
                success: false,
                message: "Update \(release.latestVersion) found, but no .zip app asset was published. Open Releases and download manually.",
                latestVersion: release.latestVersion,
                releaseURL: release.releaseURL
            )
        }

        let action = promptForUpdateInstall(
            latestVersion: release.latestVersion,
            assetName: release.zipAssetName ?? zipAssetURL.lastPathComponent
        )

        switch action {
        case .later:
            return UpdateCheckOutcome(
                success: true,
                message: "Update \(release.latestVersion) is available.",
                latestVersion: release.latestVersion,
                releaseURL: release.releaseURL
            )
        case .openReleases:
            if let releaseURL = release.releaseURL {
                NSWorkspace.shared.open(releaseURL)
            }
            return UpdateCheckOutcome(
                success: true,
                message: "Opened releases page for update \(release.latestVersion).",
                latestVersion: release.latestVersion,
                releaseURL: release.releaseURL
            )
        case .installNow:
            do {
                let installMessage = try await downloadExtractAndInstall(zipAssetURL: zipAssetURL)
                return UpdateCheckOutcome(
                    success: true,
                    message: installMessage,
                    latestVersion: release.latestVersion,
                    releaseURL: release.releaseURL
                )
            } catch {
                return UpdateCheckOutcome(
                    success: false,
                    message: "Update download/install failed: \(error.localizedDescription)",
                    latestVersion: release.latestVersion,
                    releaseURL: release.releaseURL
                )
            }
        }
    }

    static func currentVersionString() -> String {
        if let marketing = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String {
            return marketing
        }
        return "Unknown"
    }

    private static func checkGitHubReleases(currentVersion: String) async -> UpdateCheckOutcome {
        let fetched = await fetchGitHubReleaseInfo(currentVersion: currentVersion)
        guard let release = fetched.info else {
            return fetched.outcome ?? UpdateCheckOutcome(success: false, message: "Update check failed.", latestVersion: nil, releaseURL: nil)
        }

        if compareVersions(release.latestVersion, release.currentVersion) == .orderedDescending {
            return UpdateCheckOutcome(
                success: true,
                message: "New version available: \(release.latestVersion) (current \(release.currentVersion)).",
                latestVersion: release.latestVersion,
                releaseURL: release.releaseURL
            )
        }
        return UpdateCheckOutcome(
            success: true,
            message: "You are up to date (\(release.currentVersion)).",
            latestVersion: release.latestVersion,
            releaseURL: release.releaseURL
        )
    }

    private static func fetchGitHubReleaseInfo(currentVersion: String) async -> GitHubReleaseFetch {
        guard let url = githubLatestReleaseAPIURL else {
            return GitHubReleaseFetch(info: nil, outcome: UpdateCheckOutcome(success: false, message: "Invalid releases URL configuration.", latestVersion: nil, releaseURL: githubReleasesPageURL))
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        request.setValue("CruiseControl/\(currentVersion)", forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return GitHubReleaseFetch(info: nil, outcome: UpdateCheckOutcome(success: false, message: "Update check failed: invalid server response.", latestVersion: nil, releaseURL: githubReleasesPageURL))
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
                            message: "No GitHub release is published yet for \(githubOwner)/\(githubRepo). Publish your first release to enable in-app updates.",
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
                            message: "GitHub API rate limit reached. Try again later or configure Sparkle.",
                            latestVersion: nil,
                            releaseURL: githubReleasesPageURL
                        )
                    )
                }

                return GitHubReleaseFetch(
                    info: nil,
                    outcome: UpdateCheckOutcome(
                        success: false,
                        message: "Update check failed: HTTP \(statusCode).",
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

            let preferredZip = payload.assets.first {
                let lower = $0.name.lowercased()
                return lower.hasSuffix(".zip") && lower.contains("cruisecontrol")
            } ?? payload.assets.first {
                $0.name.lowercased().hasSuffix(".zip")
            }

            return GitHubReleaseFetch(
                info: GitHubReleaseInfo(
                    latestVersion: latest,
                    currentVersion: current,
                    releaseURL: releaseURL,
                    zipAssetURL: preferredZip.flatMap { URL(string: $0.browser_download_url) },
                    zipAssetName: preferredZip?.name,
                    isPrerelease: false
                ),
                outcome: nil
            )
        } catch {
            return GitHubReleaseFetch(info: nil, outcome: UpdateCheckOutcome(success: false, message: "Update check failed: \(error.localizedDescription)", latestVersion: nil, releaseURL: githubReleasesPageURL))
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

            let preferredZip = payload.assets.first {
                let lower = $0.name.lowercased()
                return lower.hasSuffix(".zip") && lower.contains("cruisecontrol")
            } ?? payload.assets.first {
                $0.name.lowercased().hasSuffix(".zip")
            }

            return GitHubReleaseFetch(
                info: GitHubReleaseInfo(
                    latestVersion: latest,
                    currentVersion: current,
                    releaseURL: releaseURL,
                    zipAssetURL: preferredZip.flatMap { URL(string: $0.browser_download_url) },
                    zipAssetName: preferredZip?.name,
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

    private enum UpdateInstallAction {
        case installNow
        case openReleases
        case later
    }

    @MainActor
    private static func promptForUpdateInstall(latestVersion: String, assetName: String) -> UpdateInstallAction {
        let alert = NSAlert()
        alert.messageText = "CruiseControl \(latestVersion) Available"
        alert.informativeText = "Download and install \(assetName) now?"
        alert.addButton(withTitle: "Install Now")
        alert.addButton(withTitle: "Open Releases")
        alert.addButton(withTitle: "Later")

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            return .installNow
        case .alertSecondButtonReturn:
            return .openReleases
        default:
            return .later
        }
    }

    private static func downloadExtractAndInstall(zipAssetURL: URL) async throws -> String {
        var request = URLRequest(url: zipAssetURL)
        request.timeoutInterval = 120
        request.setValue("CruiseControl-Updater", forHTTPHeaderField: "User-Agent")

        let (downloadedTempURL, response) = try await URLSession.shared.download(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw NSError(domain: "CruiseControlUpdater", code: 1, userInfo: [NSLocalizedDescriptionKey: "Download failed (HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1))."])
        }

        let fileManager = FileManager.default
        let workDir = fileManager.temporaryDirectory
            .appendingPathComponent("CruiseControl-Update-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: workDir, withIntermediateDirectories: true)

        let archiveURL = workDir.appendingPathComponent("update.zip")
        try fileManager.moveItem(at: downloadedTempURL, to: archiveURL)

        let extractedDir = workDir.appendingPathComponent("extracted", isDirectory: true)
        try fileManager.createDirectory(at: extractedDir, withIntermediateDirectories: true)

        try runProcess("/usr/bin/ditto", arguments: ["-x", "-k", archiveURL.path, extractedDir.path])

        guard let extractedAppURL = findAppBundle(in: extractedDir) else {
            throw NSError(domain: "CruiseControlUpdater", code: 2, userInfo: [NSLocalizedDescriptionKey: "Downloaded archive did not contain a .app bundle."])
        }

        let destination = try resolveUpdateDestination(appName: extractedAppURL.lastPathComponent)
        if destination.standardizedFileURL.path == Bundle.main.bundleURL.standardizedFileURL.path {
            let staged = destination.deletingLastPathComponent().appendingPathComponent("CruiseControl-updated.app")
            try replaceApp(at: staged, with: extractedAppURL)
            try await relaunchInstalledApp(at: staged)
            return "Update installed to \(staged.path). Relaunch complete."
        } else {
            try replaceApp(at: destination, with: extractedAppURL)
            try await relaunchInstalledApp(at: destination)
            return "Update installed to \(destination.path). Relaunch complete."
        }
    }

    private static func resolveUpdateDestination(appName: String) throws -> URL {
        let fileManager = FileManager.default
        let currentApp = Bundle.main.bundleURL.standardizedFileURL
        let currentParent = currentApp.deletingLastPathComponent()

        if fileManager.isWritableFile(atPath: currentParent.path) {
            return currentApp
        }

        let userApplications = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent("Applications", isDirectory: true)
        try fileManager.createDirectory(at: userApplications, withIntermediateDirectories: true)

        if fileManager.isWritableFile(atPath: userApplications.path) {
            return userApplications.appendingPathComponent(appName)
        }

        throw NSError(
            domain: "CruiseControlUpdater",
            code: 3,
            userInfo: [NSLocalizedDescriptionKey: "No writable app install path found. Use Install to /Applications manually."]
        )
    }

    private static func replaceApp(at destination: URL, with source: URL) throws {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.copyItem(at: source, to: destination)
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
        let l = lhs.split(separator: ".").map { Int($0) ?? 0 }
        let r = rhs.split(separator: ".").map { Int($0) ?? 0 }
        let count = max(l.count, r.count)

        for index in 0..<count {
            let left = index < l.count ? l[index] : 0
            let right = index < r.count ? r[index] : 0
            if left > right { return .orderedDescending }
            if left < right { return .orderedAscending }
        }
        return .orderedSame
    }
}
