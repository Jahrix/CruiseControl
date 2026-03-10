import SwiftUI

@main
struct CruiseControlApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup("CruiseControl") {
            CruiseControlRootView()
                .environmentObject(appDelegate.sampler)
                .environmentObject(appDelegate.settingsStore)
                .environmentObject(appDelegate.featureStore)
                .environmentObject(appDelegate.proGate)
                .frame(minWidth: 1120, minHeight: 760)
        }

        Settings {
            UpgradeSettingsView()
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

                Button("Open Applications Folder") {
                    _ = AppMaintenanceService.openApplicationsFolder()
                }

                Button("Install to /Applications") {
                    _ = AppMaintenanceService.installToApplications()
                }
            }
        }
    }
}

private struct CruiseControlRootView: View {
    @AppStorage("ccOnboardingSeen") private var onboardingSeen: Bool = false
    @AppStorage("ccOnboardingDontShowAgain") private var onboardingDontShowAgain: Bool = true
    @AppStorage("ccPreferredStartSection") private var preferredStartSectionRaw: String = DashboardSection.overview.rawValue
    @AppStorage("ccOpenXPlaneWizardOnLaunch") private var openXPlaneWizardOnLaunch: Bool = false

    @State private var showOnboarding: Bool = false
    @State private var dontShowAgain: Bool = true

    var body: some View {
        MenuContentView()
            .sheet(isPresented: $showOnboarding) {
                firstRunOnboardingSheet
            }
            .onAppear {
                dontShowAgain = onboardingDontShowAgain
                if !onboardingSeen || !onboardingDontShowAgain {
                    showOnboarding = true
                }
            }
    }

    private var firstRunOnboardingSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Welcome to CruiseControl")
                .font(.title2.weight(.bold))

            Text("CruiseControl is your Frame-Time Lab and X-Plane companion for monitoring simulator performance and tuning your session workflow.")
                .font(.body)

            Text("It does not perform fake RAM purges or hidden kernel tricks. Actions are transparent and user-approved.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Divider()

            HStack(spacing: 10) {
                Button("Start in General") {
                    completeOnboarding(startSection: .overview, openWizard: false)
                }
                .buttonStyle(.bordered)

                Button("Start in Sim Mode") {
                    completeOnboarding(startSection: .simMode, openWizard: false)
                }
                .buttonStyle(.borderedProminent)
            }

            Button("Quick Start: X-Plane Wizard") {
                completeOnboarding(startSection: .simMode, openWizard: true)
            }
            .buttonStyle(.link)

            Toggle("Don't show again", isOn: $dontShowAgain)
                .toggleStyle(.checkbox)
        }
        .padding(24)
        .frame(width: 560)
    }

    private func completeOnboarding(startSection: DashboardSection, openWizard: Bool) {
        preferredStartSectionRaw = startSection.rawValue
        openXPlaneWizardOnLaunch = openWizard
        onboardingSeen = true
        onboardingDontShowAgain = dontShowAgain
        showOnboarding = false
    }
}
