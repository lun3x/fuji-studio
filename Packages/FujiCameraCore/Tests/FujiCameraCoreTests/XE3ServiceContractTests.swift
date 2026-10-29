import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import FujiCameraCore

struct XE3ServiceContractTests {
  @Test(arguments: [1, 8]) func zeroObjectDimensionsRequireRealJPEGGeometry(_ orientation: Int)
    async throws
  {
    let f = try XE3ServiceFixture(orientation: orientation)
    defer { f.remove() }
    let wire = XE3Session(f)
    let journal = try CameraOperationJournal(
      directory: f.root.appendingPathComponent("journal"), filePolicy: TestJournalFilePolicy())
    let service = FujiCameraService(
      session: wire, journal: journal, pollWait: {},
      registry: FujiCameraRegistry(adapters: [XT5Adapter(), XE3Adapter()]))
    try await service.connect()
    let support = try await service.support(for: service.executionContext())
    #expect(support.capabilityOrigin == .applicationDefined)
    let result = try await service.render(
      raw: f.raw, recipe: f.recipe, policy: .fullSizeFineRecordedGeometry)
    #expect(result.width == 6000 && result.height == 4000 && result.orientation == orientation)
    #expect(result.effectiveRecipe.requested.whiteBalanceRed == -4)
    #expect(await wire.deletes == [77])
    let commands = await wire.commands
    #expect(
      commands.allSatisfy { ![UInt32(0xD186), 0xD187, 0xD18C].contains($0.parameters.first ?? 0) })
    #expect(try journal.unresolved().isEmpty)
    await service.disconnect()
  }
  @Test(arguments: [XE3Session.Mode.wrongStorage, .changedPayload, .wrongGeometry])
  func unsafeOutputCannotAuthorizeDelete(_ mode: XE3Session.Mode) async throws {
    let f = try XE3ServiceFixture(orientation: 1, smallJPEG: mode == .wrongGeometry)
    defer { f.remove() }
    let wire = XE3Session(f, mode: mode)
    let journal = try CameraOperationJournal(
      directory: f.root.appendingPathComponent("journal"), filePolicy: TestJournalFilePolicy())
    let service = FujiCameraService(
      session: wire, journal: journal, pollWait: {}, registry: .init(adapters: [XE3Adapter()]))
    try await service.connect()
    await #expect(throws: CameraServiceError.self) {
      try await service.render(raw: f.raw, recipe: f.recipe, policy: .fullSizeFineRecordedGeometry)
    }
    #expect(await wire.deletes.isEmpty)
    #expect(try journal.unresolved().count == 1)
  }
}
struct XE3ServiceFixture: Sendable {
  let root: URL, raw: PreparedRAW, recipe: RecipeSnapshot, jpeg: Data, baseline: Data
  init(orientation: Int, smallJPEG: Bool = false) throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let rawURL = root.appendingPathComponent("synthetic.RAF")
    try Data(repeating: 42, count: 256).write(to: rawURL)
    raw = PreparedRAW(
      fileURL: rawURL, sha256: try ResourceChecksum.sha256(rawURL), sourceID: "xe3",
      sourceRevision: "v1", metadata: xe3Metadata(orientation: orientation))
    let fields: [UInt16: Data] = [
      1: Data([13]), 2: Data([3]), 3: Data([2]), 4: Data([8]), 5: Data([13]), 6: Data([11]),
      7: Data([6]), 8: Data([5]), 9: Data([2]), 10: Data([7]), 11: Data([4]), 12: Data([0]),
      13: Data([0xb9, 1]),
    ]
    recipe = try XE3RecipeCodec.recipe(
      slot: 1, nameData: Data("Synthetic\0".utf8), properties: fields,
      context: .init(
        model: "X-E3", firmware: "1.30", capability: XE3Support.identifier, sessionIdentity: UUID(),
        sessionGeneration: 1), importedAt: Date())
    baseline = try xe3Baseline()
    let width = smallJPEG ? 4 : 6000
    let height = smallJPEG ? 6 : 4000
    let context = try #require(
      CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
    context.setFillColor(gray: 0, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let bytes = NSMutableData()
    let actual = try #require(
      CGImageDestinationCreateWithData(bytes, UTType.jpeg.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(actual, try #require(context.makeImage()), nil)
    #expect(CGImageDestinationFinalize(actual))
    jpeg = CoreJPEGFixture(
      model: "X-E3", orientation: UInt16(orientation), lensOptimizer: 1,
      fields: entries(xe3MakerFields()), pixelWidth: width, pixelHeight: height
    ).inject(into: bytes as Data)
  }
  func remove() { try? FileManager.default.removeItem(at: root) }
}
actor XE3Session: CameraSessionTransport {
  enum Mode: Sendable { case normal, wrongStorage, changedPayload, wrongGeometry }
  let fixture: XE3ServiceFixture, mode: Mode
  var connected = false, present = false, profile: Data?, downloads = 0
  var commands: [PTPCommand] = [], deletes: [UInt32] = []
  var observers: [AsyncStream<CameraState>.Continuation] = []
  init(_ fixture: XE3ServiceFixture, mode: Mode = .normal) {
    self.fixture = fixture
    self.mode = mode
  }
  func states() -> AsyncStream<CameraState> {
    let pair = AsyncStream<CameraState>.makeStream()
    observers.append(pair.continuation)
    return pair.stream
  }
  func connect() { connected = true }
  func currentSession() throws -> CameraSession {
    guard connected else { throw PTPError.notConnected }
    return .init(
      generation: 1, connection: .init(name: "X-E3", usbVendorID: 0x04cb, usbProductID: 0x02d6))
  }
  func close() {
    connected = false
    observers.forEach { $0.yield(.disconnected) }
  }
  func execute(_ command: PTPCommand, data: Data?) throws -> PTPReply {
    commands.append(command)
    let bytes: Data
    switch (command.opcode, command.parameters) {
    case (0x1001, []):
      bytes = ProtocolProbeFixtures.deviceInfo(
        model: "X-E3", properties: [0xD183, 0xD185],
        operations: [
          0x1001, 0x1005, 0x1007, 0x1008, 0x1009, 0x100B, 0x1015, 0x1016, 0x900C, 0x900D,
        ], firmware: "1.30")
    case (0x1015, [0xD16E]): bytes = Data([6, 0])
    case (0x900C, [0, 0, 0]), (0x900D, []): bytes = Data()
    case (0x1015, [0xD185]): bytes = profile ?? fixture.baseline
    case (0x1016, [0xD185]):
      profile = data
      bytes = Data()
    case (0x1016, [0xD183]):
      guard data == Data([1, 0]) else { throw PTPError.invalidParameters }
      present = true
      bytes = Data()
    case (0x1007, [UInt32.max, 0, 0]):
      bytes =
        ObjectObservationFixture.word(present ? 1 : 0)
        + (present ? ObjectObservationFixture.word(77) : Data())
    case (0x1008, [77]):
      var info = ObjectObservationFixture.info(byteCount: UInt32(fixture.jpeg.count))
      info.replaceSubrange(0..<4, with: ObjectObservationFixture.word(0x1000_0001))
      info.replaceSubrange(26..<34, with: Data(repeating: 0, count: 8))
      info.replaceSubrange(
        42..<44, with: ProtocolProbeFixtures.word(fixture.raw.metadata.orientation == 1 ? 7 : 2055))
      bytes = info
    case (0x1005, [0x1000_0001]):
      var storage = ObjectObservationFixture.storage()
      storage[0] = mode == .wrongStorage ? 4 : 3
      storage[4] = 2
      bytes = storage
    case (0x1009, [77]):
      downloads += 1
      var payload = fixture.jpeg
      if mode == .changedPayload && downloads > 1 { payload[payload.count - 1] ^= 1 }
      bytes = payload
    case (0x100B, [77, 0]):
      deletes.append(77)
      present = false
      bytes = Data()
    default: throw PTPError.invalidParameters
    }
    return .init(
      opcode: command.opcode, parameters: [], logicalTransactionID: command.transactionID,
      wireTransactionID: command.transactionID, correlation: .directWireTransaction,
      responseCode: 0x2001, rawResponse: Data(), data: bytes)
  }
}
