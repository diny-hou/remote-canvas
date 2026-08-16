import SwiftUI
import QuickLook
import UniformTypeIdentifiers

struct RemoteSessionView<Transport: RemoteSessionTransport>: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss
    let device: PairedDevice
    let transport: Transport

    @State private var pointer = CGPoint(x: 0.5, y: 0.5)
    @State private var keyboardText = ""
    @State private var isKeyboardVisible = false
    @State private var isFileBrowserVisible = false
    @FocusState private var keyboardFocused: Bool

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.black.ignoresSafeArea()

            RemoteWorkspaceView(frameData: transport.latestFrame, pointer: pointer) { event in
                pointer = event.normalizedLocation
                Task { try? await transport.send(pointerEvent: event) }
            }
            .ignoresSafeArea()

            VStack(spacing: 10) {
                if isKeyboardVisible {
                    TextField("Type", text: $keyboardText)
                        .focused($keyboardFocused)
                        .textFieldStyle(.roundedBorder)
                        .padding(.horizontal, 12)
                }

                HStack(spacing: 18) {
                    Button {
                        Task { await transport.disconnect() }
                        appModel.disconnect()
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel("Disconnect")

                    Spacer()

                    Button {
                        isKeyboardVisible.toggle()
                    } label: {
                        Image(systemName: "keyboard")
                    }
                    .accessibilityLabel("Keyboard")

                    Button {
                        isFileBrowserVisible = true
                    } label: {
                        Image(systemName: "folder")
                    }
                    .accessibilityLabel("Files")

                    Button {
                        let event = PointerEvent(normalizedLocation: pointer, action: .secondaryClick)
                        Task { try? await transport.send(pointerEvent: event) }
                    } label: {
                        Image(systemName: "cursorarrow.click.2")
                    }
                    .accessibilityLabel("Right click")

                    Menu {
                        Button("Up", systemImage: "arrow.up") { sendScroll(4) }
                        Button("Down", systemImage: "arrow.down") { sendScroll(-4) }
                    } label: {
                        Image(systemName: "scroll")
                    }
                    .accessibilityLabel("Scroll")
                }
                .font(.body.weight(.medium))
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.black.opacity(0.55), in: Capsule())
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
            }
        }
        .preferredColorScheme(.dark)
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
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
        .sheet(isPresented: $isFileBrowserVisible) {
            RemoteFileBrowserView(transport: transport)
        }
    }

    private func sendScroll(_ amount: CGFloat) {
        let event = PointerEvent(normalizedLocation: pointer, action: .scroll(amount))
        Task { try? await transport.send(pointerEvent: event) }
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
                    ProgressView()
                } else if entries.isEmpty {
                    ContentUnavailableView("Empty", systemImage: "folder")
                } else {
                    List(entries) { entry in
                        Button {
                            open(entry)
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: entry.isDirectory ? "folder.fill" : icon(for: entry.name))
                                    .foregroundStyle(entry.isDirectory ? .secondary : .primary)
                                    .frame(width: 28)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(entry.name)
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)
                                    if !entry.isDirectory {
                                        Text(ByteCountFormatter.string(fromByteCount: Int64(entry.size), countStyle: .file))
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                    .refreshable { await load(path: currentPath) }
                }
            }
            .navigationTitle(currentPath.isEmpty ? "Files" : URL(fileURLWithPath: currentPath).lastPathComponent)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if history.isEmpty {
                        Button("Close") { dismiss() }
                    } else {
                        Button {
                            let previous = history.removeLast()
                            Task { await load(path: previous) }
                        } label: {
                            Image(systemName: "chevron.left")
                        }
                        .accessibilityLabel("Back")
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        isImporterPresented = true
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .accessibilityLabel("Upload")
                    .disabled(currentPath.isEmpty)
                }
            }
            .task { await load(path: "") }
            .alert("File error", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "Unknown error")
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
