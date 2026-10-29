import Foundation

@testable import FujiCameraCore
@testable import FujiStudio

actor ReceiptCamera: CameraServing {
  private var context: CameraExecutionContext?
  private var state: CameraState = .disconnected
  private var observers: [AsyncStream<CameraState>.Continuation] = []
  private let original: RecipeSnapshot
  private(set) var importCount = 0, renderCount = 0
  private var importBarrier: FixtureBarrier?
  private var final: ImportedRecipeCollection?
  init() throws { original = try fixtureXE3Recipe() }
  func holdImport(_ barrier: FixtureBarrier) { importBarrier = barrier }
  func executionContext() throws -> CameraExecutionContext {
    guard let context else { throw CameraServiceError.notReady }
    return context
  }
  func support(for expected: CameraExecutionContext) throws -> VerifiedCameraSupport {
    guard context == expected else { throw CameraServiceError.unsupportedContext }
    return fixtureCollection([], context: expected).support
  }
  func states() -> AsyncStream<CameraState> {
    let pair = AsyncStream<CameraState>.makeStream()
    observers.append(pair.continuation)
    pair.continuation.yield(state)
    return pair.stream
  }
  private func emit(_ event: CameraState) {
    state = event
    observers.forEach { $0.yield(event) }
  }
  func session(_ generation: UInt64) -> CameraSession {
    .init(
      generation: generation,
      connection: .init(name: "X-E3", usbVendorID: 0x04cb, usbProductID: 0x02d6))
  }
  func connect() {
    guard context == nil else { return }
    context = .init(
      model: "X-E3", firmware: "1.30", capability: XE3Support.identifier,
      supportVersion: XE3Support.conversionVersion, sessionIdentity: UUID(), generation: 1)
    emit(.ready(session(1)))
  }
  func importRecipes() async throws -> ImportedRecipeCollection {
    let before = try executionContext()
    importCount += 1
    emit(.busy(session(before.generation)))
    if let importBarrier { await importBarrier.wait() }
    guard context == before else { throw CameraServiceError.notReady }
    let after = CameraExecutionContext(
      model: before.model, firmware: before.firmware, capability: before.capability,
      supportVersion: before.supportVersion, sessionIdentity: UUID(),
      generation: before.generation + 2)
    context = after
    let recipes = (1...7).map { slot in
      RecipeSnapshot(
        id: UUID(), slot: slot, name: original.name, importedName: original.importedName,
        importedSettings: original.importedSettings, settingsDigest: original.settingsDigest,
        cameraContext: .init(
          model: after.model, firmware: after.firmware, capability: after.capability,
          sessionIdentity: after.sessionIdentity, sessionGeneration: after.generation),
        importedAt: Date(), renderingIssues: [])
    }
    let result = fixtureCollection(recipes, context: after)
    final = result
    emit(.ready(session(after.generation)))
    await Task.yield()
    return result
  }
  func repeatFinalReady() { if let context { emit(.ready(session(context.generation))) } }
  func delayedClosedEvent() { emit(.disconnected) }
  func render(raw: PreparedRAW, recipe: RecipeSnapshot, policy: OutputPolicy) throws -> CameraJPEG {
    renderCount += 1
    throw CameraServiceError.unsupportedSource
  }
  func disconnect() {
    context = nil
    emit(.disconnected)
  }
  func resetConnection() { disconnect(); connect() }
}
