import SwiftUI
import UIKit

struct RemoteWorkspaceView: View {
    let mode: RemoteDisplayMode
    let frameData: Data?
    let pointer: CGPoint
    let onPointerEvent: (PointerEvent) -> Void

    var body: some View {
        GeometryReader { proxy in
            let interactionRect = contentRect(in: proxy.size)
            ZStack {
                if let frameData, let image = UIImage(data: frameData) {
                    Image(uiImage: image)
                        .resizable()
                        .interpolation(.low)
                        .scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(.black)
                } else {
                    switch mode {
                    case .mobile:
                        MobileWorkspaceSurface()
                    case .desktop:
                        DesktopWorkspaceSurface()
                    }
                }

                pointerView(in: interactionRect)
            }
            .contentShape(Rectangle())
            .gesture(pointerGesture(in: interactionRect))
            .simultaneousGesture(
                TapGesture(count: 2).onEnded {
                    onPointerEvent(PointerEvent(normalizedLocation: pointer, action: .primaryClick))
                }
            )
        }
    }

    private func pointerView(in rect: CGRect) -> some View {
        Image(systemName: "cursorarrow")
            .font(.title2)
            .foregroundStyle(.white, .black)
            .shadow(radius: 2)
            .position(
                x: rect.minX + max(0, min(rect.width, pointer.x * rect.width)),
                y: rect.minY + max(0, min(rect.height, pointer.y * rect.height))
            )
            .allowsHitTesting(false)
    }

    private func pointerGesture(in rect: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let location = CGPoint(
                    x: max(0, min(1, (value.location.x - rect.minX) / max(rect.width, 1))),
                    y: max(0, min(1, (value.location.y - rect.minY) / max(rect.height, 1)))
                )
                onPointerEvent(PointerEvent(normalizedLocation: location, action: .move))
            }
            .onEnded { value in
                guard abs(value.translation.width) < 6, abs(value.translation.height) < 6 else { return }
                let location = CGPoint(
                    x: max(0, min(1, (value.location.x - rect.minX) / max(rect.width, 1))),
                    y: max(0, min(1, (value.location.y - rect.minY) / max(rect.height, 1)))
                )
                onPointerEvent(PointerEvent(normalizedLocation: location, action: .primaryClick))
            }
    }

    private func contentRect(in container: CGSize) -> CGRect {
        guard let frameData, let image = UIImage(data: frameData), image.size.width > 0, image.size.height > 0 else {
            return CGRect(origin: .zero, size: container)
        }
        let scale = min(container.width / image.size.width, container.height / image.size.height)
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        return CGRect(
            x: (container.width - size.width) / 2,
            y: (container.height - size.height) / 2,
            width: size.width,
            height: size.height
        )
    }
}

private struct MobileWorkspaceSurface: View {
    private let folders = [
        ("プロジェクト", "folder.fill", "12項目"),
        ("ドキュメント", "doc.text.fill", "28項目"),
        ("ダウンロード", "arrow.down.circle.fill", "5項目"),
        ("写真", "photo.fill", "104項目")
    ]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("エクスプローラー")
                        .font(.headline)
                    Text("クイックアクセス")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "ellipsis")
                    .frame(width: 42, height: 42)
                    .background(.white.opacity(0.08), in: Circle())
            }
            .padding()

            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(folders, id: \.0) { folder in
                        HStack(spacing: 14) {
                            Image(systemName: folder.1)
                                .font(.title2)
                                .foregroundStyle(.cyan)
                                .frame(width: 46, height: 46)
                                .background(.cyan.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                            VStack(alignment: .leading, spacing: 3) {
                                Text(folder.0)
                                    .font(.body.bold())
                                Text(folder.2)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .foregroundStyle(.tertiary)
                        }
                        .padding(12)
                        .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 16))
                    }
                }
                .padding()
            }

            HStack {
                Label("ホーム", systemImage: "house.fill")
                Spacer()
                Label("このPC", systemImage: "pc")
                Spacer()
                Label("検索", systemImage: "magnifyingglass")
            }
            .font(.caption.bold())
            .padding()
            .background(.black.opacity(0.22))
        }
        .background(
            LinearGradient(
                colors: [Color(red: 0.08, green: 0.13, blue: 0.19), Color(red: 0.04, green: 0.07, blue: 0.11)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
    }
}

private struct DesktopWorkspaceSurface: View {
    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .bottom) {
                LinearGradient(
                    colors: [.blue.opacity(0.82), .indigo.opacity(0.72), .black.opacity(0.75)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )

                VStack(spacing: 14) {
                    ForEach(["desktopcomputer", "folder.fill", "trash.fill"], id: \.self) { icon in
                        Image(systemName: icon)
                            .frame(width: 38, height: 38)
                    }
                    Spacer()
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(spacing: 0) {
                    HStack {
                        Text("ファイル エクスプローラー")
                            .font(.caption.bold())
                        Spacer()
                        Image(systemName: "minus")
                        Image(systemName: "square")
                        Image(systemName: "xmark")
                    }
                    .padding(8)
                    .background(.black.opacity(0.16))
                    HStack(alignment: .top, spacing: 0) {
                        VStack(alignment: .leading, spacing: 10) {
                            Label("ホーム", systemImage: "house")
                            Label("デスクトップ", systemImage: "desktopcomputer")
                            Label("ドキュメント", systemImage: "doc")
                        }
                        .font(.caption2)
                        .padding(10)
                        .frame(width: proxy.size.width * 0.28)
                        .frame(maxHeight: .infinity, alignment: .topLeading)
                        .background(.black.opacity(0.12))
                        Text("最近使用したファイル")
                            .font(.caption)
                            .padding()
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    }
                }
                .background(.ultraThinMaterial)
                .frame(width: proxy.size.width * 0.76, height: proxy.size.height * 0.62)
                .position(x: proxy.size.width * 0.56, y: proxy.size.height * 0.48)

                HStack(spacing: 16) {
                    Image(systemName: "square.grid.2x2.fill")
                    Image(systemName: "magnifyingglass")
                    Image(systemName: "folder.fill")
                    Spacer()
                    Image(systemName: "wifi")
                    Text("10:24")
                        .font(.caption2.monospacedDigit())
                }
                .padding(.horizontal, 12)
                .frame(height: 36)
                .background(.black.opacity(0.38))
            }
        }
    }
}

#Preview("Mobile workspace") {
    RemoteWorkspaceView(mode: .mobile, frameData: nil, pointer: CGPoint(x: 0.6, y: 0.4)) { _ in }
        .frame(width: 390, height: 650)
        .preferredColorScheme(.dark)
}
