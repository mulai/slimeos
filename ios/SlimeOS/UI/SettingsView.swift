import SwiftUI

/// Settings: account, this device's pairing, the PIN, about.
struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var tunnel: TunnelController
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Slime ID") {
                    if let email = model.slimeIdEmail {
                        LabeledContent("Signed in as", value: SlimeId.maskEmail(email))
                        Button("Sign out", role: .destructive) { model.signOutSlimeId() }
                    } else {
                        Button("Sign in with Slime ID") {
                            dismiss()
                            model.startSlimeIdSignIn()
                        }
                    }
                }
                Section {
                    LabeledContent("Secure tunnel", value: tunnel.status.label)
                    if let ms = model.hubPingMs { LabeledContent("Delay to the hub", value: "\(ms) ms") }
                    if tunnel.isPaired {
                        Button("Forget this device's pairing", role: .destructive) { model.modal = .forgetPairing }
                    }
                } header: {
                    Text("This device")
                } footer: {
                    Text("Forgetting the pairing needs a new pairing code to connect again.")
                }
                Section("Security") {
                    Button("Change PIN") {
                        dismiss()
                        model.changingPin = true
                    }
                    Button("Lock now") {
                        dismiss()
                        model.lock()
                    }
                }
                Section("About") {
                    LabeledContent("Version", value: Self.version)
                    Link("Slime OS website", destination: URL(string: "https://www.slimeos.com")!)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .preferredColorScheme(.dark)
        .tint(Slime.teal)
    }

    static var version: String {
        let info = Bundle.main.infoDictionary
        return "\(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?"))"
    }
}
