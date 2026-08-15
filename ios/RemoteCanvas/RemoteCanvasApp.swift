import SwiftUI

@main
struct RemoteCanvasApp: App {
    @State private var appModel = AppModel()

    var body: some Scene {
        WindowGroup {
            AppRootView()
                .environment(appModel)
        }
    }
}
