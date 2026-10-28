import FujiCameraCore
#if DEBUG
import Foundation
import Darwin

/// A retained claim is never reclaimed by the app, including interrupted or malformed runs.
/// Merely creating the directory consumes the UUID; a crash before the receipt is safe.
struct LiveAcceptanceRun {
    let directory: URL
    let id: UUID
    init(root: URL, id: UUID) { self.id = id; directory = root.appendingPathComponent(id.uuidString, isDirectory: true) }
    func claim() throws -> Bool {
        let parent = directory.deletingLastPathComponent()
        var missingParents: [URL] = [], ancestor = parent
        while !FileManager.default.fileExists(atPath: ancestor.path) {
            missingParents.append(ancestor); ancestor = ancestor.deletingLastPathComponent()
        }
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.protectionKey: FileProtectionType.complete])
        // FileManager.createDirectory is idempotent; mkdir supplies the required exclusive claim.
        guard mkdir(directory.path, 0o700) == 0 else {
            if errno == EEXIST { return false }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        try write(id, name: "claim.json")
        // Persist every newly created ancestor entry too, before an export can be armed.
        for path in missingParents + [ancestor] { try Self.synchronize(path) }
        return true
    }
    func write<T: Encodable>(_ value: T, name: String) throws {
        let file = directory.appendingPathComponent(name)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(value).write(to: file, options: [.atomic, .completeFileProtection])
        try Self.synchronize(file)
        try Self.synchronize(directory)
    }
    func read<T: Decodable>(_ type: T.Type, name: String) throws -> T {
        let file = directory.appendingPathComponent(name)
        guard let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 2_097_152 else { throw CocoaError(.fileReadCorruptFile) }
        return try JSONDecoder().decode(type, from: Data(contentsOf: file))
    }
    private static func synchronize(_ url: URL) throws {
        let descriptor = open(url.path, O_RDONLY)
        guard descriptor >= 0 else { throw POSIXError(.EIO) }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else { throw POSIXError(.EIO) }
    }
}
#endif
