import AVFoundation
import AVKit
import MobileVLCKit
import QuickLook
import SwiftUI

struct FilePreviewContainer: View {
    let item: FilePreviewItem
    var loadRemoteFile: ((RemoteFileEntry) async throws -> URL)?
    var onClose: () -> Void

    var body: some View {
        switch item {
        case .comic(let title, let pages, let start):
            ComicReaderView(title: title, pages: pages, startIndex: start, onClose: onClose)
        case .media(let playlist, let start):
            RemoteMediaPlayerView(
                playlist: playlist,
                startIndex: start,
                loadRemoteFile: loadRemoteFile,
                onClose: onClose
            )
        case .document(let url):
            DocumentPreviewView(url: url, onClose: onClose)
        case .archive(let title, let files):
            ArchiveBrowserView(title: title, files: files, loadRemoteFile: loadRemoteFile, onClose: onClose)
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
    var loadRemoteFile: ((RemoteFileEntry) async throws -> URL)?
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
                FilePreviewContainer(item: item, loadRemoteFile: loadRemoteFile) {
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
            makeMediaPlaylist(startingAt: url, in: files)
        default:
            .document(url)
        }
    }
}

func makeMediaPlaylist(startingAt url: URL, in files: [URL]) -> FilePreviewItem {
    let siblings = files.filter { FileKind(url: $0).isPlayable }
    let list = siblings.isEmpty ? [url] : siblings
    let index = list.firstIndex(of: url) ?? 0
    return .media(
        playlist: list.map { MediaPlaylistItem(name: $0.lastPathComponent, remotePath: nil, localURL: $0) },
        startIndex: index
    )
}

struct RemoteMediaPlayerView: View {
    @State private var items: [MediaPlaylistItem]
    @State private var index: Int
    var loadRemoteFile: ((RemoteFileEntry) async throws -> URL)?
    var onClose: () -> Void

    @StateObject private var playback = VLCPlaybackController()
    @State private var controlsVisible = true
    @State private var isLoadingTrack = false
    @State private var skipHint: String?
    @State private var hideTask: Task<Void, Never>?
    @State private var loadError: String?
    @State private var dismissOffset: CGFloat = 0
    @State private var gesturesEnabled = false

    init(
        playlist: [MediaPlaylistItem],
        startIndex: Int,
        loadRemoteFile: ((RemoteFileEntry) async throws -> URL)?,
        onClose: @escaping () -> Void
    ) {
        _items = State(initialValue: playlist)
        _index = State(initialValue: min(max(startIndex, 0), max(playlist.count - 1, 0)))
        self.loadRemoteFile = loadRemoteFile
        self.onClose = onClose
    }

