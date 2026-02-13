import Foundation
import AppKit

struct UpdateCheckOutcome {
    let success: Bool
    let message: String
    let latestVersion: String?
    let releaseURL: URL?
}

enum AppMaintenanceService {
    static func showAppInFinder() -> ActionOutcome {
        let url = Bundle.main.bundleURL
        NSWorkspace.shared.activateFileViewerSelecting([url])
        return ActionOutcome(success: true, message: "Revealed app in Finder.")
    }

    static func installToApplications() -> ActionOutcome {
        let source = Bundle.main.bundleURL
        let destination = URL(fileURLWithPath: "/Applications").appendingPathComponent(source.lastPathComponent)

        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: source, to: destination)
            return ActionOutcome(success: true, message: "Installed app to \(destination.path).")
        } catch {
            return ActionOutcome(
                success: false,
                message: "Install to /Applications failed: \(error.localizedDescription). If prompted, grant Finder/admin permission and retry."
            )
        }
    }

    static func openReleasesPage() {
        guard let url = URL(string: "https://github.com/Jahrix/CruiseControl/releases") else { return }
        NSWorkspace.shared.open(url)
    }

    static func checkForUpdates(currentVersion: String) async -> UpdateCheckOutcome {
        guard let url = URL(string: "https://api.github.com/repos/Jahrix/CruiseControl/releases/latest") else {
            return UpdateCheckOutcome(success: false, message: "Invalid releases URL.", latestVersion: nil, releaseURL: nil)
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        request.setValue("CruiseControl/1.1.2", forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                return UpdateCheckOutcome(success: false, message: "Update check failed: HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1).", latestVersion: nil, releaseURL: nil)
            }

            struct ReleasePayload: Decodable {
                let tag_name: String
                let html_url: String
            }

            let payload = try JSONDecoder().decode(ReleasePayload.self, from: data)
            let latest = normalizedVersion(payload.tag_name)
            let current = normalizedVersion(currentVersion)
            let releaseURL = URL(string: payload.html_url)

            if compareVersions(latest, current) == .orderedDescending {
                return UpdateCheckOutcome(success: true, message: "New version available: \(latest) (current \(current)).", latestVersion: latest, releaseURL: releaseURL)
            }

            return UpdateCheckOutcome(success: true, message: "You are up to date (\(current)).", latestVersion: latest, releaseURL: releaseURL)
        } catch {
            return UpdateCheckOutcome(success: false, message: "Update check failed: \(error.localizedDescription)", latestVersion: nil, releaseURL: nil)
        }
    }

    static func currentVersionString() -> String {
        if let marketing = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String {
            return marketing
        }
        return "Unknown"
    }

    private static func normalizedVersion(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "v", with: "", options: [.caseInsensitive, .anchored])
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
