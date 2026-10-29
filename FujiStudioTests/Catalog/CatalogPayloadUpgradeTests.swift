import Foundation
import SwiftData
import Testing

@testable import FujiCameraCore
@testable import FujiStudio

@MainActor struct CatalogPayloadUpgradeTests {
  @Test func previousCollectionGainsDeclarationWithoutChangingSnapshots() async throws {
    let f = try RenderFixture()
    defer { f.remove() }
    let store = f.root.appendingPathComponent("v2.store")
    let schema = Schema([
      CatalogSourceRecord.self, CatalogRecipeRecord.self, CatalogCollectionRecord.self,
      CatalogJobRecord.self, CatalogOperationRecord.self, CatalogVersionRecord.self,
      CatalogPhoneRecipeRecord.self, CatalogFormatRecord.self,
    ])
    let container = try ModelContainer(
      for: schema,
      configurations: [
        ModelConfiguration("FujiStudioLocal", schema: schema, url: store, cloudKitDatabase: .none)
      ])
    let context = ModelContext(container)
    context.autosaveEnabled = false
    let recipes = (1...7).map { slot in
      RecipeSnapshot(
        id: UUID(), slot: slot, name: f.recipe.name, importedName: f.recipe.importedName,
        importedSettings: f.recipe.importedSettings, settingsDigest: f.recipe.settingsDigest,
        cameraContext: f.recipe.cameraContext, importedAt: f.recipe.importedAt,
        renderingIssues: f.recipe.renderingIssues)
    }
    for recipe in recipes {
      context.insert(
        CatalogRecipeRecord(snapshotID: recipe.id, payload: try JSONEncoder().encode(recipe)))
    }
    context.insert(
      CatalogCollectionRecord(snapshotIDs: try JSONEncoder().encode(recipes.map(\.id))))
    context.insert(CatalogFormatRecord(version: 2))
    try context.save()
    let reopened = try SwiftDataCatalog(storeURL: store)
    #expect(try await reopened.latestRecipes() == recipes)
    #expect(try await reopened.latestRecipeSlots().map(\.id) == Array(1...7))
    _ = try SwiftDataCatalog(storeURL: store)
    #expect(try await reopened.latestRecipes() == recipes)
  }
  @Test func currentPayloadUpgradePreservesFrozenHistory() async throws {
    let f = try RenderFixture()
    let store = f.root.appendingPathComponent("migration.store")
    let context = try legacyContext(at: store)
    let version = SavedVersion(
      id: UUID(), sourceID: f.source.id, outputAssetID: "photos/asset-42", recipeSnapshot: f.recipe,
      operationID: UUID(), exportedAt: Date(timeIntervalSince1970: 1000), jpeg: try f.jpeg(),
      availability: .available)
    var payload = try #require(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(version)) as? [String: Any])
    var jpeg = try #require(payload["jpeg"] as? [String: Any])
    let legacy = try oldReport()
    jpeg["effectiveRecipe"] = legacy
    payload["jpeg"] = jpeg
    context.insert(
      CatalogVersionRecord(
        version: version, payload: try JSONSerialization.data(withJSONObject: payload)))
    let copied = f.recipe.copiedToPhone()
    context.insert(
      CatalogRecipeRecord(
        snapshotID: copied.snapshot.id, payload: try JSONEncoder().encode(copied.snapshot)))
    context.insert(
      CatalogPhoneRecipeRecord(sourceSnapshotID: copied.id, snapshotID: copied.snapshot.id))
    let pending = PendingSave(
      operationID: UUID(), jpeg: version.jpeg, placeholderID: "photos/pending-17",
      submission: .unknown(at: Date(timeIntervalSince1970: 1234)))
    let job = ExportJob(
      id: UUID(), submittedAt: Date(timeIntervalSince1970: 1000), recipeSnapshot: f.recipe,
      items: [
        ExportItem(source: f.source, operationID: pending.operationID, state: .unresolved(pending))
      ], state: .unresolved)
    context.insert(
      CatalogJobRecord(
        job: job, unfinished: true, payload: try injectLegacyReport(JSONEncoder().encode(job))))
    try context.save()
    let reopened = try SwiftDataCatalog(storeURL: store)
    let saved = try #require(try await reopened.versions(sourceID: f.source.id).first)
    #expect(saved.id == version.id && saved.operationID == version.operationID)
    #expect(saved.outputAssetID == "photos/asset-42")
    #expect(saved.recipeSnapshot == f.recipe)
    #expect(saved.jpeg.settingsDigest == version.jpeg.settingsDigest)
    #expect(saved.jpeg.effectiveRecipe.requested.film == .classicChrome)
    #expect(try await reopened.phoneRecipes().first?.id == copied.id)
    #expect(try await reopened.phoneRecipes().first?.snapshot.id == copied.snapshot.id)
    let retainedJob = try await reopened.job(id: job.id)
    #expect(retainedJob.recipeSnapshot == f.recipe)
    guard case .unresolved(let retainedPending) = retainedJob.items[0].state else {
      Issue.record("Uncertainty must survive upgrade")
      return
    }
    #expect(retainedPending.operationID == pending.operationID)
    #expect(retainedPending.placeholderID == "photos/pending-17")
    #expect(retainedPending.submission == pending.submission)
  }
  @Test func interruptedCatalogCommitRollsBackAndRetriesFrozenHistory() async throws {
    let f = try RenderFixture()
    defer { f.remove() }
    let store = f.root.appendingPathComponent("commit-interruption.store")
    let schema = Schema([
      CatalogSourceRecord.self, CatalogRecipeRecord.self, CatalogCollectionRecord.self,
      CatalogJobRecord.self, CatalogOperationRecord.self, CatalogVersionRecord.self,
      CatalogPhoneRecipeRecord.self, CatalogFormatRecord.self,
    ])
    let configuration = ModelConfiguration(
      "FujiStudioLocal", schema: schema, url: store, cloudKitDatabase: .none)
    let container = try ModelContainer(for: schema, configurations: [configuration])
    let context = ModelContext(container)
    context.autosaveEnabled = false
    let version = SavedVersion(
      id: UUID(), sourceID: f.source.id, outputAssetID: "photos/frozen", recipeSnapshot: f.recipe,
      operationID: UUID(), exportedAt: Date(timeIntervalSince1970: 1000), jpeg: try f.jpeg(),
      availability: .available)
    let oldVersion = try injectLegacyReport(JSONEncoder().encode(version))
    context.insert(CatalogVersionRecord(version: version, payload: oldVersion))
    let phone = f.recipe.copiedToPhone()
    context.insert(
      CatalogRecipeRecord(
        snapshotID: phone.snapshot.id, payload: try JSONEncoder().encode(phone.snapshot)))
    context.insert(
      CatalogPhoneRecipeRecord(sourceSnapshotID: phone.id, snapshotID: phone.snapshot.id))
    let pending = PendingSave(
      operationID: UUID(), jpeg: version.jpeg, placeholderID: "photos/unresolved",
      submission: .unknown(at: Date(timeIntervalSince1970: 1234)))
    let job = ExportJob(
      id: UUID(), submittedAt: Date(timeIntervalSince1970: 1000), recipeSnapshot: f.recipe,
      items: [
        ExportItem(source: f.source, operationID: pending.operationID, state: .unresolved(pending))
      ], state: .unresolved)
    let oldJob = try injectLegacyReport(JSONEncoder().encode(job))
    context.insert(CatalogJobRecord(job: job, unfinished: true, payload: oldJob))
    context.insert(CatalogFormatRecord(version: 1))
    try context.save()
    var reachedCommit = false
    #expect(throws: SimulatedUpgradeInterruption.beforeCommit) {
      try CatalogPayloadUpgrade(context: context, storeURL: store).runIfNeeded(beforeCommit: {
        reachedCommit = true
        #expect(
          try context.fetch(FetchDescriptor<CatalogVersionRecord>()).first?.payload != oldVersion)
        #expect(try context.fetch(FetchDescriptor<CatalogFormatRecord>()).first?.version == 3)
        throw SimulatedUpgradeInterruption.beforeCommit
      })
    }
    #expect(reachedCommit)
    let afterCrash = ModelContext(try ModelContainer(for: schema, configurations: [configuration]))
    afterCrash.autosaveEnabled = false
    #expect(
      try afterCrash.fetch(FetchDescriptor<CatalogVersionRecord>()).first?.payload == oldVersion)
    #expect(try afterCrash.fetch(FetchDescriptor<CatalogJobRecord>()).first?.payload == oldJob)
    #expect(try afterCrash.fetch(FetchDescriptor<CatalogFormatRecord>()).first?.version == 1)
    let archiveURL = store.appendingPathExtension("payload-v1-backup.json")
    let archive = try Data(contentsOf: archiveURL)
    let reopened = try SwiftDataCatalog(storeURL: store)
    let saved = try #require(try await reopened.versions(sourceID: f.source.id).first)
    #expect(saved.id == version.id && saved.operationID == version.operationID)
    #expect(saved.outputAssetID == version.outputAssetID && saved.recipeSnapshot == f.recipe)
    #expect(try await reopened.phoneRecipes().first == phone)
    let retained = try await reopened.job(id: job.id)
    guard case .unresolved(let retainedPending) = retained.items[0].state else {
      Issue.record("Uncertainty must survive interrupted upgrade")
      return
    }
    #expect(retainedPending.operationID == pending.operationID)
    #expect(
      retainedPending.placeholderID == pending.placeholderID
        && retainedPending.submission == pending.submission)
    #expect(try Data(contentsOf: archiveURL) == archive)
    _ = try SwiftDataCatalog(storeURL: store)
    #expect(try await reopened.job(id: job.id) == retained)
  }
  @Test func failedUpgradeLeavesOriginalReadable() throws {
    let f = try RenderFixture()
    let store = f.root.appendingPathComponent("failure.store")
    let context = try legacyContext(at: store)
    let original = Data([0])
    context.insert(CatalogRecipeRecord(snapshotID: UUID(), payload: original))
    try context.save()
    #expect(throws: (any Error).self) { _ = try SwiftDataCatalog(storeURL: store) }
    #expect(try context.fetch(FetchDescriptor<CatalogRecipeRecord>()).first?.payload == original)
    #expect(try context.fetch(FetchDescriptor<CatalogRecipeRecord>()).count == 1)
  }
  @Test func interruptedMultiRecordJournalUpgradeRetainsDeleteIntents() throws {
    let f = try RenderFixture()
    defer { f.remove() }
    let directory = f.root.appendingPathComponent("journal")
    let journal = try CameraOperationJournal(
      directory: directory, filePolicy: IOSCameraJournalFilePolicy())
    var originals: [UUID: Data] = [:]
    var markers: [UUID: Data] = [:]
    var unresolvedID: UUID?
    for index in 0..<4 {
      var record = try journal.create(raw: f.raw, recipe: f.recipe, context: f.context)
      record.phase = .captured
      record.outputValidated = true
      record.outputHandle = UInt32(31 + index)
      record.outputSHA256 = "frozen-output-\(index)"
      record.objectInfo = Data([1])
      record.storageInfo = Data([2])
      try journal.save(record)
      try journal.beginDelete(&record)
      let folder = journal.operationDirectory(record.id)
      markers[record.id] = try Data(contentsOf: folder.appendingPathComponent("delete-intent.json"))
      if index < 3 {
        record.result = try f.jpeg()
        record.phase = .completed
        record.deleteAcknowledged = true
        record.emptyViewVerified = true
      } else {
        unresolvedID = record.id
      }
      try journal.save(record)
      let url = folder.appendingPathComponent("journal.json")
      let legacy = try injectLegacyReport(Data(contentsOf: url))
      try legacy.write(to: url, options: .atomic)
      originals[record.id] = legacy
    }
    // Crash after one durable replacement, before the second: the directory
    // now contains both payload formats and an unresolved delete intent.
    #expect(throws: CameraServiceError.storage) {
      _ = try CameraOperationJournal(
        directory: directory, filePolicy: FailSecondUpgradeWritePolicy())
    }
    let changed = try originals.filter { id, bytes in
      try Data(contentsOf: journal.operationDirectory(id).appendingPathComponent("journal.json"))
        != bytes
    }
    #expect(changed.count == 1)
    let reopened = try CameraOperationJournal(
      directory: directory, filePolicy: IOSCameraJournalFilePolicy())
    for (id, old) in originals {
      let folder = reopened.operationDirectory(id)
      #expect(
        try Data(contentsOf: folder.appendingPathComponent("journal.json"))
          == RecipePayloadUpgrade.convert(old))
      #expect(
        try Data(contentsOf: folder.appendingPathComponent("delete-intent.json")) == markers[id])
      let loaded = try reopened.load(id)
      #expect(loaded.id == id && loaded.deleteIntent && loaded.outputSHA256 != nil)
      if let result = loaded.result {
        #expect(result.settingsDigest == f.recipe.settingsDigest)
        #expect(
          result.effectiveRecipe.requested.grain == GrainSettings(strength: .off, size: .large))
        #expect(
          try Data(contentsOf: folder.appendingPathComponent("journal-v1-backup.json")) == old)
      }
    }
    let expectedID = try #require(unresolvedID)
    let unfinished = try reopened.unresolved()
    #expect(unfinished.map(\.id) == [expectedID])
    var retained = try #require(unfinished.first)
    #expect(throws: CameraServiceError.uncertainOperation(retained.id)) {
      try reopened.beginDelete(&retained)
    }
    _ = try CameraOperationJournal(directory: directory, filePolicy: IOSCameraJournalFilePolicy())
    #expect(try reopened.unresolved().map(\.id) == [expectedID])
  }
  private func legacyContext(at store: URL) throws -> ModelContext {
    let schema = Schema([
      CatalogSourceRecord.self, CatalogRecipeRecord.self, CatalogCollectionRecord.self,
      CatalogJobRecord.self, CatalogOperationRecord.self, CatalogVersionRecord.self,
      CatalogPhoneRecipeRecord.self,
    ])
    let container = try ModelContainer(
      for: schema,
      configurations: [
        ModelConfiguration("FujiStudioLocal", schema: schema, url: store, cloudKitDatabase: .none)
      ])
    let context = ModelContext(container)
    context.autosaveEnabled = false
    return context
  }
  private func injectLegacyReport(_ data: Data) throws -> Data {
    let report = try oldReport()
    func visit(_ value: Any) -> Any {
      if let array = value as? [Any] { return array.map(visit) }
      if var object = value as? [String: Any] {
        for key in Array(object.keys) {
          object[key] = key == "effectiveRecipe" ? report : visit(object[key]!)
        }
        return object
      }
      return value
    }
    return try JSONSerialization.data(
      withJSONObject: visit(JSONSerialization.jsonObject(with: data)))
  }
  private func oldReport() throws -> [String: Any] {
    let url = try #require(
      Bundle(for: MigrationResourceBundle.self).url(
        forResource: "current-xt5", withExtension: "json"))
    return try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
  }
}
private final class MigrationResourceBundle: NSObject {}

private final class FailSecondUpgradeWritePolicy: CameraJournalFilePolicy, @unchecked Sendable {
  private let lock = NSLock()
  private var replacements = 0
  func createDirectory(at url: URL) throws {
    try IOSCameraJournalFilePolicy().createDirectory(at: url)
  }
  func write(_ data: Data, to url: URL, exclusive: Bool) throws {
    if url.lastPathComponent == "journal.json" {
      lock.lock()
      replacements += 1
      let fail = replacements == 2
      lock.unlock()
      if fail { throw CocoaError(.fileWriteUnknown) }
    }
    try IOSCameraJournalFilePolicy().write(data, to: url, exclusive: exclusive)
  }
}

private enum SimulatedUpgradeInterruption: Error, Equatable { case beforeCommit }
