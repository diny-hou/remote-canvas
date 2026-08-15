import SwiftUI

struct PairDeviceView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss
    @State private var computerName = "Windows PC"
    @State private var endpoint = "http://"
    @State private var accessToken = ""
    @State private var errorMessage: String?
    @FocusState private var focusedField: Field?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label("Windows版に表示された接続先と接続キーを入力します。", systemImage: "pc")
                } footer: {
                    Text("接続キーはこのiPhone/iPadのKeychainに保存されます。")
                }

                Section("手動入力") {
                    TextField("PC名", text: $computerName)
                        .focused($focusedField, equals: .name)
                    TextField("接続先（例: http://100.x.x.x:47831）", text: $endpoint)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()
                        .focused($focusedField, equals: .endpoint)
                    SecureField("Windowsに表示された接続キー", text: $accessToken)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.body.monospaced())
                        .focused($focusedField, equals: .token)
                }

                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    }
                }

                Section {
                    Button("入力例を表示") {
                        endpoint = "http://100.64.0.2:47831"
                        accessToken = "Windows側に表示される48文字の接続キー"
                        focusedField = .endpoint
                    }
                } footer: {
                    Text("外出先から接続する場合は、両方の端末を同じTailscaleネットワークへ登録し、Windows側の100.xアドレスを入力します。")
                }
            }
            .navigationTitle("PCをペアリング")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("登録") { register() }
                        .fontWeight(.semibold)
                        .disabled(endpoint.isEmpty || accessToken.isEmpty)
                        .accessibilityIdentifier("confirm-pairing")
                }
            }
        }
    }

    private func register() {
        do {
            try appModel.registerDevice(name: computerName, endpoint: endpoint, accessToken: accessToken)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private extension PairDeviceView {
    enum Field {
        case name
        case endpoint
        case token
    }
}

#Preview {
    PairDeviceView()
        .environment(AppModel(devices: []))
}
