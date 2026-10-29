import Foundation

public enum CameraOperationPhase: String, Sendable, Codable {
  case prepared, uploadIntent, baselineReceived, profileIntent, profileAccepted
  case triggerIntent, triggerAccepted, captured, deleteIntent, deleteAcknowledged
  case completed, aborted, uncertain, reconciledMissing
}

public struct CameraOperationRecord: Sendable, Codable {
  public let id: UUID
  public let context: CameraExecutionContext
  public let sourceID: SourceID, sourceRevision: String, sourceSHA256: String
  public let recipeSnapshotID: UUID
  public let settingsDigest: String
  public let width: Int, height: Int, orientation: Int
  public var phase: CameraOperationPhase = .prepared
  public var baselineSHA256: String?, candidateSHA256: String?
  public var initialViewEmpty = false
  public var triggerIntent = false
  public var triggerAcknowledged = false
  public var outputHandle: UInt32?
  public var outputSHA256: String?
  public var objectInfo: Data?, storageInfo: Data?
  public var discardObjectInfo: Data?, discardStorageInfo: Data?, discardOutputSHA256: String?
  public var outputValidated = false
  public var deleteIntent = false
  public var deleteAcknowledged = false
  public var emptyViewVerified = false
  public var closure: String = "notRequested"
  public var failure: String?
  public var recipeMismatch: RecipeMismatchReport? = nil
  public var result: CameraJPEG?
  public init(
    id: UUID, context: CameraExecutionContext, sourceID: SourceID, sourceRevision: String,
    sourceSHA256: String, recipeSnapshotID: UUID, settingsDigest: String, width: Int, height: Int,
    orientation: Int, phase: CameraOperationPhase = .prepared, baselineSHA256: String? = nil,
    candidateSHA256: String? = nil, initialViewEmpty: Bool = false, triggerIntent: Bool = false,
    triggerAcknowledged: Bool = false, outputHandle: UInt32? = nil, outputSHA256: String? = nil,
    objectInfo: Data? = nil, storageInfo: Data? = nil, outputValidated: Bool = false,
    deleteIntent: Bool = false, deleteAcknowledged: Bool = false, emptyViewVerified: Bool = false,
    closure: String = "notRequested", failure: String? = nil, result: CameraJPEG? = nil
  ) {
    self.id = id
    self.context = context
    self.sourceID = sourceID
    self.sourceRevision = sourceRevision
    self.sourceSHA256 = sourceSHA256
    self.recipeSnapshotID = recipeSnapshotID
    self.settingsDigest = settingsDigest
    self.width = width
    self.height = height
    self.orientation = orientation
    self.phase = phase
    self.baselineSHA256 = baselineSHA256
    self.candidateSHA256 = candidateSHA256
    self.initialViewEmpty = initialViewEmpty
    self.triggerIntent = triggerIntent
    self.triggerAcknowledged = triggerAcknowledged
    self.outputHandle = outputHandle
    self.outputSHA256 = outputSHA256
    self.objectInfo = objectInfo
    self.storageInfo = storageInfo
    self.outputValidated = outputValidated
    self.deleteIntent = deleteIntent
    self.deleteAcknowledged = deleteAcknowledged
    self.emptyViewVerified = emptyViewVerified
    self.closure = closure
    self.failure = failure
    self.result = result
  }

}

