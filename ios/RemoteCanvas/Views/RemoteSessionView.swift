import SwiftUI
import QuickLook
import UniformTypeIdentifiers

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
    @State private var isFileBrowserVisible = false
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
        .task { await transport.connect() }
        .onDisappear { Task { await transport.disconnect() } }
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
        .sheet(isPresented: $isFileBrowserVisible) {
            RemoteFileBrowserView(transport: transport)
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
                Label("\(transport.statusText)・\(transportSecurityText)", systemImage: isEncryptedTransport ? "lock.fill" : "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(isEncryptedTransport ? .green : .orange)
            }

            Spacer()

            Text(transport.latestFrame == nil ? "待機中" : "LIVE")
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
        RemoteWorkspaceView(mode: displayMode, frameData: transport.latestFrame, pointer: pointer) { event in
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
                isFileBrowserVisible = true
            } label: {
                ControlIcon(systemName: "folder.fill", title: "ファイル")
            }

            Button {
                let event = PointerEvent(normalizedLocation: pointer, action: .secondaryClick)
                Task { try? await transport.send(pointerEvent: event) }
            } label: {
                ControlIcon(systemName: "cursorarrow.click.2", title: "右クリック")
            }

            Menu {
                Button("上へスクロール", systemImage: "arrow.up") {
                    sendScroll(4)
                }
                Button("下へスクロール", systemImage: "arrow.down") {
                    sendScroll(-4)
                }
            } label: {
                ControlIcon(systemName: "scroll", title: "スクロール")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
    }

    private func sendScroll(_ amount: CGFloat) {
        let event = PointerEvent(normalizedLocation: pointer, action: .scroll(amount))
        Task { try? await transport.send(pointerEvent: event) }
    }

    private var isEncryptedTransport: Bool {
        guard let url = URL(string: device.endpoint) else { return false }
        if url.scheme?.lowercased() == "https" { return true }
        guard let host = url.host else { return false }
        let parts = host.split(separator: ".").compactMap { Int($0) }
        return parts.count == 4 && parts[0] == 100 && (64...127).contains(parts[1])
    }

    private var transportSecurityText: String {
        isEncryptedTransport ? "暗号化経路" : "信頼済みLAN専用"
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

private struct RemoteFileBrowserView<Transport: RemoteSessionTransport>: View {
    @Environment(\.dismiss) private var dismiss
    let transport: Transport

    @State private var entries: [RemoteFileEntry] = []
    @State private var currentPath = ""
    @State private var history: [String] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var previewURL: URL?
    @State private var isImporterPresented = false

    var body: some View {
        NavigationStack {
            Group {
                if isLoading && entries.isEmpty {
                    ProgressView("Windowsのファイルを取得中…")
                } else if entries.isEmpty {
                    ContentUnavailableView("項目がありません", systemImage: "folder")
                } else {
                    List(entries) { entry in
                        Button {
                            open(entry)
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: entry.isDirectory ? "folder.fill" : icon(for: entry.name))
                                    .foregroundStyle(entry.isDirectory ? .cyan : .secondary)
                                    .frame(width: 28)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(entry.name)
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)
                                    if !entry.isDirectory {
                                        Text(ByteCountFormatter.string(fromByteCount: Int64(entry.size), countStyle: .file))
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                Image(systemName: entry.isDirectory ? "chevron.right" : "arrow.down.circle")
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                    .refreshable { await load(path: currentPath) }
                }
            }
            .navigationTitle(currentPath.isEmpty ? "Windowsファイル" : URL(fileURLWithPath: currentPath).lastPathComponent)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if history.isEmpty {
                        Button("閉じる") { dismiss() }
                    } else {
                        Button {
                            let previous = history.removeLast()
                            Task { await load(path: previous) }
                        } label: {
                            Label("戻る", systemImage: "chevron.left")
                        }
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        isImporterPresented = true
                    } label: {
                        Label("アップロード", systemImage: "square.and.arrow.up")
                    }
                    .disabled(currentPath.isEmpty)
                }
            }
            .task { await load(path: "") }
            .alert("ファイル操作エラー", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "不明なエラー")
            }
            .fileImporter(isPresented: $isImporterPresented, allowedContentTypes: [.data]) { result in
                guard case .success(let url) = result else { return }
                Task {
                    do {
                        try await transport.upload(localURL: url, to: currentPath)
                        await load(path: currentPath)
                    } catch {
                        errorMessage = error.localizedDescription
                    }
                }
            }
            .sheet(isPresented: Binding(
                get: { previewURL != nil },
                set: { if !$0 { previewURL = nil } }
            )) {
                if let previewURL {
                    QuickLookPreview(url: previewURL)
                        .ignoresSafeArea()
                }
            }
        }
    }

    private func open(_ entry: RemoteFileEntry) {
        if entry.isDirectory {
            history.append(currentPath)
            Task { await load(path: entry.path) }
        } else {
            isLoading = true
            Task {
                do {
                    previewURL = try await transport.download(entry)
                } catch {
                    errorMessage = error.localizedDescription
                }
                isLoading = false
            }
        }
    }

    private func load(path: String) async {
        isLoading = true
        do {
            entries = try await transport.listFiles(path: path)
            currentPath = path
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    private func icon(for name: String) -> String {
        let ext = URL(fileURLWithPath: name).pathExtension.lowercased()
        if ["jpg", "jpeg", "png", "gif", "heic", "webp"].contains(ext) { return "photo" }
        if ["mp4", "mov", "mkv", "avi", "webm"].contains(ext) { return "play.rectangle" }
        if ["mp3", "m4a", "wav", "flac"].contains(ext) { return "waveform" }
        if ext == "pdf" { return "doc.richtext" }
        return "doc"
    }
}

private struct QuickLookPreview: UIViewControllerRepresentable {
    let url: URL

    func makeCoordinator() -> Coordinator { Coordinator(url: url) }

    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: QLPreviewController, context: Context) {}

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        let url: URL
        init(url: URL) { self.url = url }
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
            url as NSURL
        }
    }
}
