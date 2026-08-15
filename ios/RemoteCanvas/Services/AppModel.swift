import Foundation
import Observation

@MainActor
@Observable
final class AppModel {
    enum PresentedSheet: Identifiable {
        case pairDevice

        var id: String { "pair-device" }
    }

    var devices: [PairedDevice]
    var presentedSheet: PresentedSheet?
    var activeDevice: PairedDevice?
    var requireOwnerAuthentication = true
    var preferDirectConnection = true
    var allowRelayFallback = false

    init(devices: [PairedDevice] = [.demo]) {
        self.devices = devices
    }

    func registerDemoDevice(name: String, code: String) throws {
        let normalizedCode = code
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()

        guard normalizedCode.count >= 6 else {
            throw PairingError.invalidCode
        }

        let suffix = normalizedCode.unicodeScalars
            .map { String(format: "%02X", $0.value) }
            .joined()
            .suffix(12)
        let fingerprint = stride(from: 0, to: suffix.count, by: 2).map { offset -> String in
            let start = suffix.index(suffix.startIndex, offsetBy: offset)
            let end = suffix.index(start, offsetBy: min(2, suffix.distance(from: start, to: suffix.endIndex)))
            return String(suffix[start..<end])
        }.joined(separator: ":")

        devices.append(
            PairedDevice(
                name: name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Windows PC" : name,
                fingerprint: fingerprint,
                availability: .online
            )
        )
    }

    func connect(to device: PairedDevice) {
        activeDevice = device
    }

    func disconnect() {
        activeDevice = nil
    }

    func forget(_ device: PairedDevice) {
        devices.removeAll { $0.id == device.id }
    }
}

enum PairingError: LocalizedError {
    case invalidCode

    var errorDescription: String? {
        switch self {
        case .invalidCode:
            "ペアリングコードは6文字以上で入力してください。"
        }
    }
}