    var body: some View {
        GeometryReader { geometry in
            let landscape = geometry.size.width > geometry.size.height
            ZStack {
                Color.black.ignoresSafeArea()
                VLCVideoSurface(controller: playback)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)

                PlayerInteractionLayer(
                    isEnabled: gesturesEnabled,
                    onTap: handlePlayerTap,
                    onDismissChanged: { translation in
                        hideTask?.cancel()
                        dismissOffset = max(0, translation)
                    },
                    onDismissEnded: { translation, velocity in
                        if translation > 110 || velocity > 900 {
                            closePlayer()
                        } else {
                            withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
                                dismissOffset = 0
                            }
                        }
                    },
                    onHorizontalSkip: { seconds in
                        playback.skip(seconds: seconds)
                        showSkipHint(seconds)
                        revealControls()
                    }
                )
                .ignoresSafeArea()

                if !playback.hasVideo && !isLoadingTrack {
                    audioPlaceholder
                        .allowsHitTesting(false)
                }

                if isLoadingTrack {
                    ProgressView()
                        .tint(.white)
                        .scaleEffect(1.2)
                }

                if let skipHint {
                    Text(skipHint)
                        .font(.title2.weight(.semibold))
                        .padding(.horizontal, 18)
                        .padding(.vertical, 10)
                        .background(.black.opacity(0.55), in: Capsule())
                        .foregroundStyle(.white)
                        .allowsHitTesting(false)
                }

                if controlsVisible {
                    VStack(spacing: 0) {
                        topBar
                            .padding(.top, landscape ? 8 : 4)
                        Spacer()
                            .allowsHitTesting(false)
                        bottomBar
                            .padding(.bottom, landscape ? 8 : 4)
                    }
                    .transition(.opacity)
                }
            }
            .offset(y: dismissOffset)
            .scaleEffect(1 - min(dismissOffset / 1400, 0.12))
            .opacity(1 - min(dismissOffset / 900, 0.45))
        }
        .background(Color.black.opacity(1 - min(dismissOffset / 500, 0.55)).ignoresSafeArea())
        .statusBarHidden(!controlsVisible)
        .persistentSystemOverlays(controlsVisible ? .automatic : .hidden)
        .preferredColorScheme(.dark)
        .task { await openCurrent(autoplay: true) }
        .onChange(of: playback.didFinish) { _, finished in
            guard finished else { return }
            Task { await advance(by: 1, auto: true) }
        }
        .task {
            try? await Task.sleep(nanoseconds: 400_000_000)
            gesturesEnabled = true
        }
        .onDisappear {
            hideTask?.cancel()
            if !playback.isPictureInPictureActive {
                playback.stop()
            }
        }
    }

    private var current: MediaPlaylistItem? {
        items.indices.contains(index) ? items[index] : nil
    }

    private var audioPlaceholder: some View {
        VStack(spacing: 16) {
            Image(systemName: "waveform")
                .font(.system(size: 56))
            Text(current?.name ?? "")
                .font(.headline)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
        }
        .foregroundStyle(.white)
    }

    private var topBar: some View {
        HStack {
            Button(action: closePlayer) {
                Image(systemName: "xmark")
                    .font(.body.weight(.semibold))
                    .padding(10)
                    .background(.black.opacity(0.45), in: Circle())
            }
            .accessibilityLabel("Close")
            Spacer()
            VStack(spacing: 2) {
                Text(current?.name ?? "")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                if items.count > 1 {
                    Text("\(index + 1) / \(items.count)")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.7))
                }
            }
            .foregroundStyle(.white)
            Spacer()
            if playback.isPictureInPicturePossible {
                Button {
                    playback.startPictureInPicture()
                } label: {
                    Image(systemName: playback.isPictureInPictureActive ? "pip.exit" : "pip.enter")
                        .font(.body.weight(.semibold))
                        .padding(10)
                        .background(.black.opacity(0.45), in: Circle())
                }
                .accessibilityLabel("Picture in Picture")
            }
            if let url = current?.localURL {
                ShareLink(item: url) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.body.weight(.semibold))
                        .padding(10)
                        .background(.black.opacity(0.45), in: Circle())
                }
            } else {
                Color.clear.frame(width: 40, height: 40)
            }
        }
        .padding(.horizontal, 16)
    }

    private var bottomBar: some View {
        VStack(spacing: 10) {
            HStack {
                Text(playback.elapsedText)
                    .font(.caption.monospacedDigit())
                Slider(
                    value: Binding(
                        get: { playback.displayedProgress },
                        set: { playback.seekPosition = $0 }
                    ),
                    in: 0...1,
                    onEditingChanged: { editing in
                        playback.isSeeking = editing
                        if editing {
                            hideTask?.cancel()
                        } else {
                            playback.seek(to: playback.seekPosition)
                            scheduleHide()
                        }
                    }
                )
                .tint(.white)
                Text(playback.durationText)
                    .font(.caption.monospacedDigit())
            }
            HStack(spacing: 36) {
                Button {
                    Task { await advance(by: -1, auto: false) }
                } label: {
                    Image(systemName: "backward.end.fill")
                        .font(.title2)
                }
                .disabled(items.count < 2)
                .opacity(items.count < 2 ? 0.35 : 1)

                Button {
                    playback.togglePlay()
                    scheduleHide()
                } label: {
                    Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                        .font(.largeTitle)
                }

                Button {
                    Task { await advance(by: 1, auto: false) }
                } label: {
                    Image(systemName: "forward.end.fill")
                        .font(.title2)
                }
                .disabled(items.count < 2)
                .opacity(items.count < 2 ? 0.35 : 1)
            }
            if let loadError {
                Text(loadError)
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else if let status = playback.statusMessage {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.black.opacity(0.45))
    }

    private func handlePlayerTap() {
        revealControls()
    }

    private func closePlayer() {
        hideTask?.cancel()
        playback.stopPictureInPicture()
        playback.stop()
        onClose()
    }

    private func revealControls() {
        withAnimation(.easeIn(duration: 0.15)) { controlsVisible = true }
        scheduleHide()
    }

    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            guard !Task.isCancelled, playback.isPlaying, !playback.isSeeking else { return }
            await MainActor.run {
                withAnimation(.easeOut(duration: 0.25)) { controlsVisible = false }
            }
        }
    }

    private func showSkipHint(_ seconds: Int) {
        skipHint = seconds > 0 ? "+\(seconds)s" : "\(seconds)s"
        Task {
            try? await Task.sleep(nanoseconds: 800_000_000)
            if skipHint == (seconds > 0 ? "+\(seconds)s" : "\(seconds)s") {
                skipHint = nil
            }
        }
    }

    private func openCurrent(autoplay: Bool) async {
        guard items.indices.contains(index) else { return }
        loadError = nil
        if items[index].localURL == nil, let remote = items[index].remoteEntry, let loadRemoteFile {
            isLoadingTrack = true
            do {
                items[index].localURL = try await loadRemoteFile(remote)
            } catch {
                loadError = error.localizedDescription
                isLoadingTrack = false
                return
            }
            isLoadingTrack = false
        }
        guard let url = items[index].localURL else {
            loadError = "Could not open this file."
            return
        }
        playback.open(url, autoplay: autoplay)
        revealControls()
        prefetchNeighbor(offset: 1)
    }

    private func advance(by delta: Int, auto: Bool) async {
        guard !items.isEmpty else { return }
        let next = index + delta
        if auto, next >= items.count {
            playback.didFinish = false
            playback.isPlaying = false
            revealControls()
            return
        }
        index = (next % items.count + items.count) % items.count
        await openCurrent(autoplay: true)
    }

    private func prefetchNeighbor(offset: Int) {
        let next = index + offset
        guard items.indices.contains(next), items[next].localURL == nil,
              let remote = items[next].remoteEntry, let loadRemoteFile
        else { return }
        Task {
            if let url = try? await loadRemoteFile(remote), items.indices.contains(next) {
                items[next].localURL = url
            }
        }
    }
}

