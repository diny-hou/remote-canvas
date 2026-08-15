import Foundation
import Observation
import UIKit

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

@MainActor
protocol RemoteSessionTransport: AnyObject {
    var latestFrame: Data? { get }
    var statusText: String { get }
    func connect() async
    func send(pointerEvent: PointerEvent) async throws
    func send(text: String) async throws
    func disconnect() async
    func listFiles(path: String) async throws -> [RemoteFileEntry]
    func download(_ file: RemoteFileEntry) async throws -> URL
    func upload(localURL: URL, to directory: String) async throws
}

@MainActor
final class PreviewRemoteSessionTransport: RemoteSessionTransport {
    var latestFrame: Data?
    var statusText: String { "プレビュー" }
    func connect() async {}
    func send(pointerEvent: PointerEvent) async throws {}
    func send(text: String) async throws {}
    func disconnect() async {}
    func listFiles(path: String) async throws -> [RemoteFileEntry] { [] }
    func download(_ file: RemoteFileEntry) async throws -> URL { URL(fileURLWithPath: "/") }
    func upload(localURL: URL, to directory: String) async throws {}
}

struct RemoteFileEntry: Codable, Identifiable, Hashable, Sendable {
    var id: String { path }
    let name: String
    let path: String
    let isDirectory: Bool
    let size: UInt64
    let modifiedUnixSeconds: UInt64
}

@MainActor
@Observable
final class LiveRemoteSession: RemoteSessionTransport {
    enum SessionError: LocalizedError {
        case invalidEndpoint
        case disconnected
        case server(String)

        var errorDescription: String? {
            switch self {
            case .invalidEndpoint: "接続先URLが正しくありません。"
            case .disconnected: "Windowsとの接続が切断されました。"
            case .server(let message): message
            }
        }
    }

    private let device: PairedDevice
    private var socket: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?

    var latestFrame: Data?
    var statusText = "接続待ち"
    var isConnected = false

    init(device: PairedDevice) {
        self.device = device
    }

    func connect() async {
        guard socket == nil else { return }
        guard var components = URLComponents(string: device.endpoint) else {
            statusText = "接続先エラー"
            return
        }
        components.scheme = components.scheme == "https" ? "wss" : "ws"
        components.path = "/ws"
        guard let url = components.url else {
            statusText = "接続先エラー"
            return
        }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(device.accessToken)", forHTTPHeaderField: "Authorization")
        let task = URLSession.shared.webSocketTask(with: request)
        socket = task
        task.resume()
        isConnected = true
        statusText = "画面を受信中"
        receiveTask = Task { [weak self] in
            await self?.receiveFrames()
        }
    }

    func send(pointerEvent: PointerEvent) async throws {
        let action: String
        let delta: Double
        switch pointerEvent.action {
        case .move:
            action = "move"
            delta = 0
        case .primaryClick:
            action = "primary_click"
            delta = 0
        case .secondaryClick:
            action = "secondary_click"
            delta = 0
        case .scroll(let amount):
            action = "scroll"
            delta = Double(amount)
        }
        try await sendJSON([
            "type": "pointer",
            "x": Double(pointerEvent.normalizedLocation.x),
            "y": Double(pointerEvent.normalizedLocation.y),
            "action": action,
            "delta": delta
        ])
    }

    func send(text: String) async throws {
        try await sendJSON(["type": "text", "text": text])
    }

    func disconnect() async {
        receiveTask?.cancel()
        receiveTask = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        isConnected = false
        statusText = "切断済み"
    }

    func listFiles(path: String) async throws -> [RemoteFileEntry] {
        var request = try apiRequest(path: "/api/files", queryItems: [URLQueryItem(name: "path", value: path)])
        request.httpMethod = "GET"
        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response: response, data: data)
        return try JSONDecoder().decode([RemoteFileEntry].self, from: data)
    }

    func download(_ file: RemoteFileEntry) async throws -> URL {
        var request = try apiRequest(path: "/api/file", queryItems: [URLQueryItem(name: "path", value: file.path)])
        request.httpMethod = "GET"
        let (temporaryURL, response) = try await URLSession.shared.download(for: request)
        try validate(response: response, data: Data())
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent(file.name)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: temporaryURL, to: destination)
        return destination
    }

    func upload(localURL: URL, to directory: String) async throws {
        let gainedAccess = localURL.startAccessingSecurityScopedResource()
        defer { if gainedAccess { localURL.stopAccessingSecurityScopedResource() } }
        var request = try apiRequest(
            path: "/api/file",
            queryItems: [
                URLQueryItem(name: "path", value: directory),
                URLQueryItem(name: "name", value: localURL.lastPathComponent)
            ]
        )
        request.httpMethod = "PUT"
        let (responseData, response) = try await URLSession.shared.upload(for: request, fromFile: localURL)
        try validate(response: response, data: responseData)
    }

    private func receiveFrames() async {
        guard let socket else { return }
        while !Task.isCancelled {
            do {
                let message = try await socket.receive()
                switch message {
                case .data(let data):
                    latestFrame = data
                    statusText = "接続中"
                case .string:
                    break
                @unknown default:
                    break
                }
            } catch {
                if !Task.isCancelled {
                    isConnected = false
                    statusText = "接続エラー"
                }
                break
            }
        }
    }

    private func sendJSON(_ object: [String: Any]) async throws {
        guard let socket else { throw SessionError.disconnected }
        let data = try JSONSerialization.data(withJSONObject: object)
        guard let string = String(data: data, encoding: .utf8) else {
            throw SessionError.server("操作データを作成できません。")
        }
        try await socket.send(.string(string))
    }

    private func apiRequest(path: String, queryItems: [URLQueryItem]) throws -> URLRequest {
        guard var components = URLComponents(string: device.endpoint) else {
            throw SessionError.invalidEndpoint
        }
        components.path = path
        components.queryItems = queryItems
        guard let url = components.url else { throw SessionError.invalidEndpoint }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(device.accessToken)", forHTTPHeaderField: "Authorization")
        return request
    }

    private func validate(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else {
            throw SessionError.server("Windowsから不正な応答を受信しました。")
        }
        guard (200..<300).contains(http.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? "HTTP \(http.statusCode)"
            throw SessionError.server(message)
        }
    }
}
