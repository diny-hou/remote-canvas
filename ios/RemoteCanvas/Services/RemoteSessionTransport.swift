import Foundation

enum RemoteDisplayMode: String, CaseIterable, Identifiable, Sendable {
    case mobile
    case desktop

    var id: Self { self }

    var title: String {
        switch self {
        case .mobile: "モバイル"
        case .desktop: "デスクトップ"
        }
    }

    var systemImage: String {
        switch self {
        case .mobile: "iphone"
        case .desktop: "desktopcomputer"
        }
    }
}

struct PointerEvent: Sendable, Equatable {
    enum Action: Sendable, Equatable {
        case move
        case primaryClick
        case secondaryClick
        case scroll(CGFloat)
    }

    let normalizedLocation: CGPoint
    let action: Action
}

protocol RemoteSessionTransport: Sendable {
    func send(pointerEvent: PointerEvent) async throws
    func send(text: String) async throws
    func disconnect() async
}

struct PreviewRemoteSessionTransport: RemoteSessionTransport {
    func send(pointerEvent: PointerEvent) async throws {}
    func send(text: String) async throws {}
    func disconnect() async {}
}
