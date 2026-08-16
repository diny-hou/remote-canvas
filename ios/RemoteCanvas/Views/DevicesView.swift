import SwiftUI

struct DevicesView: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        NavigationStack {
            Group {
                if appModel.devices.isEmpty {
                    ContentUnavailableView(
                        "No PCs",
                        systemImage: "display",
                        description: Text("Scan the QR code on the Windows host.")
                    )
                } else {
                    List {
                        ForEach(appModel.devices) { device in
                            DeviceRow(device: device)
                        }
                        .onDelete { indexSet in
                            indexSet.map { appModel.devices[$0] }.forEach(appModel.forget)
                        }
                    }
                }
            }
            .navigationTitle("PCs")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        appModel.presentedSheet = .settings
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("Settings")
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        appModel.presentedSheet = .pairDevice
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Add PC")
                    .accessibilityIdentifier("add-computer")
                }
            }
        }
    }
}

private struct DeviceRow: View {
    @Environment(AppModel.self) private var appModel
    let device: PairedDevice
    @State private var connectionError: String?

    var body: some View {
        Button {
            Task {
                do {
                    try await appModel.connect(to: device)
                } catch {
                    connectionError = error.localizedDescription
                }
            }
        } label: {
            HStack {
                Text(device.name)
                    .foregroundStyle(.primary)
                Spacer()
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
            }
        }
        .disabled(device.availability == .offline)
        .accessibilityIdentifier("connect-\(device.id.uuidString)")
        .alert("Could not connect", isPresented: Binding(
            get: { connectionError != nil },
            set: { if !$0 { connectionError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(connectionError ?? "Authentication failed.")
        }
    }

    private var statusColor: Color {
        switch device.availability {
        case .online: .green
        case .offline: .secondary
        case .connecting: .orange
        }
    }
}

#Preview("iPhone") {
    DevicesView()
        .environment(AppModel())
}