@MainActor
final class VLCPlaybackController: NSObject, ObservableObject, VLCMediaPlayerDelegate {
    let player = VLCMediaPlayer()
    @Published var isPlaying = false
    @Published var hasVideo = false
    @Published var seekPosition: Double = 0
    @Published var isSeeking = false
    @Published var elapsedText = "00:00"
    @Published var durationText = "00:00"
    @Published var statusMessage: String?
    @Published var didFinish = false
    @Published var isPictureInPictureActive = false
    @Published var isPictureInPicturePossible = AVPictureInPictureController.isPictureInPictureSupported()
    @Published private(set) var progress: Double = 0

    private var ticker: Timer?
    private var ignoreEnded = false
    private var pipController: AVPictureInPictureController?
    private var pipContent: PiPContentViewController?
    private let pipBridge = PictureInPictureBridge()
    private weak var inlineView: UIView?

    var displayedProgress: Double {
        isSeeking ? seekPosition : progress
    }

    override init() {
        super.init()
        player.delegate = self
        pipBridge.onWillStart = { [weak self] in
            Task { @MainActor in
                self?.handlePictureInPictureWillStart()
            }
        }
        pipBridge.onDidStop = { [weak self] in
            Task { @MainActor in
                self?.handlePictureInPictureDidStop()
            }
        }
        pipBridge.onFailed = { [weak self] message in
            Task { @MainActor in
                self?.handlePictureInPictureFailure(message)
            }
        }
        pipBridge.onRestore = { [weak self] completion in
            Task { @MainActor in
                self?.handleRestoreUserInterface(completion: completion)
            }
        }
        ticker = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.syncTime()
            }
        }
        if let ticker {
            RunLoop.main.add(ticker, forMode: .common)
        }
    }

    func attach(drawable: UIView) {
        inlineView = drawable
        if !isPictureInPictureActive {
            player.drawable = drawable
        }
    }

    func preparePictureInPicture(sourceView: UIView) {
        activateAudioSession()
        guard AVPictureInPictureController.isPictureInPictureSupported() else {
            isPictureInPicturePossible = false
            return
        }
        guard sourceView.window != nil, sourceView.bounds.width > 1, sourceView.bounds.height > 1 else {
            return
        }
        let content = pipContent ?? PiPContentViewController()
        pipContent = content
        let source = AVPictureInPictureController.ContentSource(
            activeVideoCallSourceView: sourceView,
            contentViewController: content
        )
        if let pipController {
            pipController.contentSource = source
            isPictureInPicturePossible = true
            return
        }
        let controller = AVPictureInPictureController(contentSource: source)
        controller.delegate = pipBridge
        controller.canStartPictureInPictureAutomaticallyFromInline = true
        pipController = controller
        isPictureInPicturePossible = true
    }

    func startPictureInPicture() {
        activateAudioSession()
        guard let inlineView else {
            statusMessage = "Picture in Picture is not ready yet."
            return
        }
        preparePictureInPicture(sourceView: inlineView)
        if isPictureInPictureActive {
            pipController?.stopPictureInPicture()
        } else {
            pipController?.startPictureInPicture()
        }
    }

    func stopPictureInPicture() {
        pipController?.stopPictureInPicture()
    }

    fileprivate func handlePictureInPictureWillStart() {
        if let canvas = pipContent?.canvas {
            player.drawable = canvas
        }
        if player.videoSize.width > 0, player.videoSize.height > 0 {
            pipContent?.preferredContentSize = player.videoSize
        }
        isPictureInPictureActive = true
    }

    fileprivate func handlePictureInPictureDidStop() {
        if let inlineView {
            player.drawable = inlineView
        }
        isPictureInPictureActive = false
    }

    fileprivate func handlePictureInPictureFailure(_ message: String) {
        statusMessage = message
        isPictureInPictureActive = false
    }

    fileprivate func handleRestoreUserInterface(completion: @escaping @Sendable (Bool) -> Void) {
        completion(true)
    }

    private func activateAudioSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .moviePlayback, options: [])
        try? session.setActive(true)
    }

    func open(_ url: URL, autoplay: Bool) {
        ensureTicker()
        activateAudioSession()
        ignoreEnded = true
        didFinish = false
        statusMessage = nil
        progress = 0
        seekPosition = 0
        elapsedText = "00:00"
        durationText = "00:00"
        player.stop()
        player.media = VLCMedia(url: url)
        ignoreEnded = false
        if autoplay {
            player.play()
        }
        isPlaying = autoplay
    }

    func togglePlay() {
        if player.isPlaying {
            player.pause()
            isPlaying = false
        } else {
            player.play()
            isPlaying = true
        }
    }

    func seek(to value: Double) {
        let clamped = min(max(value, 0), 1)
        if let length = durationMs, length > 0 {
            let target = Int64(clamped * Double(length))
            player.time = VLCTime(int: Int32(clamping: target))
        } else {
            player.position = Float(clamped)
        }
        progress = clamped
        seekPosition = clamped
        syncTime()
    }

    func skip(seconds: Int) {
        guard let length = durationMs, length > 0 else { return }
        let next = min(max((elapsedMs ?? 0) + Int64(seconds) * 1000, 0), length)
        seek(to: Double(next) / Double(length))
    }

    func stop() {
        ignoreEnded = true
        ticker?.invalidate()
        ticker = nil
        pipController?.stopPictureInPicture()
        player.stop()
        player.drawable = nil
    }

    private func ensureTicker() {
        guard ticker == nil else { return }
        ticker = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.syncTime()
            }
        }
        if let ticker {
            RunLoop.main.add(ticker, forMode: .common)
        }
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

    private var elapsedMs: Int64? {
        player.time.value?.int64Value
    }

    private var durationMs: Int64? {
        if let length = player.media?.length.value?.int64Value, length > 0 {
            return length
        }
        return nil
    }

    private func syncState() {
        isPlaying = player.isPlaying
        hasVideo = player.hasVideoOut || player.videoSize.width > 0
        switch player.state {
        case .error:
            statusMessage = "This file could not be played."
        case .ended:
            isPlaying = false
            progress = 1
            if !ignoreEnded {
                didFinish = true
            }
        default:
            if player.isPlaying { statusMessage = nil }
        }
    }

    private func syncTime() {
        let elapsed = max(elapsedMs ?? 0, 0)
        let duration = max(durationMs ?? 0, 0)
        if !isSeeking {
            if duration > 0 {
                progress = min(Double(elapsed) / Double(duration), 1)
            } else if player.position.isFinite, player.position > 0 {
                progress = Double(player.position)
            }
            seekPosition = progress
        }
        elapsedText = Self.format(milliseconds: elapsed)
        durationText = duration > 0 ? Self.format(milliseconds: duration) : "--:--"
        hasVideo = player.hasVideoOut || player.videoSize.width > 0
        if !ignoreEnded, duration > 0, elapsed + 250 >= duration, player.state == .ended || !player.isPlaying && progress > 0.98 {
            if !didFinish { didFinish = true }
        }
    }

    private static func format(milliseconds: Int64) -> String {
        let total = abs(milliseconds) / 1000
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
        view.isUserInteractionEnabled = false
        controller.attach(drawable: view)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        uiView.isUserInteractionEnabled = false
        controller.attach(drawable: uiView)
    }
}

