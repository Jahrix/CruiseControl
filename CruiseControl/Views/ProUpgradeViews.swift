import SwiftUI

struct ProFeatureGateView<Content: View, LockedView: View>: View {
    @EnvironmentObject private var proGate: ProGate

    private let content: Content
    private let lockedView: LockedView

    init(
        @ViewBuilder content: () -> Content,
        @ViewBuilder lockedView: () -> LockedView
    ) {
        self.content = content()
        self.lockedView = lockedView()
    }

    var body: some View {
        Group {
            if proGate.isProUnlocked {
                content
            } else {
                lockedView
            }
        }
    }
}

struct ProLockedCardView: View {
    let title: String
    let message: String

    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)

            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Button("Upgrade to Pro") {
                openSettings()
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct UpgradeSettingsView: View {
    @EnvironmentObject private var proGate: ProGate

    @State private var licenseKey: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("CruiseControl Pro")
                    .font(.title2.weight(.bold))

                Text("Activation is fully offline. CruiseControl verifies the signed key locally and stores it in your Keychain.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Current status")
                    .font(.headline)

                statusBadge

                Text(proGate.statusLine())
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                if let error = proGate.lastValidationError, !error.isEmpty {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("License key")
                    .font(.headline)

                TextEditor(text: $licenseKey)
                    .font(.system(size: 12, weight: .regular, design: .monospaced))
                    .frame(minHeight: 96)
                    .textSelection(.enabled)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

                HStack {
                    Button("Activate") {
                        let trimmed = licenseKey.trimmingCharacters(in: .whitespacesAndNewlines)
                        if proGate.activate(licenseString: trimmed) {
                            licenseKey = trimmed
                        }
                    }
                    .buttonStyle(.borderedProminent)

                    Button("Remove License") {
                        proGate.removeLicense()
                        licenseKey = ""
                    }
                    .buttonStyle(.bordered)
                    .disabled(proGate.installedLicense == nil && licenseKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("What Pro unlocks")
                    .font(.headline)
                Text("• Situation Presets for one-click session modes")
                Text("• Per-Airport Regulator Profiles with import/export")
                Text("• More premium workflow surfaces over time without online sign-in")
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)

            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(width: 520, alignment: .topLeading)
        .onAppear {
            if licenseKey.isEmpty {
                licenseKey = proGate.installedLicense ?? ""
            }
        }
    }

    private var statusBadge: some View {
        Text(proGate.licenseStatus.badgeText)
            .font(.caption.weight(.bold))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(badgeColor.opacity(0.14), in: Capsule())
            .foregroundStyle(badgeColor)
    }

    private var badgeColor: Color {
        switch proGate.licenseStatus {
        case .unlocked:
            return .green
        case .expired:
            return .orange
        case .invalid:
            return .red
        case .locked, .missing:
            return .secondary
        }
    }
}
