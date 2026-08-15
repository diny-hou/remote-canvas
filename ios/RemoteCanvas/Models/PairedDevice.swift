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
    var availability: Availability
    var lastSeen: Date

    init(
        id: UUID = UUID(),
        name: String,
        fingerprint: String,
        availability: Availability,
        lastSeen: Date = .now
    ) {
        self.id = id
        self.name = name
        self.fingerprint = fingerprint
        self.availability = availability
        self.lastSeen = lastSeen
    }
}

extension PairedDevice {
    static let demo = PairedDevice(
        id: UUID(uuidString: "A4D5DE90-43A9-4BBF-A28B-121086673189")!,
        name: "Home PC",
        fingerprint: "93:7A:20:5E:71:AC",
        availability: .online
    )
}
