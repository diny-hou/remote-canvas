import CryptoKit
import Foundation
import Network
import Observation
import Security
import UIKit

struct PointerEvent: Sendable, Equatable {
    enum Action: Sendable, Equatable {
        case move
        case primaryDown
        case primaryUp
        case primaryClick
        case secondaryClick
        case doubleClick
        case scroll(CGFloat)
        case scrollHorizontal(CGFloat)
    }

    let normalizedLocation: CGPoint
    let action: Action
}

struct RemoteDisplay: Codable, Identifiable, Hashable, Sendable {
    let id: UInt32
    let name: String
    let x: Int
    let y: Int
    let width: UInt32
    let height: UInt32
    let isPrimary: Bool
}

@MainActor
protocol RemoteSessionTransport: AnyObject {
    var latestFrame: Data? { get }
    var statusText: String { get }
    var lastError: String? { get }
    var isUsingLAN: Bool { get }
    var discoveredEndpoints: [String] { get }
    var displays: [RemoteDisplay] { get }
    var selectedDisplayId: UInt32? { get }
    func connect() async
    func send(pointerEvent: PointerEvent) async throws
    func send(text: String) async throws
    func send(streamQuality: StreamQualitySettings) async throws
    func selectDisplay(id: UInt32) async throws
    func refreshDisplays() async
    func disconnect() async
    func listFiles(path: String) async throws -> [RemoteFileEntry]
    func download(_ file: RemoteFileEntry) async throws -> URL
    func upload(localURL: URL, to directory: String) async throws
}

