import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        @Bindable var appModel = appModel

        NavigationStack {
            Form {
                Section {
                    Toggle("Require Face ID", isOn: $appModel.requireOwnerAuthentication)
                    Toggle("Block screenshots", isOn: $appModel.blockScreenCapture)
                    Toggle("Hide when switching apps", isOn: $appModel.hideScreenWhenInactive)
                    Toggle("Privacy shield when away", isOn: $appModel.privacyShieldWhenAway)
                    Toggle("Privacy shield always", isOn: $appModel.privacyShieldAlways)
                } footer: {
                    Text("Strongest protection is Face ID, screenshot blocking, hiding the PC in the app switcher, and a privacy shield whenever you are not on home Wi-Fi. The shield blacks out the remote screen except around your finger.")
                }

                Section {
                    if appModel.usesStrongestProtection {
                        LabeledContent("Protection", value: "Strongest")
                    } else {
                        Button("Enable strongest protection") {
                            appModel.enableStrongestProtection()
                        }
                    }
                    LabeledContent("Version", value: appVersion)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }
}

#Preview {
    SettingsView()
        .environment(AppModel())
}