/// One service/gate owns updates. Exclusive marker creation also prevents replay after process loss.
/// JSON and markers are file-synchronized; a partial/malformed journal refuses admission.
public struct CameraOperationJournal: Sendable {
  public let directory: URL
  private let filePolicy: any CameraJournalFilePolicy
  public init(directory: URL, filePolicy: any CameraJournalFilePolicy) throws {
    self.filePolicy = filePolicy
    self.directory = directory
    do {
      try filePolicy.createDirectory(at: directory)
      try upgradeExistingPayloads()
    } catch { throw CameraServiceError.storage }
  }
  private func upgradeExistingPayloads() throws {
    let directories = try FileManager.default.contentsOfDirectory(
      at: directory, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)
    var replacements: [(URL, Data, Data)] = []
    for folder in directories {
      guard let id = UUID(uuidString: folder.lastPathComponent) else {
        throw CameraServiceError.storage
      }
      let url = folder.appendingPathComponent("journal.json")
      guard let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 0,
        size <= 1_048_576
      else { throw CameraServiceError.storage }
      let old = try Data(contentsOf: url)
      let converted = try RecipePayloadUpgrade.convert(old)
      let record = try JSONDecoder().decode(CameraOperationRecord.self, from: converted)
      guard record.id == id else { throw CameraServiceError.storage }
      if converted != old { replacements.append((url, old, converted)) }
    }
    for (url, old, converted) in replacements {
      let backup = url.deletingLastPathComponent().appendingPathComponent("journal-v1-backup.json")
      if !FileManager.default.fileExists(atPath: backup.path) {
        try filePolicy.write(old, to: backup, exclusive: true)
        let handle = try FileHandle(forWritingTo: backup)
        try handle.synchronize()
        try handle.close()
      }
      try durable(converted, to: url, exclusive: false)
    }
  }
  public func operationDirectory(_ id: UUID) -> URL {
    directory.appendingPathComponent(id.uuidString, isDirectory: true)
  }
  public func create(raw: PreparedRAW, recipe: RecipeSnapshot, context: CameraExecutionContext)
    throws -> CameraOperationRecord
  {
    let record = CameraOperationRecord(
      id: UUID(), context: context, sourceID: raw.sourceID, sourceRevision: raw.sourceRevision,
      sourceSHA256: raw.sha256,
      recipeSnapshotID: recipe.id, settingsDigest: recipe.settingsDigest,
      width: raw.metadata.recordedGeometry.width, height: raw.metadata.recordedGeometry.height,
      orientation: raw.metadata.orientation)
    do {
      guard !FileManager.default.fileExists(atPath: operationDirectory(record.id).path) else {
        throw CameraServiceError.storage
      }
      try filePolicy.createDirectory(at: operationDirectory(record.id))
    } catch { throw CameraServiceError.storage }
    try save(record)
    return record
  }
  public func save(_ record: CameraOperationRecord) throws {
    if record.phase == .completed && (!record.deleteAcknowledged || !record.emptyViewVerified) {
      throw CameraServiceError.uncertainOperation(record.id)
    }
    do {
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      let data = try encoder.encode(record)
      guard data.count <= 1_048_576 else { throw CameraServiceError.storage }
      try durable(
        data, to: operationDirectory(record.id).appendingPathComponent("journal.json"),
        exclusive: false)
    } catch { throw CameraServiceError.storage }
  }
  public func load(_ id: UUID) throws -> CameraOperationRecord {
    do {
      let url = operationDirectory(id).appendingPathComponent("journal.json")
      guard let count = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize, count > 0,
        count <= 1_048_576
      else { throw CameraServiceError.storage }
      let record = try JSONDecoder().decode(CameraOperationRecord.self, from: Data(contentsOf: url))
      guard record.id == id else { throw CameraServiceError.storage }
      return record
    } catch { throw CameraServiceError.storage }
  }
  public func unresolved() throws -> [CameraOperationRecord] {
    do {
      let urls = try FileManager.default.contentsOfDirectory(
        at: directory, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)
      var records: [CameraOperationRecord] = []
      for url in urls {
        guard let id = UUID(uuidString: url.lastPathComponent) else {
          throw CameraServiceError.storage
        }
        let record = try load(id)
        if record.phase != .completed && record.phase != .aborted
          && record.phase != .reconciledMissing
        {
          records.append(record)
        }
      }
      return records
    } catch { throw CameraServiceError.storage }
  }
  public func beginDelete(_ record: inout CameraOperationRecord) throws {
    guard record.phase == .captured, record.outputValidated, record.outputHandle != nil,
      record.outputSHA256 != nil, record.objectInfo != nil, record.storageInfo != nil,
      !record.deleteIntent
    else { throw CameraServiceError.uncertainOperation(record.id) }
    try beginDeletionIntent(&record, intent: "one exact delete; never replay")
  }
  /// Explicit reset may discard this session's failed temporary conversion. It
  /// does not claim that the image passed output validation.
  public func beginDiscard(_ record: inout CameraOperationRecord) throws {
    guard record.phase == .uncertain, record.initialViewEmpty, record.triggerIntent, record.triggerAcknowledged,
      record.outputHandle != nil, record.discardObjectInfo != nil,
      record.discardStorageInfo != nil, record.discardOutputSHA256 != nil, !record.deleteIntent
    else { throw CameraServiceError.uncertainOperation(record.id) }
    try beginDeletionIntent(&record, intent: "explicit reset discards one owned temporary output; never replay")
  }
  private func beginDeletionIntent(_ record: inout CameraOperationRecord, intent: String) throws {
    let marker = operationDirectory(record.id).appendingPathComponent("delete-intent.json")
    guard !FileManager.default.fileExists(atPath: marker.path) else {
      throw CameraServiceError.uncertainOperation(record.id)
    }
    do {
      let data = try JSONEncoder().encode([
        "operation": record.id.uuidString, "intent": intent,
      ])
      try durable(data, to: marker, exclusive: true)
    } catch { throw CameraServiceError.uncertainOperation(record.id) }
    record.deleteIntent = true
    record.phase = .deleteIntent
    try save(record)
  }
  @discardableResult public func store(_ data: Data, name: String, id: UUID) throws -> URL {
    guard ["baseline.bin", "candidate.bin", "readback.bin", "output.JPG"].contains(name),
      data.count <= PTPCodec.maximumDataBytes
    else { throw CameraServiceError.storage }
    let url = operationDirectory(id).appendingPathComponent(name)
    do { try durable(data, to: url, exclusive: true) } catch { throw CameraServiceError.storage }
    return url
  }
  private func durable(_ data: Data, to url: URL, exclusive: Bool) throws {
    try filePolicy.write(data, to: url, exclusive: exclusive)
    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    try handle.synchronize()
  }
}
