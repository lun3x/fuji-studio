import Foundation
import SwiftData
import Testing
@testable import FujiCameraCore
@testable import FujiStudio

@MainActor struct CatalogPayloadUpgradeTests {
    @Test func currentPayloadUpgradePreservesFrozenHistory() async throws {
        let f = try RenderFixture()
        let store = f.root.appendingPathComponent("migration.store")
        let context = try legacyContext(at: store)
        let version = SavedVersion(id:UUID(),sourceID:f.source.id,outputAssetID:"photos/asset-42",recipeSnapshot:f.recipe,operationID:UUID(),exportedAt:Date(timeIntervalSince1970:1000),jpeg:try f.jpeg(),availability:.available)
        var payload = try #require(JSONSerialization.jsonObject(with:JSONEncoder().encode(version)) as? [String:Any])
        var jpeg = try #require(payload["jpeg"] as? [String:Any])
        let legacy = try oldReport()
        jpeg["effectiveRecipe"] = legacy; payload["jpeg"] = jpeg
        context.insert(CatalogVersionRecord(version:version,payload:try JSONSerialization.data(withJSONObject:payload)))
        let copied = f.recipe.copiedToPhone()
        context.insert(CatalogRecipeRecord(snapshotID:copied.snapshot.id,payload:try JSONEncoder().encode(copied.snapshot)))
        context.insert(CatalogPhoneRecipeRecord(sourceSnapshotID:copied.id,snapshotID:copied.snapshot.id))
        let pending = PendingSave(operationID: UUID(), jpeg: version.jpeg, placeholderID: "photos/pending-17", submission: .unknown(at: Date(timeIntervalSince1970:1234)))
        let job = ExportJob(id: UUID(), submittedAt: Date(timeIntervalSince1970:1000), recipeSnapshot:f.recipe, items:[ExportItem(source:f.source,operationID:pending.operationID,state:.unresolved(pending))], state:.unresolved)
        context.insert(CatalogJobRecord(job:job, unfinished:true, payload:try injectLegacyReport(JSONEncoder().encode(job))))
        try context.save()
        let reopened = try SwiftDataCatalog(storeURL:store)
        let saved = try #require(try await reopened.versions(sourceID:f.source.id).first)
        #expect(saved.id == version.id && saved.operationID == version.operationID)
        #expect(saved.outputAssetID == "photos/asset-42")
        #expect(saved.recipeSnapshot == f.recipe)
        #expect(saved.jpeg.settingsDigest == version.jpeg.settingsDigest)
        #expect(saved.jpeg.effectiveRecipe.requested.film == .classicChrome)
        #expect(try await reopened.phoneRecipes().first?.id == copied.id)
        #expect(try await reopened.phoneRecipes().first?.snapshot.id == copied.snapshot.id)
        let retainedJob = try await reopened.job(id:job.id)
        #expect(retainedJob.recipeSnapshot == f.recipe)
        guard case .unresolved(let retainedPending) = retainedJob.items[0].state else { Issue.record("Uncertainty must survive upgrade"); return }
        #expect(retainedPending.operationID == pending.operationID)
        #expect(retainedPending.placeholderID == "photos/pending-17")
        #expect(retainedPending.submission == pending.submission)
    }
    @Test func failedUpgradeLeavesOriginalReadable() throws {
        let f = try RenderFixture(), store=f.root.appendingPathComponent("failure.store")
        let context=try legacyContext(at: store)
        let original=Data([0])
        context.insert(CatalogRecipeRecord(snapshotID:UUID(),payload:original))
        try context.save()
        #expect(throws:(any Error).self) { _ = try SwiftDataCatalog(storeURL:store) }
        #expect(try context.fetch(FetchDescriptor<CatalogRecipeRecord>()).first?.payload == original)
        #expect(try context.fetch(FetchDescriptor<CatalogRecipeRecord>()).count == 1)
    }
    @Test func interruptedUpgradeRetriesWithoutSideEffects() throws {
        let f=try RenderFixture();defer { f.remove() }
        let directory=f.root.appendingPathComponent("journal")
        let journal=try CameraOperationJournal(directory:directory,filePolicy:IOSCameraJournalFilePolicy())
        var record=try journal.create(raw:f.raw,recipe:f.recipe,context:f.context)
        record.phase = .captured;record.outputValidated=true;record.outputHandle=31;record.outputSHA256="hash";record.objectInfo=Data([1]);record.storageInfo=Data([2])
        try journal.save(record);try journal.beginDelete(&record)
        let marker=journal.operationDirectory(record.id).appendingPathComponent("delete-intent.json")
        let intent=try Data(contentsOf:marker)
        record.result = try f.jpeg(); record.phase = .completed;record.deleteAcknowledged=true;record.emptyViewVerified=true
        try journal.save(record)
        let journalURL=journal.operationDirectory(record.id).appendingPathComponent("journal.json")
        try injectLegacyReport(Data(contentsOf:journalURL)).write(to:journalURL,options:.atomic)
        let reopened=try CameraOperationJournal(directory:directory,filePolicy:IOSCameraJournalFilePolicy())
        var loaded=try reopened.load(record.id)
        #expect(loaded.result?.settingsDigest == record.result?.settingsDigest)
        #expect(loaded.result?.effectiveRecipe.requested.grain == GrainSettings(strength:.off,size:.large))
        #expect(try Data(contentsOf:marker) == intent)
        #expect(throws:CameraServiceError.uncertainOperation(record.id)) { try reopened.beginDelete(&loaded) }
        let converted=try Data(contentsOf:journalURL)
        _ = try CameraOperationJournal(directory:directory,filePolicy:IOSCameraJournalFilePolicy())
        #expect(try Data(contentsOf:journalURL) == converted)
        #expect(try reopened.unresolved().isEmpty)
    }
    private func legacyContext(at store: URL) throws -> ModelContext {
        let schema=Schema([CatalogSourceRecord.self,CatalogRecipeRecord.self,CatalogCollectionRecord.self,CatalogJobRecord.self,CatalogOperationRecord.self,CatalogVersionRecord.self,CatalogPhoneRecipeRecord.self])
        let container=try ModelContainer(for:schema,configurations:[ModelConfiguration("FujiStudioLocal",schema:schema,url:store,cloudKitDatabase:.none)])
        let context=ModelContext(container);context.autosaveEnabled=false;return context
    }
    private func injectLegacyReport(_ data: Data) throws -> Data {
        let report=try oldReport()
        func visit(_ value: Any) -> Any {
            if let array=value as? [Any] { return array.map(visit) }
            if var object=value as? [String:Any] {
                for key in Array(object.keys) { object[key] = key == "effectiveRecipe" ? report : visit(object[key]!) }
                return object
            }
            return value
        }
        return try JSONSerialization.data(withJSONObject:visit(JSONSerialization.jsonObject(with:data)))
    }
    private func oldReport() throws -> [String:Any] {
        let url=try #require(Bundle(for:MigrationResourceBundle.self).url(forResource:"current-xt5",withExtension:"json"))
        return try #require(JSONSerialization.jsonObject(with:Data(contentsOf:url)) as? [String:Any])
    }
}
private final class MigrationResourceBundle: NSObject {}
