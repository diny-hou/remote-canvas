import LocalAuthentication
import SwiftUI
import QuickLook
import UniformTypeIdentifiers

struct RemoteSessionView<Transport: RemoteSessionTransport>: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss
    let device: PairedDevice
    let transport: Transport

    @State private var keyboardText = ""
    @State private var isKeyboardVisible = false
    @State private var isFileBrowserVisible = false
    @State private var isQualityVisible = false
    @State private var privacyOverride: Bool?
    @State private var privacyHole: CGPoint?
    @State private var isContentConcealed = false
    @State private var isAuthenticating = false
    @State private var isScreenCaptured = UIScreen.main.isCaptured
    @FocusState private var keyboardFocused: Bool

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.black.ignoresSafeArea()

            RemoteWorkspaceView(
                frameData: shouldHidePixels ? nil : transport.latestFrame,
                protectFromCapture: appModel.blockScreenCapture,
                onLocalTouch: { privacyHole = $0 }
            ) { event in
                Task { try? await transport.send(pointerEvent: event) }
            }
            .ignoresSafeArea()

            if isPrivacyShieldOn && !shouldHidePixels {
                PrivacyShieldOverlay(hole: privacyHole)
                    .ignoresSafeArea()
            }

            if shouldHidePixels {
                ConcealmentCover(
                    isRecording: isScreenCaptured && appModel.blockScreenCapture,
                    onReveal: { Task { await revealIfAllowed() } },
                    onDisconnect: {
                        Task { await transport.disconnect() }
                        appModel.disconnect()
                        dismiss()
                    }
                )
            }

            if transport.latestFrame == nil && !shouldHidePixels {
                connectionStatus
            }

            if !shouldHidePixels {
                sessionChrome
            }
        }
        .preferredColorScheme(.dark)
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .task {
            await transport.connect()
            try? await transport.send(streamQuality: appModel.streamQuality)
        }
        .onChange(of: appModel.streamQuality) { _, quality in
            Task { try? await transport.send(streamQuality: quality) }
        }
        .onChange(of: transport.discoveredEndpoints) { _, endpoints in
            appModel.mergeEndpoints(endpoints, into: device.id)
        }
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
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in
            if appModel.hideScreenWhenInactive && !isAuthenticating {
                isContentConcealed = true
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            if isContentConcealed {
                Task { await revealIfAllowed() }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIScreen.capturedDidChangeNotification)) { _ in
            isScreenCaptured = UIScreen.main.isCaptured
        }
        .sheet(isPresented: $isQualityVisible) {
            NavigationStack {
                Form {
                    StreamQualityControls(appModel: appModel)
                }
                .navigationTitle("Picture and speed")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { isQualityVisible = false }
                    }
                }
            }
            .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $isFileBrowserVisible) {
            RemoteFileBrowserView(
                transport: transport,
                hideWhenInactive: appModel.hideScreenWhenInactive,
                blockScreenCapture: appModel.blockScreenCapture
            )
        }
    }

    private var connectionStatus: some View {
        VStack(spacing: 10) {
            ProgressView()
            Text(transport.statusText)
                .font(.headline)
            if let lastError = transport.lastError {
                Text(lastError)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
    }

    private var sessionChrome: some View {
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
                    isQualityVisible = true
                } label: {
                    Image(systemName: "slider.horizontal.3")
                }
                .accessibilityLabel("Picture and speed")

                Button {
                    isFileBrowserVisible = true
                } label: {
                    Image(systemName: "folder")
                }
                .accessibilityLabel("Files")

                Button {
                    privacyOverride = !isPrivacyShieldOn
                } label: {
                    Image(systemName: isPrivacyShieldOn ? "eye.slash" : "eye")
                }
                .accessibilityLabel(isPrivacyShieldOn ? "Disable privacy shield" : "Enable privacy shield")
            }
            .font(.body.weight(.medium))
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.black.opacity(0.55), in: Capsule())
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
        }
    }

    private var isPrivacyShieldOn: Bool {
        if let privacyOverride { return privacyOverride }
        return appModel.privacyShieldAlways || (appModel.privacyShieldWhenAway && !transport.isUsingLAN)
    }

    private var shouldHidePixels: Bool {
        isContentConcealed || (appModel.blockScreenCapture && isScreenCaptured)
    }

    private func revealIfAllowed() async {
        if appModel.blockScreenCapture && UIScreen.main.isCaptured {
            return
        }
        guard appModel.requireOwnerAuthentication else {
            isContentConcealed = false
            return
        }
        isAuthenticating = true
        defer { isAuthenticating = false }
        let context = LAContext()
        context.localizedCancelTitle = "Disconnect"
        do {
            try await context.evaluatePolicy(
                .deviceOwnerAuthentication,
                localizedReason: "Reveal this PC"
            )
            isContentConcealed = false
        } catch {
            await transport.disconnect()
            appModel.disconnect()
            dismiss()
        }
    }
}

