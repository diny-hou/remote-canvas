import Foundation
import LocalAuthentication
import Observation
import Security

@MainActor
@Observable
final class AppModel {
    enum PresentedSheet: Identifiable {
        case pairDevice
        case settings

        var id: String {
            switch self {
            case .pairDevice: "pair-device"
            case .settings: "settings"
            }
        }
    }

    var devices: [PairedDevice]
    var presentedSheet: PresentedSheet?
    var activeDevice: PairedDevice?
    var requireOwnerAuthentication: Bool {
        didSet {
            UserDefaults.standard.set(requireOwnerAuthentication, forKey: "requireOwnerAuthentication")
        }
    }

    init(devices: [PairedDevice]? = nil) {
        self.devices = devices ?? SecureDeviceStore.load()
        if UserDefaults.standard.object(forKey: "requireOwnerAuthentication") == nil {
            self.requireOwnerAuthentication = true
        } else {
            self.requireOwnerAuthentication = UserDefaults.standard.bool(forKey: "requireOwnerAuthentication")
        }
    }

    func registerDevice(
        name: String,
        endpoints: [String],
        accessToken: String,
        certSha256: String
    ) throws {
        let normalizedToken = accessToken.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedEndpoints = endpoints
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/")) }
            .filter { !$0.isEmpty }
        let pin = certSha256.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        guard normalizedToken.count >= 12,
              !pin.isEmpty,
              let primary = normalizedEndpoints.first,
              let url = URL(string: primary),
              ["http", "https"].contains(url.scheme?.lowercased()) else {
            throw PairingError.invalidCode
        }

        let suffix = pin.suffix(12)
        let fingerprint = stride(from: 0, to: suffix.count, by: 2).map { offset -> String in
            let start = suffix.index(suffix.startIndex, offsetBy: offset)
            let end = suffix.index(start, offsetBy: min(2, suffix.distance(from: start, to: suffix.endIndex)))
            return String(suffix[start..<end]).uppercased()
        }.joined(separator: ":")

        devices.append(
            PairedDevice(
                name: name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Windows PC" : name,
                fingerprint: fingerprint,
                endpoint: primary,
                endpoints: normalizedEndpoints,
                certSha256: pin,
                accessToken: normalizedToken,
                availability: .online
            )
        )
        persistDevices()
    }

    func connect(to device: PairedDevice) async throws {
        if requireOwnerAuthentication {
            let context = LAContext()
            context.localizedCancelTitle = "Cancel"
            try await context.evaluatePolicy(
                .deviceOwnerAuthentication,
                localizedReason: "Connect to this PC"
            )
        }
        activeDevice = device
    }

    func disconnect() {
        activeDevice = nil
    }

    func forget(_ device: PairedDevice) {
        devices.removeAll { $0.id == device.id }
        persistDevices()
    }

    private func persistDevices() {
        SecureDeviceStore.save(devices)
    }
}

enum PairingError: LocalizedError {
    case invalidCode

    var errorDescription: String? {
        switch self {
        case .invalidCode:
            "Invalid endpoint or pairing key."
        }
    }
}

private enum SecureDeviceStore {
    private static let service = "jp.remote-canvas.app.paired-devices"
    private static let account = "default"

    static func load() -> [PairedDevice] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let devices = try? JSONDecoder().decode([PairedDevice].self, from: data) else {
            return []
        }
        return devices
    }

    static func save(_ devices: [PairedDevice]) {
        guard let data = try? JSONEncoder().encode(devices) else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            attributes.forEach { item[$0.key] = $0.value }
            SecItemAdd(item as CFDictionary, nil)
        }
    }
}
