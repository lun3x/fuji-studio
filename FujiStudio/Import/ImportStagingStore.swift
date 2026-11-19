import CryptoKit
import Darwin
import Foundation
import FujiCameraCore

enum ImportStagingError: Error, Equatable, Sendable {
    case unknownLength, lengthOverflow, lengthMismatch, unsupportedFormat, invalidPath, originalChanged
    case insufficientCapacity(required: UInt64, available: UInt64)
}

struct ImportStagingStore: Sendable {
    private let disk: ImportDisk
    private let beforeChunkWrite: @Sendable () throws -> Void
    private let availableCapacity: @Sendable () throws -> UInt64?

    init(root: URL = ImportDisk.root("staging"), beforeChunkWrite: @escaping @Sendable () throws -> Void = {},
         availableCapacity: (@Sendable () throws -> UInt64?)? = nil) throws {
        disk = try ImportDisk(root: root)
        self.beforeChunkWrite = beforeChunkWrite
        let stagingPath = disk.root.path
        self.availableCapacity = availableCapacity ?? {
            let directory = URL(fileURLWithPath: stagingPath, isDirectory: true)
            let values = try directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey,
                                                                 .volumeAvailableCapacityKey])
            return (values.volumeAvailableCapacityForImportantUsage ?? values.volumeAvailableCapacity.map(Int64.init))
                .flatMap(UInt64.init(exactly:))
        }
    }

    var cameraCacheDirectory: URL { disk.root.deletingLastPathComponent().appending(path: "camera-originals") }

    static func requiredCapacity(stagingByteLengths: [UInt64], photoCopyByteLengths: [UInt64]) throws -> UInt64 {
        var total: UInt64 = 64 * 1024 * 1024
        for length in stagingByteLengths + photoCopyByteLengths {
            guard length > 0 else { throw ImportStagingError.unknownLength }
            let (required, overflow) = total.addingReportingOverflow(length)
            guard !overflow else { throw ImportStagingError.lengthOverflow }
            total = required
        }
        return total
    }

    /// Estimate headroom for new staged files and the Photos copies of the active capture.
    func preflight(stagingByteLengths: [UInt64], photoCopyByteLengths: [UInt64]) throws {
        let required = try Self.requiredCapacity(stagingByteLengths: stagingByteLengths, photoCopyByteLengths: photoCopyByteLengths)
        if let capacity = try availableCapacity(), capacity < required {
            throw ImportStagingError.insufficientCapacity(required: required, available: capacity)
        }
    }

    func write(object: WirelessObjectDescriptor, session: any WirelessTransferSession,
               progress: @escaping @Sendable (UInt64) async -> Void = { _ in }) async throws -> StagedOriginal {
        guard let role = ImportOriginalRole(object.format) else { throw ImportStagingError.unsupportedFormat }
        guard object.byteLength > 0 else { throw ImportStagingError.unknownLength }
        guard object.byteLength <= UInt64(Int64.max) else { throw ImportStagingError.lengthOverflow }
        let capabilities = try await session.capabilities()
        if let failure = capabilities.originalSizeFailure { throw failure }
        try Task.checkCancellation()

        let id = UUID().uuidString
        let relativePath = id + "." + role.fileExtension
        let (partial, handle) = try disk.createFile(named: id + ".part")
        defer { try? FileManager.default.removeItem(at: partial) }
        defer { try? handle.close() }
        let writer = OriginalStreamVerifier(handle: handle, expected: object.byteLength, beforeWrite: beforeChunkWrite)
        let sha256 = try await stream(object, from: session, into: writer, progress: progress)
        let metadata = try OriginalImportValidator.inspect(file: partial, object: object, transferMode: capabilities.mode)
        try Task.checkCancellation()
        let destination = disk.root.appendingPathComponent(relativePath)
        try disk.rename(partial, to: destination, replacing: false)
        do {
            try disk.synchronizeDirectory()
        } catch {
            try? disk.unlink(destination)
            throw error
        }
        return .init(relativePath: relativePath,
                     fingerprint: .init(role: role, originalFilename: object.filename,
                                        byteCount: object.byteLength, sha256: sha256),
                     metadata: metadata, descriptor: object, verifiedTransferMode: capabilities.mode)
    }

    /// Each owner gets a separate filesystem link so journal cleanup cannot remove a cached original.
    func link(_ original: StagedOriginal, from source: URL, for object: WirelessObjectDescriptor) throws -> StagedOriginal {
        let path = UUID().uuidString + "." + original.role.fileExtension
        let destination = disk.root.appendingPathComponent(path)
        try FileManager.default.linkItem(at: source, to: destination)
        do { try disk.synchronizeDirectory() }
        catch { try? disk.unlink(destination); throw error }
        return .init(relativePath: path, fingerprint: original.fingerprint, metadata: original.metadata,
                     descriptor: object, verifiedTransferMode: original.verifiedTransferMode)
    }

    /// Resolve a resource for reading. Only the app-generated opaque names are accepted.
    func fileURL(for original: StagedOriginal) throws -> URL {
        guard Self.isOriginalPath(original.relativePath, role: original.role) else {
            throw ImportStagingError.invalidPath
        }
        return try fileURL(forRelativePath: original.relativePath)
    }

    func fileURL(forRelativePath path: String) throws -> URL {
        guard Self.isOriginalPath(path, role: .raf) || Self.isOriginalPath(path, role: .jpeg) else {
            throw ImportStagingError.invalidPath
        }
        let url = disk.root.appendingPathComponent(path)
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else { throw ImportStagingError.invalidPath }
        return url
    }

    /// The caller has established a unique match from a new inventory for the admitted
    /// camera and verified transfer mode. Handles and thumbnail flags are session-local.
    func reuse(_ original: StagedOriginal, frozen: WirelessObjectDescriptor,
               matching current: WirelessObjectDescriptor) throws -> StagedOriginal {
        guard frozen.matchesOriginal(current), original.describes(frozen) else { throw ImportStagingError.originalChanged }
        try checkIntegrity(original)
        return original
    }

    /// ObjectInfo does not contain a card identity or checksum. On a new session,
    /// compare the complete remote fingerprint before reusing the already-staged file.
    func rebind(_ original: StagedOriginal, to object: WirelessObjectDescriptor, session: any WirelessTransferSession,
                progress: @escaping @Sendable (UInt64) async -> Void) async throws -> StagedOriginal {
        let capabilities = try await session.capabilities()
        if let failure = capabilities.originalSizeFailure { throw failure }
        guard capabilities.mode == original.verifiedTransferMode else {
            throw WirelessFailure.originalSizeUnavailable
        }
        guard original.describes(object) else { throw ImportStagingError.originalChanged }
        let verifier = OriginalStreamVerifier(expected: original.byteCount)
        guard try await stream(object, from: session, into: verifier, progress: progress) == original.sha256 else {
            throw ImportStagingError.originalChanged
        }
        return .init(relativePath: original.relativePath, fingerprint: original.fingerprint,
                     metadata: original.metadata, descriptor: object, verifiedTransferMode: original.verifiedTransferMode)
    }

    private func stream(_ object: WirelessObjectDescriptor, from session: any WirelessTransferSession,
                        into verifier: OriginalStreamVerifier,
                        progress: @escaping @Sendable (UInt64) async -> Void) async throws -> String {
        try Task.checkCancellation()
        try await session.download(object) { data in
            let total = try await verifier.append(data)
            await progress(total)
        }
        try Task.checkCancellation()
        return try await verifier.finish()
    }

    func checkIntegrity(_ original: StagedOriginal) throws {
        let url = try fileURL(for: original)
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize
        guard size.flatMap(UInt64.init(exactly:)) == original.byteCount,
              try ResourceChecksum.sha256(url) == original.sha256 else { throw ImportStagingError.originalChanged }
    }

    func remove(_ original: StagedOriginal) throws {
        guard Self.isOriginalPath(original.relativePath, role: original.role) else {
            throw ImportStagingError.invalidPath
        }
        try disk.unlink(disk.root.appendingPathComponent(original.relativePath))
        try disk.synchronizeDirectory()
    }

    /// Run during recovery before starting transfers. Partials are never resumed.
    func removeInterruptedDownloads() throws {
        let files = try FileManager.default.contentsOfDirectory(at: disk.root, includingPropertiesForKeys: nil)
        for file in files where Self.isGeneratedPath(file.lastPathComponent, extension: "part") {
            try disk.unlink(file)
        }
        try disk.synchronizeDirectory()
    }

    func removeUnreferencedOriginals(retaining originals: Set<String>) throws {
        let files = try FileManager.default.contentsOfDirectory(at: disk.root, includingPropertiesForKeys: nil)
        for file in files {
            let name = file.lastPathComponent
            guard !originals.contains(name),
                  Self.isOriginalPath(name, role: .raf) || Self.isOriginalPath(name, role: .jpeg) else { continue }
            try disk.unlink(file)
        }
        try disk.synchronizeDirectory()
    }

    static func isOriginalPath(_ name: String, role: ImportOriginalRole) -> Bool {
        isGeneratedPath(name, extension: role.fileExtension)
    }

    private static func isGeneratedPath(_ name: String, extension ext: String) -> Bool {
        let pieces = name.split(separator: ".", omittingEmptySubsequences: false)
        guard pieces.count == 2, pieces[1] == ext,
              let id = UUID(uuidString: String(pieces[0])) else { return false }
        return id.uuidString == pieces[0]
    }
}

