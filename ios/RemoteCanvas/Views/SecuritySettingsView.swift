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
                    Text("本番実装では、Secure Enclave内の端末鍵を使用する前に本人確認を要求します。")
                }

                Section {
                    Toggle(isOn: $appModel.preferDirectConnection) {
                        Label("P2P接続を優先", systemImage: "point.3.connected.trianglepath.dotted")
                    }
                    Toggle(isOn: $appModel.allowRelayFallback) {
                        Label("暗号化リレーを許可", systemImage: "arrow.triangle.branch")
                    }
                } header: {
                    Text("ネットワーク")
                } footer: {
                    Text("リレーは直接接続できない場合だけ使います。中継先はセッション内容を復号できません。")
                }

                Section("信頼済み端末") {
                    LabeledContent("登録PC", value: "\(appModel.devices.count)台")
                    LabeledContent("プロトコル", value: "remote-canvas/1")
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
