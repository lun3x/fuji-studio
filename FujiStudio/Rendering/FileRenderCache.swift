import Foundation
import CryptoKit

enum RenderCacheError: Error, Sendable, Equatable { case invalidEntry, missing, storage, pinConflict }

/// Committed directories contain both provenance and the complete JPEG. Purgeable entries and
/// durable pending-save pins live in separate roots. Callers must journal the URL returned by pin.
actor FileRenderCache {
    typealias JPEGValidation = @Sendable (CameraJPEG) throws -> Void
    private let validateJPEG: JPEGValidation
    private struct Entry {
        let jpeg: CameraJPEG
        let bytes: Int
        let pinned: Bool
        var accessed: Date
    }
    private let directory: URL, pinnedDirectory: URL, budget: Int
    private var entries: [RenderKey: Entry]
    // Durable directory names reserve journal-owned identities even when pixels/metadata cannot
    // be validated or indexed. Only explicit unpin releases a reservation.
    private var pinnedReservations: Set<String>

    init(directory: URL, pinnedDirectory: URL, unpinnedBudget: Int = 1_073_741_824,
         validateJPEG: @escaping JPEGValidation = FileRenderCache.validateCameraJPEG) throws {
        guard unpinnedBudget > 0,
              !pinnedDirectory.standardizedFileURL.path.hasPrefix(directory.standardizedFileURL.path + "/"),
              directory.standardizedFileURL != pinnedDirectory.standardizedFileURL else { throw RenderCacheError.storage }
        self.directory = directory; self.pinnedDirectory = pinnedDirectory; budget = unpinnedBudget; self.validateJPEG = validateJPEG
        var loaded: [RenderKey: Entry] = [:]
        var reservations = Set<String>()
        for (root, pinned) in [(directory, false), (pinnedDirectory, true)] {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            for folder in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
                if folder.pathExtension == "partial" { try? FileManager.default.removeItem(at: folder); continue }
                if pinned { reservations.insert(folder.lastPathComponent) }
                let manifest = folder.appendingPathComponent("entry.json")
                guard let data = try? Data(contentsOf: manifest),
                      let original = try? JSONDecoder().decode(CameraJPEG.self, from: data),
                      folder.lastPathComponent == (try? Self.identifier(original.key)),
                      let size = try? Self.validate(original.relocated(to: folder.appendingPathComponent("image.JPG")), key: original.key, validateJPEG: validateJPEG) else {
                    // Unknown durable files may belong to a journal; only purge malformed cache entries.
                    if !pinned { try? FileManager.default.removeItem(at: folder) }; continue
                }
                let jpeg = original.relocated(to: folder.appendingPathComponent("image.JPG"))
                let accessed = (try? folder.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                loaded[jpeg.key] = Entry(jpeg: jpeg, bytes: size, pinned: pinned, accessed: accessed)
            }
        }
        // Crash after durable commit but before purgeable cleanup must not leave two full-size files.
        for entry in loaded.values where entry.pinned {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(Self.identifier(entry.jpeg.key)))
        }
        entries = loaded; pinnedReservations = reservations
        var total = loaded.values.filter { !$0.pinned }.reduce(0) { $0 + $1.bytes }
        for entry in loaded.values.filter({ !$0.pinned }).sorted(by: { $0.accessed < $1.accessed }) where total > unpinnedBudget {
            try? FileManager.default.removeItem(at: entry.jpeg.fileURL.deletingLastPathComponent())
            entries[entry.jpeg.key] = nil; total -= entry.bytes
        }
    }

    func lookup(_ key: RenderKey) async -> CameraJPEG? {
        guard !Task.isCancelled, var entry = entries[key] else { return nil }
        guard (try? Self.validate(entry.jpeg, key: key, validateJPEG: validateJPEG)) != nil else {
            if Task.isCancelled { return nil }
            entries[key] = nil
            if !entry.pinned { try? FileManager.default.removeItem(at: entry.jpeg.fileURL.deletingLastPathComponent()) }
            return nil
        }
        entry.accessed = Date(); entries[key] = entry
        try? FileManager.default.setAttributes([.modificationDate: entry.accessed], ofItemAtPath: entry.jpeg.fileURL.deletingLastPathComponent().path)
        return entry.jpeg
    }

    func store(_ jpeg: CameraJPEG, key: RenderKey) async throws {
        let size = try Self.validate(jpeg, key: key, validateJPEG: validateJPEG)
        if hasPinReservation(try Self.identifier(key)) {
            let existing = try validatedPin(key)
            if jpeg.fileURL != existing.fileURL { try? FileManager.default.removeItem(at: jpeg.fileURL) }
            return
        }
        if let existing = entries[key], (try? Self.validate(existing.jpeg, key: key, validateJPEG: validateJPEG)) != nil {
            // Same pixels/settings retain the first render's provenance, never relabel with a new ID.
            if jpeg.fileURL != existing.jpeg.fileURL { try? FileManager.default.removeItem(at: jpeg.fileURL) }
            return
        }
        guard size <= budget else { throw RenderCacheError.storage }
        let committed = try commit(jpeg, to: directory)
        entries[key] = Entry(jpeg: committed, bytes: size, pinned: false, accessed: Date())
        if jpeg.fileURL != committed.fileURL { try? FileManager.default.removeItem(at: jpeg.fileURL) }
        evict()
    }

    func pin(_ key: RenderKey) async throws -> URL {
        let identifier = try Self.identifier(key)
        if hasPinReservation(identifier) { return try validatedPin(key).fileURL }
        guard let entry = entries[key] else { throw RenderCacheError.missing }
        _ = try Self.validate(entry.jpeg, key: key, validateJPEG: validateJPEG)
        let durable = try commit(entry.jpeg, to: pinnedDirectory)
        pinnedReservations.insert(identifier)
        entries[key] = Entry(jpeg: durable, bytes: entry.bytes, pinned: true, accessed: entry.accessed)
        try? FileManager.default.removeItem(at: entry.jpeg.fileURL.deletingLastPathComponent())
        return durable.fileURL
    }

    /// Call only once no submitted/unknown journal entry still references this pin.
    func unpin(_ key: RenderKey) async {
        guard let identifier = try? Self.identifier(key), hasPinReservation(identifier) else { return }
        do { try FileManager.default.removeItem(at: pinnedDirectory.appendingPathComponent(identifier)) }
        catch {
            let failure = error as NSError
            // A failed deletion must not authorize replacement of an occupied durable identity.
            guard failure.domain == NSCocoaErrorDomain, failure.code == NSFileNoSuchFileError else { return }
        }
        pinnedReservations.remove(identifier)
        if entries[key]?.pinned == true { entries[key] = nil }
    }

    private func hasPinReservation(_ identifier: String) -> Bool {
        if FileManager.default.fileExists(atPath: pinnedDirectory.appendingPathComponent(identifier).path) {
            pinnedReservations.insert(identifier)
        }
        return pinnedReservations.contains(identifier)
    }

    private func validatedPin(_ key: RenderKey) throws -> CameraJPEG {
        guard let entry = entries[key], entry.pinned,
              (try? Self.validate(entry.jpeg, key: key, validateJPEG: validateJPEG)) != nil else { throw RenderCacheError.pinConflict }
        return entry.jpeg
    }

    func invalidate(sourceID: SourceID) async {
        for (key, entry) in entries where key.sourceID == sourceID && !entry.pinned {
            try? FileManager.default.removeItem(at: entry.jpeg.fileURL.deletingLastPathComponent()); entries[key] = nil
        }
    }

    private func commit(_ jpeg: CameraJPEG, to root: URL) throws -> CameraJPEG {
        let identifier = try Self.identifier(jpeg.key)
        let destination = root.appendingPathComponent(identifier)
        let durable = root == pinnedDirectory
        if durable, hasPinReservation(identifier) { throw RenderCacheError.pinConflict }
        let partial = root.appendingPathComponent(UUID().uuidString + ".partial")
        defer { try? FileManager.default.removeItem(at: partial) }
        do {
            try FileManager.default.createDirectory(at: partial, withIntermediateDirectories: true, attributes: [.protectionKey: FileProtectionType.complete])
            let image = partial.appendingPathComponent("image.JPG")
            try FileManager.default.copyItem(at: jpeg.fileURL, to: image)
            _ = try Self.validate(jpeg.relocated(to: image), key: jpeg.key, validateJPEG: validateJPEG)
            let committed = jpeg.relocated(to: destination.appendingPathComponent("image.JPG"))
            try JSONEncoder().encode(committed).write(to: partial.appendingPathComponent("entry.json"), options: [.atomic, .completeFileProtection])
            if FileManager.default.fileExists(atPath: destination.path) {
                guard !durable else { pinnedReservations.insert(identifier); throw RenderCacheError.pinConflict }
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: partial, to: destination)
            return committed
        } catch let error as RenderCacheError { throw error }
        catch {
            if durable, hasPinReservation(identifier) { throw RenderCacheError.pinConflict }
            throw RenderCacheError.storage
        }
    }

    private func evict() {
        var total = entries.values.filter { !$0.pinned }.reduce(0) { $0 + $1.bytes }
        for entry in entries.values.filter({ !$0.pinned }).sorted(by: { $0.accessed < $1.accessed }) where total > budget {
            try? FileManager.default.removeItem(at: entry.jpeg.fileURL.deletingLastPathComponent())
            entries[entry.jpeg.key] = nil; total -= entry.bytes
        }
    }

    nonisolated static func validateCameraJPEG(_ jpeg: CameraJPEG) throws {
        let geometry = PixelSize(width: jpeg.width, height: jpeg.height)
        let metadata = RAWMetadata(cameraModel: jpeg.cameraContext.model, containerGeometry: geometry, recordedGeometry: geometry,
            recordedAspect: geometry, cropTop: 0, cropLeft: 0, orientation: jpeg.orientation)
        _ = try XT5ConversionCodec.validateFullSizeFineJPEG(Data(contentsOf: jpeg.fileURL, options: .mappedIfSafe), expected: metadata)
    }

    private static func identifier(_ key: RenderKey) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return SHA256.hash(data: try encoder.encode(key)).map { String(format: "%02x", $0) }.joined()
    }

    private static func validate(_ jpeg: CameraJPEG, key: RenderKey, validateJPEG: JPEGValidation) throws -> Int {
        guard jpeg.key == key, jpeg.sourceID == key.sourceID, jpeg.sourceRevision == key.sourceRevision,
              jpeg.sourceSHA256 == key.sourceSHA256, jpeg.settingsDigest == key.settingsDigest,
              jpeg.cameraContext == key.cameraContext, jpeg.width == key.width, jpeg.height == key.height,
              jpeg.orientation == key.orientation, jpeg.quality == key.quality,
              key.width > 0, key.height > 0, (1...8).contains(key.orientation),
              let size = try? jpeg.fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 0,
              (try? ResourceChecksum.sha256(jpeg.fileURL)) == jpeg.outputSHA256 else { throw RenderCacheError.invalidEntry }
        do { try validateJPEG(jpeg) } catch { throw RenderCacheError.invalidEntry }
        return size
    }
}
