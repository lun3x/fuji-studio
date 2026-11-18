import Foundation
import FujiCameraCore

/// Verified camera files live independently of temporary viewer leases and pending Photos imports.
/// The browser and importer serialize camera access through their existing session loan.
actor CameraOriginalCache {
    struct Entry: Sendable {
        let original: StagedOriginal
        let url: URL
    }

    private let root: URL
    private var checkedFiles: [String: Date] = [:]
    private weak var liveSession: AnyObject?
    private var livePaths: Set<String> = []

    private func admit(_ entry: Entry, session: any WirelessTransferSession) -> Entry {
        if liveSession !== session as AnyObject {
            liveSession = session as AnyObject
            livePaths.removeAll()
        }
        livePaths.insert(entry.original.relativePath)
        return entry
    }

    init(root: URL) { self.root = root }

    private func directory(for object: WirelessObjectDescriptor) -> URL {
        let identity = CameraCaptureID(describing: [object]).rawValue
        return root.appending(path: identity)
    }

    func lookup(_ object: WirelessObjectDescriptor, session: any WirelessTransferSession) async throws -> Entry? {
        let directory = directory(for: object)
        let manifest = directory.appending(path: "original.json")
        guard let data = try? Data(contentsOf: manifest),
              let original = try? JSONDecoder().decode(StagedOriginal.self, from: data),
              original.describes(object) else { return nil }
        let store = try ImportStagingStore(root: directory)
        guard let url = try? store.fileURL(for: original),
              let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
              let date = values.contentModificationDate, values.fileSize == Int(exactly: original.byteCount) else { return nil }
        if checkedFiles[original.relativePath] != date {
            guard (try? store.checkIntegrity(original)) != nil else { return nil }
            checkedFiles[original.relativePath] = date
        }
        if original.descriptor == object, liveSession === session as AnyObject, livePaths.contains(original.relativePath) {
            return Entry(original: original, url: url)
        }

        // Handles can be reassigned on reconnect, and another card can repeat a filename.
        // Compare camera bytes at both ends and in the middle before admitting a disk hit.
        guard object.captureDate != nil,
              let sampling = session as? any WirelessOriginalSampling,
              try await session.capabilities().mode == original.verifiedTransferMode,
              let length = UInt32(exactly: original.byteCount), length > 0 else { return nil }
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let count = min(length, 4096)
        for offset in Set([0, (length - count) / 2, length - count]).sorted() {
            try file.seek(toOffset: UInt64(offset))
            let sample = try await sampling.originalSample(object, offset: offset, count: count)
            guard sample.count == Int(count), try file.read(upToCount: Int(count)) == sample else { return nil }
        }
        let current = StagedOriginal(relativePath: original.relativePath, fingerprint: original.fingerprint,
            metadata: original.metadata, descriptor: object, verifiedTransferMode: original.verifiedTransferMode)
        try JSONEncoder().encode(current).write(to: manifest, options: .atomic)
        return admit(Entry(original: current, url: url), session: session)
    }

    func viewerOriginal(_ object: WirelessObjectDescriptor, session: any WirelessTransferSession) async throws -> Entry {
        if let entry = try await lookup(object, session: session) { return entry }
        let directory = directory(for: object)
        let store = try ImportStagingStore(root: directory)
        try store.removeInterruptedDownloads()
        try store.preflight(stagingByteLengths: [object.byteLength], photoCopyByteLengths: [])
        let original = try await store.write(object: object, session: session)
        return try admit(publish(original, in: directory, store: store), session: session)
    }

    func retain(_ original: StagedOriginal, from source: URL, session: any WirelessTransferSession) throws {
        let directory = directory(for: original.descriptor)
        let store = try ImportStagingStore(root: directory)
        let linked = try store.link(original, from: source, for: original.descriptor)
        _ = try admit(publish(linked, in: directory, store: store), session: session)
    }

    private func publish(_ original: StagedOriginal, in directory: URL, store: ImportStagingStore) throws -> Entry {
        let url = try store.fileURL(for: original)
        do {
            try JSONEncoder().encode(original).write(to: directory.appending(path: "original.json"), options: .atomic)
        } catch {
            try? store.remove(original)
            throw error
        }
        checkedFiles[original.relativePath] = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        try? store.removeUnreferencedOriginals(retaining: [original.relativePath])
        return Entry(original: original, url: url)
    }
}
