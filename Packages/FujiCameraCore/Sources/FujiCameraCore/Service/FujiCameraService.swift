import Foundation

/// Owns the verified connection, every operation permit, and every output cleanup decision.
public actor FujiCameraService: CameraServing {
  private let session: any CameraSessionTransport
  private let journal: CameraOperationJournal
  private let gate: SerialCameraGate
  private let pollWait: @Sendable () async throws -> Void
  private let settle: @Sendable (Duration) async throws -> Void
  private let registry: FujiCameraRegistry
  private var activeAdapter: (any FujiCameraAdapter)?
  private var verifiedSupport: VerifiedCameraSupport?
  private var nativeSession: CameraSession?
  private var context: CameraExecutionContext?
  private var needsClose = false, stopRequested = false
  private var admissionEpoch: UInt64 = 0, transaction: UInt32 = 1
  private var state: CameraState = .disconnected
  private var operationError: CameraServiceError?
  private var observers: [UUID: AsyncStream<CameraState>.Continuation] = [:]
  private var monitor: Task<Void, Never>?
  public init(
    session: any CameraSessionTransport, journal: CameraOperationJournal,
    gate: SerialCameraGate = SerialCameraGate(),
    pollWait: @escaping @Sendable () async throws -> Void = {
      try await Task.sleep(for: .seconds(1))
    },
    settle: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
    registry: FujiCameraRegistry = FujiCameraRegistry()
  ) {
    self.session = session
    self.journal = journal
    self.gate = gate
    self.pollWait = pollWait
    self.settle = settle
    self.registry = registry
  }
  deinit { monitor?.cancel() }
  public func executionContext() async throws -> CameraExecutionContext {
    let epoch = admissionEpoch
    do {
      return try await gate.withExclusiveAccess {
        try await self.readExecutionContext(epoch: epoch)
      }
    } catch { throw Self.failure(error) }
  }
  private func readExecutionContext(epoch: UInt64) async throws -> CameraExecutionContext {
    try Task.checkCancellation()
    guard epoch == admissionEpoch, !stopRequested, let expected = context, let nativeSession else {
      throw CameraServiceError.notReady
    }
    let current = try await session.currentSession()
    try Task.checkCancellation()
    guard epoch == admissionEpoch, !stopRequested, context == expected,
      self.nativeSession == nativeSession
    else { throw CameraServiceError.cancelled }
    guard current.generation == expected.generation, current.generation == nativeSession.generation
    else { throw CameraServiceError.unsupportedContext }
    return expected
  }
  public func states() -> AsyncStream<CameraState> {
    let id = UUID()
    let pair = AsyncStream<CameraState>.makeStream(bufferingPolicy: .bufferingNewest(32))
    observers[id] = pair.continuation
    pair.continuation.yield(state)
    pair.continuation.onTermination = { [weak self] _ in Task { await self?.removeObserver(id) } }
    return pair.stream
  }
  private func removeObserver(_ id: UUID) { observers[id] = nil }
  private func publish(_ next: CameraState) {
    state = next
    observers.values.forEach { $0.yield(next) }
  }
  private func startMonitor() async {
    guard monitor == nil else { return }
    let stream = await session.states()
    monitor = Task { [weak self] in
      for await event in stream {
        guard !Task.isCancelled else { break }
        await self?.nativeEvent(event)
      }
    }
  }
  private func nativeEvent(_ event: CameraState) async {
    switch event {
    case .busy, .sessionOpen, .ready, .attentionRequired: return  // Wire activity never changes whole-operation readiness.
    case .disconnected, .recoverableError, .authorizationDenied:
      // A metadata failure during verification can retain an open native session
      // before a public execution context exists. Real removal must retire it too.
      guard context != nil || operationError != nil, let expected = nativeSession else { return }
      let identity = context?.sessionIdentity, epoch = admissionEpoch
      if let current = try? await session.currentSession(),
        current.generation == expected.generation
      {
        return
      }
      guard admissionEpoch == epoch, nativeSession == expected,
        context?.sessionIdentity == identity else { return }
      stopRequested = true
      context = nil
      nativeSession = nil
      operationError = nil
      publish(event)
    case .authorizationRequired, .discovering, .opening, .wrongMode:
      if context == nil { publish(event) }
    }
  }
  public func connect() async throws {
    let epoch = admissionEpoch
    do { try await gate.withExclusiveAccess { try await self.connectOwned(epoch: epoch) } } catch {
      throw Self.failure(error)
    }
  }
  private func connectOwned(epoch: UInt64) async throws {
    guard epoch == admissionEpoch else { throw CameraServiceError.cancelled }
    try Task.checkCancellation()
    if let operationError { throw operationError }
    if context != nil && !stopRequested {
      try await validateCurrent()
      return
    }
    stopRequested = false
    await startMonitor()
    // Subscription can suspend while disconnect revokes this admission. No native open yet.
    try Task.checkCancellation()
    guard epoch == admissionEpoch, !stopRequested else { throw CameraServiceError.cancelled }
    publish(.opening)
    needsClose = true
    do {
      context = try await openVerified(epoch: epoch)
      let pending = try journal.unresolved()
      if !pending.isEmpty {
        guard try await handles().isEmpty else {
          throw CameraServiceError.uncertainOperation(pending[0].id)
        }
        // Fresh empty view reconciles absence only. Old acknowledgements/files stay honest;
        // no trigger/delete is replayed and no old uncertain file becomes a success.
        for var record in pending {
          record.phase = .reconciledMissing
          record.failure =
            "Fresh session observed no visible output; previous acknowledgement and input buffer remain unknown"
          try journal.save(record)
        }
      }
      try await validateCurrent()
      try await finishReady()
    } catch {
      let failure = Self.failure(error)
      if let retained = await sessionToRetain(after: failure) {
        pause(failure, message: Self.validationMessage(failure), session: retained)
        throw failure
      }
      let closed = await closeUncancelled()
      if !closed { throw CameraServiceError.closeUnconfirmed }
      throw failure
    }
  }
  /// Opens and verifies under the current operation permit. The owner decides when
  /// the returned context can be published; import's intermediate session stays private.
  private func openVerified(epoch: UInt64) async throws -> CameraExecutionContext {
    try Task.checkCancellation()
    guard epoch == admissionEpoch, !stopRequested else { throw CameraServiceError.cancelled }
    needsClose = true
    try await session.connect()
    nativeSession = try await session.currentSession()
    try Task.checkCancellation()
    guard epoch == admissionEpoch, !stopRequested else { throw CameraServiceError.cancelled }
    try await verifyCapabilities()
    try await validateCurrent()
    guard epoch == admissionEpoch, let nativeSession, let support = verifiedSupport else {
      throw CameraServiceError.cancelled
    }
    return CameraExecutionContext(
      model: support.model, firmware: support.firmware, capability: support.capability,
      supportVersion: support.supportVersion, sessionIdentity: UUID(),
      generation: nativeSession.generation)
  }
  private func reopenForImport(epoch: UInt64, attachment: UUID) async throws
    -> CameraExecutionContext
  {
    // Retire public affinity before native close callbacks can arrive. Only this owner
    // opens again, and a real detach is checked by currentSession on every command.
    let previousGeneration = nativeSession?.generation
    context = nil
    guard await closeUncancelled(publishState: false) else {
      throw CameraServiceError.closeUnconfirmed
    }
    try Task.checkCancellation()
    guard epoch == admissionEpoch, !stopRequested else { throw CameraServiceError.cancelled }
    let opened = try await openVerified(epoch: epoch)
    guard opened.generation != previousGeneration,
      nativeSession?.connection.attachmentIdentity == attachment
    else {
      throw CameraServiceError.unsupportedContext
    }
    return opened
  }
  private func withIO<T: Sendable>(
    temporarySelector: TemporaryBankSelector? = nil,
    _ body: @Sendable (CameraOperationIO) async throws -> T
  ) async throws -> T {
    let io = CameraOperationIO(temporarySelector: temporarySelector, settle: settle) {
      [weak self] opcode, parameters, data in
      guard let self else { throw CameraServiceError.notReady }
      return try await self.send(opcode, parameters, data)
    }
    do {
      let result = try await body(io)
      await io.finish()
      return result
    } catch {
      await io.finish()
      throw error
    }
  }
  private func verifyCapabilities() async throws {
    let info = try PTPDatasets.deviceInfo(await send(0x1001).data)
    let adapter = try registry.adapter(for: info)
    let support = try await withIO { try await adapter.verifyDevice(info, io: $0) }
    activeAdapter = adapter
    verifiedSupport = support
  }
  public func support(for expected: CameraExecutionContext) async throws -> VerifiedCameraSupport {
    let epoch = admissionEpoch
    return try await gate.withExclusiveAccess {
      let current = try await self.readExecutionContext(epoch: epoch)
      guard current == expected, let support = await self.currentSupport() else {
        throw CameraServiceError.unsupportedContext
      }
      return support
    }
  }
  private func currentSupport() -> VerifiedCameraSupport? { verifiedSupport }
  public func importRecipes() async throws -> ImportedRecipeCollection {
    let epoch = admissionEpoch
    let expected = context
    do {
      return try await gate.withExclusiveAccess {
        try await self.importOwned(epoch: epoch, expected: expected)
      }
    } catch { throw Self.failure(error) }
  }
  private func importOwned(epoch: UInt64, expected: CameraExecutionContext?) async throws
    -> ImportedRecipeCollection
  {
    guard let expected, context == expected, epoch == admissionEpoch else {
      throw CameraServiceError.notReady
    }
    guard verifiedSupport?.capabilities.recipeImport == .supported else {
      throw CameraServiceError.recipeImportUnavailable
    }
    var execution = try await admit(epoch: epoch)
    do {
      guard try await handles().isEmpty else { throw CameraServiceError.preexistingObjects }
      guard let adapter = activeAdapter, let support = verifiedSupport else {
        throw CameraServiceError.notReady
      }
      let operationEpoch: UInt64
      let attachment = nativeSession?.connection.attachmentIdentity
      if adapter.recipeImportSessionPolicy == .freshBeforeAndAfter {
        guard let attachment else { throw CameraServiceError.unsupportedContext }
        admissionEpoch &+= 1
        operationEpoch = admissionEpoch
        execution = try await reopenForImport(epoch: operationEpoch, attachment: attachment)
        guard verifiedSupport == support else { throw CameraServiceError.unsupportedContext }
      } else {
        operationEpoch = epoch
      }
      let importingContext = Self.recipeContext(execution)
      let result = try await withIO(temporarySelector: adapter.temporaryBankSelector) {
        try await adapter.importRecipes(io: $0, support: support, context: importingContext)
      }
      let ids = result.declaredSlots.map(\.id)
      guard result.declaredSlots == support.capabilities.bankSlots,
        Set(ids).count == ids.count, result.recipes.count == ids.count,
        Set(result.recipes.map(\.slot)) == Set(ids),
        Set(result.recipes.map(\.id)).count == result.recipes.count
      else { throw CameraServiceError.unsupportedContext }
      if adapter.recipeImportSessionPolicy == .freshBeforeAndAfter {
        guard let attachment else { throw CameraServiceError.unsupportedContext }
        execution = try await reopenForImport(epoch: operationEpoch, attachment: attachment)
        guard verifiedSupport == support else { throw CameraServiceError.unsupportedContext }
        context = execution
      }
      let current = Self.recipeContext(execution)
      let recipes = result.recipes.map { r in
        let issues: [RecipeRenderingIssue]
        switch r.renderingSupport(using: RecipeCodecRegistry()) {
        case .supported: issues = []
        case .unsupported(let observed): issues = observed
        }
        return RecipeSnapshot(
          id: r.id, slot: r.slot, name: r.name, importedName: r.importedName,
          importedSettings: r.importedSettings, settingsDigest: r.settingsDigest,
          cameraContext: current, importedAt: r.importedAt, renderingIssues: issues)
      }
      try await finishReady()
      return ImportedRecipeCollection(
        recipes: recipes, declaredSlots: result.declaredSlots, context: execution, support: support)
    } catch {
      let failure = Self.failure(error)
      if let retained = await sessionToRetain(after: failure) {
        pause(failure, message: Self.validationMessage(failure), session: retained)
        throw failure
      }
      if !(await closeUncancelled()) { throw CameraServiceError.closeUnconfirmed }
      throw failure
    }
  }
  private static func recipeContext(_ execution: CameraExecutionContext) -> RecipeCameraContext {
    .init(
      model: execution.model, firmware: execution.firmware, capability: execution.capability,
      sessionIdentity: execution.sessionIdentity, sessionGeneration: execution.generation)
  }
  public func render(raw: PreparedRAW, recipe: RecipeSnapshot, policy: OutputPolicy) async throws
    -> CameraJPEG
  {
    let epoch = admissionEpoch
    let expected = context
    do {
      return try await gate.withExclusiveAccess {
        guard let expected, await self.matches(expected, epoch: epoch) else {
          throw CameraServiceError.notReady
        }
        return try await self.renderOwned(raw: raw, recipe: recipe, policy: policy, epoch: epoch)
      }
    } catch { throw Self.failure(error) }  // A rejected/cancelled waiter owns no close responsibility.
  }
  private func matches(_ expected: CameraExecutionContext, epoch: UInt64) -> Bool {
    context == expected && admissionEpoch == epoch && !stopRequested
  }
  private func renderOwned(
    raw: PreparedRAW, recipe: RecipeSnapshot, policy: OutputPolicy, epoch: UInt64
  ) async throws -> CameraJPEG {
    guard let adapter = activeAdapter, let support = verifiedSupport,
      recipe.cameraContext.model == support.model,
      recipe.cameraContext.firmware == support.firmware,
      recipe.cameraContext.capability == support.capability
    else { throw CameraServiceError.unsupportedContext }
    try adapter.validateSource(raw.metadata)
    _ = try adapter.decodeRecipe(recipe).requireSettings()
    let dialect = adapter.conversionDialect
    guard try ResourceChecksum.sha256(raw.fileURL) == raw.sha256 else {
      throw CameraServiceError.sourceChanged
    }
    let execution = try await admit(epoch: epoch)
    var record: CameraOperationRecord
    do { record = try journal.create(raw: raw, recipe: recipe, context: execution) } catch {
      _ = await closeUncancelled()
      throw CameraServiceError.storage
    }
    do {
      guard try await handles().isEmpty else { throw CameraServiceError.preexistingObjects }
      record.initialViewEmpty = true
      record.phase = .uploadIntent
      try journal.save(record)
      do {
        let size = try raw.fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        let info = try dialect.uploadInfo(byteCount: size)
        let payload = try Data(contentsOf: raw.fileURL, options: .mappedIfSafe)
        guard payload.count == size, ResourceChecksum.sha256(payload) == raw.sha256 else {
          throw CameraServiceError.sourceChanged
        }
        _ = try await send(dialect.uploadInfoOpcode, [0, 0, 0], info)
        _ = try await send(dialect.uploadOpcode, [], payload)
      }
      let baseline = try await send(0x1015, [dialect.profileProperty]).data
      let patch = try adapter.prepareConversion(
        baseline: baseline, source: raw.metadata, recipe: recipe, support: support, policy: policy)
      record.baselineSHA256 = patch.baselineSHA256
      record.candidateSHA256 = patch.candidateSHA256
      record.phase = .baselineReceived
      try journal.store(baseline, name: "baseline.bin", id: record.id)
      try journal.store(patch.bytes, name: "candidate.bin", id: record.id)
      try journal.save(record)
      record.phase = .profileIntent
      try journal.save(record)
      _ = try await send(0x1016, [dialect.profileProperty], patch.bytes)
      let readback = try await send(0x1015, [dialect.profileProperty]).data
      guard readback == patch.bytes else { throw CameraServiceError.profileReadbackMismatch }
      try journal.store(readback, name: "readback.bin", id: record.id)
      record.phase = .profileAccepted
      try journal.save(record)
      guard try await handles().isEmpty else { throw CameraServiceError.preexistingObjects }
      record.triggerIntent = true
      record.phase = .triggerIntent
      try journal.save(record)
      _ = try await send(0x1016, [dialect.triggerProperty], dialect.triggerValue)
      record.triggerAcknowledged = true
      record.phase = .triggerAccepted
      try journal.save(record)
      let handle = try await awaitOutput()
      record.outputHandle = handle
      let object = try await send(0x1008, [handle]).data
      // Retain rejected metadata too; a failed conversion may leave the camera
      // unavailable for later inspection. Dataset decoding is bounded to 4 KiB.
      record.objectInfo = Data(object.prefix(4096))
      try journal.save(record)
      let info: PTPObjectInfo
      do { info = try FujiConversionCodec.objectInfo(object) } catch {
        record.failure = "The camera returned unreadable information for the converted photo."
        throw error
      }
      if let issue = Self.outputMetadataIssue(info, dialect: dialect, source: raw.metadata) {
        record.failure = issue
        throw CameraServiceError.invalidOutput
      }
      let storage = try await send(0x1005, [info.storageID]).data
      record.storageInfo = Data(storage.prefix(4096))
      try journal.save(record)
      let storageInfo: PTPStorageInfo
      do { storageInfo = try FujiConversionCodec.storageInfo(storage) } catch {
        record.failure = "The camera returned unreadable storage information for the converted photo."
        throw error
      }
      guard storageInfo.storageType == 3, storageInfo.filesystemType == 2, storageInfo.access == 2
      else {
        record.failure = "The camera reported an unexpected storage location for the converted photo."
        throw CameraServiceError.ownershipChanged
      }
      guard try await handles() == [handle] else { throw CameraServiceError.ownershipChanged }
      let assessment: CameraOutputAssessment
      let outputURL: URL
      do {
        let payload = try await send(0x1009, [handle]).data
        guard payload.count == info.byteCount else { throw CameraServiceError.invalidOutput }
        try await revalidate(
          handle: handle, object: object, storage: storage, storageID: info.storageID)
        do { assessment = try adapter.validateOutput(payload, conversion: patch) } catch {
          record.failure = Self.jpegValidationMessage(error)
          throw error
        }
        record.outputSHA256 = ResourceChecksum.sha256(payload)
        outputURL = try journal.store(payload, name: "output.JPG", id: record.id)
      }
      let metadata = assessment.metadata
      record.outputValidated = true
      record.phase = .captured
      try journal.save(record)
      try await cleanup(record: &record, outputURL: outputURL, info: info)
      try await validateCurrent()
      let report: EffectiveRecipeReport
      switch assessment.admission {
      case .accepted(let accepted): report = accepted
      case .rejected(let mismatch):
        record.recipeMismatch = mismatch
        record.failure = mismatch.summary
        throw CameraServiceError.invalidOutput
      }
      let key = RenderKey(
        sourceID: raw.sourceID, sourceRevision: raw.sourceRevision, sourceSHA256: raw.sha256,
        settingsDigest: recipe.settingsDigest, cameraContext: execution,
        width: metadata.width, height: metadata.height, orientation: metadata.orientation,
        policy: policy, quality: .fullResolutionFine)
      let result = CameraJPEG(
        fileURL: outputURL, sourceID: raw.sourceID, sourceRevision: raw.sourceRevision,
        sourceSHA256: raw.sha256, recipeSnapshotID: recipe.id,
        settingsDigest: recipe.settingsDigest,
        cameraContext: execution, operationID: record.id, width: metadata.width,
        height: metadata.height, orientation: metadata.orientation, quality: .fullResolutionFine,
        effectiveRecipe: report,
        baselineSHA256: patch.baselineSHA256, candidateSHA256: patch.candidateSHA256,
        outputSHA256: record.outputSHA256!, key: key)
      record.result = result
      record.phase = .completed
      try journal.save(record)
      try await finishReady()
      return result
    } catch {
      let failure = Self.failure(error)
      record.failure = record.failure ?? Self.validationMessage(failure)
      let retained = await sessionToRetain(after: failure)
      let closed: Bool
      if retained != nil { closed = false; record.closure = "notRequested" }
      else { closed = await closeUncancelled(); record.closure = closed ? "confirmed" : "unconfirmed" }
      let uncertain = (record.triggerIntent && !record.emptyViewVerified) || (retained == nil && !closed)
      record.phase = uncertain ? .uncertain : .aborted
      do { try journal.save(record) } catch {
        if retained != nil { _ = await closeUncancelled() }
        throw CameraServiceError.uncertainOperation(record.id)
      }
      if let retained { pause(failure, message: record.failure!, session: retained) }
      if uncertain { throw CameraServiceError.uncertainOperation(record.id) }
      throw failure
    }
  }
  private func cleanup(record: inout CameraOperationRecord, outputURL: URL, info: PTPObjectInfo)
    async throws
  {
    guard let handle = record.outputHandle, let object = record.objectInfo,
      let storage = record.storageInfo, let hash = record.outputSHA256,
      try ResourceChecksum.sha256(outputURL) == hash
    else { throw CameraServiceError.ownershipChanged }
    try await revalidate(
      handle: handle, object: object, storage: storage, storageID: info.storageID)
    do {
      let live = try await send(0x1009, [handle]).data
      guard live.count == info.byteCount, ResourceChecksum.sha256(live) == hash else {
        throw CameraServiceError.ownershipChanged
      }
    }
    try journal.beginDelete(&record)
    try await revalidate(
      handle: handle, object: object, storage: storage, storageID: info.storageID)
    _ = try await send(0x100B, [handle, 0])
    record.deleteAcknowledged = true
    record.phase = .deleteAcknowledged
    try journal.save(record)
    guard try await handles().isEmpty else { throw CameraServiceError.ownershipChanged }
    record.emptyViewVerified = true
    try journal.save(record)
  }
  private func revalidate(handle: UInt32, object: Data, storage: Data, storageID: UInt32)
    async throws
  {
    guard try await handles() == [handle], try await send(0x1008, [handle]).data == object,
      try await send(0x1005, [storageID]).data == storage, try await handles() == [handle]
    else { throw CameraServiceError.ownershipChanged }
  }
  private func awaitOutput() async throws -> UInt32 {
    let clock = ContinuousClock()
    let deadline = ContinuousClock.now.advanced(by: .seconds(30))
    for _ in 0..<20 {
      let current = try await handles()
      guard clock.now <= deadline else { throw CameraServiceError.timeout }
      guard current.count <= 1 else { throw CameraServiceError.ownershipChanged }
      if let handle = current.first { return handle }
      try await pollWait()
    }
    throw CameraServiceError.timeout
  }
  private func handles() async throws -> [UInt32] {
    try FujiConversionCodec.objectHandles(await send(0x1007, [UInt32.max, 0, 0]).data)
  }
  private func admit(epoch: UInt64) async throws -> CameraExecutionContext {
    if let operationError { throw operationError }
    guard epoch == admissionEpoch, !stopRequested, let context, let nativeSession else {
      throw CameraServiceError.notReady
    }
    try await validateCurrent()
    if let pending = try journal.unresolved().first {
      throw CameraServiceError.uncertainOperation(pending.id)
    }
    publish(.busy(nativeSession))
    return context
  }
  private func finishReady() async throws {
    try await validateCurrent()
    guard let nativeSession, context != nil else { throw CameraServiceError.notReady }
    publish(.ready(nativeSession))
  }
  private func validateCurrent() async throws {
    try Task.checkCancellation()
    guard !stopRequested, let expected = nativeSession else { throw CameraServiceError.cancelled }
    guard try await session.currentSession().generation == expected.generation else {
      throw CameraServiceError.unsupportedContext
    }
    try Task.checkCancellation()
    guard !stopRequested else { throw CameraServiceError.cancelled }
  }
  private func send(_ opcode: UInt16, _ parameters: [UInt32] = [], _ data: Data? = nil) async throws
    -> PTPReply
  {
    try await validateCurrent()
    guard transaction < UInt32.max else { throw CameraServiceError.unsupportedContext }
    let command = PTPCommand(opcode: opcode, parameters: parameters, transactionID: transaction)
    transaction += 1
    let reply = try await session.execute(command, data: data)
    try await validateCurrent()
    guard reply.responseCode == 0x2001 else { throw PTPError.responseCode(reply.responseCode) }
    return reply
  }
  public func disconnect() async {
    admissionEpoch &+= 1
    stopRequested = true
    let owner = Task.detached {
      try await self.gate.withExclusiveAccess { _ = await self.closeUncancelled() }
    }
    _ = try? await owner.value
  }
  public func resetConnection() async throws {
    admissionEpoch &+= 1
    let epoch = admissionEpoch
    stopRequested = true
    do {
      try await gate.withExclusiveAccess { try await self.resetOwned(epoch: epoch) }
    } catch { throw Self.failure(error) }
  }
  private func resetOwned(epoch: UInt64) async throws {
    guard epoch == admissionEpoch else { throw CameraServiceError.cancelled }
    try Task.checkCancellation()
    stopRequested = false
    do {
      if nativeSession != nil {
        do { try await reconcileForReset() } catch {
          // An explicit reset still tries one native close/reopen when metadata
          // cannot be trusted. No unknown object is deleted; only a fresh empty
          // view can clear its unresolved journal after reopening.
          guard await sessionToRetain(after: Self.failure(error)) != nil else { throw error }
        }
      }
      // Retire the public affinity before our own native close event arrives.
      context = nil
      operationError = nil
      guard await closeUncancelled(publishState: false) else { throw CameraServiceError.closeUnconfirmed }
      try await connectOwned(epoch: epoch)
    } catch {
      let failure = Self.failure(error)
      if let retained = await sessionToRetain(after: failure) {
        pause(failure, message: "Reset could not finish. " + Self.validationMessage(failure), session: retained)
      }
      throw failure
    }
  }
  private func reconcileForReset() async throws {
    let pending = try journal.unresolved()
    let visible = try await handles()
    if visible.isEmpty {
      for var record in pending {
        record.phase = .reconciledMissing
        try journal.save(record)
      }
      return
    }
    guard pending.count == 1, var record = pending.first, record.context == context,
      record.initialViewEmpty, record.triggerAcknowledged,
      let handle = record.outputHandle, visible == [handle], !record.deleteIntent,
      let dialect = activeAdapter?.conversionDialect
    else { throw CameraServiceError.preexistingObjects }
    // Only a stable JPEG in the camera's measured temporary conversion storage
    // can be discarded. Unknown/card objects and an old session are never deleted.
    let object = try await send(0x1008, [handle]).data
    let info = try FujiConversionCodec.objectInfo(object)
    guard info.format == 0x3801, info.protection == 0, info.byteCount > 0,
      info.byteCount <= PTPCodec.maximumDataBytes,
      dialect.outputAssociationTypes.contains(info.associationType)
    else { throw CameraServiceError.invalidOutput }
    let storage = try await send(0x1005, [info.storageID]).data
    let storageInfo = try FujiConversionCodec.storageInfo(storage)
    guard storageInfo.storageType == 3, storageInfo.filesystemType == 2, storageInfo.access == 2
    else { throw CameraServiceError.ownershipChanged }
    try await revalidate(handle: handle, object: object, storage: storage, storageID: info.storageID)
    let hash: String
    do {
      let data = try await send(0x1009, [handle]).data
      guard data.count == info.byteCount else { throw CameraServiceError.invalidOutput }
      hash = ResourceChecksum.sha256(data)
    }
    if let originalHash = record.outputSHA256 ?? record.discardOutputSHA256, originalHash != hash {
      throw CameraServiceError.ownershipChanged
    }
    record.discardObjectInfo = object
    record.discardStorageInfo = storage
    record.discardOutputSHA256 = hash
    try journal.save(record)
    try await revalidate(handle: handle, object: object, storage: storage, storageID: info.storageID)
    do {
      let data = try await send(0x1009, [handle]).data
      guard data.count == info.byteCount, ResourceChecksum.sha256(data) == hash else {
        throw CameraServiceError.ownershipChanged
      }
    }
    try journal.beginDiscard(&record)
    do {
      try await revalidate(handle: handle, object: object, storage: storage, storageID: info.storageID)
      _ = try await send(0x100B, [handle, 0])
      record.deleteAcknowledged = true
      record.phase = .deleteAcknowledged
      try journal.save(record)
      guard try await handles().isEmpty else { throw CameraServiceError.ownershipChanged }
      record.emptyViewVerified = true
      record.phase = .aborted
      try journal.save(record)
    } catch {
      record.phase = .uncertain
      try journal.save(record)
      throw error
    }
  }
  private func sessionToRetain(after failure: CameraServiceError) async -> CameraSession? {
    switch failure {
    case .invalidOutput, .ownershipChanged, .profileReadbackMismatch, .unsupportedProfile,
      .unsupportedContext, .preexistingObjects, .uncertainOperation, .recipeImportFailed,
      .transport(.responseCode): break
    default: return nil
    }
    guard !stopRequested, let expected = nativeSession,
      let current = try? await session.currentSession(), current.generation == expected.generation,
      !stopRequested, nativeSession == expected else { return nil }
    return current
  }
  private func pause(_ failure: CameraServiceError, message: String, session: CameraSession) {
    operationError = failure
    publish(.attentionRequired(session, message: message))
  }
  private static func outputMetadataIssue(_ info: PTPObjectInfo, dialect: FujiRAWConversionDialect, source: RAWMetadata) -> String? {
    if info.format != 0x3801 { return "The camera reported an unexpected image format for the converted photo (expected JPEG)." }
    if info.protection != 0 { return "The camera reported the temporary converted photo as protected." }
    if info.byteCount == 0 { return "The camera reported a converted photo with no image data (0 bytes)." }
    if info.byteCount > PTPCodec.maximumDataBytes { return "The camera reported a converted photo larger than the supported transfer size." }
    if !dialect.outputAssociationTypes.contains(info.associationType) { return "The camera reported an unexpected type of temporary conversion output." }
    if (info.width != 0 && info.width != source.recordedGeometry.width) || (info.height != 0 && info.height != source.recordedGeometry.height) {
      return "The camera reported unexpected photo dimensions: \(info.width) × \(info.height); expected \(source.recordedGeometry.width) × \(source.recordedGeometry.height)."
    }
    return nil
  }
  private static func jpegValidationMessage(_ error: any Error) -> String {
    switch error {
    case FujiJPEGValidationError.notFine, FujiJPEGValidationError.unsupportedQuality: "The camera returned a photo with unexpected JPEG quality (expected FINE)."
    case FujiJPEGValidationError.cameraMismatch: "The converted photo reports a different camera model."
    case FujiJPEGValidationError.geometryMismatch: "The converted photo has different dimensions from the original."
    case FujiJPEGValidationError.orientationMismatch: "The converted photo has a different orientation from the original."
    case FujiJPEGValidationError.missingMetadata: "The converted photo is missing required image metadata."
    default: "The converted photo contains unreadable or unexpected image metadata."
    }
  }
  private static func validationMessage(_ failure: CameraServiceError) -> String {
    switch failure {
    case .invalidOutput: "The camera returned unreadable or unexpected conversion output."
    case .ownershipChanged: "The camera's temporary conversion output changed unexpectedly."
    case .profileReadbackMismatch: "The camera returned different processing settings than were sent."
    case .unsupportedProfile: "The camera returned processing settings this app does not recognize."
    case .unsupportedContext: "The camera returned an unsupported model, firmware, or conversion mode."
    case .preexistingObjects, .uncertainOperation: "An unfinished conversion could not be safely cleared. Reset the camera connection to try again."
    case .recipeImportFailed: "The camera returned an incomplete or unexpected recipe collection."
    case .transport(.responseCode(let code)): "The camera declined the operation (error \(String(format: "0x%04X", code)))."
    default: safeFailure(failure)
    }
  }
  private func closeUncancelled(publishState: Bool = true) async -> Bool {
    let expected = nativeSession?.generation
    let task = Task.detached {
      await self.closeOwned(expected: expected, publishState: publishState)
    }
    return await task.value
  }
  private func closeOwned(expected: UInt64?, publishState: Bool) async -> Bool {
    guard needsClose else { return true }
    do {
      if let expected, let current = try? await session.currentSession(),
        current.generation != expected
      {
        throw CameraServiceError.closeUnconfirmed
      }
      try await session.close()
      needsClose = false
      nativeSession = nil
      context = nil
      activeAdapter = nil
      verifiedSupport = nil
      operationError = nil
      if publishState { publish(.disconnected) }
      return true
    } catch {
      context = nil
      publish(.recoverableError(.sessionFailure("Native close unconfirmed")))
      return false
    }
  }
  public static func failure(_ error: any Error) -> CameraServiceError {
    if let error = error as? CameraServiceError { return error }
    if error is CancellationError { return .cancelled }
    if let error = error as? PTPError { return .transport(error) }
    if error is FujiJPEGValidationError || error is PTPDatasetError { return .invalidOutput }
    if let error = error as? ResourceError, error == .checksumMismatch { return .sourceChanged }
    return .storage
  }
  public static func safeFailure(_ error: CameraServiceError) -> String {
    switch error {
    case .transport: return "camera transport failed"
    case .uncertainOperation: return "camera operation uncertain"
    default: return String(describing: error)
    }
  }
}
