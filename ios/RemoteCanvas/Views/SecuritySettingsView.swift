import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        @Bindable var appModel = appModel

        NavigationStack {
            Form {
                Section {
                    StreamQualityControls(appModel: appModel)
                } header: {
                    Text("Picture and speed")
                } footer: {
                    Text("These settings apply to the whole remote screen, including photos and video. Higher quality uses more CPU and bandwidth.")
                }

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

struct StreamQualityControls: View {
    var appModel: AppModel

    var body: some View {
        Picker("Preset", selection: Binding(
            get: { appModel.streamPreset },
            set: { appModel.applyStreamPreset($0) }
        )) {
            ForEach(StreamQualityPreset.allCases) { preset in
                Text(preset.title).tag(preset)
            }
        }

        Text(appModel.streamPreset.subtitle)
            .font(.footnote)
            .foregroundStyle(.secondary)

        Stepper(value: jpegBinding, in: 40...95, step: 5) {
            LabeledContent("Picture quality", value: "\(appModel.streamQuality.jpegQuality)")
        }
        Picker("Resolution", selection: widthBinding) {
            ForEach(StreamQualitySettings.widthChoices, id: \.self) { width in
                Text("\(width)px").tag(width)
            }
        }
        Picker("Frame rate", selection: fpsBinding) {
            ForEach(StreamQualitySettings.fpsChoices, id: \.self) { fps in
                Text("\(fps) fps").tag(fps)
            }
        }
    }

    private var jpegBinding: Binding<Int> {
        fieldBinding(\.jpegQuality)
    }

    private var widthBinding: Binding<Int> {
        fieldBinding(\.maxWidth)
    }

    private var fpsBinding: Binding<Int> {
        fieldBinding(\.framesPerSecond)
    }

    private func fieldBinding(_ keyPath: WritableKeyPath<StreamQualitySettings, Int>) -> Binding<Int> {
        Binding(
            get: { appModel.streamQuality[keyPath: keyPath] },
            set: { value in
                var next = appModel.streamQuality
                next[keyPath: keyPath] = value
                appModel.updateStreamQuality(next)
            }
        )
    }
}

#Preview {
    SettingsView()
        .environment(AppModel())
}
