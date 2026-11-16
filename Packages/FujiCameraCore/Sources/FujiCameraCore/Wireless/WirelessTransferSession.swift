import Foundation

public protocol WirelessTransferSession: Sendable {
  func open() async throws -> WirelessIdentity
  func capabilities() async throws -> WirelessCapabilities
  /// A new stream replays previously returned batches and continues the same session inventory.
  func enumerate() async throws -> AsyncThrowingStream<WirelessInventoryBatch, Error>
  func thumbnail(_ object: WirelessObjectDescriptor) async throws -> Data
  func download(
    _ object: WirelessObjectDescriptor, to sink: @escaping @Sendable (Data) async throws -> Void
  ) async throws
  /// Return only after native I/O is closed and cannot be reused.
  func close() async throws
}

#if DEBUG
/// Candidate bytes for independent comparison with originals copied from the card.
public protocol WirelessDiagnosticCandidateSession: Sendable {
  func downloadDiagnosticCandidate(
    _ object: WirelessObjectDescriptor, to sink: @escaping @Sendable (Data) async throws -> Void
  ) async throws
}
#endif

/// Owns transaction IDs, storage selection and object affinity for a single camera-hosted socket.
actor CameraHostedTransferSession: WirelessTransferSession {
  private struct CardScan {
    let id: UInt32
    let handles: [UInt32]
    var index = 0
  }

  let transport: WirelessPTPTransport
  let expectedIdentity: WirelessIdentity
  let mode: WirelessMode
  private let clientGUID: Data
  private let clientName: String
  private let sessionID = UUID()
  #if DEBUG
  var galleryObjects: [UInt32: [UInt32: WirelessObjectDescriptor]]?
  var galleryOriginalModePrepared = false
  var galleryOriginalRestoration: GalleryOriginalRestoration?
  #endif
  private var peer: WirelessIdentity?
  private var didOpenSession = false
  private var closing: Task<Void, Error>?
  var busy = false
  private var transactionID: UInt32 = 0

  var selectedStorage: UInt32?
  private var storageIDs: [UInt32]?
  private var pendingStorage: [UInt32] = []
  private var cardScan: CardScan?
  private var batches: [WirelessInventoryBatch] = []
  private var objects: [UInt32: [UInt32: WirelessObjectDescriptor]] = [:]
  private var rawExposure: WirelessRAWExposure = .unknown
  private var declaresJPEGOnly = false
  private var inventoryFailure: (any Error)?
  private var xAppOriginalControlObserved: Bool?
  private var xAppOriginalControlConflict = false
  var legacyObjectCount: UInt32?
  var legacyAccurateLengthsEnabled = false

  init(
    transport: WirelessPTPTransport, expectedIdentity: WirelessIdentity, mode: WirelessMode,
    clientGUID: Data, clientName: String? = nil
  ) {
    self.transport = transport
    self.expectedIdentity = expectedIdentity
    self.mode = mode
    self.clientGUID = clientGUID
    self.clientName = clientName ?? "Fuji Studio"
  }

  func open() async throws -> WirelessIdentity {
    guard (mode == .xApp && expectedIdentity.model == .xt5)
      || (mode != .xApp && expectedIdentity.model == .xe3)
    else { throw WirelessFailure.unsupportedProtocol }
    if mode == .autoSave, expectedIdentity.protocolPeerKey?.bytes.count != 32 {
      throw WirelessFailure.autoSaveIdentityUnavailable
    }
    if let peer, closing == nil { return peer }
    try begin()
    defer { busy = false }
    try await startSession()
    let data = try await execute(0x1001).data
    let (device, observed) = try validateDeviceInfo(data)
    declaresJPEGOnly = mode == .phone && !device.imageFormats.isEmpty
      && !device.imageFormats.contains(0xb103)
    peer = observed
    return observed
  }

  private func startSession() async throws {
    let request = try FujiWirelessFrameDecoder.initializationRequest(
      clientName: clientName, clientGUID: clientGUID)
    do {
      _ = try await transport.initialize(request)
    } catch PTPError.authorizationDenied {
      throw WirelessFailure.authentication
    }
    // The pinned libfuji camera-hosted implementation waits 50 ms after the ACK.
    transport.observeIdentity(.init(.openSessionDelay, .waiting))
    do {
      try await Task.sleep(for: .milliseconds(50))
    } catch {
      transport.observeIdentity(.init(.openSessionDelay, .failed, failure: .init(error)))
      throw error
    }
    transport.observeIdentity(.init(.openSessionDelay, .completed))
    _ = try await execute(0x1002, [1])
    didOpenSession = true
  }

  private func validateDeviceInfo(_ data: Data) throws -> (FujiDeviceInfo, WirelessIdentity) {
    transport.observeIdentity(.init(.deviceInfoValidation, .waiting))
    let device: FujiDeviceInfo
    let evidence: WirelessProtocolPeerKey?
    do {
      (device, evidence) = try PTPDatasets.wirelessDeviceInfo(data)
    } catch is PTPDatasetError {
      transport.observeIdentity(.init(.deviceInfoValidation, .failed, failure: .malformedData))
      throw WirelessFailure.malformedData
    }
    guard device.manufacturer.uppercased() == "FUJIFILM",
      device.model == expectedIdentity.model.rawValue,
      mode != .autoSave || evidence == expectedIdentity.protocolPeerKey
    else {
      transport.observeIdentity(.init(.deviceInfoValidation, .failed, failure: .peerMismatch))
      throw WirelessFailure.peerMismatch
    }
    let observed = WirelessIdentity(
      cameraID: expectedIdentity.cameraID, model: expectedIdentity.model,
      firmware: device.firmware.isEmpty ? nil : device.firmware, protocolPeerKey: evidence)
    transport.observeIdentity(.init(.deviceInfoValidation, .completed))
    return (device, observed)
  }

  #if DEBUG
  func abortGallery() async {
    markGalleryRestorationUnconfirmed(.cancelled)
    await transport.close()
  }

  func openGallery() async throws -> XAppConnectionDiagnosticResult {
    guard WirelessSupportPolicy().assess(model: expectedIdentity.model.rawValue, firmware: expectedIdentity.firmware)
      == .supported(.xt5)
    else { throw WirelessFailure.unsupportedFirmware }
    let connection = try await openXAppDiagnostic()
    if case .identified(let observed) = connection {
      guard WirelessSupportPolicy().assess(model: observed.model.rawValue, firmware: observed.firmware)
        == .supported(.xt5)
      else { throw WirelessFailure.unsupportedFirmware }
    }
    try await checkXAppStartup()
    return connection
  }

  func checkConnection() async throws -> XAppConnectionDiagnosticResult {
    try begin()
    defer { busy = false }
    let connection = try await openXAppDiagnostic()
    if connection == .respondingWithoutDeviceInfo { try await checkXAppStartup() }
    return connection
  }

  private func openXAppDiagnostic() async throws -> XAppConnectionDiagnosticResult {
    guard mode == .xApp, expectedIdentity.model == .xt5 else {
      throw WirelessFailure.unsupportedProtocol
    }
    try await startSession()
    let command = try commandFor(0x1001, [], whileClosing: false)
    let (reply, receivedDataContainer) = try await transport.executeWithDataPhase(command)
    try checkOpenOperation()
    if !reply.data.isEmpty {
      let (_, identity) = try validateDeviceInfo(reply.data)
      return .identified(identity)
    }
    guard receivedDataContainer, reply.parameters.isEmpty else {
      transport.observeIdentity(.init(.deviceInfoValidation, .failed, failure: .malformedData))
      throw WirelessFailure.malformedData
    }
    transport.observeIdentity(.init(.deviceInfoValidation, .noData, bytes: 0))
    return .respondingWithoutDeviceInfo
  }
  #endif

  func capabilities() throws -> WirelessCapabilities {
    try requireAdmission()
    let evidenceID: String
    switch mode {
    case .xApp: evidenceID = "libfuji-xapp-reference"
    case .phone: evidenceID = "libfuji-phone-reference"
    case .autoSave: evidenceID = "libfuji-autosave-reference"
    }
    return WirelessCapabilities(
      mode: mode, rawExposure: rawExposure, storageIDs: storageIDs ?? [],
      originalSizeVerified: xAppOriginalControlObserved == true, evidenceID: evidenceID,
      originalSizeObservationsConflict: xAppOriginalControlConflict)
  }

  func enumerate() async throws -> AsyncThrowingStream<WirelessInventoryBatch, Error> {
    try requireAdmission()
    if let inventoryFailure { throw inventoryFailure }
    if storageIDs == nil {
      try begin()
      defer { busy = false }
      do {
        let slots: [UInt32]
        switch mode {
        case .xApp: slots = try await configureXApp()
        case .phone: slots = try await configurePhone()
        case .autoSave: slots = try await configureAutoSave()
        }
        storageIDs = slots.sorted()
        pendingStorage = slots
      } catch {
        inventoryFailure = error
        throw error
      }
    }
    let cursor = InventoryCursor()
    return AsyncThrowingStream(unfolding: { try await cursor.next(in: self) })
  }

  private func nextBatch(at index: Int) async throws -> WirelessInventoryBatch? {
    try requireAdmission()
    if let inventoryFailure { throw inventoryFailure }
    if index < batches.count { return batches[index] }
    guard cardScan != nil || !pendingStorage.isEmpty else { return nil }
    try begin()
    defer { busy = false }
    do {
      var batch = try await scanNextBatch()
      if index == 0, let storageIDs {
        var initial = Dictionary(uniqueKeysWithValues: storageIDs.map { ($0, WirelessStorageInventory.Completeness.pending) })
        initial.merge(batch.storageChanges) { _, latest in latest }
        batch = .init(objects: batch.objects, storageChanges: initial, rawExposure: batch.rawExposure)
      }
      batches.append(batch)
      return batch
    } catch {
      inventoryFailure = error
      throw error
    }
  }

  private func scanNextBatch() async throws -> WirelessInventoryBatch {
    if cardScan == nil {
      let storage = pendingStorage.removeFirst()
      let handles: [UInt32]?
      if mode == .xApp {
        handles = try await configureXAppCard(storage)
        if let handles, !handles.isEmpty { try await recordXAppOriginalSize() }
      } else if let legacyObjectCount {
        // The legacy gallery exposes consecutive handles starting at 1.
        handles = (0..<legacyObjectCount).map { $0 + 1 }
      } else {
        throw WirelessFailure.unavailableStorage
      }
      guard let handles else {
        return .init(objects: [], storageChanges: [storage: .unavailable])
      }
      cardScan = CardScan(id: storage, handles: handles)
    }
    guard var scan = cardScan else { throw WirelessFailure.unavailableStorage }
    if !scan.handles.isEmpty, selectedStorage != scan.id {
      try await selectStorage(for: scan.id)
    }
    var additions: [WirelessObjectDescriptor] = []
    let previousExposure = rawExposure
    let end = min(scan.index + 16, scan.handles.count)
    if scan.index < end {
      additions = try await withAccurateLegacyLengths {
        var metadata: [WirelessObjectDescriptor] = []
        for handle in scan.handles[scan.index..<end] {
          metadata.append(try await objectInfo(handle: handle, storage: scan.id))
        }
        return metadata
      }
    }
    for object in additions {
      objects[scan.id, default: [:]][object.handle] = object
      if object.format == .raf { rawExposure = .available }
    }
    scan.index = end
    let complete = end == scan.handles.count
    cardScan = complete ? nil : scan
    if complete, pendingStorage.isEmpty, declaresJPEGOnly, rawExposure == .unknown {
      rawExposure = .unavailable
    }
    return .init(
      objects: additions, storageChanges: complete ? [scan.id: .complete] : [:],
      rawExposure: previousExposure == rawExposure ? nil : rawExposure)
  }

  func thumbnail(_ object: WirelessObjectDescriptor) async throws -> Data {
    try checkMember(object)
    guard object.hasThumbnail else { return Data() }
    try begin()
    defer { busy = false }
    try await selectStorage(for: object.storageID)
    return try await withAccurateLegacyLengths {
      // Libfuji observes that newer camera bodies require ObjectInfo immediately before GetThumb.
      try await verifyObject(object)
      return try await execute(0x100a, [object.handle]).data
    }
  }

  func download(
    _ object: WirelessObjectDescriptor, to sink: @escaping @Sendable (Data) async throws -> Void
  ) async throws {
    try checkMember(object)
    // Legacy D227 verifies size reporting. The representation still needs target evidence.
    guard mode == .xApp else { throw WirelessFailure.originalSizeUnavailable }
    let length = try originalLength(object)
    guard !xAppOriginalControlConflict else { throw WirelessFailure.inconsistentOriginalSizeObservations }
    try begin()
    defer { busy = false }
    try await selectStorage(for: object.storageID)
    try await recordXAppOriginalSize()
    if let failure = try capabilities().originalSizeFailure { throw failure }
    try await streamMatchingObject(object, length: length, to: sink)
  }

  #if DEBUG
  func downloadDiagnosticCandidate(
    _ object: WirelessObjectDescriptor, to sink: @escaping @Sendable (Data) async throws -> Void
  ) async throws {
    try checkMember(object)
    guard mode != .xApp else { throw WirelessFailure.unsupportedProtocol }
    let length = try originalLength(object)
    try begin()
    defer { busy = false }
    try await withAccurateLegacyLengths { try await streamMatchingObject(object, length: length, to: sink) }
  }
  #endif

  private func recordXAppOriginalSize() async throws {
    let observed = try await observesXAppOriginalSize()
    // D226's scope across slots is unverified. Contradictory observations
    // disqualify the current session until the user reconnects.
    if let first = xAppOriginalControlObserved {
      if first != observed { xAppOriginalControlConflict = true }
    } else {
      xAppOriginalControlObserved = observed
    }
  }

  func originalLength(_ object: WirelessObjectDescriptor) throws -> UInt32 {
    guard object.format == .raf || object.format == .jpeg,
      let length = UInt32(exactly: object.byteLength), length > 0,
      transport.partialObjectLimit > 0
    else { throw WirelessFailure.unsupportedProtocol }
    return length
  }

  func streamMatchingObject(
    _ object: WirelessObjectDescriptor, length: UInt32, to sink: @escaping @Sendable (Data) async throws -> Void
  ) async throws {
    try await verifyObject(object)
    var offset: UInt32 = 0
    while offset < length {
      let count = min(transport.partialObjectLimit, length - offset)
      let command = try commandFor(0x101b, [object.handle, offset, count])
      let reply = try await transport.receive(command, expectedBytes: UInt64(count), sink: sink)
      guard reply.parameters.isEmpty || reply.parameters == [count] else {
        throw WirelessFailure.malformedData
      }
      offset += count
    }
  }

  func close() async throws {
    if let closing { return try await closing.value }
    #if DEBUG
    galleryObjects = nil
    #endif
    let shouldCloseSession = didOpenSession && !busy && !Task.isCancelled
    let close = Task<Void, Error> {
      #if DEBUG
      let restoration: Result<Void, Error>
      do {
        try await restoreGalleryOriginalMode(canRestore: shouldCloseSession, whileClosing: true)
        restoration = .success(())
      } catch {
        restoration = .failure(error)
      }
      #endif
      if shouldCloseSession {
        if legacyAccurateLengthsEnabled { try? await resetLegacyLengthReporting(whileClosing: true) }
        // Even a PTP refusal must be followed by confirmed native socket teardown.
        _ = try? await execute(0x1003, whileClosing: true)
      }
      await transport.close()
      #if DEBUG
      try restoration.get()
      #endif
    }
    closing = close
    try await close.value
  }

  func execute(
    _ opcode: UInt16, _ parameters: [UInt32] = [], data: Data? = nil,
    whileClosing: Bool = false, onAcknowledged: () -> Void = {}
  ) async throws -> PTPReply {
    let command = try commandFor(opcode, parameters, whileClosing: whileClosing)
    let response = try await transport.execute(command, data: data)
    // A complete, successful response applied the command even if the caller
    // was cancelled while waiting to resume on this session's executor.
    onAcknowledged()
    if !whileClosing { try checkOpenOperation() }
    return response
  }

  func property(_ code: UInt32) async throws -> Data { try await execute(0x1015, [code]).data }

  func setProperty(
    _ code: UInt32, _ scalar: UInt32, width: Int, whileClosing: Bool = false,
    onAcknowledged: () -> Void = {}
  ) async throws {
    let bytes = Data((0..<width).map { UInt8(truncatingIfNeeded: scalar >> ($0 * 8)) })
    _ = try await execute(0x1016, [code], data: bytes, whileClosing: whileClosing, onAcknowledged: onAcknowledged)
  }

  func readScalar(_ code: UInt32, widths: Set<Int> = [4]) async throws -> UInt32 {
    try Self.scalar(try await property(code), widths: widths)
  }

  static func scalar(_ data: Data, widths: Set<Int> = [4]) throws -> UInt32 {
    guard widths.contains(data.count) else { throw WirelessFailure.malformedData }
    return data.enumerated().reduce(0) { $0 | UInt32($1.element) << ($1.offset * 8) }
  }

  private func commandFor(_ opcode: UInt16, _ parameters: [UInt32], whileClosing: Bool = false)
    throws -> PTPCommand
  {
    if !whileClosing { try checkOpenOperation() }
    guard transactionID < UInt32.max else { throw WirelessFailure.connectionLost }
    transactionID += 1
    return PTPCommand(opcode: opcode, parameters: parameters, transactionID: transactionID)
  }

  private func requireAdmission() throws {
    try checkOpenOperation()
    guard let peer else { throw WirelessFailure.connectionLost }
    let policy = WirelessSupportPolicy()
    guard policy.assess(model: peer.model.rawValue, firmware: peer.firmware) == .supported(peer.model),
      expectedIdentity.firmware == nil
        || policy.assess(model: peer.model.rawValue, firmware: expectedIdentity.firmware)
          == .supported(peer.model)
    else { throw WirelessFailure.unsupportedFirmware }
  }

  func begin() throws {
    try checkOpenOperation()
    guard !busy else { throw WirelessFailure.cameraBusy }
    busy = true
  }

  func checkOpenOperation() throws {
    try Task.checkCancellation()
    guard closing == nil else { throw WirelessFailure.connectionLost }
  }

  private func checkMember(_ object: WirelessObjectDescriptor) throws {
    try requireAdmission()
    guard objects[object.storageID]?[object.handle] == object else {
      throw WirelessFailure.objectChanged
    }
  }

  private func verifyObject(_ object: WirelessObjectDescriptor) async throws {
    let fresh = try await objectInfo(handle: object.handle, storage: object.storageID)
    guard object.matchesOriginal(fresh) else { throw WirelessFailure.objectChanged }
  }

  func objectInfo(handle: UInt32, storage: UInt32) async throws -> WirelessObjectDescriptor {
    let info = try await execute(0x1008, [handle]).data
    transport.observeIdentity(.init(.galleryObjectInfoValidation, .waiting))
    do {
      var r = try PTPDatasets.Reader(info)
      let reportedStorage = try r.u32()
      let code = try r.u16()
      _ = try r.u16()  // Object protection.
      let length = try r.u32()
      _ = try r.u16()  // Thumbnail format.
      let thumbnailBytes = try r.u32()
      _ = try r.u32()
      _ = try r.u32()
      let width = try r.u32()
      let height = try r.u32()
      _ = try r.bytes(18)  // Bit depth, parent, association and sequence number.
      let path = try r.string()
      let captureDate = try r.string()
      _ = try r.string()  // Modification timestamp.
      let keywords = r.offset < r.data.count ? try r.string() : ""
      try r.finish()
      let components = path.split(whereSeparator: { $0 == "/" || $0 == "\\" })
      guard let filename = components.last else { throw WirelessFailure.malformedData }
      let directory = components.count > 1 ? components.dropLast().joined(separator: "/") : nil
      let format: WirelessObjectFormat
      switch code {
      case 0xb103: format = .raf
      case 0x3801: format = .jpeg
      default: format = .other(code)
      }
      let orientation = keywords.hasPrefix("Orientation:") ? Int(keywords.dropFirst(12)) : nil
      transport.observeIdentity(.init(.galleryObjectInfoValidation, .completed))
      return .init(
        cameraID: expectedIdentity.cameraID, sessionID: sessionID, storageID: storage, handle: handle,
        directory: directory, filename: String(filename), format: format, byteLength: UInt64(length),
        captureDate: captureDate.isEmpty ? nil : captureDate,
        dimensions: width > 0 && height > 0 ? .init(width: Int(width), height: Int(height)) : nil,
        orientation: orientation.flatMap { (1...8).contains($0) ? $0 : nil },
        reportedStorageID: reportedStorage == 0 ? nil : reportedStorage,
        hasThumbnail: mode != .autoSave && thumbnailBytes > 0)
    } catch {
      transport.observeIdentity(.init(.galleryObjectInfoValidation, .failed, failure: .malformedData))
      throw WirelessFailure.malformedData
    }
  }

  func selectStorage(for storage: UInt32) async throws {
    guard mode == .xApp, selectedStorage != storage else { return }
    guard try await configureXAppCard(storage) != nil else { throw WirelessFailure.unavailableStorage }
  }

  private actor InventoryCursor {
    private var position = 0

    func next(in session: CameraHostedTransferSession) async throws -> WirelessInventoryBatch? {
      let batch = try await session.nextBatch(at: position)
      if batch != nil { position += 1 }
      return batch
    }
  }
}

#if DEBUG
extension CameraHostedTransferSession: WirelessDiagnosticCandidateSession {}
#endif