@MainActor
final class PreviewRemoteSessionTransport: RemoteSessionTransport {
    var latestFrame: Data?
    var statusText: String { "Preview" }
    var lastError: String? { nil }
    var isUsingLAN: Bool { true }
    var discoveredEndpoints: [String] { [] }
    var displays: [RemoteDisplay] = [
        RemoteDisplay(id: 1, name: "Main display", x: 0, y: 0, width: 1920, height: 1080, isPrimary: true),
        RemoteDisplay(id: 2, name: "Second display", x: 1920, y: 0, width: 2560, height: 1440, isPrimary: false)
    ]
    var selectedDisplayId: UInt32? = 1
    func connect() async {}
    func send(pointerEvent: PointerEvent) async throws {}
    func send(text: String) async throws {}
    func send(streamQuality: StreamQualitySettings) async throws {}
    func selectDisplay(id: UInt32) async throws { selectedDisplayId = id }
    func refreshDisplays() async {}
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

struct PairingResult: Sendable {
    let accessToken: String
    let certSha256: String
    let endpoints: [String]
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
            case .invalidEndpoint: "Invalid endpoint."
            case .disconnected: "Disconnected from Windows."
            case .server(let message): message
            }
        }
    }

    private let device: PairedDevice
    private let pinDelegate: PinDelegate
    private let session: URLSession
    private var socket: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var shouldReconnect = false
    private var activeEndpoint: String?
    private var pendingMove: PointerEvent?
    private var moveFlushTask: Task<Void, Never>?
    private var pendingStreamQuality: StreamQualitySettings?
    private var pendingDisplayId: UInt32?

    var latestFrame: Data?
    var statusText = "Waiting"
    var lastError: String?
    var isConnected = false
    var isUsingLAN = false
    var discoveredEndpoints: [String] = []
    var displays: [RemoteDisplay] = []
    var selectedDisplayId: UInt32?

    init(device: PairedDevice) {
        self.device = device
        let pinDelegate = PinDelegate(expectedSha256: device.certSha256)
        self.pinDelegate = pinDelegate
        self.session = URLSession(configuration: .ephemeral, delegate: pinDelegate, delegateQueue: nil)
        self.isUsingLAN = device.preferredEndpoints.first.map(isLikelyLAN) ?? false
    }

    static func exchangePairingCode(
        endpoints: [String],
        code: String,
        certSha256: String?
    ) async throws -> PairingResult {
        var lastError: Error = SessionError.invalidEndpoint
        let reachable = endpoints.filter { !isLoopback($0) }
        for endpoint in (reachable.isEmpty ? endpoints : reachable) {
            do {
                return try await exchangePairingCode(endpoint: endpoint, code: code, certSha256: certSha256)
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    private static func exchangePairingCode(
        endpoint: String,
        code: String,
        certSha256: String?
    ) async throws -> PairingResult {
        guard var components = URLComponents(string: endpoint) else {
            throw SessionError.invalidEndpoint
        }
        if components.scheme?.lowercased() == "http" {
            components.scheme = "https"
        }
        components.path = "/api/pair"
        guard let url = components.url else { throw SessionError.invalidEndpoint }

        let pin = PinDelegate(expectedSha256: certSha256)
        let session = URLSession(configuration: .default, delegate: pin, delegateQueue: nil)
        defer { session.invalidateAndCancel() }

        var request = URLRequest(url: url, timeoutInterval: 12)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            PairingRequest(code: code, clientName: UIDevice.current.name)
        )
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw mapPairingError(error, endpoint: endpoint)
        }
        guard let http = response as? HTTPURLResponse else {
            throw SessionError.server("Unexpected response from Windows.")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw SessionError.server("Wrong or expired code. Generate a new one on Windows.")
        }
        let credentials = try JSONDecoder().decode(PairingCredentials.self, from: data)
        let pinValue = credentials.certSha256.isEmpty ? (pin.seenSha256 ?? certSha256 ?? "") : credentials.certSha256
        var resolved = credentials.endpoints
        if resolved.isEmpty { resolved = [endpoint] }
        return PairingResult(accessToken: credentials.accessToken, certSha256: pinValue, endpoints: resolved)
    }

    func connect() async {
        shouldReconnect = true
        await connectWithRetry(resetBackoff: true)
    }

    func send(pointerEvent: PointerEvent) async throws {
        if pointerEvent.action == .move {
            pendingMove = pointerEvent
            if moveFlushTask == nil {
                moveFlushTask = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: 12_000_000)
                    await self?.flushPendingMove()
                }
            }
            return
        }
        await flushPendingMove()
        try await sendPointerNow(pointerEvent)
    }

    private func flushPendingMove() async {
        moveFlushTask = nil
        guard let pendingMove else { return }
        self.pendingMove = nil
        try? await sendPointerNow(pendingMove)
    }

    private func sendPointerNow(_ pointerEvent: PointerEvent) async throws {
        let action: String
        let delta: Double
        switch pointerEvent.action {
        case .move:
            action = "move"
            delta = 0
        case .primaryDown:
            action = "primary_down"
            delta = 0
        case .primaryUp:
            action = "primary_up"
            delta = 0
        case .primaryClick:
            action = "primary_click"
            delta = 0
        case .secondaryClick:
            action = "secondary_click"
            delta = 0
        case .doubleClick:
            action = "double_click"
            delta = 0
        case .scroll(let amount):
            action = "scroll"
            delta = Double(amount)
        case .scrollHorizontal(let amount):
            action = "scroll_horizontal"
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

    func send(streamQuality: StreamQualitySettings) async throws {
        pendingStreamQuality = streamQuality
        try await sendJSON([
            "type": "set_stream_quality",
            "interval_ms": streamQuality.intervalMs,
            "jpeg_quality": streamQuality.jpegQuality,
            "max_width": streamQuality.maxWidth
        ])
    }

    func selectDisplay(id: UInt32) async throws {
        pendingDisplayId = id
        selectedDisplayId = id
        try await sendJSON(["type": "set_display", "id": id])
    }

    func refreshDisplays() async {
        if let listed = try? await fetchDisplays() {
            applyDisplays(listed.displays, selected: listed.selected)
            return
        }
        try? await sendJSON(["type": "list_displays"])
    }

    func disconnect() async {
        shouldReconnect = false
        receiveTask?.cancel()
        receiveTask = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        isConnected = false
        statusText = "Disconnected"
    }

    func listFiles(path: String) async throws -> [RemoteFileEntry] {
        var request = try apiRequest(path: "/api/files", queryItems: [URLQueryItem(name: "path", value: path)])
        request.httpMethod = "GET"
        let (data, response) = try await session.data(for: request)
        try validate(response: response, data: data)
        return try JSONDecoder().decode([RemoteFileEntry].self, from: data)
    }

    func download(_ file: RemoteFileEntry) async throws -> URL {
        var request = try apiRequest(path: "/api/file", queryItems: [URLQueryItem(name: "path", value: file.path)])
        request.httpMethod = "GET"
        request.timeoutInterval = 6 * 60 * 60
        let (temporaryURL, response) = try await session.download(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let details = (try? Data(contentsOf: temporaryURL)) ?? Data()
            try validate(response: response, data: details)
        }
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
        let (responseData, response) = try await session.upload(for: request, fromFile: localURL)
        try validate(response: response, data: responseData)
    }

    private func connectWithRetry(resetBackoff: Bool) async {
        var delay: UInt64 = resetBackoff ? 250_000_000 : 800_000_000
        while shouldReconnect && !Task.isCancelled {
            if await openSocket() {
                receiveTask?.cancel()
                receiveTask = Task { [weak self] in
                    await self?.receiveFrames()
                }
                lastError = nil
                if let pendingStreamQuality {
                    try? await send(streamQuality: pendingStreamQuality)
                }
                if let pendingDisplayId {
                    try? await selectDisplay(id: pendingDisplayId)
                } else {
                    await refreshDisplays()
                }
                return
            }
            statusText = "Reconnecting"
            lastError = awayFromHomeHint()
            try? await Task.sleep(nanoseconds: delay)
            delay = min(delay * 2, 4_000_000_000)
        }
    }

    private func openSocket() async -> Bool {
        guard let endpoint = await firstReachableEndpoint() else {
            socket = nil
            isConnected = false
            return false
        }
        guard let url = websocketURL(from: endpoint) else { return false }
        var request = URLRequest(url: url, timeoutInterval: 12)
        applyAuth(&request, path: isLikelyLAN(endpoint) ? "lan" : "tailscale")
        let task = session.webSocketTask(with: request)
        task.resume()
        do {
            let message = try await receiveOnce(task, timeout: 8)
            switch message {
            case .data(let data):
                latestFrame = data
            case .string(let text):
                applyHostMessage(text)
            @unknown default:
                break
            }
        } catch {
            task.cancel(with: .goingAway, reason: nil)
            return false
        }
        socket = task
        activeEndpoint = endpoint
        isConnected = true
        isUsingLAN = isLikelyLAN(endpoint)
        statusText = isUsingLAN ? "LAN" : "Remote"
        return true
    }

    private func firstReachableEndpoint() async -> String? {
        let endpoints = candidateEndpoints()
        guard !endpoints.isEmpty else { return nil }
        return await withTaskGroup(of: (String, Int)?.self) { group in
            for endpoint in endpoints {
                group.addTask {
                    if await self.probe(endpoint) {
                        return (endpoint, await self.preferenceRank(endpoint))
                    }
                    return nil
                }
            }
            var best: (String, Int)?
            for await result in group {
                guard let result else { continue }
                if best == nil || result.1 < best!.1 {
                    best = result
                }
            }
            return best?.0
        }
    }

    private func candidateEndpoints() -> [String] {
        var ordered: [String] = []
        for candidate in discoveredEndpoints + device.preferredEndpoints {
            let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty, !isLoopback(trimmed), !ordered.contains(trimmed) {
                ordered.append(trimmed)
            }
        }
        if PathState.shared.isCellularOnly {
            return ordered.sorted { preferenceRank($0) < preferenceRank($1) }
        }
        return ordered
    }

    private func preferenceRank(_ endpoint: String) -> Int {
        if PathState.shared.isCellularOnly {
            return isLikelyLAN(endpoint) ? 2 : 0
        }
        return isLikelyLAN(endpoint) ? 0 : 1
    }

    private func probe(_ endpoint: String) async -> Bool {
        guard var components = URLComponents(string: endpoint) else { return false }
        components.path = "/health"
        guard let url = components.url else { return false }
        let timeout: TimeInterval
        if PathState.shared.isCellularOnly && isLikelyLAN(endpoint) {
            timeout = 0.7
        } else {
            timeout = isLikelyLAN(endpoint) ? 1.4 : 10
        }
        let request = URLRequest(url: url, timeoutInterval: timeout)
        do {
            let (data, response) = try await session.data(for: request)
            guard ((response as? HTTPURLResponse)?.statusCode ?? 500) < 300 else { return false }
            if let health = try? JSONDecoder().decode(HealthInfo.self, from: data) {
                mergeDiscovered(health.endpoints ?? [])
            }
            return true
        } catch {
            return false
        }
    }

    private func mergeDiscovered(_ endpoints: [String]) {
        var merged = discoveredEndpoints
        for endpoint in endpoints {
            let trimmed = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty, !isLoopback(trimmed), !merged.contains(trimmed) {
                merged.append(trimmed)
            }
        }
        if merged != discoveredEndpoints {
            discoveredEndpoints = merged
        }
    }

    private func receiveOnce(
        _ task: URLSessionWebSocketTask,
        timeout: TimeInterval
    ) async throws -> URLSessionWebSocketTask.Message {
        try await withThrowingTaskGroup(of: URLSessionWebSocketTask.Message.self) { group in
            group.addTask { try await task.receive() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw SessionError.disconnected
            }
            let message = try await group.next()!
            group.cancelAll()
            return message
        }
    }

    private func awayFromHomeHint() -> String {
        if PathState.shared.isCellularOnly {
            return "Away from home. The PC must be on Tailscale."
        }
        return "Could not reach the PC."
    }

    private func receiveFrames() async {
        guard let socket else { return }
        while shouldReconnect && !Task.isCancelled {
            do {
                let message = try await socket.receive()
                switch message {
                case .data(let data):
                    latestFrame = data
                    if let activeEndpoint {
                        isUsingLAN = isLikelyLAN(activeEndpoint)
                        statusText = isUsingLAN ? "LAN" : "Remote"
                    }
                case .string(let text):
                    applyHostMessage(text)
                @unknown default:
                    break
                }
            } catch {
                if shouldReconnect && !Task.isCancelled {
                    isConnected = false
                    statusText = "Reconnecting"
                    self.socket = nil
                    await connectWithRetry(resetBackoff: false)
                }
                break
            }
        }
    }

    private func sendJSON(_ object: [String: Any]) async throws {
        guard let socket else { throw SessionError.disconnected }
        let data = try JSONSerialization.data(withJSONObject: object)
        guard let string = String(data: data, encoding: .utf8) else {
            throw SessionError.server("Could not encode input.")
        }
        try await socket.send(.string(string))
    }

    private func apiRequest(path: String, queryItems: [URLQueryItem]) throws -> URLRequest {
        let endpoint = activeEndpoint ?? device.preferredEndpoints.first ?? device.endpoint
        guard var components = URLComponents(string: endpoint) else {
            throw SessionError.invalidEndpoint
        }
        components.path = path
        components.queryItems = queryItems
        guard let url = components.url else { throw SessionError.invalidEndpoint }
        var request = URLRequest(url: url)
        applyAuth(&request, path: isLikelyLAN(endpoint) ? "lan" : "tailscale")
        return request
    }

    private func applyAuth(_ request: inout URLRequest, path: String) {
        request.setValue("Bearer \(device.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(String(Int(Date().timeIntervalSince1970)), forHTTPHeaderField: "X-RC-Ts")
        request.setValue(randomNonce(), forHTTPHeaderField: "X-RC-Nonce")
        request.setValue(path, forHTTPHeaderField: "X-RC-Path")
    }

    private func validate(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else {
            throw SessionError.server("Unexpected response from Windows.")
        }
        guard (200..<300).contains(http.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? "HTTP \(http.statusCode)"
            throw SessionError.server(message)
        }
    }

    private func fetchDisplays() async throws -> DisplaysPayload {
        var request = try apiRequest(path: "/api/displays", queryItems: [])
        request.httpMethod = "GET"
        let (data, response) = try await session.data(for: request)
        try validate(response: response, data: data)
        return try JSONDecoder().decode(DisplaysPayload.self, from: data)
    }

    private func applyHostMessage(_ text: String) {
        guard let data = text.data(using: .utf8),
              let payload = try? JSONDecoder().decode(DisplaysPayload.self, from: data),
              payload.type == "displays"
        else { return }
        applyDisplays(payload.displays, selected: payload.selected)
    }

    private func applyDisplays(_ displays: [RemoteDisplay], selected: UInt32?) {
        self.displays = displays
        if let pendingDisplayId, displays.contains(where: { $0.id == pendingDisplayId }) {
            selectedDisplayId = pendingDisplayId
        } else {
            selectedDisplayId = selected ?? displays.first(where: \.isPrimary)?.id ?? displays.first?.id
        }
    }

    private func websocketURL(from endpoint: String) -> URL? {
        guard var components = URLComponents(string: endpoint) else { return nil }
        components.scheme = "wss"
        components.path = "/ws"
        return components.url
    }
}

private func mapPairingError(_ error: Error, endpoint: String) -> Error {
    let nsError = error as NSError
    if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorTimedOut {
        return LiveRemoteSession.SessionError.server("Timed out reaching \(endpoint)")
    }
    if nsError.domain == NSURLErrorDomain && (nsError.code == NSURLErrorCancelled || nsError.code == NSURLErrorServerCertificateUntrusted) {
        return LiveRemoteSession.SessionError.server("Could not trust \(endpoint). Scan the QR again.")
    }
    return LiveRemoteSession.SessionError.server("\(endpoint): \(error.localizedDescription)")
}

private func isLoopback(_ endpoint: String) -> Bool {
    guard let host = URL(string: endpoint)?.host else { return false }
    return host == "127.0.0.1" || host == "localhost" || host == "::1"
}

private func isLikelyLAN(_ endpoint: String) -> Bool {
    guard let host = URL(string: endpoint)?.host else { return false }
    if host.hasPrefix("100.") || isLoopback(endpoint) { return false }
    return host.hasPrefix("192.168.") || host.hasPrefix("10.") || host.hasPrefix("172.")
}

private func randomNonce() -> String {
    var bytes = [UInt8](repeating: 0, count: 16)
    _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
    return bytes.map { String(format: "%02x", $0) }.joined()
}

final class PinDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
    private let expectedSha256: String?
    private(set) var seenSha256: String?

    init(expectedSha256: String?) {
        let trimmed = expectedSha256?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        self.expectedSha256 = trimmed?.isEmpty == true ? nil : trimmed
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }

        let certificate: SecCertificate?
        if let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate] {
            certificate = chain.first
        } else {
            certificate = SecTrustGetCertificateAtIndex(trust, 0)
        }
        guard let certificate else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }

        let digest = SHA256.hash(data: SecCertificateCopyData(certificate) as Data)
            .map { String(format: "%02x", $0) }
            .joined()
        seenSha256 = digest
        if let expectedSha256, expectedSha256 != digest {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
}

