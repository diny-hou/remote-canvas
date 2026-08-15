import SwiftUI

struct AppRootView: View {
    @Environment(AppModel.self) private var appModel
    @State private var selectedTab: AppTab = .devices

    var body: some View {
        @Bindable var appModel = appModel

        TabView(selection: $selectedTab) {
            DevicesView()
                .tabItem { Label("PC", systemImage: "display") }
                .tag(AppTab.devices)

            SecuritySettingsView()
                .tabItem { Label("セキュリティ", systemImage: "lock.shield") }
                .tag(AppTab.security)
        }
        .tint(.cyan)
        .sheet(item: $appModel.presentedSheet) { destination in
            switch destination {
            case .pairDevice:
                PairDeviceView()
            }
        }
        .fullScreenCover(item: $appModel.activeDevice) { device in
            RemoteSessionView(device: device, transport: LiveRemoteSession(device: device))
        }
    }
}

private enum AppTab: Hashable {
    case devices
    case security
}

#Preview {
    AppRootView()
        .environment(AppModel())
}
