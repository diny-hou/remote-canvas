import Compression
import Foundation
import QuickLook
import UniformTypeIdentifiers

enum FileKind {
    case image
    case video
    case audio
    case archive
    case document
    case text
    case other

    init(url: URL) {
        self.init(fileName: url.lastPathComponent)
    }

    init(fileName: String) {
        switch URL(fileURLWithPath: fileName).pathExtension.lowercased() {
        case "jpg", "jpeg", "png", "gif", "heic", "heif", "webp", "bmp", "tif", "tiff",
             "jxl", "avif", "ico", "icns", "tga", "psd", "svg":
            self = .image
        case "mp4", "mov", "m4v", "mkv", "avi", "webm", "wmv", "flv", "ts", "m2ts", "mts",
             "mpeg", "mpg", "mpe", "3gp", "3g2", "ogv", "ogg", "vob", "asf", "f4v", "rm",
             "rmvb", "divx", "m2v", "mpv", "ogm", "mxf", "dv", "amv", "m4p", "qt", "dat":
            self = .video
        case "mp3", "m4a", "aac", "wav", "flac", "aiff", "aif", "caf", "oga", "wma", "opus",
             "ac3", "dts", "mka", "ape", "m4b", "amr", "mid", "midi":
            self = .audio
        case "zip", "cbz", "cbr":
            self = .archive
        case "txt", "md", "json", "xml", "csv", "log", "yml", "yaml", "toml", "ini", "conf",
             "swift", "rs", "py", "js", "tsx", "html", "css", "c", "h", "cpp", "java", "kt",
             "srt", "ass", "ssa", "vtt", "sub", "lrc":
            self = .text
        default:
            self = .document
        }
    }

    var symbolName: String {
        switch self {
        case .image: "photo"
        case .video: "play.rectangle"
        case .audio: "waveform"
        case .archive: "doc.zipper"
        case .document: "doc.richtext"
        case .text: "doc.text"
        case .other: "doc"
        }
    }

    static func isImage(fileName: String) -> Bool {
        FileKind(fileName: fileName) == .image
    }

    var isPlayable: Bool {
        self == .video || self == .audio
    }
}

struct MediaPlaylistItem: Identifiable, Hashable, Sendable {
    var id: String { remotePath ?? localURL?.path ?? name }
    let name: String
    let remotePath: String?
    var localURL: URL?

    var remoteEntry: RemoteFileEntry? {
        guard let remotePath else { return nil }
        return RemoteFileEntry(
            name: name,
            path: remotePath,
            isDirectory: false,
            size: 0,
            modifiedUnixSeconds: 0
        )
    }
}

enum FilePreviewItem: Identifiable {
    case comic(title: String, pages: [URL], startIndex: Int)
    case media(playlist: [MediaPlaylistItem], startIndex: Int)
    case document(URL)
    case archive(title: String, files: [URL])

    var id: String {
        switch self {
        case .comic(_, let pages, let start):
            pages.first?.path ?? "comic-\(start)"
        case .archive(_, let files):
            files.first?.path ?? "archive"
        case .media(let playlist, let start):
            playlist.first?.id ?? "media-\(start)"
        case .document(let url):
            url.path
        }
    }
}

enum ZipArchive {
    private static let maxFiles = 20_000
    private static let maxUncompressed = 8 * 1024 * 1024 * 1024
    private static let maxEntry = 512 * 1024 * 1024

