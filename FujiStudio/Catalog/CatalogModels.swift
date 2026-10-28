import FujiCameraCore
import Foundation
import SwiftData

// Persistence-only records. No relationships cascade source removal into export history.
// The initial local schema stores lossless value payloads; it has no CloudKit configuration.
@Model final class CatalogSourceRecord {
    @Attribute(.unique) var sourceID: String
    var payload: Data
    var availability: String
    init(sourceID: String, payload: Data, availability: AssetAvailability = .available) {
        self.sourceID = sourceID
        self.payload = payload
        self.availability = availability.rawValue
    }
}

@Model final class CatalogRecipeRecord {
    @Attribute(.unique) var snapshotID: UUID
    var payload: Data
    init(snapshotID: UUID, payload: Data) { self.snapshotID = snapshotID; self.payload = payload }
}

@Model final class CatalogCollectionRecord {
    @Attribute(.unique) var key: String
    var snapshotIDs: Data
    init(snapshotIDs: Data) { key = "latest"; self.snapshotIDs = snapshotIDs }
}

@Model final class CatalogPhoneRecipeRecord {
    @Attribute(.unique) var sourceSnapshotID: UUID
    @Attribute(.unique) var snapshotID: UUID
    var savedAt: Date
    init(sourceSnapshotID: UUID, snapshotID: UUID) {
        self.sourceSnapshotID = sourceSnapshotID; self.snapshotID = snapshotID; savedAt = Date()
    }
}

@Model final class CatalogJobRecord {
    @Attribute(.unique) var jobID: UUID
    var submittedAt: Date
    var unfinished: Bool
    var payload: Data
    init(job: ExportJob, unfinished: Bool, payload: Data) {
        jobID = job.id; submittedAt = job.submittedAt
        self.unfinished = unfinished; self.payload = payload
    }
}

@Model final class CatalogOperationRecord {
    @Attribute(.unique) var operationID: UUID
    var jobID: UUID
    init(operationID: UUID, jobID: UUID) { self.operationID = operationID; self.jobID = jobID }
}

@Model final class CatalogVersionRecord {
    @Attribute(.unique) var operationID: UUID
    @Attribute(.unique) var versionID: UUID
    var sourceID: String
    var outputAssetID: String
    var exportedAt: Date
    var payload: Data
    init(version: SavedVersion, payload: Data) {
        operationID = version.operationID; versionID = version.id; sourceID = version.sourceID
        outputAssetID = version.outputAssetID; exportedAt = version.exportedAt; self.payload = payload
    }
}
