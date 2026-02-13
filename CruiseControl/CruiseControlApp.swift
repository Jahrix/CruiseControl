import SwiftUI

@main
struct CruiseControlApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup("CruiseControl") {
            MenuContentView()
                .environmentObject(appDelegate.sampler)
                .environmentObject(appDelegate.settingsStore)
                .environmentObject(appDelegate.featureStore)
                .frame(minWidth: 1120, minHeight: 760)
        }

        Settings {
            VStack(alignment: .leading, spacing: 12) {
                Text("CruiseControl")
                    .font(.title2)
                    .fontWeight(.semibold)
                Text("Desktop performance control center for flight simulator sessions.")
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
            .padding(20)
            .frame(width: 440)
        }

        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") {
                    appDelegate.checkForUpdatesFromMenu()
                }

                Button("Show App in Finder") {
                    _ = AppMaintenanceService.showAppInFinder()
                }

                Button("Install to /Applications") {
                    _ = AppMaintenanceService.installToApplications()
                }
            }
        }
    }
}