private final class PictureInPictureBridge: NSObject, AVPictureInPictureControllerDelegate {
    var onWillStart: (@Sendable () -> Void)?
    var onDidStop: (@Sendable () -> Void)?
    var onFailed: (@Sendable (String) -> Void)?
    var onRestore: (@Sendable (@escaping @Sendable (Bool) -> Void) -> Void)?

    func pictureInPictureControllerWillStartPictureInPicture(
        _ pictureInPictureController: AVPictureInPictureController
    ) {
        onWillStart?()
    }

    func pictureInPictureControllerDidStopPictureInPicture(
        _ pictureInPictureController: AVPictureInPictureController
    ) {
        onDidStop?()
    }

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        failedToStartPictureInPictureWithError error: Error
    ) {
        onFailed?(error.localizedDescription)
    }

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
    ) {
        let box = UncheckedCompletion(completionHandler)
        if let onRestore {
            onRestore { restored in
                box.call(restored)
            }
        } else {
            box.call(true)
        }
    }
}

private final class UncheckedCompletion: @unchecked Sendable {
    private let handler: (Bool) -> Void

    init(_ handler: @escaping (Bool) -> Void) {
        self.handler = handler
    }

    func call(_ value: Bool) {
        handler(value)
    }
}

private struct PlayerInteractionLayer: UIViewRepresentable {
    var isEnabled: Bool
    var onTap: () -> Void
    var onDismissChanged: (CGFloat) -> Void
    var onDismissEnded: (CGFloat, CGFloat) -> Void
    var onHorizontalSkip: (Int) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIView(context: Context) -> PlayerInteractionView {
        let view = PlayerInteractionView()
        view.coordinator = context.coordinator
        view.isUserInteractionEnabled = isEnabled
        return view
    }

