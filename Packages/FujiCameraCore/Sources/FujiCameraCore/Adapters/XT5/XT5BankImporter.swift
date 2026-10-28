import Foundation

public enum XT5BankImportIssue: Error, Sendable, Equatable {
  case sessionChanged, unsupportedContext, missingProperties, invalidSelector
  case selectorMismatch
  case bankChanged(Int)
  case originalBankChanged, restorationTimeout
}

public enum XT5SelectorRestoration: String, Sendable, Codable {
  case notNeeded, pending, verified, unconfirmed
}

public struct XT5BankImportEvidence: Sendable, Encodable {
  public struct CommandFailure: Sendable, Encodable {
    public let stage: String
    public let opcode: String
    public let property: String?
    public let responseCode: String?
    public init(stage: String, opcode: String, property: String? = nil, responseCode: String? = nil)
    {
      self.stage = stage
      self.opcode = opcode
      self.property = property
      self.responseCode = responseCode
    }

  }
  public struct Comparison: Sendable, Encodable {
    public let slot: Int
    public let namesMatch: Bool
    public let settingsMatch: Bool
    public init(slot: Int, namesMatch: Bool, settingsMatch: Bool) {
      self.slot = slot
      self.namesMatch = namesMatch
      self.settingsMatch = settingsMatch
    }

  }
  public let schemaVersion = 1
  public let observedAt = Date()
  public var model: String?
  public var firmware: String?
  public var capability: String?
  public var originalSelector: Int?
  public var restoredSelector: Int?
  public var beforeSlots: [Int] = []
  public var afterSlots: [Int] = []
  public var comparisons: [Comparison] = []
  public var restoration: XT5SelectorRestoration = .notNeeded
  public var failure: String?
  public var restorationFailure: String?
  public var firstFailedCommand: CommandFailure?
  public var complete = false
  public let conversionValidated = false
  public let settingsPerBank = 23
  public init(
    model: String? = nil, firmware: String? = nil, capability: String? = nil,
    originalSelector: Int? = nil, restoredSelector: Int? = nil, beforeSlots: [Int] = [],
    afterSlots: [Int] = [], comparisons: [Comparison] = [],
    restoration: XT5SelectorRestoration = .notNeeded, failure: String? = nil,
    restorationFailure: String? = nil, firstFailedCommand: CommandFailure? = nil,
    complete: Bool = false
  ) {
    self.model = model
    self.firmware = firmware
    self.capability = capability
    self.originalSelector = originalSelector
    self.restoredSelector = restoredSelector
    self.beforeSlots = beforeSlots
    self.afterSlots = afterSlots
    self.comparisons = comparisons
    self.restoration = restoration
    self.failure = failure
    self.restorationFailure = restorationFailure
    self.firstFailedCommand = firstFailedCommand
    self.complete = complete
  }

  // No names, identifiers, hashes, or raw property values in public evidence.
}

public struct XT5BankImportUpdate: Sendable {
  public let evidence: XT5BankImportEvidence
  public let snapshots: [RecipeSnapshot]
  public let verificationSnapshots: [RecipeSnapshot]
  public init(
    evidence: XT5BankImportEvidence, snapshots: [RecipeSnapshot],
    verificationSnapshots: [RecipeSnapshot]
  ) {
    self.evidence = evidence
    self.snapshots = snapshots
    self.verificationSnapshots = verificationSnapshots
  }

}

public struct XT5BankImportResult: Sendable {
  public let evidence: XT5BankImportEvidence
  public let recipes: [RecipeSnapshot]
  public init(evidence: XT5BankImportEvidence, recipes: [RecipeSnapshot]) {
    self.evidence = evidence
    self.recipes = recipes
  }

}

public struct XT5BankImportFailure: Error, Sendable {
  public let evidence: XT5BankImportEvidence
  public init(evidence: XT5BankImportEvidence) { self.evidence = evidence }

}

