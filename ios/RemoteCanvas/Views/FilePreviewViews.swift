import AVKit
import MobileVLCKit
import QuickLook
import SwiftUI

struct FilePreviewContainer: View {
    let item: FilePreviewItem
    var onClose: () -> Void

    var body: some View {
        switch item {
        case .comic(let title, let pages, let start):
            ComicReaderView(title: title, pages: pages, startIndex: start, onClose: onClose)
        case .media(let url):
            RemoteMediaPlayerView(url: url, onClose: onClose)
        case .document(let url):
            DocumentPreviewView(url: url, onClose: onClose)
        case .archive(let title, let files):
            ArchiveBrowserView(title: title, files: files, onClose: onClose)
        }
    }
}

struct ComicReaderView: View {
    let title: String
    let pages: [URL]
    let startIndex: Int
    var onClose: () -> Void

    @State private var page: Int
    @State private var rightToLeft = true

    init(title: String, pages: [URL], startIndex: Int, onClose: @escaping () -> Void) {
        self.title = title
        self.pages = pages
        self.startIndex = startIndex
        self.onClose = onClose
        _page = State(initialValue: min(max(startIndex, 0), max(pages.count - 1, 0)))
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                if pages.isEmpty {
                    ContentUnavailableView("No images", systemImage: "photo")
                        .foregroundStyle(.white)
                } else {
                    TabView(selection: $page) {
                        ForEach(pages.indices, id: \.self) { index in
                            ZoomablePage(url: pages[index])
                                .tag(index)
                        }
                    }
                    .tabViewStyle(.page(indexDisplayMode: .never))
                    .environment(\.layoutDirection, rightToLeft ? .rightToLeft : .leftToRight)
                    .ignoresSafeArea()
                    .overlay(alignment: .bottom) {
                        Text("\(page + 1) / \(pages.count)")
                            .font(.footnote.monospacedDigit())
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(.black.opacity(0.55), in: Capsule())
                            .padding(.bottom, 16)
                    }
                    .overlay {
                        HStack(spacing: 0) {
                            Color.clear
                                .frame(width: 80)
                                .contentShape(Rectangle())
                                .onTapGesture { turn(forward: rightToLeft) }
                            Spacer()
                            Color.clear
                                .frame(width: 80)
                                .contentShape(Rectangle())
                                .onTapGesture { turn(forward: !rightToLeft) }
                        }
                        .environment(\.layoutDirection, .leftToRight)
                    }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", action: onClose)
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        rightToLeft.toggle()
                    } label: {
                        Image(systemName: rightToLeft ? "book.closed" : "book")
                    }
                    .accessibilityLabel(rightToLeft ? "Right-to-left" : "Left-to-right")
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private func turn(forward: Bool) {
        let next = page + (forward ? 1 : -1)
        guard pages.indices.contains(next) else { return }
        page = next
    }
}

private struct ZoomablePage: View {
    let url: URL
    @State private var scale: CGFloat = 1
    @State private var offset = CGSize.zero

    var body: some View {
        GeometryReader { geometry in
            if let image = UIImage(contentsOfFile: url.path) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .scaleEffect(scale)
                    .offset(offset)
                    .gesture(
                        MagnifyGesture()
                            .onChanged { value in
                                scale = min(max(value.magnification, 1), 6)
                            }
                            .onEnded { _ in
                                if scale < 1.05 {
                                    scale = 1
                                    offset = .zero
                                }
                            }
                    )
                    .simultaneousGesture(
                        DragGesture()
                            .onChanged { value in
                                guard scale > 1.05 else { return }
                                offset = value.translation
                            }
                    )
                    .onTapGesture(count: 2) {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            if scale > 1.05 {
                                scale = 1
                                offset = .zero
                            } else {
                                scale = 2.4
                            }
                        }
                    }
            } else {
                ContentUnavailableView("Unreadable page", systemImage: "photo")
                    .frame(width: geometry.size.width, height: geometry.size.height)
            }
        }
    }
}

struct ArchiveBrowserView: View {
    let title: String
    let files: [URL]
    var onClose: () -> Void

    @State private var nested: FilePreviewItem?

    var body: some View {
        NavigationStack {
            List(files, id: \.path) { url in
                Button {
                    nested = previewItem(for: url)
                } label: {
                    Label(url.lastPathComponent, systemImage: FileKind(url: url).symbolName)
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", action: onClose)
                }
            }
            .fullScreenCover(item: $nested) { item in
                FilePreviewContainer(item: item) {
                    nested = nil
                }
            }
        }
    }

    private func previewItem(for url: URL) -> FilePreviewItem {
        switch FileKind(url: url) {
        case .image:
            .comic(title: url.lastPathComponent, pages: [url], startIndex: 0)
        case .video, .audio:
            .media(url)
        default:
            .document(url)
        }
    }
}

struct RemoteMediaPlayerView: View {
    let url: URL
    var onClose: () -> Void

