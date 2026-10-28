import Foundation
import Testing

@testable import FujiCameraCore

struct RecipeImportSessionTests {
  @Test(arguments: ["close1", "close2", "identity2", "identity3", "generation"])
  func failedTransitionsCannotPublishReceiptOrRepeatRead(_ failure: String) async throws {
    let f = try ImportSessionFixture(failure: failure)
    defer { f.remove() }
    try await f.service.connect()
    await #expect(throws: CameraServiceError.self) { try await f.service.importRecipes() }
    await #expect(throws: CameraServiceError.self) { try await f.service.executionContext() }
    #expect(await f.wire.backupReads <= (failure == "close2" || failure == "identity3" ? 1 : 0))
  }
  @Test func backupUsesExactlyOneReadBetweenFreshSessions() async throws {
    let f = try ImportSessionFixture()
    defer { f.remove() }
    var states = await f.service.states().makeAsyncIterator()
    try await f.service.connect()
    let before = try await f.service.executionContext()
    let receipt = try await f.service.importRecipes()
    #expect(await f.wire.backupReads == 1)
    #expect(receipt.context.generation == 3)
    #expect(receipt.context.sessionIdentity != before.sessionIdentity)
    #expect(
      receipt.recipes.allSatisfy {
        $0.cameraContext.sessionGeneration == receipt.context.generation
          && $0.cameraContext.sessionIdentity == receipt.context.sessionIdentity
      })
    #expect(try await f.service.executionContext() == receipt.context)
    #expect(
      await f.wire.events.filter { $0.hasPrefix("open") || $0.hasPrefix("close") || $0 == "backup" }
        == ["open1", "close1", "open2", "backup", "close2", "open3"])
    #expect(await f.wire.writes == 0)
    #expect(await states.next() == .disconnected)
    #expect(await states.next() == .opening)
    guard case .ready(let firstSession) = await states.next() else { Issue.record("Missing initial ready");return }
    #expect(firstSession.generation == 1)
    #expect(await states.next() == .busy(firstSession))
    guard case .ready(let finalSession) = await states.next() else { Issue.record("Only final ready may follow owned import");return }
    #expect(finalSession.generation == 3)
    await f.service.disconnect()
  }
  @Test(arguments:["open2","backup","open3"])
  func physicalDetachDuringOwnedReopenRevokesAdmission(_ point:String) async throws {
    let f = try ImportSessionFixture(hold: point)
    defer { f.remove() }
    try await f.service.connect()
    let importing = Task { try await f.service.importRecipes() }
    await f.wire.barrier.entered()
    await f.wire.detach()
    await f.wire.barrier.release()
    await #expect(throws: CameraServiceError.self) { try await importing.value }
    await #expect(throws: CameraServiceError.self) { try await f.service.executionContext() }
    #expect(await f.wire.backupReads == (point == "open2" ? 0 : 1))
  }
  @Test(arguments: ["close1", "open2", "close2", "open3"])
  func cancellationAtEveryBoundaryNeverPublishesReceipt(_ boundary: String) async throws {
    let f = try ImportSessionFixture(hold: boundary)
    defer { f.remove() }
    try await f.service.connect()
    let importing = Task { try await f.service.importRecipes() }
    await f.wire.barrier.entered()
    importing.cancel()
    await f.wire.barrier.release()
    await #expect(throws: CameraServiceError.cancelled) { try await importing.value }
    #expect(await f.wire.backupReads <= 1)
    #expect(await f.wire.connected == false)
    await #expect(throws: CameraServiceError.self) { try await f.service.executionContext() }
  }
  @Test func oldQueuedAndDuringTransitionWorkCannotAdoptNewSession() async throws {
    let gate = SerialCameraGate()
    let f = try ImportSessionFixture(hold: "close1", gate: gate)
    defer { f.remove() }
    try await f.service.connect()
    let first = Task { try await f.service.importRecipes() }
    await f.wire.barrier.entered()
    let during = Task { try await f.service.importRecipes() }
    while await gate.queuedOperationCount < 1 { await Task.yield() }
    await f.wire.barrier.release()
    _ = try await first.value
    await #expect(throws: CameraServiceError.self) { try await during.value }
    #expect(await f.wire.backupReads == 1)
    await f.service.disconnect()
  }
  @Test func queuedBeforeTransitionCannotReplayBackup() async throws {
    let gate = SerialCameraGate()
    let f = try ImportSessionFixture(gate: gate)
    defer { f.remove() }
    try await f.service.connect()
    let hold = FixtureBarrier()
    let owner = Task { try await gate.withExclusiveAccess { await hold.wait() } }
    await hold.entered()
    let first = Task { try await f.service.importRecipes() }
    while await gate.queuedOperationCount < 1 { await Task.yield() }
    let stale = Task { try await f.service.importRecipes() }
    while await gate.queuedOperationCount < 2 { await Task.yield() }
    await hold.release()
    try await owner.value
    _ = try await first.value
    await #expect(throws: CameraServiceError.self) { try await stale.value }
    #expect(await f.wire.backupReads == 1)
    await f.service.disconnect()
  }
}
struct ImportSessionFixture: Sendable {
  let root: URL, wire: ImportSessionWire, service: FujiCameraService
  init(hold: String? = nil, gate: SerialCameraGate = SerialCameraGate(), failure: String? = nil)
    throws
  {
    root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    wire = ImportSessionWire(hold: hold, failure: failure)
    service = FujiCameraService(
      session: wire,
      journal: try CameraOperationJournal(directory: root, filePolicy: TestJournalFilePolicy()),
      gate: gate, pollWait: {})
  }
  func remove() { try? FileManager.default.removeItem(at: root) }
}
actor ImportSessionWire: CameraSessionTransport {
  let barrier = FixtureBarrier(), hold: String?, failure: String?
  var generation: UInt64 = 0, connected = false, detached = false, backupReads = 0, writes = 0,
    events: [String] = []
  var observers: [AsyncStream<CameraState>.Continuation] = []
  init(hold: String?, failure: String? = nil) {
    self.hold = hold
    self.failure = failure
  }
  func states() -> AsyncStream<CameraState> {
    let pair = AsyncStream<CameraState>.makeStream()
    observers.append(pair.continuation)
    return pair.stream
  }
  func checkpoint(_ event: String) async {
    events.append(event)
    if hold == event { await barrier.wait() }
  }
  func connect() async throws {
    generation += 1
    await checkpoint("open\(generation)")
    guard !detached else { throw PTPError.notConnected }
    connected = true
  }
  func close() async throws {
    await checkpoint("close\(generation)")
    if failure == "close\(generation)" { throw PTPError.timeout }
    connected = false
    observers.forEach { $0.yield(.disconnected) }
  }
  func detach() {
    detached = true
    connected = false
    observers.forEach { $0.yield(.disconnected) }
  }
  func currentSession() throws -> CameraSession {
    guard connected && !detached else { throw PTPError.notConnected }
    return .init(
      generation: failure == "generation" ? 1 : generation,
      connection: .init(name: "X-E3", usbVendorID: 0x04cb, usbProductID: 0x02d6))
  }
  func execute(_ command: PTPCommand, data: Data?) async throws -> PTPReply {
    _ = try currentSession()
    let result: Data
    if data != nil { writes += 1 }
    switch (command.opcode, command.parameters) {
    case (0x1001, []):
      result = ProtocolProbeFixtures.deviceInfo(
        model: "X-E3", properties: [0xD183, 0xD185],
        operations: [
          0x1001, 0x1005, 0x1007, 0x1008, 0x1009, 0x100B, 0x1015, 0x1016, 0x900C, 0x900D,
        ], firmware: failure == "identity\(generation)" ? "1.31" : "1.30")
    case (0x1015, [0xD16E]): result = Data([6, 0])
    case (0x1007, [UInt32.max, 0, 0]): result = Data(repeating: 0, count: 4)
    case (0x1008, [0]):
      var info = ObjectObservationFixture.info(byteCount: 5660)
      info.replaceSubrange(4..<6, with: Data([0, 0x50]))
      result = info
    case (0x1009, [0]):
      backupReads += 1
      await checkpoint("backup")
      _ = try currentSession()
      result = syntheticXE3Backup()
    default: throw PTPError.invalidParameters
    }
    return .init(
      opcode: command.opcode, parameters: [], logicalTransactionID: command.transactionID,
      wireTransactionID: command.transactionID, correlation: .directWireTransaction,
      responseCode: 0x2001, rawResponse: Data(), data: result)
  }
}