private struct PrivacyShieldOverlay: View {
    let hole: CGPoint?

    var body: some View {
        GeometryReader { geometry in
            let center = hole ?? CGPoint(x: geometry.size.width / 2, y: geometry.size.height * 0.42)
            let radius: CGFloat = hole == nil ? 96 : 118
            Canvas { context, size in
                var path = Path(CGRect(origin: .zero, size: size))
                path.addEllipse(in: CGRect(
                    x: center.x - radius,
                    y: center.y - radius,
                    width: radius * 2,
                    height: radius * 2
                ))
                context.fill(path, with: .color(.black.opacity(0.96)), style: FillStyle(eoFill: true))
            }
        }
        .allowsHitTesting(false)
    }
}

private struct ConcealmentCover: View {
    let isRecording: Bool
    let onReveal: () -> Void
    let onDisconnect: () -> Void

    var body: some View {
        Color.black
            .ignoresSafeArea()
            .overlay {
                VStack(spacing: 16) {
                    Image(systemName: isRecording ? "record.circle" : "eye.slash")
                        .font(.largeTitle)
                    Text(isRecording ? "Recording blocked" : "Hidden")
                        .font(.headline)
                    Text(isRecording ? "Stop screen recording to continue." : "Tap to reveal")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Button("Disconnect", action: onDisconnect)
                        .buttonStyle(.bordered)
                        .padding(.top, 8)
                }
                .foregroundStyle(.white)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                if !isRecording { onReveal() }
            }
    }
}

#Preview {
    RemoteSessionView(device: .demo, transport: PreviewRemoteSessionTransport())
        .environment(AppModel())
}

private struct RemoteFileBrowserView<Transport: RemoteSessionTransport>: View {
    @Environment(\.dismiss) private var dismiss
    let transport: Transport
    var hideWhenInactive = false
    var blockScreenCapture = false

    @State private var entries: [RemoteFileEntry] = []
    @State private var currentPath = ""
    @State private var history: [String] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var previewURL: URL?
    @State private var isImporterPresented = false
    @State private var isContentConcealed = false
    @State private var isScreenCaptured = UIScreen.main.isCaptured

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
                                Image(systemName: entry.isDirectory ? folderIcon(for: entry) : icon(for: entry.name))
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
            .overlay {
                if isContentConcealed || (blockScreenCapture && isScreenCaptured) {
                    Color.black.ignoresSafeArea()
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in
                if hideWhenInactive { isContentConcealed = true }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
                isContentConcealed = false
            }
            .onReceive(NotificationCenter.default.publisher(for: UIScreen.capturedDidChangeNotification)) { _ in
                isScreenCaptured = UIScreen.main.isCaptured
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

    private func folderIcon(for entry: RemoteFileEntry) -> String {
        if entry.name == "Home" { return "house.fill" }
        if entry.name.contains(":") { return "internaldrive.fill" }
        return "folder.fill"
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