/// Restricted to the actually observed X-T5 4.31 / _0200 protocol context. This importer owns no
/// connection/retry policy. The required validator binds every command to the original live session.
public actor XT5BankImporter {
  private let transport: any PTPTransport
  private let sessionGeneration: UInt64
  private let sessionIdentity = UUID()
  private let validateSession: @Sendable () async throws -> Void
  private let settle: @Sendable (Duration) async throws -> Void
  private let cleanupTimeout: Duration
  private let gate: SerialCameraGate
  private var transaction: UInt32 = 1
  private var commandStage = "preflight"
  private var firstFailedCommand: XT5BankImportEvidence.CommandFailure?

  public init(
    transport: any PTPTransport, sessionGeneration: UInt64,
    validateSession: @escaping @Sendable () async throws -> Void,
    settle: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
    cleanupTimeout: Duration = .seconds(10),
    gate: SerialCameraGate = SerialCameraGate()
  ) {
    self.transport = transport
    self.sessionGeneration = sessionGeneration
    self.validateSession = validateSession
    self.settle = settle
    self.gate = gate
    self.cleanupTimeout = cleanupTimeout
  }

  public func importRecipesVerified(
    onUpdate: @escaping @Sendable (XT5BankImportUpdate) async -> Void = { _ in }
  ) async throws -> XT5BankImportResult {
    try await gate.withExclusiveAccess { try await self.importExclusively(onUpdate: onUpdate) }
  }

  private func importExclusively(onUpdate: @Sendable (XT5BankImportUpdate) async -> Void)
    async throws -> XT5BankImportResult
  {
    commandStage = "preflight"
    firstFailedCommand = nil
    var evidence = XT5BankImportEvidence()
    var snapshots: [RecipeSnapshot] = []
    var verificationSnapshots: [RecipeSnapshot] = []
    var initial: RecipeSnapshot?
    var context: RecipeCameraContext?
    var selectorAttempted = false
    await onUpdate(
      XT5BankImportUpdate(
        evidence: evidence, snapshots: snapshots, verificationSnapshots: verificationSnapshots))
    do {
      let info = try XT5RecipeCodec.deviceInfo(await send(0x1001))
      guard info.manufacturer == "FUJIFILM", info.model == "X-T5", info.firmware == "4.31" else {
        throw XT5BankImportIssue.unsupportedContext
      }
      let properties: [UInt16] = [0xD16E, 0xD186, 0xD187, 0xD18C, 0xD18D] + Array(0xD18E...0xD1A4)
      guard [UInt16(0x1015), 0x1016].allSatisfy(info.operations.contains),
        properties.allSatisfy(info.properties.contains)
      else { throw XT5BankImportIssue.missingProperties }
      guard try await send(0x1015, property: 0xD16E) == Data([6, 0]) else {
        throw XT5BankImportIssue.unsupportedContext
      }
      for code: UInt16 in [0xD186, 0xD187] {
        let key = try XT5RecipeCodec.value(await send(0x1015, property: code), type: 0xffff).string
        guard key == "X-T5_0200" else { throw XT5BankImportIssue.unsupportedContext }
      }
      commandStage = "initial selector"
      let current = try await selectedSlot()
      let camera = RecipeCameraContext(
        model: "X-T5", firmware: "4.31", capability: "X-T5_0200", sessionIdentity: sessionIdentity,
        sessionGeneration: sessionGeneration)
      context = camera
      evidence.model = camera.model
      evidence.firmware = camera.firmware
      evidence.capability = camera.capability
      evidence.originalSelector = current
      commandStage = "initial bank"
      initial = try await readBank(current, context: camera)
      for pass in 1...2 {
        for slot in 1...7 {
          try Task.checkCancellation()
          selectorAttempted = true  // A failed reply cannot prove that a write had no effect.
          evidence.restoration = .pending
          commandStage = "scan \(pass) C\(slot)"
          try await select(slot)
          let bank = try await readBank(slot, context: camera)
          if pass == 1 {
            snapshots.append(bank)
            evidence.beforeSlots.append(slot)
            if slot == current, let initial, !sameContents(initial, bank) {
              throw XT5BankImportIssue.bankChanged(slot)
            }
          } else {
            verificationSnapshots.append(bank)
            let before = snapshots[slot - 1]
            let comparison = XT5BankImportEvidence.Comparison(
              slot: slot, namesMatch: before.importedName == bank.importedName,
              settingsMatch: before.importedSettings == bank.importedSettings)
            evidence.afterSlots.append(slot)
            evidence.comparisons.append(comparison)
            guard comparison.namesMatch && comparison.settingsMatch else {
              throw XT5BankImportIssue.bankChanged(slot)
            }
          }
          await onUpdate(
            XT5BankImportUpdate(
              evidence: evidence, snapshots: snapshots, verificationSnapshots: verificationSnapshots
            ))
        }
      }
      try Task.checkCancellation()
    } catch { evidence.failure = Self.safeFailure(error) }

    if selectorAttempted, let initial, let context {
      // A cancelled parent cannot cancel this one bounded cleanup attempt. The operation gate
      // is held until cleanup returns. No reconnect; validator rejects a different/closed run.
      let cleanup = Task.detached { try await self.restoreBounded(initial, context: context) }
      do {
        try await cleanup.value
        evidence.restoration = .verified
        evidence.restoredSelector = initial.slot
      } catch {
        evidence.restoration = .unconfirmed
        evidence.restorationFailure = Self.safeFailure(error)
      }
    }
    if evidence.failure == nil && Task.isCancelled { evidence.failure = "cancelled" }
    evidence.firstFailedCommand = firstFailedCommand
    evidence.complete =
      evidence.failure == nil && evidence.restoration == .verified
      && evidence.comparisons.count == 7
    await onUpdate(
      XT5BankImportUpdate(
        evidence: evidence, snapshots: snapshots, verificationSnapshots: verificationSnapshots))
    guard evidence.complete else { throw XT5BankImportFailure(evidence: evidence) }
    return XT5BankImportResult(evidence: evidence, recipes: snapshots)
  }

  private func restoreBounded(_ initial: RecipeSnapshot, context: RecipeCameraContext) async throws
  {
    commandStage = "restoration"
    try await withThrowingTaskGroup(of: Void.self) { group in
      group.addTask {
        try await self.select(initial.slot)
        let restored = try await self.readBank(initial.slot, context: context)
        guard self.sameContents(initial, restored) else {
          throw XT5BankImportIssue.originalBankChanged
        }
      }
      group.addTask {
        try await Task.sleep(for: self.cleanupTimeout)
        throw XT5BankImportIssue.restorationTimeout
      }
      defer { group.cancelAll() }
      try await group.next()
    }
  }
  private func select(_ slot: Int) async throws {
    guard (1...7).contains(slot) else { throw XT5BankImportIssue.invalidSelector }
    _ = try await send(
      0x1016, property: 0xD18C, data: Data([UInt8(slot), 0]),
      stage: "\(commandStage) selector write")
    try await settle(.milliseconds(100))
    guard try await selectedSlot(stage: "\(commandStage) selector readback") == slot else {
      throw XT5BankImportIssue.selectorMismatch
    }
  }
  private func selectedSlot(stage: String? = nil) async throws -> Int {
    let bytes = try await send(0x1015, property: 0xD18C, stage: stage)
    guard bytes.count == 2, bytes[bytes.startIndex + 1] == 0,
      (1...7).contains(bytes[bytes.startIndex])
    else { throw XT5BankImportIssue.invalidSelector }
    return Int(bytes[bytes.startIndex])
  }
  private func readBank(_ slot: Int, context: RecipeCameraContext) async throws -> RecipeSnapshot {
    let name = try await send(0x1015, property: 0xD18D)
    guard name.count <= 511 else { throw XT5ProtocolError.oversized }
    var properties: [UInt16: Data] = [:]
    for code in UInt16(0xD18E)...0xD1A4 {
      let bytes = try await send(0x1015, property: code)
      guard bytes.count == 2 else { throw RecipeImportError.malformedProperty(code) }
      properties[code] = bytes
    }
    guard try await selectedSlot(stage: "\(commandStage) bank selector guard") == slot else {
      throw XT5BankImportIssue.selectorMismatch
    }
    return try XT5RecipeCodec.recipe(
      slot: slot, nameData: name, properties: properties, context: context, importedAt: Date())
  }
  private nonisolated func sameContents(_ a: RecipeSnapshot, _ b: RecipeSnapshot) -> Bool {
    a.importedName == b.importedName && a.importedSettings == b.importedSettings
  }
  private func send(
    _ opcode: UInt16, property: UInt16? = nil, data: Data? = nil, stage: String? = nil
  ) async throws -> Data {
    try Task.checkCancellation()
    try await validateSession()
    try Task.checkCancellation()
    guard transaction < UInt32.max else { throw PTPError.invalidParameters }
    let id = transaction
    transaction += 1
    let reply: PTPReply
    do {
      reply = try await transport.execute(
        PTPCommand(
          opcode: opcode, parameters: property.map { [UInt32($0)] } ?? [], transactionID: id),
        data: data)
    } catch {
      // Capture once: restoration may fail differently but must not overwrite the command
      // that first failed. No payload, bank name, object handle or private value is retained.
      if firstFailedCommand == nil {
        var responseCode: String?
        if let ptp = error as? PTPError, case .responseCode(let code) = ptp {
          responseCode = String(format: "0x%04X", code)
        }
        firstFailedCommand = .init(
          stage: stage ?? commandStage, opcode: String(format: "0x%04X", opcode),
          property: property.map { String(format: "0x%04X", $0) }, responseCode: responseCode)
      }
      throw error
    }

    try await validateSession()
    return reply.data
  }
  public static func safeFailure(_ error: any Error) -> String {
    if let issue = error as? XT5BankImportIssue { return String(describing: issue) }
    if let issue = error as? RecipeImportError {
      switch issue {
      case .invalidSlot: return "invalid slot"
      case .incompletePropertyBlock: return "incomplete property block"
      case .malformedProperty(let code): return String(format: "malformed property 0x%04X", code)
      case .unsupportedRendering: return "unsupported rendering"
      }
    }
    return safeError(error)
  }
  public static func safeError(_ error: any Error) -> String {
    if let error = error as? XT5ProtocolError { return String(describing: error) }
    if let error = error as? PTPError {
      switch error {
      case .responseCode(let code): return "PTP response \(String(format: "0x%04X", code))"
      case .authorizationDenied: return "authorization denied or restricted"
      case .timeout: return "transport timeout"
      case .notConnected: return "session unavailable"
      case .sessionClosing: return "session closing or quarantined"
      default: return "transport failure (details redacted)"
      }
    }
    if error is CancellationError { return "cancelled" }
    return "failure (details redacted)"
  }
}
