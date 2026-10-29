import Foundation
import FujiCameraCore

struct LaptopRuntime: Sendable {
  let camera: any CameraServing
  let journal: CameraOperationJournal
  let closeConfirmed: @Sendable () async -> Bool
  var diagnostics: @Sendable () async -> [String] = { [] }
  var commandCounts: @Sendable () async -> [String: Int] = { [:] }
}
struct LaptopSourceEvidence: Codable, Sendable {
  let model: String, compression: UInt32?, bitDepth: Int?, rafVersion: String?
  let containerWidth: Int, containerHeight: Int, recordedWidth: Int, recordedHeight: Int,
    cropTop: Int, cropLeft: Int, orientation: Int
  init(_ metadata: RAWMetadata) {
    model = metadata.cameraModel
    compression = metadata.compression?.rawValue
    bitDepth = metadata.bitDepth
    rafVersion = metadata.rafVersion
    containerWidth = metadata.containerGeometry.width
    containerHeight = metadata.containerGeometry.height
    recordedWidth = metadata.recordedGeometry.width
    recordedHeight = metadata.recordedGeometry.height
    cropTop = metadata.cropTop
    cropLeft = metadata.cropLeft
    orientation = metadata.orientation
  }
}
struct LaptopSupportEvidence: Codable, Sendable {
  let adapter: String, model: String, firmware: String, capability: String,
    capabilityOrigin: String, supportVersion: String
  let capabilities: CameraCapabilities
  init(_ support: VerifiedCameraSupport) {
    adapter = support.adapterID.rawValue
    model = support.model
    firmware = support.firmware
    capability = support.capability
    capabilityOrigin = support.capabilityOrigin.rawValue
    supportVersion = support.supportVersion
    capabilities = support.capabilities
  }
}
struct LaptopEvidence: Codable, Sendable {
  var schema = "fujifilm-shared-core-laptop-v1"
  var support: LaptopSupportEvidence?, context: CameraExecutionContext?
  var recipes: [RecipeSnapshot]?, declaredSlots: [RecipeSlot]?, jpeg: CameraJPEG?,
    operation: CameraOperationRecord?
  var sourceSHA256: String?, sourceUnchanged: Bool?, closeConfirmed = false, failure: String?
  var nativeDiagnostics: [String] = []
  var source: LaptopSourceEvidence?
  var commandCounts: [String: Int] = [:]
}
enum LaptopRunner {
  typealias RuntimeFactory = @Sendable (URL) async throws -> LaptopRuntime
  typealias Preparer = @Sendable (LocalResource) throws -> PreparedRAW
  @MainActor static func nativeRuntime(_ root: URL) throws -> LaptopRuntime {
    let driver = MacImageCaptureDriver()
    let transport = SessionCommandTransport(driver: driver)
    let journal = try CameraOperationJournal(
      directory: root.appendingPathComponent("journal"), filePolicy: MacJournalFilePolicy())
    return .init(
      camera: FujiCameraService(session: transport, journal: journal), journal: journal,
      closeConfirmed: { await driver.confirmedClosed },
      diagnostics: { await driver.diagnosticSummary() },
      commandCounts: { await driver.commandCounts })
  }
  static func run(
    arguments: [String],
    makeRuntime: RuntimeFactory = { root in try await MainActor.run { try nativeRuntime(root) } },
    prepare: Preparer = { try RAFMetadataReader().prepare($0) }
  ) async throws {
    let invocation = try LaptopArguments(arguments)
    var prepared: PreparedRAW?
    var offline: RecipeSnapshot?
    // Validate files before constructing any native discovery object.
    if case .render(let raw, let selection) = invocation.operation {
      let values = try raw.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
      guard values.isRegularFile == true, let size = values.fileSize, size > 0,
        size <= PTPCodec.maximumDataBytes, raw.pathExtension.lowercased() == "raf"
      else { throw LaptopError.invalidSource }
      let hash = try ResourceChecksum.sha256(raw)
      let token = ResourceToken(
        assetID: "laptop-file", role: .primaryOriginal,
        contentTypeIdentifier: "com.fujifilm.raw-image", format: .raf,
        originalFilename: raw.lastPathComponent, discriminator: "original", sourceRevision: hash)
      prepared = try prepare(.init(token: token, fileURL: raw, checksum: hash))
      if case .file(let path) = selection {
        let file = try FileHandle(forReadingFrom: path)
        defer { try? file.close() }
        let bytes = try file.read(upToCount: 1_048_577) ?? Data()
        guard bytes.count <= 1_048_576 else { throw LaptopError.invalidRecipe }
        offline = try JSONDecoder().decode(RecipeSnapshot.self, from: bytes)
        try offline!.requireRenderable(using: RecipeCodecRegistry())
      }
    }
    try Task.checkCancellation()
    let policy = MacJournalFilePolicy()
    try policy.createFreshDirectory(at: invocation.output)
    let runtime = try await makeRuntime(invocation.output)
    var evidence = LaptopEvidence()
    if let prepared {
      evidence.source = LaptopSourceEvidence(prepared.metadata)
      evidence.sourceSHA256 = prepared.sha256
    }
    var failure: (any Error)?
    do {
      try await runtime.camera.connect()
      let initial = try await runtime.camera.executionContext()
      evidence.support = LaptopSupportEvidence(try await runtime.camera.support(for: initial))
      evidence.context = initial
      switch invocation.operation {
      case .importRecipes:
        let collection = try await runtime.camera.importRecipes()
        try Task.checkCancellation()
        evidence.support = LaptopSupportEvidence(collection.support)
        evidence.context = collection.context
        evidence.recipes = collection.recipes
        evidence.declaredSlots = collection.declaredSlots
        try policy.write(
          encode(collection.recipes),
          to: invocation.output.appendingPathComponent("recipes-private.json"), exclusive: true)
      case .render(_, let selection):
        let recipe: RecipeSnapshot
        switch selection {
        case .file:
          guard let offline else { throw LaptopError.invalidRecipe }
          recipe = offline
        case .slot(let slot):
          let collection = try await runtime.camera.importRecipes()
          evidence.support = LaptopSupportEvidence(collection.support)
          evidence.context = collection.context
          evidence.recipes = collection.recipes
          evidence.declaredSlots = collection.declaredSlots
          guard let bank = collection.recipes.first(where: { $0.slot == slot }) else {
            throw LaptopError.missingSlot
          }
          recipe = bank
        }
        guard let raw = prepared else { throw LaptopError.invalidSource }
        evidence.sourceSHA256 = raw.sha256
        let jpeg = try await runtime.camera.render(
          raw: raw, recipe: recipe, policy: .fullSizeFineRecordedGeometry)
        try Task.checkCancellation()
        evidence.jpeg = jpeg
        evidence.context = jpeg.cameraContext
        evidence.operation = try runtime.journal.load(jpeg.operationID)
        evidence.sourceUnchanged = try ResourceChecksum.sha256(raw.fileURL) == raw.sha256
        guard evidence.sourceUnchanged == true else { throw CameraServiceError.sourceChanged }
        try policy.write(
          Data(contentsOf: jpeg.fileURL),
          to: invocation.output.appendingPathComponent("output.JPG"), exclusive: true)
        try policy.write(
          encode(jpeg), to: invocation.output.appendingPathComponent("render-private.json"),
          exclusive: true)
      }
    } catch {
      failure = error
      evidence.failure = String(describing: error)
    }
    await runtime.camera.disconnect()
    evidence.closeConfirmed = await runtime.closeConfirmed()
    evidence.nativeDiagnostics = await runtime.diagnostics()
    evidence.commandCounts = await runtime.commandCounts()
    try policy.write(
      encode(evidence), to: invocation.output.appendingPathComponent("evidence-private.json"),
      exclusive: true)
    guard evidence.closeConfirmed else { throw LaptopError.closeUnconfirmed }
    if let failure { throw failure }
  }
  private static func encode<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return try encoder.encode(value)
  }
}