    func updateUIView(_ uiView: PlayerInteractionView, context: Context) {
        context.coordinator.parent = self
        uiView.coordinator = context.coordinator
        uiView.isUserInteractionEnabled = isEnabled
    }

    final class Coordinator {
        var parent: PlayerInteractionLayer
        init(_ parent: PlayerInteractionLayer) {
            self.parent = parent
        }
    }
}

private final class PlayerInteractionView: UIView, UIGestureRecognizerDelegate {
    weak var coordinator: PlayerInteractionLayer.Coordinator?
    private var isDismissing = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        isMultipleTouchEnabled = false
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap))
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan))
        tap.delegate = self
        pan.delegate = self
        addGestureRecognizer(pan)
        addGestureRecognizer(tap)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func handleTap() {
        coordinator?.parent.onTap()
    }

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        let translation = gesture.translation(in: self)
        let velocity = gesture.velocity(in: self)
        switch gesture.state {
        case .changed:
            if isDismissing || (translation.y > 24 && translation.y > abs(translation.x) + 8) {
                isDismissing = true
                coordinator?.parent.onDismissChanged(translation.y)
            }
        case .ended, .cancelled:
            if isDismissing {
                isDismissing = false
                coordinator?.parent.onDismissEnded(translation.y, velocity.y)
            } else if abs(translation.x) > abs(translation.y), abs(translation.x) > 36 {
                let seconds = min(max(Int((translation.x / 70).rounded()) * 10, -120), 120)
                if seconds != 0 {
                    coordinator?.parent.onHorizontalSkip(seconds)
                }
            }
        default:
            break
        }
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        true
    }
}

private final class PiPContentViewController: AVPictureInPictureVideoCallViewController {
    let canvas = UIView()

    override init(nibName nibNameOrNil: String?, bundle nibBundleOrNil: Bundle?) {
        super.init(nibName: nibNameOrNil, bundle: nibBundleOrNil)
        preferredContentSize = CGSize(width: 16, height: 9)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        canvas.backgroundColor = .black
        canvas.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(canvas)
        NSLayoutConstraint.activate([
            canvas.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            canvas.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            canvas.topAnchor.constraint(equalTo: view.topAnchor),
            canvas.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
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
