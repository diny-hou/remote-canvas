import SwiftUI

struct AppRootView: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        @Bindable var appModel = appModel

        DevicesView()
            .sheet(item: $appModel.presentedSheet) { destination in
                switch destination {
                case .pairDevice:
                    PairDeviceView()
                case .settings:
                    SettingsView()
                }
            }
            .fullScreenCover(item: $appModel.activeDevice) { device in
                RemoteSessionView(device: device, transport: LiveRemoteSession(device: device))
            }
    }
}

#Preview {
    AppRootView()
        .environment(AppModel())
}
