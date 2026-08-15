import SwiftUI

struct RemoteSessionView<Transport: RemoteSessionTransport>: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    let device: PairedDevice
    let transport: Transport

    @State private var displayMode: RemoteDisplayMode = .mobile
    @State private var pointer = CGPoint(x: 0.68, y: 0.42)
    @State private var keyboardText = ""
    @State private var isKeyboardVisible = false
    @FocusState private var keyboardFocused: Bool

    var body: some View {
        ZStack {
            Color(red: 0.035, green: 0.055, blue: 0.08)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                sessionHeader
                workspace
                sessionControls
            }
        }
        .preferredColorScheme(.dark)
        .onChange(of: keyboardText) { oldValue, newValue in
            guard newValue != oldValue, !newValue.isEmpty else { return }
            Task {
                try? await transport.send(text: newValue)
                keyboardText = ""
            }
        }
        .onChange(of: isKeyboardVisible) { _, isVisible in
            keyboardFocused = isVisible
        }
        .overlay(alignment: .bottom) {
            if isKeyboardVisible {
                TextField("Windowsへ入力", text: $keyboardText)
                    .focused($keyboardFocused)
                    .textFieldStyle(.roundedBorder)
                    .padding(.horizontal)
                    .padding(.bottom, 66)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }

    private var sessionHeader: some View {
        HStack(spacing: 12) {
            Button {
                Task { await transport.disconnect() }
                appModel.disconnect()
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .frame(width: 36, height: 36)
                    .background(.white.opacity(0.10), in: Circle())
            }
            .accessibilityLabel("接続を終了")

            VStack(alignment: .leading, spacing: 2) {
                Text(device.name)
                    .font(.subheadline.bold())
                Label("P2P・暗号化済み", systemImage: "lock.fill")
                    .font(.caption2)
                    .foregroundStyle(.green)
            }

            Spacer()

            Text("24 ms")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var workspace: some View {
        if horizontalSizeClass == .regular {
            HStack(spacing: 12) {
                CompactAppRail()
                    .frame(width: 82)
                remoteSurface
            }
            .padding(.horizontal, 14)
        } else {
            remoteSurface
                .padding(.horizontal, 10)
        }
    }

    private var remoteSurface: some View {
        RemoteWorkspaceView(mode: displayMode, pointer: pointer) { event in
            pointer = event.normalizedLocation
            Task { try? await transport.send(pointerEvent: event) }
        }
        .clipShape(RoundedRectangle(cornerRadius: 22))
        .overlay {
            RoundedRectangle(cornerRadius: 22)
                .stroke(.white.opacity(0.14))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var sessionControls: some View {
        HStack(spacing: 10) {
            Menu {
                Picker("表示", selection: $displayMode) {
                    ForEach(RemoteDisplayMode.allCases) { mode in
                        Label(mode.title, systemImage: mode.systemImage)
                            .tag(mode)
                    }
                }
            } label: {
                ControlIcon(systemName: displayMode.systemImage, title: "表示")
            }

            Button {
                isKeyboardVisible.toggle()
            } label: {
                ControlIcon(systemName: "keyboard", title: "入力")
            }

            Button {
                let event = PointerEvent(normalizedLocation: pointer, action: .secondaryClick)
                Task { try? await transport.send(pointerEvent: event) }
            } label: {
                ControlIcon(systemName: "cursorarrow.click.2", title: "右クリック")
            }

            Button {} label: {
                ControlIcon(systemName: "command", title: "ショートカット")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
    }
}

private struct ControlIcon: View {
    let systemName: String
    let title: String

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: systemName)
                .font(.body.bold())
            Text(title)
                .font(.caption2)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, minHeight: 40)
        .contentShape(Rectangle())
    }
}

private struct CompactAppRail: View {
    var body: some View {
        VStack(spacing: 18) {
            ForEach(["folder.fill", "safari.fill", "envelope.fill", "terminal.fill"], id: \.self) { icon in
                Image(systemName: icon)
                    .font(.title2)
                    .frame(width: 50, height: 50)
                    .background(.white.opacity(icon == "folder.fill" ? 0.16 : 0.06), in: RoundedRectangle(cornerRadius: 14))
            }
            Spacer()
        }
        .padding(.vertical, 12)
    }
}

#Preview {
    RemoteSessionView(device: .demo, transport: PreviewRemoteSessionTransport())
        .environment(AppModel())
}
