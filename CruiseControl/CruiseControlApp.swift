import SwiftUI

@main
struct CruiseControlApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup("CruiseControl") {
            CruiseControlV2View()
                .environmentObject(appDelegate.sampler)
                .environmentObject(appDelegate.settingsStore)
                .environmentObject(appDelegate.featureStore)
                .environmentObject(appDelegate.proGate)
                .frame(minWidth: 900, minHeight: 650)
        }

        Settings {
            CruiseControlV2SettingsView()
                .environmentObject(appDelegate.settingsStore)
                .environmentObject(appDelegate.proGate)
        }

        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") {
                    appDelegate.checkForUpdatesFromMenu()
                }

                Button("Show App in Finder") {
                    _ = AppMaintenanceService.showAppInFinder()
                }

            }
        }
    }
}