/// Count and hash bounded transfer chunks, optionally writing a new staged original.
actor OriginalStreamVerifier {
    private let handle: FileHandle?
    private let expected: UInt64
    private let beforeWrite: @Sendable () throws -> Void
    private var length: UInt64 = 0
    private var hash = SHA256()
    private var completed = false

    init(handle: FileHandle? = nil, expected: UInt64, beforeWrite: @escaping @Sendable () throws -> Void = {}) {
        self.handle = handle
        self.expected = expected
        self.beforeWrite = beforeWrite
    }

    func append(_ data: Data) throws -> UInt64 {
        guard !completed else { throw ImportStagingError.lengthMismatch }
        do {
            try Task.checkCancellation()
            guard UInt64(data.count) <= expected - length else { throw ImportStagingError.lengthMismatch }
            try beforeWrite()
            try handle?.write(contentsOf: data)
            hash.update(data: data)
            length += UInt64(data.count)
            return length
        } catch {
            completed = true
            throw error
        }
    }

    func finish() throws -> String {
        guard !completed, length == expected else { throw ImportStagingError.lengthMismatch }
        completed = true
        try handle?.synchronize()
        try handle?.close()
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// Both durable stores live under Application Support. The system can reclaim caches
/// without removing import evidence. Files and directories are protected and excluded from backups.
struct ImportDisk: Sendable {
    let root: URL

    static func root(_ component: String) -> URL {
        URL.applicationSupportDirectory
            .appendingPathComponent("FujiStudio/wireless-import", isDirectory: true)
            .appendingPathComponent(component, isDirectory: true)
    }

    init(root: URL) throws {
        guard root.isFileURL else { throw ImportStagingError.invalidPath }
        let manager = FileManager.default
        var existingAncestor = root
        while !manager.fileExists(atPath: existingAncestor.path) {
            existingAncestor.deleteLastPathComponent()
        }
        try manager.createDirectory(at: root, withIntermediateDirectories: true, attributes: [
            .posixPermissions: 0o700,
            .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication
        ])
        let values = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else { throw ImportStagingError.invalidPath }
        var canonical = root.resolvingSymlinksInPath()
        try manager.setAttributes([.posixPermissions: 0o700,
                                   .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                                  ofItemAtPath: canonical.path)
        var policy = URLResourceValues()
        policy.isExcludedFromBackup = true
        try canonical.setResourceValues(policy)
        // A fresh install can create several directory entries before its first write.
        // Flush each new entry in its parent so a successful journal flush survives relaunch.
        let ancestorPath = existingAncestor.resolvingSymlinksInPath().path
        var directory = canonical
        while directory.path != ancestorPath {
            directory.deleteLastPathComponent()
            try Self.synchronizeDirectory(at: directory)
        }
        self.root = canonical
    }

    func createFile(named name: String) throws -> (URL, FileHandle) {
        let url = root.appendingPathComponent(name)
        let descriptor = open(url.path, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        guard descriptor >= 0 else { throw Self.fileError() }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            try FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)
            return (url, handle)
        } catch {
            try? handle.close()
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }

    func rename(_ from: URL, to destination: URL, replacing: Bool = true) throws {
        let result = replacing ? Darwin.rename(from.path, destination.path)
            : renamex_np(from.path, destination.path, UInt32(RENAME_EXCL))
        guard result == 0 else { throw Self.fileError() }
    }

    func unlink(_ file: URL) throws {
        guard Darwin.unlink(file.path) == 0 || errno == ENOENT else { throw Self.fileError() }
    }

    func synchronizeDirectory() throws { try Self.synchronizeDirectory(at: root) }

    private static func synchronizeDirectory(at directory: URL) throws {
        let descriptor = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw Self.fileError() }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else { throw Self.fileError() }
    }

    private static func fileError() -> POSIXError { POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
}
