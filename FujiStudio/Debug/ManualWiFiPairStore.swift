#if DEBUG
import Darwin
import Foundation
import FujiCameraCore

/// The resolved pair belongs to this diagnostic scan and has no import capabilities.
struct ManualWiFiPair: Sendable {
  let raf: WirelessObjectDescriptor
  let jpeg: WirelessObjectDescriptor

  static func select(from objects: [WirelessObjectDescriptor], scan: XAppGalleryDiagnosticResult) -> Self? {
    let storage: [UInt32: WirelessStorageInventory.Completeness] = Dictionary(
      uniqueKeysWithValues: scan.cards.map { card in
        let status: WirelessStorageInventory.Completeness = switch card.summary.status {
        case .available: .complete
        case .unavailable: .unavailable
        case .scanning: .pending
        }
        return (card.summary.slot, status)
      })
    let captures = CaptureResolver.resolve(objects: objects, inventory: .init(
      storage: storage, rawExposure: objects.contains { $0.format == .raf } ? .available : .unknown))
    var firstSplitPair: Self?
    for capture in captures where capture.availability == .pair {
      guard let raf = capture.raw, let jpeg = capture.jpeg else { continue }
      let pair = Self(raf: raf, jpeg: jpeg)
      if raf.storageID == jpeg.storageID { return pair }
      if firstSplitPair == nil { firstSplitPair = pair }
    }
    return firstSplitPair
  }
}

struct ManualWiFiPairReceipt: Codable, Equatable, Sendable {
  struct File: Codable, Equatable, Sendable {
    let role: WirelessIdentityTrace.PairRole
    let relativePath: String
    let cameraFilename: String
    let expectedBytes: UInt64
    let actualBytes: UInt64
    let sha256: String
    let metadata: OriginalImportMetadata
    let originalControl: XAppOriginalControlObservation
  }

  let qualification: String
  let files: [File]

  init(files: [File]) {
    self.qualification = "diagnostic candidates; camera card byte equality unverified"
    self.files = files
  }
}

/// A pending directory is owned by one attempt. The caller publishes it only after
/// the session closes and the handoff is still current on the main actor.
struct ManualWiFiPairStore: Sendable {
  private static let process = UUID().uuidString
  private let root: URL
  private let attempt: UUID
  private let beforeWrite: @Sendable () throws -> Void
  private let capacity: (@Sendable () throws -> UInt64)?
  private var pending: URL {
    root.appending(path: "pending-\(Self.process)-\(attempt.uuidString)", directoryHint: .isDirectory)
  }
  private var completed: URL { root.appending(path: "completed", directoryHint: .isDirectory) }

  init(root: URL = URL.documentsDirectory.appending(path: "ManualWiFiPair", directoryHint: .isDirectory),
       beforeWrite: @escaping @Sendable () throws -> Void = {},
       capacity: (@Sendable () throws -> UInt64)? = nil) {
    self.root = root
    attempt = UUID()
    self.beforeWrite = beforeWrite
    self.capacity = capacity
  }

  func stage(_ pair: ManualWiFiPair, session: any XAppGalleryDiagnostic,
             trace: WirelessIdentityTrace.Observer?) async throws -> ManualWiFiPairReceipt {
    let disk: ImportDisk
    trace?(.init(.pairStoragePrepare, .waiting))
    do {
      try Task.checkCancellation()
      let namespace = try ImportDisk(root: root)
      // A process may have exited mid-test. Only remove generated pending directories.
      for item in try FileManager.default.contentsOfDirectory(at: namespace.root, includingPropertiesForKeys: nil) {
        let name = item.lastPathComponent
        if name.hasPrefix("pending-"), name.count == 81,
           let owner = UUID(uuidString: String(name.dropFirst(8).prefix(36))),
           owner.uuidString != Self.process,
           UUID(uuidString: String(name.suffix(36))) != nil {
          try FileManager.default.removeItem(at: item)
        }
      }
      let required = try ImportStagingStore.requiredCapacity(
        stagingByteLengths: [pair.raf.byteLength, pair.jpeg.byteLength], photoCopyByteLengths: [])
      let available = try capacity?() ?? availableCapacity(at: namespace.root)
      guard available >= required else {
        throw ImportStagingError.insufficientCapacity(required: required, available: available)
      }
      disk = try ImportDisk(root: pending)
      trace?(.init(.pairStoragePrepare, .completed))
    } catch {
      trace?(.init(.pairStoragePrepare, .failed, failure: .init(error)))
      throw error
    }

    let raf = try await stageFile(pair.raf, role: .raf, disk: disk, session: session, trace: trace)
    let jpeg = try await stageFile(pair.jpeg, role: .jpeg, disk: disk, session: session, trace: trace)
    trace?(.init(.pairValidation, .waiting))
    do {
      try Task.checkCancellation()
      try OriginalImportValidator.checkPair(raf.metadata, jpeg.metadata)
      let receipt = ManualWiFiPairReceipt(files: [raf, jpeg])
      let manifest = disk.root.appending(path: "manifest.json", directoryHint: .notDirectory)
      try JSONEncoder().encode(receipt).write(to: manifest, options: [.atomic, .completeFileProtection])
      try disk.synchronizeDirectory()
      try Task.checkCancellation()
      trace?(.init(.pairValidation, .completed))
      return receipt
    } catch {
      trace?(.init(.pairValidation, .failed, failure: .init(error), validationCheck: Self.validationCheck(error)))
      throw error
    }
  }

