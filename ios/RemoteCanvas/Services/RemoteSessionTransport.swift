import CryptoKit
import Foundation
import Observation
import Security
import UIKit

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
    var isUsingLAN: Bool { get }
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
    var statusText: String { "Preview" }
    var isUsingLAN: Bool { true }
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

    var latestFrame: Data?
    var statusText = "Waiting"
    var isConnected = false
    var isUsingLAN = false

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
        let (temporaryURL, response) = try await session.download(for: request)
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
        let (responseData, response) = try await session.upload(for: request, fromFile: localURL)
        try validate(response: response, data: responseData)
    }

    private func connectWithRetry(resetBackoff: Bool) async {
        var delay: UInt64 = resetBackoff ? 400_000_000 : 1_000_000_000
        while shouldReconnect && !Task.isCancelled {
            if await openSocket() {
                receiveTask?.cancel()
                receiveTask = Task { [weak self] in
                    await self?.receiveFrames()
                }
                return
            }
            statusText = "Reconnecting"
            try? await Task.sleep(nanoseconds: delay)
            delay = min(delay * 2, 4_000_000_000)
        }
    }

    private func openSocket() async -> Bool {
        for endpoint in device.preferredEndpoints {
            guard await probe(endpoint), let url = websocketURL(from: endpoint) else { continue }
            var request = URLRequest(url: url, timeoutInterval: 10)
            applyAuth(&request, path: isLikelyLAN(endpoint) ? "lan" : "tailscale")
            let task = session.webSocketTask(with: request)
            socket = task
            task.resume()
            activeEndpoint = endpoint
            isConnected = true
            isUsingLAN = isLikelyLAN(endpoint)
            statusText = isUsingLAN ? "LAN" : "Remote"
            return true
        }
        socket = nil
        isConnected = false
        return false
    }

    private func probe(_ endpoint: String) async -> Bool {
        guard var components = URLComponents(string: endpoint) else { return false }
        components.path = "/health"
        guard let url = components.url else { return false }
        var request = URLRequest(url: url, timeoutInterval: isLikelyLAN(endpoint) ? 3 : 8)
        do {
            let (_, response) = try await session.data(for: request)
            return ((response as? HTTPURLResponse)?.statusCode ?? 500) < 300
        } catch {
            return false
        }
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
                case .string:
                    break
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
