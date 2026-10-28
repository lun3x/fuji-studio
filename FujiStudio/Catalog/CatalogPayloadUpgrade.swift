import Foundation
import SwiftData
import FujiCameraCore

/// Prepare and validate every affected payload before the single database commit.
/// Historical decoding is confined to this one-way storage-open operation.
struct CatalogPayloadUpgrade {
    let context: ModelContext
    let storeURL: URL
    func runIfNeeded() throws {
        let formats = try context.fetch(FetchDescriptor<CatalogFormatRecord>())
        if let current = formats.first, current.version == 3 { return }
        let version=formats.first?.version ?? 1
        guard formats.count <= 1, [1,2].contains(version) else { throw CatalogError.durableFailure("Unsupported catalog payload version") }
        var updates: [() -> Void] = []
        var backup: [String: Data] = [:]
        func prepare<T: Decodable>(_ payload: Data, as type: T.Type) throws -> Data {
            let converted = try RecipePayloadUpgrade.convert(payload)
            _ = try JSONDecoder().decode(type, from: converted)
            return converted
        }
        if version == 1 {
        for record in try context.fetch(FetchDescriptor<CatalogSourceRecord>()) {
            let data=try prepare(record.payload,as:PhotoSource.self)
            backup["source/\(record.sourceID)"]=record.payload; updates.append { record.payload=data }
        }
        for record in try context.fetch(FetchDescriptor<CatalogRecipeRecord>()) {
            let data=try prepare(record.payload,as:RecipeSnapshot.self)
            backup["recipe/\(record.snapshotID)"]=record.payload; updates.append { record.payload=data }
        }
        for record in try context.fetch(FetchDescriptor<CatalogJobRecord>()) {
            let data=try prepare(record.payload,as:ExportJob.self)
            backup["job/\(record.jobID)"]=record.payload; updates.append { record.payload=data }
        }
        for record in try context.fetch(FetchDescriptor<CatalogVersionRecord>()) {
            let data=try prepare(record.payload,as:SavedVersion.self)
            backup["version/\(record.versionID)"]=record.payload; updates.append { record.payload=data }
        }
        }
        let recipeRecords=try context.fetch(FetchDescriptor<CatalogRecipeRecord>())
        for record in try context.fetch(FetchDescriptor<CatalogCollectionRecord>()) {
            let ids=try JSONDecoder().decode([UUID].self,from:record.snapshotIDs)
            let recipes=try ids.map { id -> RecipeSnapshot in
                guard let recipe=recipeRecords.first(where:{ $0.snapshotID == id }) else { throw CatalogError.invalidRecipeCollection }
                return try JSONDecoder().decode(RecipeSnapshot.self,from:version == 1 ? RecipePayloadUpgrade.convert(recipe.payload) : recipe.payload)
            }
            guard let first=recipes.first?.cameraContext,recipes.allSatisfy({ $0.cameraContext == first && !$0.isPhoneRecipe }) else { throw CatalogError.invalidRecipeCollection }
            let codecs=RecipeCodecRegistry(),capabilities=try codecs.capabilities(for:first)
            guard recipes.count == capabilities.bankSlots.count,Set(recipes.map(\.slot)) == Set(capabilities.bankSlots.map(\.id)),Set(ids).count == ids.count else { throw CatalogError.invalidRecipeCollection }
            let execution=CameraExecutionContext(model:first.model,firmware:first.firmware,capability:first.capability,supportVersion:try codecs.supportVersion(for:first),sessionIdentity:first.sessionIdentity,generation:first.sessionGeneration)
            let declaration=try JSONEncoder().encode(RecipeCollectionDeclaration(slots:capabilities.bankSlots,context:execution))
            backup["collection/\(record.key)"]=record.snapshotIDs
            updates.append { record.declaration=declaration }
        }
        if !backup.isEmpty {
            // Keep the recovery artifact private, outside the database. Existing backups are never overwritten.
            let url=storeURL.appendingPathExtension("payload-v\(version)-backup.json")
            if !FileManager.default.fileExists(atPath:url.path) {
                try IOSCameraJournalFilePolicy().write(JSONEncoder().encode(backup),to:url,exclusive:true)
                let file=try FileHandle(forWritingTo:url);try file.synchronize();try file.close()
            }
        }
        do {
            try context.transaction {
                updates.forEach { $0() }
                if let current=formats.first { current.version=3 }
                else { context.insert(CatalogFormatRecord(version:3)) }
                try context.save()
            }
        } catch { context.rollback();throw error }
    }
}