  func publish() throws {
    try Task.checkCancellation()
    let namespace = try ImportDisk(root: root)
    let replacing = FileManager.default.fileExists(atPath: completed.path)
    if replacing {
      try swapCompletedDirectory()
    } else {
      try namespace.rename(pending, to: completed, replacing: false)
    }
    do {
      try namespace.synchronizeDirectory()
    } catch {
      if replacing {
        try? swapCompletedDirectory()
      } else {
        try? namespace.rename(completed, to: pending, replacing: false)
      }
      throw error
    }
  }

  func cleanPending() throws {
    do {
      try FileManager.default.removeItem(at: pending)
    } catch let error as CocoaError where error.code == .fileNoSuchFile {
      // A completed first attempt moved the entire directory into place.
    }
  }

  private func swapCompletedDirectory() throws {
    guard renamex_np(pending.path, completed.path, UInt32(RENAME_SWAP)) == 0 else {
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
  }

  private func availableCapacity(at url: URL) throws -> UInt64 {
    let values = try url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey,
                                                   .volumeAvailableCapacityKey])
    return (values.volumeAvailableCapacityForImportantUsage ?? values.volumeAvailableCapacity.map(Int64.init))
      .flatMap(UInt64.init(exactly:)) ?? 0
  }

  private func stageFile(
    _ object: WirelessObjectDescriptor, role: WirelessIdentityTrace.PairRole, disk: ImportDisk,
    session: any XAppGalleryDiagnostic, trace: WirelessIdentityTrace.Observer?
  ) async throws -> ManualWiFiPairReceipt.File {
    let expected = object.byteLength
    var stage = WirelessIdentityTrace.Stage.pairFileTransfer
    trace?(.init(stage, .waiting, pairFile: .init(role: role, expectedBytes: expected, receivedBytes: 0)))
    do {
      try Task.checkCancellation()
      let fileExtension = role == .raf ? "raf" : "jpg"
      let name = "\(attempt.uuidString)-\(role.rawValue).\(fileExtension)"
      let (file, handle) = try disk.createFile(named: name)
      defer { try? handle.close() }
      let writer = OriginalStreamVerifier(handle: handle, expected: expected, beforeWrite: beforeWrite)
      let control = try await session.downloadGalleryCandidate(object) { data in
        let written = try await writer.append(data)
        trace?(.init(.pairFileTransfer, .waiting,
          pairFile: .init(role: role, expectedBytes: expected, receivedBytes: written)))
      }
      try Task.checkCancellation()
      let hash = try await writer.finish()
      let progress = WirelessIdentityTrace.PairFile(
        role: role, expectedBytes: expected, receivedBytes: expected, originalControl: control)
      trace?(.init(stage, .completed, pairFile: progress))
      stage = .pairFileValidation
      trace?(.init(stage, .waiting, pairFile: progress))
      let metadata = try OriginalImportValidator.inspect(file: file, object: object)
      guard metadata.cameraModel == WirelessCameraModel.xt5.rawValue else {
        throw OriginalImportError.validation(.cameraModel)
      }
      try OriginalImportValidator.checkDiagnosticCaptureTime(metadata, object: object)
      trace?(.init(stage, .completed, pairFile: progress))
      return .init(role: role, relativePath: name, cameraFilename: object.filename, expectedBytes: expected,
                   actualBytes: expected, sha256: hash, metadata: metadata, originalControl: control)
    } catch {
      let validationCheck = stage == .pairFileValidation ? Self.validationCheck(error) : nil
      trace?(.init(stage, .failed, failure: .init(error), pairFile: .init(role: role, expectedBytes: expected),
        validationCheck: validationCheck))
      throw error
    }
  }

  private static func validationCheck(_ error: any Error) -> WirelessIdentityTrace.ValidationCheck? {
    if error is CancellationError { return nil }
    if case OriginalImportError.validation(let check) = error { return check }
    if case ResourceError.invalidRAF(let reason) = error, let issue = RAFMetadataReader.Issue(rawValue: reason) {
      return .rafMetadata(issue)
    }
    if error is CocoaError || error is POSIXError { return .fileRead }
    return .unknown
  }
}
#endif
