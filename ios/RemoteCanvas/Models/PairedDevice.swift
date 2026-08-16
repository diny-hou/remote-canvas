import Foundation

struct PairedDevice: Identifiable, Hashable, Codable, Sendable {
    enum Availability: String, Codable, Sendable {
        case online
        case offline
        case connecting
    }

    let id: UUID
    var name: String
    var fingerprint: String
    var endpoint: String
    var endpoints: [String]
    var certSha256: String
    var accessToken: String
    var availability: Availability
    var lastSeen: Date

    init(
        id: UUID = UUID(),
        name: String,
        fingerprint: String,
        endpoint: String,
        endpoints: [String] = [],
        certSha256: String,
        accessToken: String,
        availability: Availability,
        lastSeen: Date = .now
    ) {
        self.id = id
        self.name = name
        self.fingerprint = fingerprint
        self.endpoint = endpoint
        self.endpoints = endpoints.isEmpty ? [endpoint] : endpoints
        self.certSha256 = certSha256
        self.accessToken = accessToken
        self.availability = availability
        self.lastSeen = lastSeen
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        fingerprint = try container.decode(String.self, forKey: .fingerprint)
        endpoint = try container.decode(String.self, forKey: .endpoint)
        endpoints = try container.decodeIfPresent([String].self, forKey: .endpoints) ?? [endpoint]
        certSha256 = try container.decodeIfPresent(String.self, forKey: .certSha256) ?? ""
        accessToken = try container.decode(String.self, forKey: .accessToken)
        availability = try container.decode(Availability.self, forKey: .availability)
        lastSeen = try container.decode(Date.self, forKey: .lastSeen)
    }

    var preferredEndpoints: [String] {
        var ordered: [String] = []
        for candidate in endpoints + [endpoint] {
            let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty, !ordered.contains(trimmed) {
                ordered.append(trimmed)
            }
        }
        return ordered.sorted { lhs, rhs in
            lanRank(lhs) < lanRank(rhs)
        }
    }

    private func lanRank(_ value: String) -> Int {
        guard let host = URL(string: value)?.host else { return 2 }
        if host.hasPrefix("100.") { return 1 }
        return 0
    }
}

extension PairedDevice {
    static let demo = PairedDevice(
        id: UUID(uuidString: "A4D5DE90-43A9-4BBF-A28B-121086673189")!,
        name: "Home PC",
        fingerprint: "93:7A:20:5E:71:AC",
        endpoint: "https://192.168.1.10:47831",
        endpoints: ["https://192.168.1.10:47831", "https://100.64.0.2:47831"],
        certSha256: "00",
        accessToken: "preview-access-token",
        availability: .online
    )
}
