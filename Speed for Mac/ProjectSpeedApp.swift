import SwiftUI

@main
struct ProjectSpeedApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup("Project Speed") {
            MenuContentView()
                .environmentObject(appDelegate.sampler)
                .environmentObject(appDelegate.settingsStore)
                .frame(minWidth: 1120, minHeight: 760)
        }

        Settings {
            VStack(alignment: .leading, spacing: 12) {
                Text("Project Speed")
                    .font(.title2)
                    .fontWeight(.semibold)
                Text("Desktop performance control center for flight simulator sessions.")
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
            .padding(20)
            .frame(width: 440)
        }
    }
}