    static func extract(from archive: URL, to directory: URL) throws -> [URL] {
        let data = try Data(contentsOf: archive, options: .mappedIfSafe)
        let entries = try readCentralDirectory(in: data)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var files: [URL] = []
        var total: Int = 0
        for entry in entries {
            if files.count >= maxFiles { break }
            if entry.isDirectory { continue }
            let name = entry.name
            if shouldSkip(name) { continue }
            guard entry.uncompressedSize <= maxEntry else { continue }
            total += entry.uncompressedSize
            if total > maxUncompressed { throw ZipError.tooLarge }
            let bytes = try extractEntry(entry, from: data)
            let destination = sanitizedURL(for: name, in: directory)
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try bytes.write(to: destination, options: .atomic)
            files.append(destination)
        }
        return files.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    static func imagePages(in files: [URL]) -> [URL] {
        files.filter { FileKind.isImage(fileName: $0.lastPathComponent) }
    }

    private static func shouldSkip(_ name: String) -> Bool {
        let lowered = name.lowercased()
        return name.hasPrefix("__MACOSX")
            || name.contains("/__MACOSX")
            || lowered.hasSuffix(".ds_store")
            || name.hasSuffix("/")
    }

    private static func sanitizedURL(for name: String, in directory: URL) -> URL {
        let parts = name.split(separator: "/").map(String.init).filter { $0 != ".." && $0 != "." && !$0.isEmpty }
        return parts.reduce(directory) { $0.appendingPathComponent($1) }
    }

    private static func readCentralDirectory(in data: Data) throws -> [ZipEntry] {
        guard let eocd = findEOCD(in: data) else { throw ZipError.invalid }
        let count = Int(readU16(data, eocd + 10))
        var offset = Int(readU32(data, eocd + 16))
        var entries: [ZipEntry] = []
        entries.reserveCapacity(count)
        for _ in 0..<count {
            guard offset + 46 <= data.count, readU32(data, offset) == 0x0201_4b50 else { throw ZipError.invalid }
            let method = readU16(data, offset + 10)
            let flags = readU16(data, offset + 8)
            let compressed = Int(readU32(data, offset + 20))
            let uncompressed = Int(readU32(data, offset + 24))
            let nameLen = Int(readU16(data, offset + 28))
            let extraLen = Int(readU16(data, offset + 30))
            let commentLen = Int(readU16(data, offset + 32))
            let localOffset = Int(readU32(data, offset + 42))
            let nameStart = offset + 46
            let nameEnd = nameStart + nameLen
            guard nameEnd <= data.count else { throw ZipError.invalid }
            let name = String(data: data[nameStart..<nameEnd], encoding: .utf8)
                ?? String(data: data[nameStart..<nameEnd], encoding: .shiftJIS)
                ?? "file"
            entries.append(
                ZipEntry(
                    name: name,
                    method: method,
                    flags: flags,
                    compressedSize: compressed,
                    uncompressedSize: uncompressed,
                    localHeaderOffset: localOffset,
                    isDirectory: name.hasSuffix("/")
                )
            )
            offset = nameEnd + extraLen + commentLen
        }
        return entries
    }

    private static func extractEntry(_ entry: ZipEntry, from data: Data) throws -> Data {
        var cursor = entry.localHeaderOffset
        guard cursor + 30 <= data.count, readU32(data, cursor) == 0x0403_4b50 else { throw ZipError.invalid }
        let nameLen = Int(readU16(data, cursor + 26))
        let extraLen = Int(readU16(data, cursor + 28))
        cursor += 30 + nameLen + extraLen
        let end = cursor + entry.compressedSize
        guard end <= data.count else { throw ZipError.invalid }
        let payload = data[cursor..<end]
        switch entry.method {
        case 0:
            return Data(payload)
        case 8:
            return try inflate(Data(payload), uncompressedSize: max(entry.uncompressedSize, 1))
        default:
            throw ZipError.unsupported
        }
    }

    private static func inflate(_ source: Data, uncompressedSize: Int) throws -> Data {
        if let decoded = decodeZlib(source, uncompressedSize: uncompressedSize) {
            return decoded
        }
        var wrapped = Data([0x78, 0x01])
        wrapped.append(source)
        if let decoded = decodeZlib(wrapped, uncompressedSize: uncompressedSize) {
            return decoded
        }
        throw ZipError.inflateFailed
    }

    private static func decodeZlib(_ source: Data, uncompressedSize: Int) -> Data? {
        var destination = Data(count: max(uncompressedSize, source.count * 4))
        let written = destination.withUnsafeMutableBytes { dest in
            source.withUnsafeBytes { src in
                compression_decode_buffer(
                    dest.bindMemory(to: UInt8.self).baseAddress!,
                    dest.count,
                    src.bindMemory(to: UInt8.self).baseAddress!,
                    source.count,
                    nil,
                    COMPRESSION_ZLIB
                )
            }
        }
        guard written > 0 else { return nil }
        destination.count = written
        return destination
    }

    private static func findEOCD(in data: Data) -> Int? {
        let start = max(0, data.count - 65_535 - 22)
        var index = data.count - 22
        while index >= start {
            if readU32(data, index) == 0x0605_4b50 {
                return index
            }
            index -= 1
        }
        return nil
    }

    private static func readU16(_ data: Data, _ offset: Int) -> UInt16 {
        UInt16(data[offset]) | UInt16(data[offset + 1]) << 8
    }

    private static func readU32(_ data: Data, _ offset: Int) -> UInt32 {
        UInt32(data[offset])
            | UInt32(data[offset + 1]) << 8
            | UInt32(data[offset + 2]) << 16
            | UInt32(data[offset + 3]) << 24
    }
}

enum ZipError: LocalizedError {
    case invalid
    case unsupported
    case tooLarge
    case inflateFailed

    var errorDescription: String? {
        switch self {
        case .invalid: "This ZIP file is damaged or unreadable."
        case .unsupported: "This archive uses a compression method that is not supported. Use ZIP or CBZ."
        case .tooLarge: "This archive is too large to open on the phone."
        case .inflateFailed: "Could not unpack this ZIP file."
        }
    }
}

private struct ZipEntry {
    let name: String
    let method: UInt16
    let flags: UInt16
    let compressedSize: Int
    let uncompressedSize: Int
    let localHeaderOffset: Int
    let isDirectory: Bool
}

func readTextFile(_ url: URL) -> String? {
    let encodings: [String.Encoding] = [
        .utf8, .utf16LittleEndian, .utf16BigEndian, .shiftJIS, .japaneseEUC, .isoLatin1
    ]
    for encoding in encodings {
        if let text = try? String(contentsOf: url, encoding: encoding) {
            return text
        }
    }
    return nil
}

func fileLooksLikeText(_ url: URL) -> Bool {
    if FileKind(url: url) == .text { return true }
    guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
    defer { try? handle.close() }
    let prefix = (try? handle.read(upToCount: 2048)) ?? Data()
    if prefix.isEmpty { return true }
    if prefix.contains(0) { return false }
    return encodingsThatDecode(prefix) != nil
}

private func encodingsThatDecode(_ data: Data) -> String.Encoding? {
    let encodings: [String.Encoding] = [.utf8, .utf16LittleEndian, .utf16BigEndian, .shiftJIS, .japaneseEUC]
    return encodings.first { String(data: data, encoding: $0) != nil }
}

func hexPreview(of url: URL, limit: Int = 4096) -> String {
    guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
    defer { try? handle.close() }
    let data = (try? handle.read(upToCount: limit)) ?? Data()
    return data.enumerated().map { index, byte in
        let hex = String(format: "%02X", byte)
        return (index + 1) % 16 == 0 ? hex + "\n" : hex + " "
    }.joined()
}

@MainActor
func canQuickLook(_ url: URL) -> Bool {
    QLPreviewController.canPreview(url as QLPreviewItem)
}
