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
        if let current = formats.first, current.version == 2 { return }
        guard formats.count <= 1, formats.first?.version ?? 1 == 1 else { throw CatalogError.durableFailure("Unsupported catalog payload version") }
        var updates: [() -> Void] = []
        var backup: [String: Data] = [:]
        func prepare<T: Decodable>(_ payload: Data, as type: T.Type) throws -> Data {
            let converted = try RecipePayloadUpgrade.convert(payload)
            _ = try JSONDecoder().decode(type, from: converted)
            return converted
        }
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
        if !backup.isEmpty {
            // Keep the recovery artifact private, outside the database. Existing backups are never overwritten.
            let url=storeURL.appendingPathExtension("payload-v1-backup.json")
            if !FileManager.default.fileExists(atPath:url.path) {
                try IOSCameraJournalFilePolicy().write(JSONEncoder().encode(backup),to:url,exclusive:true)
                let file=try FileHandle(forWritingTo:url);try file.synchronize();try file.close()
            }
        }
        do {
            try context.transaction {
                updates.forEach { $0() }
                if let current=formats.first { current.version=2 }
                else { context.insert(CatalogFormatRecord(version:2)) }
                try context.save()
            }
        } catch { context.rollback();throw error }
    }
}