    @StateObject private var playback = VLCPlaybackController()

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                VLCVideoSurface(controller: playback)
                    .ignoresSafeArea()
                if !playback.hasVideo {
                    VStack(spacing: 16) {
                        Image(systemName: "waveform")
                            .font(.system(size: 56))
                        Text(url.lastPathComponent)
                            .font(.headline)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                    }
                    .foregroundStyle(.white)
                    .allowsHitTesting(false)
                }
            }
            .safeAreaInset(edge: .bottom) {
                mediaControls
            }
            .navigationTitle(url.lastPathComponent)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", action: onClose)
                }
                ToolbarItem(placement: .primaryAction) {
                    ShareLink(item: url) {
                        Image(systemName: "square.and.arrow.up")
                    }
                }
            }
        }
        .preferredColorScheme(.dark)
        .onAppear { playback.open(url) }
        .onDisappear { playback.stop() }
    }

    private var mediaControls: some View {
        VStack(spacing: 10) {
            Slider(
                value: Binding(
                    get: { Double(playback.isSeeking ? playback.seekPosition : playback.position) },
                    set: { playback.seekPosition = Float($0) }
                ),
                in: 0...1,
                onEditingChanged: { editing in
                    playback.isSeeking = editing
                    if !editing {
                        playback.seek(to: playback.seekPosition)
                    }
                }
            )
            HStack {
                Text(playback.elapsedText)
                    .font(.caption.monospacedDigit())
                Spacer()
                Button {
                    playback.togglePlay()
                } label: {
                    Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title2)
                }
                Spacer()
                Text(playback.remainingText)
                    .font(.caption.monospacedDigit())
            }
            if let status = playback.statusMessage {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial)
    }
}

@MainActor
final class VLCPlaybackController: NSObject, ObservableObject, VLCMediaPlayerDelegate {
    let player = VLCMediaPlayer()
    @Published var isPlaying = false
    @Published var hasVideo = false
    @Published var position: Float = 0
    @Published var seekPosition: Float = 0
    @Published var isSeeking = false
    @Published var elapsedText = "00:00"
    @Published var remainingText = "--:--"
    @Published var statusMessage: String?

    override init() {
        super.init()
        player.delegate = self
    }

    func attach(drawable: UIView) {
        player.drawable = drawable
    }

    func open(_ url: URL) {
        statusMessage = nil
        player.media = VLCMedia(url: url)
        player.play()
    }

    func togglePlay() {
        if player.isPlaying {
            player.pause()
        } else {
            player.play()
        }
        isPlaying = player.isPlaying
    }

    func seek(to value: Float) {
        player.position = min(max(value, 0), 1)
        position = player.position
    }

    func stop() {
        player.stop()
        player.drawable = nil
    }

    nonisolated func mediaPlayerStateChanged(_ aNotification: Notification) {
        Task { @MainActor in
            self.syncState()
        }
    }

    nonisolated func mediaPlayerTimeChanged(_ aNotification: Notification) {
        Task { @MainActor in
            self.syncTime()
        }
    }

    private func syncState() {
        isPlaying = player.isPlaying
        hasVideo = player.hasVideoOut || player.videoSize.width > 0
        switch player.state {
        case .error:
            statusMessage = "This file could not be played."
        case .ended:
            isPlaying = false
            position = 1
        default:
            if player.isPlaying { statusMessage = nil }
        }
    }

    private func syncTime() {
        if !isSeeking {
            position = player.position
            seekPosition = player.position
        }
        elapsedText = Self.format(player.time)
        remainingText = Self.format(player.remainingTime)
        hasVideo = player.hasVideoOut || player.videoSize.width > 0
    }

    private static func format(_ time: VLCTime?) -> String {
        guard let value = time?.value?.int64Value else { return "--:--" }
        let total = abs(value) / 1000
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }
}

private struct VLCVideoSurface: UIViewRepresentable {
    @ObservedObject var controller: VLCPlaybackController

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .black
        controller.attach(drawable: view)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        controller.attach(drawable: uiView)
    }
}

struct DocumentPreviewView: View {
    let url: URL
    var onClose: () -> Void

    var body: some View {
        NavigationStack {
            Group {
                if canQuickLook(url) {
                    QuickLookPreview(url: url)
                } else if fileLooksLikeText(url), let text = readTextFile(url) {
                    ScrollView {
                        Text(text)
                            .font(.body.monospaced())
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding()
                            .textSelection(.enabled)
                    }
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            Text("This file type has no built-in preview. Share it to open in another app.")
                                .foregroundStyle(.secondary)
                            Text(hexPreview(of: url))
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                        }
                        .padding()
                    }
                }
            }
            .navigationTitle(url.lastPathComponent)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", action: onClose)
                }
                ToolbarItem(placement: .primaryAction) {
                    ShareLink(item: url) {
                        Image(systemName: "square.and.arrow.up")
                    }
                }
            }
        }
    }
}

struct QuickLookPreview: UIViewControllerRepresentable {
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
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> any QLPreviewItem {
            url as NSURL
        }
    }
}
