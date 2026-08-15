import SwiftUI

struct DevicesView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    var body: some View {
        NavigationStack {
            Group {
                if horizontalSizeClass == .regular {
                    regularLayout
                } else {
                    compactLayout
                }
            }
            .navigationTitle("マイPC")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        appModel.presentedSheet = .pairDevice
                    } label: {
                        Label("PCを追加", systemImage: "plus")
                    }
                    .accessibilityIdentifier("add-computer")
                }
            }
        }
    }

    private var compactLayout: some View {
        ScrollView {
            LazyVStack(spacing: 16) {
                securityBanner
                deviceCards
            }
            .padding()
        }
        .background(Color(.systemGroupedBackground))
    }

    private var regularLayout: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 18) {
                Image(systemName: "rectangle.connected.to.line.below")
                    .font(.system(size: 44, weight: .medium))
                    .foregroundStyle(.cyan)
                Text("Windowsを、\n手の中のワークスペースに。")
                    .font(.largeTitle.bold())
                Text("Tailscaleの端末認証とRemoteCanvas接続キーの両方で、Windowsへの接続を制限します。")
                    .foregroundStyle(.secondary)
                securityBanner
                Spacer()
            }
            .padding(32)
            .frame(maxWidth: 390)
            .background(.thinMaterial)

            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 20)], spacing: 20) {
                    deviceCards
                }
                .padding(28)
            }
            .background(Color(.systemGroupedBackground))
        }
    }

    @ViewBuilder
    private var deviceCards: some View {
        if appModel.devices.isEmpty {
            ContentUnavailableView(
                "登録済みPCがありません",
                systemImage: "display.badge.plus",
                description: Text("Windowsホストに表示されるQRコードから追加してください。")
            )
            .frame(maxWidth: .infinity, minHeight: 280)
        } else {
            ForEach(appModel.devices) { device in
                DeviceCard(device: device)
            }
        }
    }

    private var securityBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.shield.fill")
                .font(.title2)
                .foregroundStyle(.green)
            VStack(alignment: .leading, spacing: 2) {
                Text("端末認証が有効")
                    .font(.subheadline.bold())
                Text("Face ID・Tailscale・192-bit接続キー")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(14)
        .background(.green.opacity(0.10), in: RoundedRectangle(cornerRadius: 16))
    }
}

private struct DeviceCard: View {
    @Environment(AppModel.self) private var appModel
    let device: PairedDevice
    @State private var connectionError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14)
                        .fill(.cyan.opacity(0.14))
                    Image(systemName: "pc")
                        .font(.title2)
                        .foregroundStyle(.cyan)
                }
                .frame(width: 52, height: 52)

                VStack(alignment: .leading, spacing: 4) {
                    Text(device.name)
                        .font(.headline)
                    Label(statusText, systemImage: "circle.fill")
                        .font(.caption)
                        .foregroundStyle(statusColor)
                }
                Spacer()

                Menu {
                    Button("登録解除", role: .destructive) {
                        appModel.forget(device)
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.title3)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("端末鍵")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(device.fingerprint)
                    .font(.caption.monospaced())
            }

            Button {
                Task {
                    do {
                        try await appModel.connect(to: device)
                    } catch {
                        connectionError = error.localizedDescription
                    }
                }
            } label: {
                Label("安全に接続", systemImage: "arrow.right.circle.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(.cyan)
            .disabled(device.availability == .offline)
            .accessibilityIdentifier("connect-\(device.id.uuidString)")
        }
        .padding(18)
        .background(.background, in: RoundedRectangle(cornerRadius: 22))
        .overlay {
            RoundedRectangle(cornerRadius: 22)
                .stroke(.primary.opacity(0.06))
        }
        .alert("接続を開始できません", isPresented: Binding(
            get: { connectionError != nil },
            set: { if !$0 { connectionError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(connectionError ?? "本人確認に失敗しました。")
        }
    }

    private var statusText: String {
        switch device.availability {
        case .online: "オンライン"
        case .offline: "オフライン"
        case .connecting: "接続中"
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
