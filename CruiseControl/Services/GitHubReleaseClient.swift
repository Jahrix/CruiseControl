import Foundation

struct GitHubReleaseAsset: Decodable {
    let name: String
    let browserDownloadURL: URL

    enum CodingKeys: String, CodingKey {
        case name
        case browserDownloadURL = "browser_download_url"
    }
}

struct GitHubRelease: Decodable {
    let tagName: String
    let htmlURL: URL
    let draft: Bool
    let prerelease: Bool
    let assets: [GitHubReleaseAsset]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case htmlURL = "html_url"
        case draft
        case prerelease
        case assets
    }
}

struct GitHubReleaseSelection {
    let repoLabel: String
    let endpoint: URL
    let release: GitHubRelease
    let preferredAsset: GitHubReleaseAsset?

    var normalizedVersion: String {
        release.tagName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "v", with: "", options: [.caseInsensitive, .anchored])
    }
}

enum GitHubReleaseLookupResult {
    case success(GitHubReleaseSelection)
    case offline(repoLabel: String, endpoint: URL, errorDescription: String)
    case unauthorized(repoLabel: String, endpoint: URL)
    case notFound(repoLabel: String, endpoint: URL)
    case rateLimited(repoLabel: String, endpoint: URL, resetAt: Date?)
    case forbidden(repoLabel: String, endpoint: URL, detail: String)
    case empty(repoLabel: String, endpoint: URL)
    case apiError(repoLabel: String, endpoint: URL, statusCode: Int, detail: String?)
    case invalidResponse(repoLabel: String, endpoint: URL, detail: String)
}

enum GitHubReleaseClient {
    nonisolated static let owner = "jahrix"
    nonisolated static let repo = "cruisecontrol"
    nonisolated static let repoLabel = "\(owner)/\(repo)"
    nonisolated static let releasesPageURL = URL(string: "https://github.com/\(owner)/\(repo)/releases")!
    nonisolated static let releasesEndpoint = URL(string: "https://api.github.com/repos/\(owner)/\(repo)/releases")!

    static func fetchLatestRelease(
        currentVersion: String,
        includePrereleases: Bool
    ) async -> GitHubReleaseLookupResult {
        var components = URLComponents(url: releasesEndpoint, resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "per_page", value: "20")
        ]

        guard let requestURL = components?.url else {
            return .invalidResponse(repoLabel: repoLabel, endpoint: releasesEndpoint, detail: "Could not build the GitHub Releases endpoint.")
        }

        var request = URLRequest(url: requestURL)
        request.timeoutInterval = 12
        request.setValue("CruiseControl/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        log("repo=\(repoLabel) endpoint=\(requestURL.absoluteString)")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .invalidResponse(repoLabel: repoLabel, endpoint: requestURL, detail: "Invalid server response.")
            }

            log("httpStatus=\(http.statusCode)")

            switch http.statusCode {
            case 200:
                let decoder = JSONDecoder()
                let releases = try decoder.decode([GitHubRelease].self, from: data)
                let filtered = releases.filter { release in
                    release.draft == false && (includePrereleases || isPrereleaseLike(release) == false)
                }

                guard let selectedRelease = filtered.first else {
                    return .empty(repoLabel: repoLabel, endpoint: requestURL)
                }

                let asset = preferredAsset(from: selectedRelease)
                log("selectedTag=\(selectedRelease.tagName) selectedAsset=\(asset?.name ?? "none")")

                return .success(GitHubReleaseSelection(
                    repoLabel: repoLabel,
                    endpoint: requestURL,
                    release: selectedRelease,
                    preferredAsset: asset
                ))

            case 401:
                return .unauthorized(repoLabel: repoLabel, endpoint: requestURL)

            case 404:
                return .notFound(repoLabel: repoLabel, endpoint: requestURL)

            case 403:
                if http.value(forHTTPHeaderField: "X-RateLimit-Remaining") == "0" {
                    let resetAt = rateLimitResetDate(from: http)
                    return .rateLimited(repoLabel: repoLabel, endpoint: requestURL, resetAt: resetAt)
                }
                let detail = responseSnippet(from: data) ?? "Forbidden."
                return .forbidden(repoLabel: repoLabel, endpoint: requestURL, detail: detail)

            default:
                return .apiError(
                    repoLabel: repoLabel,
                    endpoint: requestURL,
                    statusCode: http.statusCode,
                    detail: responseSnippet(from: data)
                )
            }
        } catch {
            if isOfflineError(error) {
                return .offline(repoLabel: repoLabel, endpoint: requestURL, errorDescription: error.localizedDescription)
            }
            return .invalidResponse(repoLabel: repoLabel, endpoint: requestURL, detail: error.localizedDescription)
        }
    }

    private static func preferredAsset(from release: GitHubRelease) -> GitHubReleaseAsset? {
        let assets = release.assets

        if let dmg = assets.first(where: { asset in
            let lower = asset.name.lowercased()
            return lower.hasSuffix(".dmg") && lower.contains("cruisecontrol")
        }) {
            return dmg
        }

        if let anyDMG = assets.first(where: { $0.name.lowercased().hasSuffix(".dmg") }) {
            return anyDMG
        }

        if let zip = assets.first(where: { asset in
            let lower = asset.name.lowercased()
            return lower.hasSuffix(".zip") && lower.contains("cruisecontrol")
        }) {
            return zip
        }

        return assets.first(where: { $0.name.lowercased().hasSuffix(".zip") })
    }

    private static func isPrereleaseLike(_ release: GitHubRelease) -> Bool {
        if release.prerelease {
            return true
        }

        let lowerTag = release.tagName.lowercased()
        return lowerTag.contains("-rc") || lowerTag.contains("-beta") || lowerTag.contains("-alpha")
    }

    private static func responseSnippet(from data: Data) -> String? {
        guard var text = String(data: data, encoding: .utf8)?
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines),
              text.isEmpty == false else {
            return nil
        }

        if text.count > 180 {
            text = String(text.prefix(180)) + "…"
        }
        return text
    }

    private static func rateLimitResetDate(from response: HTTPURLResponse) -> Date? {
        guard let raw = response.value(forHTTPHeaderField: "X-RateLimit-Reset"),
              let seconds = TimeInterval(raw) else {
            return nil
        }
        return Date(timeIntervalSince1970: seconds)
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

    private static func log(_ message: String) {
        print("[CruiseControl Update] \(message)")
    }
}
