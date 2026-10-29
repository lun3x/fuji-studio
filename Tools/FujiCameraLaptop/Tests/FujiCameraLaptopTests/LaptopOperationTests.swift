import CoreGraphics
import Foundation
import FujiCameraCore
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import FujiCameraLaptop

struct LaptopOperationTests {
  @Test func laptopRenderUsesCoreOwnedCleanup() async throws {
    let f = try LaptopOperationFixture()
    defer { f.remove() }
    let wire = LaptopOperationWire(fixture: f)
    try await run(f, wire: wire)
    #expect(await wire.deletes == [77])
    #expect(await wire.closes == 1)
    #expect(try Data(contentsOf: f.output.appendingPathComponent("output.JPG")) == f.jpeg)
    let evidence = try JSONDecoder().decode(
      LaptopEvidence.self,
      from: Data(contentsOf: f.output.appendingPathComponent("evidence-private.json")))
    #expect(evidence.closeConfirmed && evidence.sourceUnchanged == true)
    #expect(
      evidence.operation?.phase == .completed && evidence.operation?.emptyViewVerified == true)
    #expect(evidence.jpeg?.cameraContext.model == "X-E3")
    #expect(evidence.jpeg?.effectiveRecipe.evidenceBySetting?[.sharpness] == .jpegObserved)
  }
  @Test func laptopCannotDeleteChangedOutput() async throws {
    let f = try LaptopOperationFixture()
    defer { f.remove() }
    let wire = LaptopOperationWire(fixture: f, changeOutput: true)
    await #expect(throws: CameraServiceError.self) { try await run(f, wire: wire) }
    #expect(await wire.deletes.isEmpty)
    #expect(
      !FileManager.default.fileExists(atPath: f.output.appendingPathComponent("output.JPG").path))
    let evidence = try JSONDecoder().decode(
      LaptopEvidence.self,
      from: Data(contentsOf: f.output.appendingPathComponent("evidence-private.json")))
    #expect(evidence.closeConfirmed && evidence.jpeg == nil)
    #expect(try Data(contentsOf: f.raw) == f.rawBytes)
  }
  private func run(_ f: LaptopOperationFixture, wire: LaptopOperationWire) async throws {
    try await LaptopRunner.run(
      arguments: [
        "render", "--raw", f.raw.path, "--recipe-file", f.recipeFile.path, "--output",
        f.output.path,
      ],
      makeRuntime: { root in
        let journal = try CameraOperationJournal(
          directory: root.appendingPathComponent("journal"), filePolicy: MacJournalFilePolicy())
        return .init(
          camera: FujiCameraService(session: wire, journal: journal, pollWait: {}),
          journal: journal, closeConfirmed: { await wire.closes == 1 })
      },
      prepare: { local in
        PreparedRAW(
          fileURL: local.fileURL, sha256: local.checksum, sourceID: local.token.assetID,
          sourceRevision: local.token.sourceRevision, metadata: f.metadata)
      })
  }
}
struct LaptopOperationFixture: Sendable {
  let root: URL, raw: URL, recipeFile: URL, output: URL, baseline: Data, jpeg: Data
  let rawBytes = Data(repeating: 42, count: 256)
  let metadata = RAWMetadata(
    cameraModel: "X-E3", containerGeometry: .init(width: 6160, height: 4032),
    recordedGeometry: .init(width: 6000, height: 4000), recordedAspect: .init(width: 3, height: 2),
    cropTop: 16, cropLeft: 16, orientation: 1, compression: .uncompressed, bitDepth: 14,
    rafVersion: "0130")
  init() throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try MacJournalFilePolicy().createFreshDirectory(at: root)
    raw = root.appendingPathComponent("source.RAF")
    recipeFile = root.appendingPathComponent("recipe.json")
    output = root.appendingPathComponent("run")
    try rawBytes.write(to: raw)
    let fields: [UInt16: Data] = [
      1: Data([13]), 2: Data([3]), 3: Data([1]), 4: Data([8]), 5: Data([13]), 6: Data([11]),
      7: Data([6]), 8: Data([5]), 9: Data([2]), 10: Data([7]), 11: Data([4]), 12: Data([0]),
      13: Data([0xb9, 1]),
    ]
    let recipe = try XE3RecipeCodec.recipe(
      slot: 4, nameData: Data("CLI fixture\0".utf8), properties: fields,
      context: .init(
        model: "X-E3", firmware: "1.30", capability: XE3Support.identifier, sessionIdentity: UUID(),
        sessionGeneration: 1), importedAt: Date())
    try JSONEncoder().encode(recipe).write(to: recipeFile)
    let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .appendingPathComponent(
        "../../../../Packages/FujiCameraCore/Tests/FujiCameraCoreTests/Fixtures/XE3/1.30"
      ).standardizedFileURL
    baseline = try Data(contentsOf: fixtures.appendingPathComponent("baseline-dr400-weak.bin"))
    let context = try #require(
      CGContext(
        data: nil, width: 6000, height: 4000, bitsPerComponent: 8, bytesPerRow: 24000,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
    context.setFillColor(gray: 0, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: 6000, height: 4000))
    let bytes = NSMutableData()
    let writer = try #require(
      CGImageDestinationCreateWithData(bytes, UTType.jpeg.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(writer, try #require(context.makeImage()), nil)
    #expect(CGImageDestinationFinalize(writer))
    func short(_ n: UInt16) -> (UInt16, UInt32, Data) { (3, 1, ProtocolProbeFixtures.word(n)) }
    func signed(_ values: [Int32]) -> (UInt16, UInt32, Data) {
      (
        9, UInt32(values.count),
        values.reduce(Data()) { $0 + ObjectObservationFixture.word(UInt32(bitPattern: $1)) }
      )
    }
    let fieldsJPEG: [UInt16: (UInt16, UInt32, Data)] = [
      0x1001: short(3), 0x1002: short(0xff0), 0x1003: short(0x400), 0x1005: short(6300),
      0x100a: signed([-80, -40]), 0x100e: short(0x2e0), 0x1040: signed([-32]), 0x1041: signed([16]),
      0x1047: signed([32]), 0x1401: short(0x600), 0x1403: short(400),
    ]
    jpeg = CoreJPEGFixture(
      model: "X-E3", orientation: 1, lensOptimizer: 1,
      fields: fieldsJPEG.keys.sorted().map {
        let v = fieldsJPEG[$0]!
        return ($0, v.0, v.1, v.2)
      }, pixelWidth: 6000, pixelHeight: 4000
    ).inject(into: bytes as Data)
  }
  func remove() { try? FileManager.default.removeItem(at: root) }
}
actor LaptopOperationWire: CameraSessionTransport {
  let fixture: LaptopOperationFixture, changeOutput: Bool
  var connected = false, present = false, profile: Data?, downloads = 0, closes = 0,
    deletes: [UInt32] = []
  init(fixture: LaptopOperationFixture, changeOutput: Bool = false) {
    self.fixture = fixture
    self.changeOutput = changeOutput
  }
  func states() -> AsyncStream<CameraState> { AsyncStream { $0.finish() } }
  func connect() { connected = true }
  func currentSession() throws -> CameraSession {
    guard connected else { throw PTPError.notConnected }
    return .init(
      generation: 1, connection: .init(name: "X-E3", usbVendorID: 0x04cb, usbProductID: 0x02d6))
  }
  func close() {
    connected = false
    closes += 1
  }
  func execute(_ command: PTPCommand, data: Data?) throws -> PTPReply {
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
      info.replaceSubrange(42..<44, with: Data([7, 0]))
      bytes = info
    case (0x1005, [0x1000_0001]):
      var storage = ObjectObservationFixture.storage()
      storage[0] = 3
      storage[4] = 2
      bytes = storage
    case (0x1009, [77]):
      downloads += 1
      var jpeg = fixture.jpeg
      if changeOutput && downloads > 1 { jpeg[jpeg.count - 1] ^= 1 }
      bytes = jpeg
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
