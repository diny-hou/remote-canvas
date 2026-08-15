import SwiftUI

struct SecuritySettingsView: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        @Bindable var appModel = appModel

        NavigationStack {
            Form {
                Section {
                    Toggle(isOn: $appModel.requireOwnerAuthentication) {
                        Label("Face IDを要求", systemImage: "faceid")
                    }
                } header: {
                    Text("接続承認")
                } footer: {
                    Text("接続開始前にFace ID、Touch ID、または端末パスコードで本人確認します。")
                }

                Section {
                    Label("Tailscale / LANで直接接続", systemImage: "point.3.connected.trianglepath.dotted")
                    Label("RemoteCanvas独自サーバー不使用", systemImage: "server.rack")
                } header: {
                    Text("ネットワーク")
                } footer: {
                    Text("外出先ではTailscaleのWireGuard暗号化を使います。現在の版に独自リレー機能はありません。")
                }

                Section("信頼済み端末") {
                    LabeledContent("登録PC", value: "\(appModel.devices.count)台")
                    LabeledContent("プロトコル", value: "remote-canvas/1")
                    LabeledContent("接続キー", value: "Keychainに保存")
                }
            }
            .navigationTitle("セキュリティ")
        }
    }
}

#Preview {
    SecuritySettingsView()
        .environment(AppModel())
}
