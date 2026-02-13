import Foundation

#if canImport(Sparkle)
import Sparkle
#endif

enum SparkleUpdateBridge {
    static func checkForUpdatesIfAvailable() -> UpdateCheckOutcome {
        guard let feedURL = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String,
              !feedURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let _ = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String else {
            return UpdateCheckOutcome(success: false, message: "Sparkle not configured. Falling back to GitHub Releases.", latestVersion: nil, releaseURL: nil)
        }

        #if canImport(Sparkle)
        DispatchQueue.main.async {
            if let delegate = NSApp.delegate as? AppDelegate,
               let updaterController = delegate.sparkleUpdaterController {
                updaterController.checkForUpdates(nil)
            }
        }
        return UpdateCheckOutcome(success: true, message: "Sparkle update check triggered.", latestVersion: nil, releaseURL: nil)
        #else
        return UpdateCheckOutcome(success: false, message: "Sparkle configured but framework is not linked. Falling back to GitHub Releases.", latestVersion: nil, releaseURL: nil)
        #endif
    }
}