private struct HealthInfo: Decodable {
    let endpoints: [String]?
}

private struct DisplaysPayload: Decodable {
    let type: String
    let displays: [RemoteDisplay]
    let selected: UInt32?
}

@MainActor
private final class PathState {
    static let shared = PathState()
    private let monitor = NWPathMonitor()
    private(set) var isCellularOnly = false

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let cellular = path.usesInterfaceType(.cellular)
                && !path.usesInterfaceType(.wifi)
                && !path.usesInterfaceType(.wiredEthernet)
            Task { @MainActor in
                self?.isCellularOnly = cellular
            }
        }
        monitor.start(queue: DispatchQueue(label: "jp.remote-canvas.path"))
    }
}

private struct PairingRequest: Encodable {
    let code: String
    let clientName: String
}

private struct PairingCredentials: Decodable {
    let accessToken: String
    let certSha256: String
    let endpoints: [String]

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        accessToken = try container.decode(String.self, forKey: .accessToken)
        certSha256 = try container.decodeIfPresent(String.self, forKey: .certSha256) ?? ""
        endpoints = try container.decodeIfPresent([String].self, forKey: .endpoints) ?? []
    }

    private enum CodingKeys: String, CodingKey {
        case accessToken
        case certSha256
        case endpoints
    }
}
