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
        didSet { persist("requireOwnerAuthentication", requireOwnerAuthentication) }
    }
    var blockScreenCapture: Bool {
        didSet { persist("blockScreenCapture", blockScreenCapture) }
    }
    var hideScreenWhenInactive: Bool {
        didSet { persist("hideScreenWhenInactive", hideScreenWhenInactive) }
    }
    var privacyShieldWhenAway: Bool {
        didSet { persist("privacyShieldWhenAway", privacyShieldWhenAway) }
    }
    var privacyShieldAlways: Bool {
        didSet { persist("privacyShieldAlways", privacyShieldAlways) }
    }

    var usesStrongestProtection: Bool {
        requireOwnerAuthentication
            && blockScreenCapture
            && hideScreenWhenInactive
            && privacyShieldWhenAway
    }

    init(devices: [PairedDevice]? = nil) {
        self.devices = devices ?? SecureDeviceStore.load()
        self.requireOwnerAuthentication = Self.storedFlag("requireOwnerAuthentication", default: true)
        self.blockScreenCapture = Self.storedFlag("blockScreenCapture", default: true)
        self.hideScreenWhenInactive = Self.storedFlag("hideScreenWhenInactive", default: true)
        self.privacyShieldWhenAway = Self.storedFlag("privacyShieldWhenAway", default: true)
        self.privacyShieldAlways = Self.storedFlag("privacyShieldAlways", default: false)
    }

    func enableStrongestProtection() {
        requireOwnerAuthentication = true
        blockScreenCapture = true
        hideScreenWhenInactive = true
        privacyShieldWhenAway = true
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

    func mergeEndpoints(_ endpoints: [String], into id: UUID) {
        guard let index = devices.firstIndex(where: { $0.id == id }) else { return }
        var ordered = devices[index].endpoints
        for endpoint in endpoints {
            let trimmed = endpoint
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if !trimmed.isEmpty, !ordered.contains(trimmed) {
                ordered.append(trimmed)
            }
        }
        guard ordered != devices[index].endpoints else { return }
        devices[index].endpoints = ordered
        persistDevices()
    }

    func forget(_ device: PairedDevice) {
        devices.removeAll { $0.id == device.id }
        persistDevices()
    }

    private func persistDevices() {
        SecureDeviceStore.save(devices)
    }

    private func persist(_ key: String, _ value: Bool) {
        UserDefaults.standard.set(value, forKey: key)
    }

    private static func storedFlag(_ key: String, default defaultValue: Bool) -> Bool {
        UserDefaults.standard.object(forKey: key) == nil
            ? defaultValue
            : UserDefaults.standard.bool(forKey: key)
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
