import SwiftUI

struct PairDeviceView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss
    @State private var computerName = "Windows PC"
    @State private var pairingCode = ""
    @State private var errorMessage: String?
    @FocusState private var focusedField: Field?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    scannerPlaceholder
                } footer: {
                    Text("Windows版RemoteCanvasの「端末を追加」に表示されるQRコードを読み取ります。")
                }

                Section("手動入力") {
                    TextField("PC名", text: $computerName)
                        .focused($focusedField, equals: .name)
                    TextField("ペアリングコード", text: $pairingCode)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .font(.body.monospaced())
                        .focused($focusedField, equals: .code)
                }

                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    }
                }

                Section {
                    Button("デモコードを入力") {
                        pairingCode = "CANVAS-4821"
                        focusedField = .code
                    }
                } footer: {
                    Text("現在はUIプロトタイプです。カメラと暗号鍵交換は次の実装段階で接続します。")
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
                        .disabled(pairingCode.isEmpty)
                        .accessibilityIdentifier("confirm-pairing")
                }
            }
        }
    }

    private var scannerPlaceholder: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 22)
                .fill(Color.black.gradient)
                .aspectRatio(1.45, contentMode: .fit)

            VStack(spacing: 14) {
                Image(systemName: "qrcode.viewfinder")
                    .font(.system(size: 72, weight: .thin))
                Text("QRコードを枠内に合わせる")
                    .font(.subheadline.bold())
            }
            .foregroundStyle(.white)
        }
        .listRowInsets(EdgeInsets())
        .listRowBackground(Color.clear)
        .accessibilityLabel("ペアリングQRコードスキャナー")
    }

    private func register() {
        do {
            try appModel.registerDemoDevice(name: computerName, code: pairingCode)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private extension PairDeviceView {
    enum Field {
        case name
        case code
    }
}

#Preview {
    PairDeviceView()
        .environment(AppModel(devices: []))
}
